-- A narrowly scoped experiment for the local hunter's f_arm279 material.
local base = "player/mod/f/pl279/f_arm279"
local original = base .. ".mdf2"
local data = "MHRS-Files-HotReload/"
local mesh_type = sdk.typeof("via.render.Mesh")
local interval, last_id = 0, nil
local saved, owner

local function arm()
    local manager = sdk.get_managed_singleton("snow.player.PlayerManager")
    local player = manager and manager:call("findMasterPlayer")
    local root = player and player:call("get_GameObject"):call("get_Transform")
    assert(root, "Local hunter unavailable")
    local child = root:call("get_Child")
    local parts = {}
    while child do
        local obj = child:call("get_GameObject")
        local name = obj:call("get_Name")
        if name == "f_arm279" then
            return assert(obj:call("getComponent(System.Type)", mesh_type), "Arm mesh unavailable")
        end
        if name:find("_arm") then parts[#parts + 1] = name end
        child = child:call("get_Next")
    end
    error("Target arm unavailable. Other arms: " .. table.concat(parts, ", "))
end

local function inspect(mesh)
    local holder = assert(mesh:call("get_Material"), "No material holder")
    local path = holder:call("get_ResourcePath")
    local result = {mesh = tostring(mesh:get_address()), path = path, ready = mesh:call("get_MaterialReady"), slots = {}}
    if not result.ready then return result end
    for i = 0, mesh:call("get_MaterialNum") - 1 do
        local slot = {name = mesh:call("getMaterialName", i), enabled = mesh:call("getMaterialsEnable", i)}
        for j = 0, mesh:call("getMaterialVariableNum", i) - 1 do
            local name = mesh:call("getMaterialVariableName", i, j)
            if name == "S_col_R" or name == "moon_RimColor" then
                local c = mesh:call("getMaterialFloat4", i, j)
                slot[name] = {c.x, c.y, c.z, c.w}
            end
        end
        result.slots[#result.slots + 1] = slot
    end
    return result
end

local function normalized(path)
    return (path or ""):lower():gsub("\\", "/"):gsub("^@", "")
end

local function run(action)
    local mesh = arm()
    if action == "inspect" then return inspect(mesh) end
    assert(action == "same" or action == "restore", "Unknown action")
    local before = inspect(mesh)
    local bound = normalized(before.path)
    assert(bound == original, "Unexpected material: " .. tostring(before.path))
    if owner ~= before.mesh then saved, owner = nil, before.mesh end
    if not saved then
        assert(bound == original, "Original holder unavailable")
        saved = mesh:call("get_Material")
    end
    if action == "restore" then
        mesh:call("set_Material", saved)
        saved, owner = nil, nil
        return {before = before}
    end
    local path = original
    local res = assert(sdk.create_resource("via.render.MeshMaterialResource", path), "Resource unavailable")
    local holder = assert(res:create_holder("via.render.MeshMaterialResourceHolder"), "Holder unavailable")
    assert(normalized(holder:call("get_ResourcePath")) == path, "Resource path mismatch")
    mesh:call("set_Material", holder)
    return {before = before, requested = path, resource = tostring(res:get_address())}
end

-- A request is executed once per id. The host requests another independent sample
-- after the engine has had time to finish rendering with the assigned holder.
local initial = json.load_file(data .. "request.json")
last_id = initial and initial.id
json.dump_file(data .. "status.json", {state = "loaded"})
re.on_application_entry("UpdateBehavior", function()
    if os.clock() < interval then return end
    interval = os.clock() + 0.25
    local req = json.load_file(data .. "request.json")
    if not req or type(req.id) ~= "string" or req.id == last_id then return end
    last_id = req.id
    local ok, value = pcall(run, req.action)
    json.dump_file(data .. "status.json", {id = req.id, action = req.action, ok = ok, result = ok and value or tostring(value)})
end)
