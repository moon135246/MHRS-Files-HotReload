-- Exercise actual local hunter and generation checks without a native engine.
package.path="reframework/autorun/?.lua;"..package.path
re={on_application_entry=function() end}
local function object(fields,id)
    return {call=function(_,name,...)
        local v=fields[name]
        if type(v)=="function" then return v(...) end
        assert(v~=nil,name);return v
    end,get_address=function() return id end}
end
local key="player/mod/f/pl888/f_arm888.mesh"
local ptr=98765432
local holder=object({get_ResourcePath="@Player\\Mod\\f\\pl888\\f_arm888.mesh"})
holder.read_qword=function(_,offset) assert(offset==0x10);return ptr end
local mesh=object({getMesh=holder,get_Material=object({get_ResourcePath="arm.mdf2"}),get_MeshReady=true,get_MaterialReady=true},100)
local update,draw,input,kind=true,true,true,"snow.player.PlayerLobbyBase"
local parts={}
for i=0,4 do
    local is_arm=i==2
    parts[i]=object({get_Valid=true,get_Name="part"..i,get_Update=function() return update end,
        ["getComponent(System.Type)"]=function(t) if is_arm and t=="via.render.Mesh" then return mesh end end}, i+1)
end
local go=object({get_Valid=true,get_Draw=function() return draw end})
local p=object({get_GameObject=go,getPartsGameObject=function(i) return parts[i] end,
    isMasterPlayer=true,getPlayerIndex=0,isInput=function() return input end,isActivePlayer=true,get_AreaMoveFlag=2})
p.get_type_definition=function() return {get_full_name=function() return kind end,
    is_a=function(_,name) return name==kind end} end
local pm=object({findMasterPlayer=p,getMasterPlayerID=0,isReadyPlayer=true,isReadyPlayerLoadState=true})
local area=object({isIdle=true,getCurrentAreaNo=1})
local managers={["snow.SnowGameManager"]=object({getStatus=function() return kind=="snow.player.PlayerQuestBase" and 0 or 1 end}),["snow.player.PlayerManager"]=pm,["snow.VillageAreaManager"]=area,["snow.data.EquipDataManager"]={}}
sdk={get_managed_singleton=function(t) return managers[t] end,typeof=function(t) return t end}
local village=require("MHRS_HotReload.village_equipment")
local function state() return village.worn_state({[key]=true,["other.mesh"]=true}) end
local initial,ids=state()
assert(initial.ready and initial.available[key] and initial.observed[key]==tostring(ptr) and ids[key]==100)
draw=false
assert(not state().ready and state().observed[key]==tostring(ptr))
draw=true;input=false
assert(state().ready and state().observed[key]==tostring(ptr))
input=true;update=false
assert(state().ready and not state().available[key])
update=true
local tx=assert(village.capture({{go=parts[2],mesh={original=ptr}}},{},{},nil,{}))
ptr=ptr+1
local ok,why=pcall(village.advance,tx,{},{})
assert(ok and why==false and not tx.deferred_mount.retry and not tx.started)
assert(state().observed[key]==tostring(ptr))
kind="snow.player.PlayerQuestBase"
assert(not state().ready and not next(state().observed))
print("Hidden and non-local hunters, dormant parts, and stale mesh generations passed")
