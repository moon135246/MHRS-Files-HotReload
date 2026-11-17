-- Exercise one real capture/request/restore/verify cycle with simulated Rise objects.
package.path="reframework/autorun/?.lua;"..package.path
local t=2
os.clock=function() return t end
local behavior
re={on_application_entry=function(_,callback) behavior=callback end}
local function object(id,values)
    local o={get_address=function() return id end}
    function o:call(method,...)
        local value=values[method]
        if type(value)=="function" then return value(...) end
        assert(value~=nil,method)
        return value
    end
    return o
end
local key="player/mod/f/pl279/f_arm279.mesh"
local function holder(name,ptr)
    local h=object(0,{get_ResourcePath=name})
    h.read_qword=function() return ptr end
    return h
end
local readings={_r_Vital=150,_vitalMax=150,_stamina=3000,_staminaMax=3000}
local data=object(555,{})
data.get_type_definition=function() return {get_field=function(_,key)
    if readings[key]~=nil then return {get_data=function() return readings[key] end} end
end} end
local function weapon(name)
    local mesh=object(0,{getMesh=holder("weapon/Bow/Bow086/"..name..".mesh",10)})
    return object(0,{get_Valid=true,["getComponent(System.Type)"]=function() return mesh end})
end
local main,sub=weapon("bow"),weapon("quiver")
local writes,game_status=0,1
local function actor(id,visible,training,new,area_flag)
    local a={visible=visible,training=training,main=main,sub=sub,data=data,drawn=false,area_flag=area_flag,parts={},
             weapon_type=13,class="snow.player.Bow"}
    local tr=object(2,{get_Position=function() return {x=a.x or 9.01,y=new and 0.6 or 0,z=8} end,
                       get_Rotation={x=0,y=0,z=0,w=1}})
    a.go=object(id,{get_Valid=true,get_Draw=function() return a.visible end,get_Transform=tr})
    for i=0,4 do
        local mesh=object(id+i+1,{getMesh=holder(i==0 and key or "part"..i..".mesh",new and 44 or 22),
            get_Material=holder("part"..i..".mdf2",12),get_MeshReady=true,get_MaterialReady=true,
            get_MaterialNum=1,getMaterialName="test"})
        local chain=object(3,{get_ChainAsset=holder("part"..i..".chain",9),get_ResourceGroupCount=1,
                            get_Enabled=true,get_Setuped=true,getGroupCount=1})
        a.parts[i]=object(id+i+10,{get_Valid=true,get_Update=true,get_Name="part"..i,
            ["getComponent(System.Type)"]=function(kind) return kind=="via.render.Mesh" and mesh or chain end})
    end
    a.p=object(id+200,{get_GameObject=a.go,getPlayerIndex=0,isMasterPlayer=true,
        get_IsInTrainingArea=function() return a.training end,isWeaponOn=function() return a.drawn end,
        get_PlayerData=function() return a.data end,get_AreaMoveFlag=function() return a.area_flag end,
        setAreaMoveFlag=function(v) writes=writes+1;a.area_flag=v;a.visible=true;a.training=(game_status==1) end,
        isInput=function() return a.visible and not a.animation_lock end,isActivePlayer=function() return a.visible end,
        isDie=false,isQuestResultAction=true,get_IsMarionetteAction=false,get_IsAimModeAction=function() return a.aim or false end,
        isFrozenReaction=false,isFloatingReaction=false,get_IsDuringSlipDamage=false,
        getPartsGameObject=function(i) return a.parts[i] end})
    a.p.get_type_definition=function() return {get_full_name=function() return a.class end,
        is_a=function(_,name) return name=="snow.player.PlayerQuestBase" end} end
    a.p.get_field=function(_,name) return ({_playerWeaponType=a.weapon_type,_WeaponMain=a.main,_WeaponSub=a.sub})[name] end
    return a
end
local old=actor(100,true,true,false,7)
local current=old
local area_number,training_area,gui_blocked=5,true,false
local area=object(1,{getCurrentAreaNo=function() return area_number end,isIdle=true,
    checkCurrentArea_TrainingArea=function() return training_area end})
local gui=object(0,{IsPlayerAllInputDisable=function() return gui_blocked end})
local indices={77,97,97,97,97,97,0,18,0,16,77,18,474,495,492,502,502,506}
local ids={get_size=function() return #indices end,get_type_definition=function()
    return {get_full_name=function() return "System.Int32[]" end,get_method=function(_,key)
        assert(key=="Get(System.Int32)")
        return {call=function(_,_,i) return indices[i+1] end}
    end}
end}
local req=object(7,{get_EquipIndex=ids})
local parameters={get_element=function(_,i) assert(i==0);return req end}
local pm=object(1,{findMasterPlayer=function() return current.p end,get_PlayerParam=parameters,getMasterPlayerID=0,isReadyPlayer=true,
                   isReadyPlayerLoad=true,isReadyPlayerLoadState=true})
local nullable=object(1,{get_HasValue=true,get_Value=0})
local calls=0
local eq=object(0,{getMasterPlayerIndex=nullable})
eq.get_type_definition=function() return {get_method=function(_,name)
    assert(name=="reloadPlayerModel")
    return {call=function(_,manager,deferred,index) assert(manager==eq and deferred==false and index==nullable);calls=calls+1 end}
end} end
local managers={["snow.VillageAreaManager"]=area,["snow.gui.GuiManager"]=gui,
    ["snow.SnowGameManager"]=object(9,{getStatus=function() return game_status end}),
    ["snow.player.PlayerManager"]=pm,["snow.data.EquipDataManager"]=eq}
sdk={typeof=function(t) return t end,get_managed_singleton=function(n) return managers[n] end}
local v=require("MHRS_HotReload.village_equipment")
local rec_path="MHRS-Files-HotReload/model-recovery.json"
local disk={}
json={load_file=function(path) return disk[path] end,dump_file=function(path,r) disk[path]=r end}
-- A new DLL does not initiate reconstruction. It can still finish a pending
-- same-process receipt written by an older version before a Lua state reset.
disk[rec_path]={pid=123,manager="1",expires=os.time()+20,index=0,area=5,area_flag=7,
    class=old.class,old_address="100"}
current=actor(700,false,true,true,0)
v.install(123)
behavior();behavior()
assert(writes==1 and current.visible and not next(disk[rec_path]))
game_status=2
managers["snow.VillageAreaManager"]=nil
local quest_data=object(7856,{})
local start_demo=false
managers["snow.QuestManager"]=object(55,{getQuestNo=10708,getMapNo=2,getActiveQuestData=quest_data,
    getStatus=2,getQuestElapsedTimeSec=100,isQuestReset=false,isQuestTimeOver=false,
    isWaitQuestEnd=false,isPhaseResult=false,isQuestStartEventDemo=function() return start_demo end,
    isQuestInterruptEventDemo=false})
local qc=require("MHRS_HotReload.quest_context")
-- Any complete worn set (identified by the five current holders) uses the
-- existing root even when the factory, its full source or rollback is late.
local mount={}
package.loaded["MHRS_HotReload.mounted_equipment"]=mount
local before_calls=calls
current=actor(2900,true,false,false,1)
local original=current
local wanted,rows={},{}
for i=0,4 do
    local go=current.parts[i]
    local h=go:call("getComponent(System.Type)","via.render.Mesh"):call("getMesh")
    local name=h:call("get_ResourcePath")
    wanted[name]=true
    rows[i+1]={go=go,mesh={original=h:read_qword(0x10),path=name},expected={"test"}}
end
v.worn_state(wanted);t=t+1.2
current.drawn,current.aim,current.animation_lock=true,true,true
gui_blocked=true
start_demo=true
current.main=nil -- The armor consumer is ready while the bow renderer is temporarily absent.
local full=v.worn_state(wanted)
assert(full.complete_outfit and full.ready and full.root=="2900")
assert(not qc.available(qc.read(),current.p))
local function outfit()
    local tx=assert(v.capture(rows,{},{},nil,{},false,wanted))
    assert(tx.full_outfit and not tx.missing_binding and not tx.started)
    return tx
end
mount.capture=function() error("Shared cold armor factory: example") end
local blocked=outfit()
assert(not v.advance(blocked,{}) and blocked.deferred_mount.retry and blocked.deferred_mount.wait_factory)
assert(blocked.deferred_mount.root==full.root and blocked.deferred_mount.scope==full.scope)
for key,old_id in pairs(full.observed) do assert(blocked.deferred_mount.worn[key]==old_id) end
mount.capture=function() error("[normal equip] Independent face visibility") end
local complex=outfit()
assert(not v.advance(complex,{}) and not complex.deferred_mount.retry)
rows[5]=nil
local incomplete=assert(v.capture(rows,{},{},nil,{},false,wanted))
assert(incomplete.full_outfit and incomplete.missing_binding and not v.advance(incomplete,{}) and incomplete.deferred_mount.retry)
rows[5]={go=current.parts[4],mesh={original=22,path="part4.mesh"}}

-- Exercise both mounted routes while aiming/moving through an animation.
-- Changing gameplay state during file preparation must not veto the commit.
mount.capture=function() return {phase="warm"} end
mount.advance=function() return false end
for _,batch in ipairs({rows,{rows[1]}}) do
    local moving=assert(v.capture(batch,{},{},nil,{},false,batch==rows and wanted or {[key]=true}))
    current.x=(current.x or 10)+2
    readings._stamina=readings._stamina-10
    assert(v.advance(moving,{}) and not v.advance(moving,{}))
    assert(moving.stable==2 and moving.new_address==full.root and not moving.started and calls==before_calls)
end
local switched=outfit()
indices[1]=78
assert(not v.advance(switched,{}) and not switched.mount and calls==before_calls)
indices[1]=77
local partial=assert(v.capture({rows[1]},{},{},nil,{},false,{[key]=true}))
mount.capture=function() error("Shared cold armor factory: arm") end
assert(not v.advance(partial,{}) and partial.deferred_mount.retry and partial.deferred_mount.partial)
assert(partial.deferred_mount.worn[key]=="22" and not partial.deferred_mount.worn["part3.mesh"])
assert(calls==0)

-- One old piece has already been legitimately retired. Rebase records the
-- survivor's actual new holder, and the next attempt can only use that mix.
mount.capture=function() return {phase="handover"} end
mount.advance=function() error("test interruption") end
mount.rollback=function() return false end
mount.rebase=function(j,tx)
    local mixed=actor(3000,true,false,true,1)
    original.parts[3]=mixed.parts[3]
    tx.parts[3].object=mixed.parts[3]:get_address()
    tx.parts[3].before=44
end
local mixed=outfit()
assert(v.advance(mixed,{}) and not v.advance(mixed,{}))
assert(mixed.deferred_mount.retry and mixed.deferred_mount.worn["part3.mesh"]=="44" and mixed.deferred_mount.worn[key]=="22")
-- A naturally replaced hunter invalidates every old holder. Only logical
-- paths may be rediscovered for an in-place copy.
rows[4]={go=original.parts[3],mesh={original=44,path="part3.mesh"}}
local vanished=outfit()
current=actor(3050,true,false,false,1)
assert(not v.advance(vanished,{}) and vanished.deferred_mount.retry and vanished.deferred_mount.discover)
for name in pairs(wanted) do assert(vanished.deferred_mount.worn[name]==true) end
assert(calls==before_calls)
print("Complete outfit source, shared cold factory, partial capture, independent helmet, mixed handover and new root never request a hunter rebuild")
