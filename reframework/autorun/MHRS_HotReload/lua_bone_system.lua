-- Let the installed Lua Bone System select the active part and apply its own
-- offsets at its own animation phase. Refresh its profile cache and supply
-- the rest positions of the wearer whose joints it is currently processing.
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
            ik=s.ik_initialized, pending=s.ik_pending, set_joint=u.set_joint,
            shadow=s.shadowmesh_data==u.shadowmesh_data and u.shadowmesh_data or nil,base=u.base_position_list}
end

local function same_map(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k,v in pairs(a) do if b[k] ~= v then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local default_offset = {x=0,y=0,z=0}
local sparse = {__index=function() return default_offset end}

-- The original owner caches the first instance's rest positions per sex.
-- A FirstNatives suit can give two hunters of the same sex different rests.
-- Cache actual rests by transform and shadow resource. The original set_joint
-- continues to choose and apply the profile, then runs its weapon and IK logic.
local verified_rests=setmetatable({},{__mode="k"})
function M.rest_changed(root) verified_rests[root]=(verified_rests[root] or 0)+1 end

local function install_rests(cb,o)
    if not debug.setupvalue or type(o.shadow)~="table" or type(o.base)~="table" then return false end
    local cache=setmetatable({},{__mode="k"})
    local mesh_type
    local reported={}
    local function offsets(go,sex,index)
        mesh_type=mesh_type or sdk.typeof("via.render.Mesh")
        local mesh=go:call("getComponent(System.Type)",mesh_type)
        if not mesh or not mesh:call("get_MeshReady") then return end
        local h=mesh:call("getMesh")
        local id=h and h:read_qword(0x10)
        local tr=go:call("get_Transform")
        if not tr or not id or id==0 then return end
        local entry=cache[tr]
        if entry and entry.id==id and entry.revision==verified_rests[go] and entry.sex==sex then return entry.rows end
        local path=h:call("get_ResourcePath"):lower():gsub("^@",""):gsub("\\","/")
        if not path:match("^player/mod/[fm]/[^/]+/[fm]_shadow%.mesh$") then return end
        local rows={}
        local base=o.base[sex]
        for _,j in pairs(tr:get_Joints()) do
            local name=j:get_Name()
            local b=base[name]
            if b then
                local p=j:call("get_BaseLocalPosition")
                rows[name]={x=p.x-b.x,y=p.y-b.y,z=p.z-b.z}
            else rows[name]=default_offset end
        end
        if not next(rows) then return end
        for name in pairs(base) do if not rows[name] then return rows end end
        cache[tr]={id=id,revision=verified_rests[go],sex=sex,rows=rows}
        if index~=nil and reported[index]~=id then
            reported[index]=id
            log.info("[MHRS-Files-HotReload] Lua Bone System sampled shadow rests for hunter "..index)
        end
        return rows
    end
    for i=1,255 do
        local name,fn=debug.getupvalue(cb,i)
        if not name then break end
        if name=="set_joint" and fn==o.set_joint then
            local function pose(go,sex,index,tree)
                local selected=o.selected[index]
                -- The owner's part_changed loop can see an empty slot list
                -- during re-entry and retain the preceding wearer's selection.
                if selected and o.parts[index] and not next(o.parts[index]) then
                    o.selected[index]=nil
                else
                    local profile=selected and o.imports[selected]
                    if type(profile)=="table" and not getmetatable(profile) then setmetatable(profile,sparse) end
                end
                local ok,rows=pcall(offsets,go,sex,index)
                if not ok or not rows then return fn(go,sex,index,tree) end
                local previous=o.shadow[sex]
                o.shadow[sex]=rows
                local applied,err=pcall(fn,go,sex,index,tree)
                o.shadow[sex]=previous
                if not applied then error(err,0) end
            end
            return debug.setupvalue(cb,i,pose)=="set_joint"
        end
    end
    return false
end

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
                    local rests=install_rests(cb,owner)
                    log.info("[MHRS-Files-HotReload] Connected to unmodified Lua Bone System: "..phase..
                        (rests and " (per-hunter rest positions)" or ""))
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
