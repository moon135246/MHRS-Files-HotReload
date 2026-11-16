-- Let the installed Lua Bone System select the active part and apply its own
-- offsets, at its own animation phase. We only expire its file/selection caches.
local M = {}
local dir = "MHRS-Files-HotReload/"
local function read(name)
    local f = io.open(dir .. name, "rb")
    if not f then return end
    local raw = f:read("*a")
    f:close()
    return raw
end

local function locals_of(fn)
    local vars = {}
    for i = 1, 255 do
        local name, value = debug.getupvalue(fn, i)
        if not name then break end
        vars[name] = value
    end
    return vars
end

local function identify(cb)
    if type(cb) ~= "function" then return end
    local source = (debug.getinfo(cb, "S").source or ""):lower():gsub("\\", "/")
    if not (source:match("/autorun/luabonesystem%.lua$") or source == "@luabonesystem.lua") then return end
    local u = locals_of(cb)
    if u.custom_dir ~= "LUABoneSystem/custom/" or type(u.old_players_parts) ~= "table"
        or type(u.import_joint_data) ~= "table" or type(u.player_joint) ~= "table"
        or type(u.set_joint) ~= "function" then return end
    local s = locals_of(u.set_joint)
    if s.import_joint_data ~= u.import_joint_data or s.player_joint ~= u.player_joint then return end
    return {parts=u.old_players_parts, imports=u.import_joint_data, selected=u.player_joint,
            ik=s.ik_initialized, pending=s.ik_pending}
end

local function same_map(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k,v in pairs(a) do if b[k] ~= v then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local default_offset = {x=0,y=0,z=0}
local sparse = {__index=function() return default_offset end}

local function actor_transforms(affected)
    local prefixes = {}
    local m = sdk.get_managed_singleton("snow.player.PlayerManager")
    local players = m and m:get_field("PlayerList")
    if players then
        for _,player in pairs(players) do
            local ok, p = pcall(function()
                if not affected[player:call("getPlayerIndex")] then return end
                return tostring(player:call("get_GameObject"):call("get_Transform"):get_address())..":"
            end)
            if ok and p then prefixes[p] = true end
        end
    end
    return prefixes
end

local function apply(o, previous, head)
    if type(head) ~= "table" or head.version ~= 1 or type(head.session) ~= "string"
        or type(head.profiles) ~= "table" then return end
    local hashes, changed = head.profiles, {}
    for k,v in pairs(hashes) do if previous[k] ~= v then changed[k] = true end end
    for k in pairs(previous) do if not hashes[k] then changed[k] = true end end
    for name in pairs(o.imports) do
        local key = name:lower()
        if not hashes[key] then changed[key] = true end
    end
    if not next(changed) then return hashes end

    local raw = read("bone-profile-data.json")
    local data = raw and json.load_string(raw)
    if type(data) ~= "table" or data.session ~= head.session or not same_map(data.profiles, hashes)
       or type(data.values) ~= "table" then return end -- a newer generation is being published
    local values = {}
    for k in pairs(changed) do
        if hashes[k] then
            local profile = data.values[hashes[k]]
            if type(profile) ~= "table" or not next(profile) then return end
            values[k] = setmetatable(profile, sparse)
        end
    end

    local affected, aliases = {}, {}
    for index, name in pairs(o.selected) do
        if changed[name:lower()] then affected[index] = true end
    end
    for index, slots in pairs(o.parts) do
        for _, obj in pairs(slots) do
            local ok, name = pcall(function() return obj:get_Name() end)
            if ok and type(name) == "string" and changed[name:lower()] then
                affected[index], aliases[name] = true, name:lower()
            end
        end
    end
    for name in pairs(o.imports) do
        if changed[name:lower()] then aliases[name] = name:lower() end
    end
    for k in pairs(changed) do o.imports[k] = values[k] end
    for name,k in pairs(aliases) do o.imports[name] = values[k] end

    local count = 0
    if type(o.ik) == "table" and type(o.pending) == "table" and next(affected) then
        -- The v2 owner caches its leg-length initialization by transform and
        -- profile NAME. A content change with the same name must warm up again.
        local ok, prefixes = pcall(actor_transforms, affected)
        if not ok then prefixes = {} end
        for index in pairs(affected) do
            local old = o.ik[index]
            if type(old) == "string" then prefixes[old:match("^[^:]+:") or old] = true end
            o.ik[index] = nil
        end
        for key in pairs(o.pending) do
            if type(key) == "string" and prefixes[key:match("^[^:]+:")] then o.pending[key] = nil end
        end
    end
    for index in pairs(affected) do
        o.parts[index], o.selected[index] = nil, nil
        count = count + 1
    end
    local names = {}
    for k in pairs(changed) do names[#names+1] = (hashes[k] and "+" or "-")..k end
    table.sort(names)
    log.info("[MHRS-Files-HotReload] Lua Bone System profiles: "..table.concat(names,", ")..
             "; refreshing "..count.." hunter(s)")
    return hashes
end

function M.install(pid)
    if not (debug and debug.getinfo and debug.getupvalue) then
        log.warn("[MHRS-Files-HotReload] Lua Bone System bridge: debug API unavailable")
        return
    end
    local owner, next_check, previous = nil, 0, {}
    -- The embedded watcher is shared across Lua state resets. Accept an
    -- unchanged notice from *this* process when rebuilding the new owner's
    -- caches, but ignore artifacts left by a previous game process.
    local consumed = not pid and read("bone-profiles.json") or nil
    local collecting, originals, wrappers = true, {}, {}
    local function finish()
        collecting = false
        for name,wrapped in pairs(wrappers) do
            if re[name] == wrapped then re[name] = originals[name] end
        end
    end
    re.on_frame(function()
        if collecting then finish() end -- all autoruns have now registered
        local now = os.clock()
        if not owner or now < next_check then return end
        next_check = now + 0.5
        local raw = read("bone-profiles.json")
        if raw and raw ~= consumed then
            local ok, hashes = pcall(function()
                local head = json.load_string(raw)
                if not head or (pid and head.pid ~= pid) then return end
                return apply(owner, previous, head)
            end)
            if ok and hashes then previous, consumed = hashes, raw end
        end
    end)
    local function observe(name, phase)
        local register = re[name]
        if type(register) ~= "function" then return end
        originals[name] = register
        wrappers[name] = function(event, cb, ...)
            if collecting and event == phase then
                local ok, candidate = pcall(identify, cb)
                if ok and candidate then
                    owner = candidate
                    finish()
                    log.info("[MHRS-Files-HotReload] Connected to unmodified Lua Bone System: "..phase)
                end
            end
            return register(event, cb, ...)
        end
        re[name] = wrappers[name]
    end
    observe("on_application_entry", "UpdateMotion")
    observe("on_pre_application_entry", "PrepareRendering")
end

return M
