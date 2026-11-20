-- Run with Lua 5.4 from the project root. Exercise the actual batch entry
-- points in a scene with no instantiated armor or prefab.
package.path = "reframework/autorun/?.lua;" .. package.path
local tmp, open = {}, io.open
io.open = function(path, mode)
    if not path:match("^MHRS%-Files%-HotReload/") then return open(path, mode) end
    tmp[path] = tmp[path] or os.tmpname()
    return open(tmp[path], mode)
end
local function read(name)
    local file = assert(io.open("MHRS-Files-HotReload/" .. name, "rb"))
    local data = file:read("*a")
    file:close()
    return data
end
local function write(name, data)
    local file = assert(io.open("MHRS-Files-HotReload/" .. name, "wb"))
    assert(file:write(data))
    file:close()
end
local cache, created, uid = {}, {}, 0
local source = "First"
local clock,original_clock=0,os.clock
os.clock=function() return clock end
local fail_path
local function request(_, name)
    clock=clock+.0025
    local key = name:gsub("^@", "")
    if key==fail_path then return nil end
    if not cache[key] then
        uid = uid + 1
        local res = {id=uid, refs=0, source=source, platform=name:sub(1,1)=="@"}
        function res:get_address() return self.id end
        function res:release()
            self.refs = self.refs - 1
            assert(self.refs >= 0)
            if self.refs == 0 and cache[key] == self then cache[key] = nil end
        end
        cache[key] = res
        created[#created+1] = name
    end
    cache[key].refs = cache[key].refs + 1
    return cache[key]
end
re = {on_application_entry=function() end, on_script_reset=function() end}
json = {dump_file=function() end}
log = {info=function() end}
sdk = {
    hook=function() end, get_native_singleton=function() end,
    get_managed_singleton=function() end,
    call_native_func=function() return nil end, -- title screen, no scene
    find_type_definition=function() return {get_method=function() end, get_methods=function() return {} end} end,
    create_resource=request,
}
local outfit = require("MHRS_HotReload.outfit")
local function native(action)
    if action == "forget_batch" then
        local totals = {}
        for path in read("asset-paths.txt"):gmatch("[^\n]+") do
            totals[#totals+1] = cache[path] and "1" or "0"
            cache[path] = nil
        end
        write("retired-counts.txt", table.concat(totals,"\n") .. "\n")
        return "retired batch"
    end
    assert(action == "equipment_ready")
    local slots = {}
    for path in read("equipment-paths.txt"):gmatch("[^\n]+") do
        assert(not path:match("%.tex$"))
        if path:match("%.mdf2$") then
            slots[#slots+1] = path .. "\t" .. cache[path].id .. "\t" .. cache[path].source
        end
    end
    write("equipment-slots.txt",#slots>0 and table.concat(slots,"\n").."\n" or "")
    for path,ptr in read("equipment-platform.txt"):gmatch("([^\n\t]+)\t(%d+)\n") do
        assert(cache[path].platform and cache[path].id == tonumber(ptr))
    end
    return "ready"
end
local mesh, mdf, tex = "player/mod/demo.mesh", "player/mod/demo.mdf2", "player/mod/diffuse.tex"
local mixed = "player/mod/Diffuse.tex"
local function start_all()
    for _=1,8 do outfit.start_equipment_loads() end
end
local function batch(paths, options)
    options.paths = paths
    local result = outfit.run("asset_removed", options, native)
    if result.equipment then
        start_all()
        local done = outfit.run("asset_factories_ready", {}, native)
        assert(not done.pending)
        return done
    end
    return result
end
local paths = {mesh,mdf,tex}
local options = {paths=paths,platform_files=paths, aliases={[tex]={mixed}}, expected_materials={[mdf]={"First"}}}
assert(outfit.run("asset_removed",options,native).equipment and #created==0)
assert(outfit.run("asset_factories_ready",{},native).pending,"checked older readiness data")
outfit.start_equipment_loads()
assert(#created==2 and cache[mesh]==nil and cache[mdf]==nil,"resource creation did not yield")
assert(outfit.run("asset_factories_ready",{},native).pending,"polled a partial generation")
outfit.start_equipment_loads()
assert(not outfit.run("asset_factories_ready",{},native).pending)
assert(created[1]:match("%.tex$") and created[2]:match("%.tex$"))
assert(created[3] == "@"..mesh and created[4] == "@"..mdf)
local original = {}
for _,path in ipairs({mesh,mdf,tex,mixed}) do
    original[path] = cache[path]
    local ordinary = request(nil,path)
    assert(ordinary == original[path] and ordinary.platform)
    ordinary:release()
    assert(ordinary.refs == 1)
end

-- Strong ownership survives unrelated notifications and a missing scene.
batch({"standalone.tex"},{})
assert(cache[mdf] == original[mdf] and original[mdf].refs == 1)
source = "Second"
options.expected_materials[mdf]={"Second"}
batch(paths,options)
for path,previous in pairs(original) do
    assert(previous.refs == 0 and cache[path].source == "Second" and cache[path].refs == 1)
end
-- An old spelling must retire even if this batch no longer lists its alias.
batch({tex},{})
assert(not cache[tex] and not cache[mixed] and cache[mdf])
local remaining = cache[mesh]
outfit.reset(native)
assert(remaining.refs == 0 and not next(cache))

-- A loose MOT can arrive before the village, its factory or its playback
-- layer exists. A later normal request must find the same pinned platform key.
local idle_motion="stage/v01/a00/mod/v01a00_suisha01.mot"
batch({idle_motion},{platform_files={idle_motion}})
local cold_clip=cache[idle_motion]
assert(cold_clip and cold_clip.platform)
local playback=request("via.motion.MotionResource",idle_motion)
assert(playback==cold_clip)
playback:release()
batch({idle_motion},{})
assert(not next(cache) and cold_clip.refs==0)

source = "Wrong source"
local rejected = batch(paths,options)
assert(rejected.source_mismatch:find("Wrong source",1,true))
assert(not next(cache))

source="First"
options.expected_materials[mdf]={"First"}
assert(outfit.run("asset_removed",options,native).equipment)
outfit.start_equipment_loads()
assert(next(cache))
assert(not outfit.run("asset_equipment_abort",{},native).pending)
outfit.start_equipment_loads()
assert(not next(cache))

fail_path=mdf
assert(outfit.run("asset_removed",options,native).equipment)
start_all()
local started,load_error=pcall(outfit.run,"asset_factories_ready",{},native)
assert(not started and tostring(load_error):find(mdf,1,true) and not next(cache))
fail_path=nil

-- An actor built from the title-screen mesh can only enter the live batch
-- after its physics subtree has been inspected.
options.loose_equipment={mesh}
assert(not batch(paths,options).source_mismatch)
local observable=false
local go={get_address=function() return 811 end}
local transform={call=function(_,k)
    if k=="get_GameObject" then return go end
    assert(k=="get_Child")
end}
function go:call(k)
    if k=="get_Transform" then return observable and transform or nil end
    assert(k=="get_Update" or k=="get_Valid")
    return true
end
local function slot(name)
    local id=cache[name].id
    return {call=function(_,k) assert(k=="get_ResourcePath");return name end,read_qword=function() return id end}
end
local visible_mesh,visible_mdf=slot(mesh),slot(mdf)
local renderer={get_address=function() return 812 end}
function renderer:call(key)
    if key=="get_GameObject" then return go end
    if key=="getMesh" then return visible_mesh end
    if key=="get_Material" then return visible_mdf end
    if key=="get_MaterialReady" then return false end
    error("Unexpected mutation or query "..key)
end
sdk.typeof=function(t) return t end
local exists,has_chain=false,false
local hunter={call=function(_,k,slot)
    if k=="get_GameObject" or (k=="getPartsGameObject" and slot==0) then return go end
    if k=="isMasterPlayer" then return true end
    if k=="getPlayerIndex" then return 0 end
end}
sdk.get_managed_singleton=function(n)
    if n=="snow.player.PlayerManager" then return {get_field=function() end,call=function(_,k)
        if k=="findMasterPlayer" or k=="getPlayer" then return hunter end
        if k=="getMasterPlayerID" then return 0 end
    end} end
end
local chain={call=function(_,k) assert(k=="get_GameObject");return go end}
sdk.call_native_func=function() return {call=function(_,_,t)
    if t=="via.render.Mesh" then return {renderer} end
    return t=="via.motion.Chain" and has_chain and {chain} or {}
end} end
local rebuilds=0
package.loaded["MHRS_HotReload.village_equipment"]={
    worn_state=function() return {observed={}} end,
    capture=function(candidates) assert(candidates[812].go==go);return exists and {} or nil end,
    advance=function(tx)
        rebuilds=rebuilds+1
        assert(tx.resources[mesh]==cache[mesh])
        return rebuilds==1
    end,
}
source="Second";options.expected_materials[mdf]={"Second"}
local receipt=outfit.run("asset_removed",options,native)
assert(receipt.equipment_bindings==0 and #receipt.deferred_equipment==2)
start_all()
local result=outfit.run("asset_factories_ready",{},native)
assert(not result.pending and not result.source_mismatch and visible_mesh:read_qword(0x10)~=cache[mesh].id)
observable=true
local chain_free=outfit.run("asset_removed",options,native)
assert(chain_free.equipment_bindings==1 and not chain_free.deferred_equipment)
start_all()
assert(outfit.run("asset_factories_ready",{},native).pending)
has_chain=true
local safe,why=pcall(outfit.run,"asset_factories_ready",{},native)
assert(not safe and tostring(why):find("Hunter or physics changed",1,true))
assert(not outfit.run("asset_equipment_abort",{},native).pending)
exists,has_chain=true,true
local natural=outfit.run("asset_removed",options,native)
assert(natural.equipment_bindings==1 and not natural.deferred_equipment)
start_all()
assert(outfit.run("asset_factories_ready",{},native).pending)
assert(not outfit.run("asset_factories_ready",{},native).pending and rebuilds==2)
outfit.reset(native)

-- Scan large scenes in multiple updates without mutating the resource cache.
local current_scene={call=function() return {renderer,renderer} end}
sdk.call_native_func=function() return current_scene end
local get=renderer.call
renderer.call=function(self,key)
    if key=="get_MaterialReady" then clock=clock+.004 end
    return get(self,key)
end
local scan=assert(outfit.begin_texture_scan({paths={tex}}))
assert(not outfit.advance_texture_scan(scan) and scan.cursor==2)
assert(outfit.advance_texture_scan(scan))
scan=assert(outfit.begin_texture_scan({paths={tex}}))
assert(not outfit.advance_texture_scan(scan))
current_scene={}
local ok,reason=pcall(outfit.advance_texture_scan,scan)
assert(not ok and tostring(reason):find("Scene changed",1,true))

os.clock=original_clock
for _,path in pairs(tmp) do os.remove(path) end
print("Platform texture ordering, idle first use, replacement, removal, reset and source rejection passed")
