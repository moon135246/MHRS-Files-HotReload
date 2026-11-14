-- A narrowly scoped experiment for the local hunter's f_arm279 material.
local base = "player/mod/f/pl279/f_arm279"
local original = base .. ".mdf2"
local data = "MHRS-Files-HotReload/"
local mesh_type = sdk.typeof("via.render.Mesh")
local arm_mdf = require("MHRS_HotReload.arm_mdf")
local interval, last_id = 0, nil

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

local function diagnose(mesh)
    local methods = {}
    for _, name in ipairs({"via.ResourceManager", "via.ResourceHolder", "via.render.MeshMaterialResourceHolder",
        "via.render.MeshMaterialResource", "via.Resource", "via.render.Mesh", "via.io.file", "via.io.FileStream",
        "via.io.fileStream", "via.io.NativeFileStream", "via.io.Stream", "System.IO.File"}) do
        local td = sdk.find_type_definition(name)
        local names = {}
        if td then
            for _, method in ipairs(td:get_methods()) do
                local n = method:get_name()
                if name ~= "via.render.Mesh" or n:lower():find("reload") or n:find("Material") then
                    if name:find("^via%.io%.") then
                        local args = {}
                        for _, t in ipairs(method:get_param_types()) do args[#args + 1] = t:get_full_name() end
                        n = n .. "(" .. table.concat(args, ",") .. ")"
                    end
                    names[#names + 1] = n
                end
            end
        end
        methods[name] = {found = td ~= nil, methods = names}
    end
    local holder = mesh:call("get_Material")
    assert(normalized(holder:call("get_ResourcePath")) == original, "Unexpected target")
    local res = assert(sdk.create_resource("via.render.MeshMaterialResource", original))
    -- REFramework c4b13148: Resource::create_holder stores Resource* immediately
    -- after REManagedObject::runtime_size() (16 bytes on Rise).
    local bound = holder:read_qword(0x10)
    return {methods = methods, bound = tostring(bound), requested = tostring(res:get_address()),
        identical = bound == res:get_address()}
end

local function run(action)
    local mesh = arm()
    if action == "inspect" then return inspect(mesh) end
    if action == "diagnose" then return diagnose(mesh) end
    local before = inspect(mesh)
    local bound = normalized(before.path)
    assert(bound == original, "Unexpected material: " .. tostring(before.path))
    assert(before.ready, "Arm material not ready")
    if action == "capture" then return arm_mdf.begin(mesh, before) end
    if action == "refresh" then return arm_mdf.refresh(mesh, before) end
    assert(action == "request_same", "Unknown action")
    local path = original
    local res = assert(sdk.create_resource("via.render.MeshMaterialResource", path), "Resource unavailable")
    return {before = before, requested = path, resource = tostring(res:get_address())}
end

local queued, feedback
re.on_draw_ui(function()
    if not imgui.tree_node("MHRS Files HotReload") then return end
    if imgui.button("Capture f_arm279 before editing") then queued = "capture" end
    if imgui.button("Read MDF and refresh arm colors") then queued = "refresh" end
    if feedback then imgui.text(feedback) end
    imgui.tree_pop()
end)

-- A request is executed once per id. The host requests another independent sample
-- after the engine has had time to finish rendering with the assigned holder.
local initial = json.load_file(data .. "request.json")
last_id = initial and initial.id
json.dump_file(data .. "status.json", {state = "loaded"})
re.on_application_entry("UpdateBehavior", function()
    if queued then
        local action = queued
        queued = nil
        local ok, value = pcall(run, action)
        feedback = ok and (action == "capture" and ("Captured: " .. value.bindings)
            or ("Updated: " .. value.changed)) or tostring(value)
    end
    if os.clock() < interval then return end
    interval = os.clock() + 0.25
    local req = json.load_file(data .. "request.json")
    if not req or type(req.id) ~= "string" or req.id == last_id then return end
    last_id = req.id
    local ok, value = pcall(run, req.action)
    json.dump_file(data .. "status.json", {id = req.id, action = req.action, ok = ok, result = ok and value or tostring(value)})
end)
