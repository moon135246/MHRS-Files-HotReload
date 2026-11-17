local clock, reads, writes, warnings = 0, 0, 0, 0
local frame, ui, toggle, button, result
local groups, local_y, base_y = 3, .054748, .054748
local slots = {"skin", "0x1234abcd", "12345678901234567", "00112233-4455-6677-8899-aabbccddeeff"}
local forbidden, joint_reads = {}, 0
local function object(methods)
    return {call=function(_, key, ...)
        local f = methods[key]
        if f == nil then forbidden[#forbidden+1] = key; error(key) end
        if type(f) == "function" then return f(...) end
        return f
    end}
end
local chain = object({get_ResourceGroupCount=function() return groups end, get_Setuped=true,
    getGroupCount=function() return groups end})
local mesh = object({get_MaterialReady=true, get_MaterialNum=40,
    getMaterialName=function(i) return slots[i+1] or "body" end})
local part = object({get_Name="f_arm279", ["getComponent(System.Type)"]=function(t)
    return t=="via.render.Mesh" and mesh or chain
end})
local joint = object({get_BaseLocalPosition=function() return {x=0,y=base_y,z=0} end,
    get_LocalPosition=function() return {x=0,y=local_y,z=0} end})
local tr = object({["getJointByName(System.String)"]=function(name)
    assert(name=="Head_00"); joint_reads=joint_reads+1; return joint
end})
local root = object({get_Transform=tr})
local entries = {}
for i, role in ipairs({"unconfirmed", "peer", "follower", "master"}) do
    entries[i] = {role=role, index=4-i, root=root, slots={[2]=part},
        guid="PRIVATE_GUID", scope="PRIVATE_ADDRESS", player="PRIVATE_PLAYER"}
end
local roster = {read=function()
    reads = reads+1
    return {entries=entries, status=2, members={"PRIVATE_GUID"}, scope="PRIVATE_ADDRESS"}
end, describe=function() forbidden[#forbidden+1]="describe"; error("describe") end}
package.loaded["MHRS_HotReload.hunter_roster"]=roster
sdk={typeof=function(t) return t end, get_managed_singleton=function(t)
    assert(t=="snow.QuestManager")
    return object({getQuestNo=101, getMapNo=5})
end}
os.clock=function() return clock end
log={warn=function() warnings=warnings+1 end}
re={on_frame=function(f) assert(not frame); frame=f end, on_draw_ui=function(f) assert(not ui); ui=f end}
imgui={tree_node=function() return true end, tree_pop=function() end, checkbox=function(label,value)
    if label==toggle then toggle=nil; return true, not value end
    return false, value
end, button=function() local r=button; button=false; return r end}
local reject=false
json={dump_file=function(path,obj)
    assert(path=="MHRS-Files-HotReload/online-observations.json")
    if reject then return false end
    writes, result=writes+1,obj.samples
    local function scrub(t)
        for k,v in pairs(t) do
            assert(k~="player" and k~="guid" and k~="scope" and k~="root")
            if type(v)=="table" then scrub(v)
            elseif type(v)=="string" then assert(not v:find("PRIVATE") and not v:find("0x")
                    and v~=slots[3] and v~=slots[4]) end
        end
    end
    scrub(obj)
    return true
end}
dofile("tools/observe_multiplayer.lua")
dofile("tools/observe_multiplayer.lua")
frame()
assert(writes==1 and reads==1 and joint_reads==0)
local scene=result[1].scene
assert(scene.status==2 and scene.quest==101 and scene.map==5)
for i,role in ipairs({"master","follower","peer","unconfirmed"}) do
    local actor=scene.actors[i]
    assert(actor.index==i-1 and actor.role==role and #actor.parts==5 and not actor.head)
    local p=actor.parts[3]
    assert(p.name=="f_arm279" and p.material_count==40 and #p.material_slots==32)
    assert(p.material_slots[1]=="skin" and p.material_slots[2]==false)
    assert(p.chain_attached and p.running_groups==3 and p.resource_groups==3)
end
clock=2;frame();assert(reads==1)
clock=3;frame();assert(reads==2 and writes==1)
clock=60;frame();assert(result[2].reason=="periodic")
toggle="Record Head_00 base/local position";ui();frame()
assert(result[3].scene.actors[1].head.local_position.y==local_y)
clock=63;local_y=.2;frame();assert(writes==3)
clock=66;base_y=.128;frame();assert(writes==4 and result[4].scene.actors[1].head.local_position.y==.2)
toggle="Pause automatic observations";ui()
clock=1000;frame();assert(writes==4)
button=true;ui();frame();assert(writes==5 and result[5].reason=="requested")
toggle="Pause automatic observations";ui()
for i=1,60 do clock=clock+3;groups=groups+1;frame() end
assert(#result==48 and result[48].scene.actors[1].parts[3].running_groups==63)
reject=true;local oldest=result[1];clock=clock+3;groups=64;frame()
assert(#result==48 and result[1]==oldest)
assert(#forbidden==0 and warnings==1)
print("Read-only multiplayer observation roles, redaction, bounded history, cadence and opt-in joint passed")
