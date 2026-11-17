-- Run once from REFramework's ScriptRunner after MHRS Files HotReload is loaded.
-- A session replaces reframework/data/MHRS-Files-HotReload/online-observations.json.
-- The tool UI can sample now, pause recording, or include the Head_00 joint.
-- Each row describes a local scene slot at the sampled time; indices can be reused.
local loaded, roster = pcall(require, "MHRS_HotReload.hunter_roster")
if not loaded or type(roster) ~= "table" or type(roster.read) ~= "function" then
    log.warn("[MHRS observer] Load MHRS Files HotReload before running this tool.")
    return
end
if rawget(_G, "MHRS_readonly_multiplayer_observer") then return end
_G.MHRS_readonly_multiplayer_observer = true

local output = "MHRS-Files-HotReload/online-observations.json"
local history = {}
local first_tick = os.clock()
local last_write, next_tick = -math.huge, 0
local last_scene, error_reported
local requested, paused, include_head = false, false, false
local roles = {master=true, peer=true, unconfirmed=true, follower=true}
local parts = {helm=true, body=true, arm=true, wst=true, leg=true}

local function read(object, method, ...)
    if not object then return end
    local ok, value = pcall(object.call, object, method, ...)
    if ok then return value end
end

local function integer(n)
    if type(n) == "number" and n >= -1 and n < 2147483648 and n % 1 == 0 then return n end
end

local function part_name(go)
    local name = read(go, "get_Name")
    if type(name) ~= "string" then return end
    local part = name:match("^[fm]_([a-z]+)%d%d?%d?%d?$")
    if parts[part] then return name end
end

local function material_name(name)
    if type(name) ~= "string" or #name == 0 or #name > 64 or name:find("[%c/\\]")
            or name:find("0[xX]%x%x%x%x") or name:find("%d%d%d%d%d%d%d%d%d%d")
            or name:find("%x%x%x%x%x%x%x%x%-%x%x%x%x%-") then return false end
    return name
end

local function part_state(slot, go)
    local part = {slot=slot, present=go ~= nil}
    if not go then return part end
    part.name = part_name(go)
    local mesh = read(go, "getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
    if read(mesh, "get_MaterialReady") == true then
        part.material_count = integer(read(mesh, "get_MaterialNum"))
        if part.material_count and part.material_count >= 0 then
            part.material_slots = {}
            for i=0,math.min(part.material_count, 32)-1 do
                part.material_slots[i+1] = material_name(read(mesh, "getMaterialName", i))
            end
        end
    end
    -- Restrict counts to the actual Chain attached to this equipped part object.
    local ok, chain = pcall(go.call, go, "getComponent(System.Type)", sdk.typeof("via.motion.Chain"))
    if ok then
        part.chain_attached = chain ~= nil
        if chain then
            part.resource_groups = integer(read(chain, "get_ResourceGroupCount"))
            if read(chain, "get_Setuped") == true then
                part.running_groups = integer(read(chain, "getGroupCount"))
            end
        end
    end
    return part
end

local function xyz(v)
    if not v then return end
    local result = {}
    for _, axis in ipairs({"x", "y", "z"}) do
        local n = v[axis]
        if type(n) ~= "number" or not (math.abs(n) < 10000) then return end
        result[axis] = math.floor(n * 1000000 + 0.5) / 1000000
    end
    return result
end

local function capture()
    local actors = roster.read()
    local scene = {status=integer(actors.status), actors={}, head_requested=include_head}
    if actors.status == 1 then
        scene.area = integer(read(sdk.get_managed_singleton("snow.VillageAreaManager"), "getCurrentAreaNo"))
    elseif actors.status == 2 then
        local quest = sdk.get_managed_singleton("snow.QuestManager")
        scene.quest = integer(read(quest, "getQuestNo"))
        scene.map = integer(read(quest, "getMapNo"))
    else
        return scene
    end
    for _, entry in ipairs(actors.entries) do
        if #scene.actors == 8 then scene.more_actors = true; break end
        local actor = {role=roles[entry.role] and entry.role or "unconfirmed",
            index=integer(entry.index), parts={}}
        for slot=0,4 do actor.parts[slot+1] = part_state(slot, entry.slots[slot]) end
        if include_head then
            local transform = read(entry.root, "get_Transform")
            local joint = read(transform, "getJointByName(System.String)", "Head_00")
            if joint then
                actor.head = {base=xyz(read(joint, "get_BaseLocalPosition")),
                    local_position=xyz(read(joint, "get_LocalPosition"))}
            end
        end
        scene.actors[#scene.actors+1] = actor
    end
    table.sort(scene.actors, function(a, b)
        if a.index == b.index then return a.role < b.role end
        return (a.index or -2) < (b.index or -2)
    end)
    return scene
end

-- Keep animation from generating a record at each poll. A changed rest position
-- still generates an observation and each recorded sample carries the current pose.
local function same(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for k, v in pairs(a) do
        if k ~= "local_position" and not same(v, b[k]) then return false end
    end
    for k in pairs(b) do if k ~= "local_position" and a[k] == nil then return false end end
    return true
end

re.on_frame(function()
    local now = os.clock()
    if (paused or now < next_tick) and not requested then return end
    local ok, scene = pcall(capture)
    next_tick = now + (ok and #scene.actors > 1 and 3 or 10)
    if not ok then
        requested = false
        if not error_reported then log.warn("[MHRS observer] Scene unavailable."); error_reported = true end
        return
    end
    local reason = requested and "requested" or not same(scene, last_scene) and "changed"
        or now - last_write >= 60 and "periodic"
    requested = false
    if not reason then return end
    local oldest = #history >= 48 and table.remove(history, 1)
    history[#history+1] = {elapsed_s=math.floor(now-first_tick), reason=reason, scene=scene}
    local wrote, result = pcall(json.dump_file, output, {version=1, samples=history})
    if wrote and result ~= false then
        last_write, last_scene, error_reported = now, scene, false
    else
        table.remove(history)
        if oldest then table.insert(history, 1, oldest) end
        if not error_reported then log.warn("[MHRS observer] Could not write observation file."); error_reported = true end
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("MHRS read-only multiplayer observations") then return end
    local changed, checked = imgui.checkbox("Record Head_00 base/local position", include_head)
    if changed then include_head, requested = checked, true end
    changed, checked = imgui.checkbox("Pause automatic observations", paused)
    if changed then paused = checked end
    if imgui.button("Sample current scene") then requested = true end
    imgui.tree_pop()
end)
