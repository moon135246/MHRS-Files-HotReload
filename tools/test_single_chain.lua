-- Exercise the standalone CHAIN transaction without a mesh change.
package.path="reframework/autorun/?.lua;"..package.path
local path="player/mod/f/pl279/f_arm279.chain"
local file=os.tmpname()
local open=io.open
io.open=function(name,mode)
    if name=="MHRS-Files-HotReload/asset-path.txt" then name=file end
    return open(name,mode)
end
local model,count=1,15
local counts={[1]=15,[2]=14,[3]=15,[4]=4,[5]=3,[6]=4}
local function holder(id)
    return {read_qword=function() return id end,call=function(_,k) assert(k=="get_ResourcePath");return path end}
end
local function resource(id)
    return {get_address=function() return id end,release=function() end,create_holder=function() return holder(id) end}
end
local go={get_address=function() return 51 end}
local preview=false
local transform={call=function(_,k)
    if k=="get_GameObject" then return go end
    assert(k=="get_Parent")
end}
function go:call(k,arg)
    if k=="get_Transform" then return transform end
    if k=="getComponent(System.Type)" then return preview and arg=="snow.player.PlayerPreview" and true or nil end
    assert(k=="get_Valid" or k=="get_Update");return true
end
local chain={get_address=function() return 100 end}
function chain:call(k,arg)
    if k=="get_ChainAsset" then return holder(model) end
    if k=="set_ChainAsset" then model=arg:read_qword(0x10);count=counts[model];return end
    if k=="get_GameObject" then return go end
    if k=="get_ResourceGroupCount" then return counts[model] end
    if k=="getGroupCount" then return count end
    error(k)
end
local scene={call=function(_,k,typ) assert(k=="findComponents(System.Type)" and typ=="via.motion.Chain");return {chain} end}
local fresh
re={on_application_entry=function() end,on_script_reset=function() end};json={dump_file=function() end}
sdk={hook=function() end,get_native_singleton=function() end,call_native_func=function() return scene end,
    find_type_definition=function() return {get_method=function() end,get_methods=function() return {} end} end,
    typeof=function(t) return t end,to_ptr=function(n) return n end,to_resource=resource,
    create_resource=function(_,name) assert(name==path);return resource(fresh) end}
local plugin=require("MHRS_HotReload.outfit")
local function native(op)
    if op=="asset" then return "pending",tostring(fresh) end
    if op=="poll" then return "ready" end
    if op=="commit" then return "committed" end
    if op=="abort" then return "rolled back" end
    error(op)
end
local function begin(id,expected)
    fresh=id
    local b=plugin.run("asset_begin",{path=path,expected_groups=expected,platform=true},native)
    assert(b.bindings==1)
    local f=assert(open(file,"rb"));assert(f:read("*a")=="@"..path);f:close()
    assert(plugin.run("asset_poll",{},native).state=="ready")
    assert(plugin.run("asset_bind",{},native).state=="pending")
end
-- A scene-wide player/mod CHAIN on an unknown object cannot be written by
-- the standalone asset path, even if the player's own list is unavailable.
assert(#plugin.run("asset_inspect",{path=path},native).bindings==0)
preview=true
begin(2,14)
preview=false
assert(plugin.run("asset_abort",{},native).state=="rolled back" and model==2,
    "aborting the resource transaction wrote to a former preview after ownership changed")
model,count,preview=1,15,true
for _,id in ipairs({2,3,5,6}) do
    if id==5 then model,count=4,counts[4];path="npc/outfit/test.chain" end
    begin(id,counts[id])
    assert(plugin.run("asset_bind",{},native).state=="committed")
    assert(model==id and count==counts[id])
end
begin(5,7)
assert(plugin.run("asset_bind",{},native).state=="pending")
assert(plugin.run("asset_abort",{},native).state=="rolled back" and model==6 and count==4)
os.remove(file)
print("Standalone chain 15→14→15 and NPC 4→3→4 passed, including source spelling and rollback")
