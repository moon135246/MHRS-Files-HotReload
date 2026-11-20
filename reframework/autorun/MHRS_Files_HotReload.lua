-- Dispatch path-based hot reloads and the legacy f_arm279 command-line diagnostics.
local base = "player/mod/f/pl279/f_arm279"
local original = base .. ".mdf2"
local data = "MHRS-Files-HotReload/"
local mesh_type = sdk.typeof("via.render.Mesh")
local arm_mdf = require("MHRS_HotReload.arm_mdf")
local outfit = require("MHRS_HotReload.outfit")
local game_update = require("MHRS_HotReload.game_update")
local next_read, next_reconcile, dirty, last_id = 0, 0, false, nil

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

-- The plugin supplies its own functions when running this chunk in REFramework.
-- Source installs resolve the same functions from their development binaries.
local embedded = ...
if type(embedded) ~= "table" then embedded = nil end
require("MHRS_HotReload.lua_bone_system").install(embedded and embedded.process_id)
require("MHRS_HotReload.village_equipment").install(embedded and embedded.process_id)
local native_lib = embedded or {}
local dll_dir = "reframework/data/MHRS-Files-HotReload/"
local runtime_dll = dll_dir .. "mhrs_hotreload.dll"
local combined_watch = embedded and embedded.request_changed or package.loadlib(runtime_dll, "mhrs_request_changed")
-- Older source installations can still load the original two modules.
local material_dll = combined_watch and runtime_dll or dll_dir .. "arm_material.dll"
local watch_dll = combined_watch and runtime_dll or dll_dir .. "request_watch.dll"
local native_job
local function native(action)
    if not native_lib[action] then
        native_lib[action] = assert(package.loadlib(material_dll, "mhrs_" .. action))
    end
    native_lib[action]()
    local f = assert(io.open(data .. "native-state.txt", "r"))
    local state, address = f:read("*l"), f:read("*l")
    f:close()
    return state, address
end

local function textures(mesh)
    local holder = mesh:call("get_Material")
    local result = {path=holder:call("get_ResourcePath"), mesh=tostring(mesh:get_address()),
        resource=tostring(holder:read_qword(0x10)), ready=mesh:call("get_MaterialReady"), slots={}}
    if not result.ready then return result end
    for i=0, mesh:call("get_MaterialNum")-1 do
        local slot = {name=mesh:call("getMaterialName",i), enabled=mesh:call("getMaterialsEnable",i), textures={}}
        for j=0, mesh:call("getMaterialTextureNum",i)-1 do
            local name = mesh:call("getMaterialTextureName",i,j)
            local tex = mesh:call("getMaterialTexture",i,j)
            if name and tex then slot.textures[name]=tex:call("get_ResourcePath") end
        end
        result.slots[#result.slots+1]=slot
    end
    return result
end

local function native_action(action, mesh)
    if action == "native_poll" then
        local state,address=native("poll")
        return {state=state,address=address}
    end
    if action == "native_begin" then
        assert(not native_job, "Reload already pending")
        local prior=textures(mesh)
        assert(prior.ready and normalized(prior.path)==original and #prior.slots>0,"Arm not ready")
        local state,address=native("begin")
        assert(state=="pending",state)
        native_job={mesh=prior.mesh, prior=prior.resource, fresh=address, slots=prior.slots}
        return {state=state,address=address,prior=prior}
    end
    if action=="native_abort" then
        local state=native("abort")
        if state=="rolled back" or state=="no active transaction" then native_job=nil end
        return {state=state}
    end
    assert(action=="native_bind" and native_job, "No pending reload")
    local state,address=native("poll")
    assert(state=="ready" and address==native_job.fresh,"MDF or its dependencies not ready")
    local prior=mesh:call("get_Material")
    assert(tostring(mesh:get_address())==native_job.mesh and tostring(prior:read_qword(0x10))==native_job.prior,
        "Equipped mesh or binding changed")
    local resource=assert(sdk.create_resource("via.render.MeshMaterialResource",original))
    assert(tostring(resource:get_address())==address,"Resource manager returned another object")
    local holder=assert(resource:create_holder("via.render.MeshMaterialResourceHolder"))
    resource:release() -- balance create_resource; holder and transaction retain their own references
    mesh:call("set_Material(via.render.MeshMaterialResourceHolder)",holder)
    assert(tostring(mesh:call("get_Material"):read_qword(0x10))==address,"Mesh did not bind new MDF")
    local committed=native("commit")
    assert(committed=="committed",committed)
    local switches={}
    for _,s in ipairs(native_job.slots) do switches[s.name]=s.enabled end
    native_job=nil
    if mesh:call("get_MaterialReady") then
        for i=0,mesh:call("get_MaterialNum")-1 do
            local enabled=switches[mesh:call("getMaterialName",i)]
            if enabled~=nil and mesh:call("getMaterialsEnable",i)~=enabled then mesh:call("setMaterialsEnable",i,enabled) end
        end
    end
    return {state=committed,resource=address}
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

local function run(action,req,texture_owners)
    if action:sub(1,6)=="asset_" then
        assert(not native_job,"Arm material transaction active")
        return outfit.run(action,req,native,texture_owners)
    end
    if action:sub(1,7)=="native_" then assert(not outfit.active(),"Outfit transaction active") end
    if action=="native_abort" then return native_action(action) end
    local mesh = arm()
    if action=="textures" then return textures(mesh) end
    if action:sub(1,7)=="native_" then return native_action(action,mesh) end
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

local request_changed=combined_watch or package.loadlib(watch_dll,"mhrs_request_changed")
local close_request_watch=embedded and embedded.close_request_watch or package.loadlib(watch_dll,"mhrs_close_request_watch")
if request_changed then request_changed(true) end
re.on_script_reset(function()
    if close_request_watch then close_request_watch() end
    if native_job then native_action("native_abort") end
    outfit.reset(native)
end)
-- A request is executed once per id. The host requests another independent sample
-- after the engine has had time to finish rendering with the assigned holder.
local function read_request()
    local f = io.open(data .. "request.json", "rb")
    if not f then return end
    local raw = f:read("*a")
    f:close()
    if not raw or raw == "" then return end
    local ok, request = pcall(json.load_string, raw)
    if ok and type(request) == "table" and type(request.id) == "string" and type(request.action) == "string" then
        return request
    end
end
local initial = read_request()
last_id = initial and initial.id
json.dump_file(data .. "status.json", {state = "loaded"})
local start_watcher = embedded and embedded.start_watcher or package.loadlib(watch_dll, "mhrs_start_watcher")
if not (start_watcher and start_watcher(true)) then
    log.warn("[MHRS-Files-HotReload] Packaged watcher unavailable. Check the installation or run tools/watch_outfit.py from source.")
end
local removal
local function reply(req,ok,value)
    json.dump_file(data .. "status.json", {id = req.id, action = req.action, ok = ok, result = ok and value or tostring(value)})
end
local function resume_removal()
    local ok,owners=pcall(outfit.advance_texture_scan,removal.scan)
    if ok and not owners then return end
    local req=removal.request
    removal=nil
    local current=read_request()
    if not current or current.id~=req.id then
        next_reconcile=0 -- Recheck the mailbox on the next update.
        return
    end
    last_id=req.id
    local value=owners
    if ok then ok,value=pcall(run,req.action,req,owners) end
    reply(req,ok,value)
end
game_update.register(function()
    outfit.start_equipment_loads()
    if removal then resume_removal();return end
    local now = os.clock()
    -- Probe the already armed event each update. Leave disk reads to actual
    -- notifications, with a periodic check for missed events or older hosts.
    if request_changed and request_changed(true) then dirty = true end
    if now < next_read or (not dirty and now < next_reconcile) then return end
    local notified = dirty
    dirty = false
    next_reconcile = now + (request_changed and 1 or 0.25)
    local req = read_request()
    if not req or req.id == last_id then
        next_read = now + 0.025
        -- A notification can arrive while an editor still has the request
        -- open. Give that read one prompt retry even without another signal.
        if not req and notified then next_reconcile = now + 0.05 end
        return
    end
    if req.action=="asset_removed" then
        local ok,scan=pcall(outfit.begin_texture_scan,req)
        if ok and scan then
            removal={request=req,scan=scan}
            resume_removal()
            return
        end
    end
    last_id = req.id
    local ok, value = pcall(run, req.action, req)
    reply(req,ok,value)
end)
