-- Exercise the production mount state machine with a nonzero local slot, a
-- registered peer, and an NPC follower. Only the master's leg may change.
package.path="reframework/autorun/?.lua;"..package.path
local seq=0
local function obj(data)
    seq=seq+1
    local o={id=seq,data=data or {}}
    function o:get_address() assert(not self.destroyed,"address from a retired game object");return self.id end
    function o:get_field(key) return self.data[key] end
    function o:call(key,...)
        assert(not self.destroyed,"called "..key.." on a retired game object")
        local value=self.data[key]
        if type(value)=="function" then return value(...) end
        assert(value~=nil,key)
        return value
    end
    function o:get_type_definition() return self.td end
    return o
end
local function array(t,n)
    return {get_element=function(_,i) return t[i] end,get_size=function() return n end}
end
local function method(name,types,result,static,call)
    local function datatype(t) return {get_full_name=function() return t end} end
    local params={}
    for _,t in ipairs(types) do params[#params+1]=datatype(t) end
    return {get_name=function()return name end,is_static=function()return static end,
        get_return_type=function()return datatype(result) end,get_param_types=function()return params end,call=call}
end
local function td(m) return {get_methods=function() return {m} end,get_parent_type=function() end} end
local mounted,party
local function setup()
    local gen={mesh=obj(),mdf=obj()}
    local names={"f_body279","f_arm279","f_wst279","f_leg279","f_helm279"}
    local pos={x=0,y=0,z=0}
    local requests,players,actors,factories={},{},{},{}
    local lookup={get_method=function() return {call=function(_,ids,pack) return ids.data.indices[pack] end} end}
    local masterslot=2
    local members={[0]="peer",[2]="local"}
    local scope="quest/test"
    local localgo,foreignmutations={},0
    local function newpart(a,s,logical)
        local go=obj({get_Valid=true,get_Update=true,get_DrawSelf=true,get_Name=names[s+1]})
        local tr=obj({get_Parent=a.tr,get_Position=pos,get_LocalPosition=pos,get_SameJointsConstraint=true})
        tr.data.get_GameObject=go;tr.data.get_Next=function()return tr.next end
        tr.next=a.first;a.first=tr;a.tr.data.get_Child=function()return a.first end
        local mesh=obj({get_MeshReady=true,get_MaterialReady=true})
        local h,d=obj({get_ResourcePath="player/mod/f_leg279.mesh"}),obj()
        h.read_qword=function()return gen.mesh:get_address() end
        d.read_qword=function()return gen.mdf:get_address() end
        mesh.data.getMesh=h;mesh.data.get_Material=d
        local mp=obj({_ParentMaterialCtrl=a.ctrl,get_plPartsNo=s,get_RefMesh=mesh,get_GameObject=go})
        go.data.get_Transform=tr
        go.data["getComponent(System.Type)"]=function(c)
            if c=="snow.player.PlayerMaterialParts" then return mp elseif c=="via.render.Mesh" then return mesh end
        end
        if logical then a.slots[s],a.mats[s]=go,mp end
        if a.i==masterslot then localgo[go]=true end
        mp.go=go
        return go,mp
    end
    for _,i in ipairs({masterslot,0,4}) do
        local a={i=i,tr=obj(),slots={},mats={}}
        a.root=obj({get_Valid=true,get_Transform=a.tr})
        a.ctrl=obj({get_GameObject=a.root,_MaterialParts=array(a.mats,5),getPartsGameObject=function(s)return a.slots[s]end,
            getPartsMaterial=function(s)return a.mats[s]end})
        a.p=obj({get_GameObject=a.root,getPlayerIndex=i,isMasterPlayer=i==masterslot,isServant=i==4,
            _RefPlayerMaterialCtrl=a.ctrl,get_RefWeaponParts=obj(),getPartsGameObject=a.ctrl.data.getPartsGameObject,
            getPartsMaterial=a.ctrl.data.getPartsMaterial})
        for s=0,4 do newpart(a,s,true) end
        local ids=obj({indices={[5]=i}})
        ids.td=lookup
        a.req=obj({get_EquipIndex=ids})
        a.factory=obj({get_Path=i==masterslot and "player/prefab/mod/f_leg279.pfb" or "other"..i,
            get_ResourcePath="player/prefab/mod/f_leg279.pfb",get_Exist=true,get_Standby=false,get_Valid=false,get_Ready=false})
        a.writes={}
        a.factory.data.set_Standby=function(v)
            if i~=masterslot then foreignmutations=foreignmutations+1 end
            a.writes[#a.writes+1]=v
            a.factory.data.get_Standby=v;a.factory.data.get_Valid=v;a.factory.data.get_Ready=v
        end
        actors[i],requests[i],factories[i]=a,a.req,a.factory
        players[#players+1]=a.p
    end
    local me=actors[masterslot]
    local disabled=array({},5)
    disabled.get_type_definition=function()
        return {get_method=function(_,name)
            assert(name=="Get(System.Int32)")
            return {call=function(_,_,i) assert(i==4);return false end}
        end}
    end
    local base=obj({_IsEnableSymbolColor1=disabled,_IsEnableSymbolColor2=disabled})
    local pm=obj({getPlayer=function(i)return actors[i] and actors[i].p end,findMasterPlayer=me.p,
        getMasterPlayerID=masterslot,get_PlayerParam=array(requests,5),get_PlayerBaseData=array({[masterslot]=base},5),
        getPlayerWeaponType=0,getPlayerSexType=1,
        isReadyPlayerLoadState=true,isReadyPlayer=true,getPartsPrefabList=function(pack)
            assert(pack==5);return obj({get_Count=5,get_Item=function(i) return factories[i] end})
        end})
    pm.td=td(method("instantiatePlayerParts",{"via.Transform","snow.player.PlayerRequestEquipsData.EquipPack",
        "snow.player.PlayerRequestEquipsData","via.vec3"},"via.GameObject",false,function(_,mgr,parent,pack,req,where)
        assert(mgr==pm and parent==me.tr and pack==5 and req==me.req and where==pos)
        return newpart(me,3,true)
    end))
    me.ctrl.td=td(method("addMaterialParts",{"snow.player.PlayerMaterialParts","System.Int32"},"System.Void",false,
        function(_,ctrl,mp,s)
            assert(ctrl==me.ctrl and localgo[mp.go] and mp.data._ParentMaterialCtrl==ctrl)
            me.mats[s],me.slots[s]=mp,mp.go
        end))
    local destroy=td(method("destroy",{"via.GameObject"},"System.Void",true,function(_,receiver,go)
        assert(not receiver and localgo[go]);go.data.get_Valid=false
        local tr=go.data.get_Transform
        local prev,entry=nil,me.first
        while entry~=tr do assert(entry);prev,entry=entry,entry.next end
        if prev then prev.next=entry.next else me.first=entry.next end
        go.destroyed=true
        me.mats[3],me.slots[3]=nil,nil
    end))
    sdk={typeof=function(t)return t end,find_type_definition=function()return destroy end,get_managed_singleton=function()return pm end}
    local parts={}
    for s=0,4 do
        parts[s]={object=me.slots[s]:get_address(),name=names[s+1],requested=s==3,
            mesh="player/mod/f_leg279.mesh",mdf="player/mod/f_leg279.mdf2",mesh_name="mesh",mdf_name="mdf"}
    end
    package.loaded["MHRS_HotReload.hunter_roster"]={context=function() return scope,members end,players=function() return players end,
        render_part=function(go)local m=go:call("getComponent(System.Type)","via.render.Mesh");return m,m:call("getMesh"),m:call("get_Material") end}
    package.loaded["MHRS_HotReload.equipped_hunter"]={equip_indices=function() return "worn" end}
    package.loaded["MHRS_HotReload.equipped_parts"]={part_ready=function(go)return go:call("get_Valid") end}
    package.loaded["MHRS_HotReload.mounted_shadow"]={begin=function() end}
    package.loaded["MHRS_HotReload.shadow_skeleton"]={}
    package.loaded["MHRS_HotReload.mounted_equipment"]=nil
    package.loaded["MHRS_HotReload.mounted_party"]=nil
    mounted=require("MHRS_HotReload.mounted_equipment")
    local original={};for _,i in ipairs({0,4}) do
        original[i]={}
        for s=0,4 do original[i][s]=actors[i].slots[s] end
    end
    return {me=me,actors=actors,requests=requests,factories=factories,
        capture=function()
            for s=0,4 do parts[s].object=me.slots[s]:get_address() end
            return mounted.capture({index=masterslot,parts=parts},pm,me.p,me.root,gen)
        end,
        untouched=function()
            assert(foreignmutations==0)
            for i,old in pairs(original) do for s=0,4 do assert(actors[i].slots[s]==old[s] and actors[i].mats[s].go==old[s]) end end
        end}
end
local function commit(c)
    local old=c.me.slots[3];local j=assert(c.capture());local pending=true
    for _=1,8 do if pending then mounted.repair_registry(j);pending=mounted.advance(j) end end
    assert(not pending and c.me.slots[3]~=old and not old.data.get_Valid)
    c.untouched()
end
local c=setup()
commit(c)
assert(#c.me.writes==2 and c.me.writes[1] and not c.me.writes[2])
-- The previous mod, the restored PAK and the next mod all retire a
-- different wrapper on the same live actor. Calling any method on one of
-- these wrappers raises, as can happen with a released native GO in Rise.
commit(c);commit(c)
assert(#c.me.writes==6)
c=setup();c.factories[0]=c.me.factory
assert(not pcall(c.capture) and #c.me.writes==0);c.untouched()
c.me.factory.data.get_Valid=true;c.me.factory.data.get_Ready=true
commit(c);assert(#c.me.writes==0)
c=setup();c.requests[4]=c.me.req
assert(not pcall(c.capture) and #c.me.writes==0)
c=setup();c.actors[0].mats[0]=c.me.mats[3]
assert(not pcall(c.capture) and #c.me.writes==0)
c=setup();c.actors[4].p.data._RefPlayerMaterialCtrl=c.me.ctrl
assert(not pcall(c.capture) and #c.me.writes==0)
c=setup();local j=assert(c.capture());assert(mounted.advance(j))
c.factories[4]=c.me.factory
for _=1,7 do if not mounted.advance(j) then break end end
assert(#c.me.writes==1 and c.me.factory.data.get_Standby);c.untouched()
print("Local armor factory ownership with peer, follower, shared/claimed factory and aliased request/material/controller passed")
c=setup();j=assert(c.capture())
local old_leg=c.me.slots[3]
assert(mounted.advance(j))
j.shadow={batch={shadow={owner={},fresh=obj(),canonical="player/mod/f/bone/f_shadow.mesh",suit_request="player/mod/f/pl279/f_shadow.mesh"}}}
local record=assert(mounted.reset_record(j,42))
assert(record.replay and #record.replay.slots==5 and #record.rows==1)
mounted.reset_cleanup(j)
assert(not c.me.factory.data.get_Standby)
local waiting,restored=mounted.recover_record(record)
assert(not waiting and restored and c.me.slots[3]==old_leg)
local state=assert(mounted.replay_state(record))
assert(state.id==record.replay.id and state.paths[record.replay.shadow] and state.worn["player/mod/f_leg279.mesh"])
c.me.p.data.get_RefWeaponParts=obj()
assert(not mounted.replay_state(record))
c.untouched()
print("VM reset restored the original slot and prefab standby, rediscovered local disk-replay targets, and rejected a different weapon")
c=setup();j=assert(c.capture())
for _=1,3 do assert(mounted.advance(j)) end
assert(j.retiring and j.rows[3].retired)
local retired_record=assert(mounted.reset_record(j,42))
assert(retired_record.rows[1].retired)
assert(not mounted.rollback(j))
c.me.root.destroyed=true;c.me.p.data.get_GameObject=obj()
assert(not mounted.rollback(j) and not mounted.reset_record(j,42))
print("Handover reset and scene exit never query a dead part or the previous hunter root")
