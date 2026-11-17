-- Supply the installed, unedited LuaBoneSystem.lua as arg[1]. Exercise the real
-- pose and selection functions using three persistent hunter/part instances.
local run = assert(loadfile(arg[1]))
package.path = "reframework/autorun/?.lua;" .. package.path
local bridge = require("MHRS_HotReload.lua_bone_system")
local function xyz(x) return {x=x,y=0,z=0} end
local function profile(x) return {L_Arm_01=xyz(x)} end
local now,reads=0,0
local files,loose,decoded={},{},{}
local path="MHRS-Files-HotReload/"
os.clock=function() return now end
io.open=function(name,mode)
    assert(mode=="rb")
    reads=reads+1
    if files[name] then return {read=function() return files[name] end, close=function() end} end
end
json={load_file=function(name)
    if name:find("LUABoneSystem/base/",1,true) then return {L_Arm_01=xyz(1),L_Leg_01=xyz(1)} end
    return loose[name:match("custom/(.-)%.json$")]
end, load_string=function(token) return assert(decoded[token]) end}
Vector3f={new=function(x,y,z) return {x=x,y=y,z=z} end}
local update, phase, tick, unrelated, ui
local function register(event,cb)
    if cb==unrelated then return "passed through" end
    assert(not update)
    phase,update=event,cb
end
re={on_frame=function(cb) tick=cb end, on_application_entry=register, on_pre_application_entry=register,
    on_draw_ui=function(cb) ui=cb end}
local messages={}
log={info=function(text) messages[#messages+1]=text end}
local function joint(name,rest)
    local j={position=xyz(rest),rest=rest,writes=0}
    function j:get_Name() return name end
    function j:get_LocalPosition() return self.position end
    function j:call(n,value)
        if n=="get_BaseLocalPosition" then return xyz(self.rest) end
        assert(n=="set_LocalPosition"); self.writes=self.writes+1; self.position=value
    end
    return j
end
local function player(index,part,rest,sex)
    local arm,leg=joint("L_Arm_01",rest or 1),joint("L_Leg_01",1)
    local partgo={get_Name=function() return part end, call=function(_,n) assert(n=="get_Name");return part end}
    local child={call=function(_,n)
        if n=="get_GameObject" then return partgo end
        assert(n=="get_Next")
    end}
    local trans={get_address=function() return index end,get_reference_count=function() return 2 end,
        get_Joints=function() return {arm,leg} end,call=function(_,n) assert(n=="get_Child"); return part and child end}
    local ik={count=0,call=function(self,n)
        if n=="firstUpdate" then self.count=self.count+1; return end
        if n:find("^get_") then return "Foot" end
        assert(n=="set_LeftFootJointName" or n=="set_RightFootJointName")
    end}
    local shadow={id=1,read_qword=function(h) return h.id end,
        call=function(_,n) assert(n=="get_ResourcePath");return "player/mod/f/bone/f_shadow.mesh" end}
    local mesh={call=function(_,n)
        if n=="get_MeshReady" then return true end
        assert(n=="getMesh");return shadow
    end}
    local go={call=function(_,n,t)
        if n=="get_Transform" then return trans end
        if t=="via.render.Mesh" then return mesh end
        assert(n=="getComponent(System.Type)"); return ik
    end}
    return {arm=arm, leg=leg, ik=ik,go=go,shadow=shadow, get_type_definition=function() return {is_a=function() return false end} end,
        get_field=function(_,n) if n=="mSex" then return sex or 1 end;assert(n=="_playerWeaponType");return 1 end,
        call=function(_,n)
            if n=="get_GameObject" then return go end
            if n=="getPlayerIndex" then return index end
            assert(n=="get_IsFieldMainOutZone" or n=="get_IsFieldMainZone");return true
        end}
end
local a,b,c=player(0,"f_arm507",1.125),player(1,"f_arm507",0.875),player(2,"f_helm602",1.5)
local players={a,b,c}
local manager={get_field=function() return players end,call=function() return a end}
sdk={get_managed_singleton=function(n)
    if n=="snow.player.PlayerManager" then return manager end
    if n=="snow.TimeScaleManager" then return {get__Pausing=function() return false end} end
    assert(n=="snow.eventcut.EventManager")
end, typeof=function(n) assert(n=="via.motion.IkLeg" or n=="via.render.Mesh");return n end}
local function manifest(id, hashes, values)
    decoded["m"..id]={version=1,pid=123,session="new",profiles=hashes}
    decoded["d"..id]={version=1,pid=123,session="new",profiles=hashes,values=values}
    files[path.."bone-profiles.json"]="m"..id
    files[path.."bone-profile-data.json"]="d"..id
end
local function sample(t,expected,enabled)
    now=t
    for _,p in ipairs(players) do
        for _,j in ipairs({p.arm,p.leg}) do j.position=xyz(j.rest);j.writes=0 end
    end
    tick()
    update()
    for _,p in ipairs(players) do
        assert(p.arm.writes==(enabled==false and 0 or 1) and p.leg.writes==p.arm.writes,"unexpected writes")
        assert(p.arm.position.x==(enabled==false and p.arm.rest or expected[p]) and p.leg.position.x==1,
               "wrong active offsets: "..tostring(p.arm.position.x).." expected "..tostring(expected[p]))
    end
end
local function frame(t,x,y,enabled) sample(t,{[a]=x,[b]=x,[c]=y},enabled) end

manifest("stale",{f_arm507="stale"},{stale=profile(9)})
decoded.mstale.pid=999
bridge.install(123)
unrelated=function() error("unrelated callback") end
assert(re.on_application_entry("UpdateMotion",unrelated)=="passed through")
-- One hunter starts wearing a mod, the other two start without one.
loose.f_helm602=profile(0.75)
run()
assert(messages[1]:find(phase,1,true) and re.on_application_entry==register and re.on_pre_application_entry==register)
frame(0,1,1.75)
manifest("1",{f_helm602="other"},{other=profile(0.75)})
for i=1,5 do frame(i,1,1.75) end
local ik_v2=phase=="UpdateMotion"
assert(c.ik.count==(ik_v2 and 1 or 0))
manifest("2",{f_helm602="other",f_arm507="a"},{other=profile(0.75),a=profile(0.25)})
frame(6,1.25,1.75)
local prev=reads
frame(6.01,1.25,1.75)
assert(prev==reads and a.ik.count==(ik_v2 and 1 or 0),"unexpected per-frame reads or early IK")
for i=7,10 do frame(i,1.25,1.75) end
assert(a.ik.count==(ik_v2 and 2 or 0) and b.ik.count==a.ik.count)
-- Head advanced while data contains a different generation: keep live pose.
manifest("3",{f_helm602="other",f_arm507="b"},{other=profile(0.75),b=profile(0.5)})
files[path.."bone-profile-data.json"]="d2"
frame(11,1.25,1.75)
files[path.."bone-profile-data.json"]="d3"
for i=12,16 do frame(i,1.5,1.75) end
assert(a.ik.count==(ik_v2 and 3 or 0) and c.ik.count==(ik_v2 and 1 or 0),"wrong IK invalidation scope")
manifest("4",{f_helm602="other"},{other=profile(0.75)})
frame(17,1,1.75)
manifest("5",{f_arm507="c"},{c=profile(0.875)})
loose.f_helm602=nil
frame(18,1.875,1)
imgui={tree_node=function() return true end,tree_pop=function() end,button=function() return false end,
       checkbox=function() return true,false end}
ui() -- user's own Enable still controls all pose writes
frame(19,1,1,false)
update=nil
bridge.install(123) -- REFramework Reset Scripts, but watcher & digest are unchanged
run()
frame(20,1.875,1)
-- While the quest is running both remote hunters now use different JSONs.
-- Reorder PlayerList and reuse slot 1 before the new player has any parts.
local empty=player(1,nil,0.5)
players={c,empty,a}
sample(21,{[c]=1,[empty]=1,[a]=1.875})
local other=player(1,"m_leg610",0.625,0)
players={other,c,a}
manifest("6",{f_arm507="c",f_helm602="other",m_leg610="male"},
    {c=profile(0.875),other=profile(0.75),male=profile(-0.5)})
sample(22,{[other]=0.5,[c]=1.75,[a]=1.875})
-- A completed shadow bind can finish reconstructing its joints after an
-- initial read of the new holder; recapture only that hunter's rest.
c.arm.rest=1.25;c.shadow.id=2
sample(23,{[other]=0.5,[c]=1.75,[a]=1.875})
c.arm.rest=1.375;bridge.rest_changed(c.go)
sample(24,{[other]=0.5,[c]=1.75,[a]=1.875})
print("PASS unmodified "..phase..": distinct same-sex rests and JSONs, recycled quest slot, startup, swap, removal, sparse joints, IK, UI and state reset")
