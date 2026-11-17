-- Pass the actual generated LuaBoneSystem.lua as arg[1]; no game dependencies.
local run = assert(loadfile(arg[1]))
local now = 0
local reads, files, payloads = 0, {}, {}
local function xyz(x) return {x=x,y=0,z=0} end
os.clock = function() return now end
io.open = function(path, mode)
    assert(mode == "rb")
    reads=reads+1
    local data=files[path]
    if data then return {read=function() return data end,close=function() end} end
end
json={load_file=function() return {L_Arm_01=xyz(1)} end,
      load_string=function(raw) return assert(payloads[raw],"incomplete JSON") end}
Vector3f={new=function(x,y,z) return {x=x,y=y,z=z} end}
local update
re={on_application_entry=function(n,cb) assert(n=="UpdateMotion");update=cb end,on_draw_ui=function() end}

local function player(index,part)
    local joint={position=xyz(1),writes=0}
    function joint:get_Name() return "L_Arm_01" end
    function joint:get_LocalPosition() return self.position end
    function joint:call(n,value)
        if n=="get_BaseLocalPosition" then return xyz(1) end
        assert(n=="set_LocalPosition");self.writes=self.writes+1;self.position=value
    end
    local partgo={get_Name=function() return part end,call=function(_,n) assert(n=="get_Name");return part end}
    local child={call=function(_,n)
        if n=="get_GameObject" then return partgo end
        assert(n=="get_Next")
    end}
    local trans={get_address=function() return index end,get_reference_count=function() return 2 end,
                 get_Joints=function() return {joint} end,call=function(_,n) assert(n=="get_Child");return child end}
    local go={call=function(_,n)
        if n=="get_Transform" then return trans end
        assert(n=="getComponent(System.Type)")
    end}
    return {joint=joint,get_type_definition=function() return {is_a=function() return false end} end,
        get_field=function(_,n) assert(n=="mSex" or n=="_playerWeaponType");return 1 end,
        call=function(_,n)
            if n=="get_GameObject" then return go end
            if n=="getPlayerIndex" then return index end
            assert(n=="get_IsFieldMainOutZone" or n=="get_IsFieldMainZone");return false
        end}
end
local a,b,c=player(0,"f_arm507"),player(1,"f_arm507"),player(2,"f_helm602")
local players={a,b,c}
local manager={get_field=function() return players end,call=function() return a end}
sdk={get_managed_singleton=function(type)
        if type=="snow.player.PlayerManager" then return manager end
        if type=="snow.TimeScaleManager" then return {get__Pausing=function() return false end} end
        assert(type=="snow.eventcut.EventManager")
    end,typeof=function(name) assert(name=="via.motion.IkLeg");return name end}

local function profile(name, token, x)
    files["LUABoneSystem/custom/"..name..".json"]=token
    if token and x then payloads[token]={L_Arm_01=xyz(x)} end
end
local function manifest(token,profiles)
    payloads[token]={version=1,profiles=profiles}
    files["MHRS-Files-HotReload/bone-profiles.json"]=token
end
local function frame(time, x, y)
    now=time
    for _,p in ipairs(players) do p.joint.position=xyz(1);p.joint.writes=0 end
    update()
    for _,p in ipairs(players) do
        assert(p.joint.writes==1,"pose applied twice or skipped")
        local expected=p==c and y or x
        assert(math.abs(p.joint.position.x-expected)<0.000001,"Expected "..expected.." got "..p.joint.position.x)
    end
end

run()
frame(0,1,1)
profile("f_arm507","a",0.25)
profile("f_helm602","other",0.75)
manifest("m1",{f_arm507="a",f_helm602="other"})
frame(1,1.25,1.75)
local previous_reads=reads
frame(1.01,1.25,1.75)
assert(reads==previous_reads,"Unexpected per-frame filesystem access")
-- Same instances and filenames; preserve the prior pose while the target file
-- differs from the newly observed generation, then retry without a new signal.
profile("f_arm507","broken",nil)
manifest("m2",{f_arm507="b",f_helm602="other"})
frame(2,1.25,1.75)
profile("f_arm507","b",0.5)
frame(3,1.5,1.75)
profile("f_arm507",nil)
manifest("m3",{f_helm602="other"})
frame(4,1,1.75)
profile("f_arm507","c",0.875)
manifest("m4",{f_arm507="c",f_helm602="other"})
frame(5,1.875,1.75)
print("Lua Bone System retained both players' instances across add, overwrite, transient read, deletion and reinstallation")
