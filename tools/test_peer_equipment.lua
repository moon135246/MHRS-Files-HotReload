-- A live client can have several identical outfits, a Follower, and a
-- preview at the same time. Test ownership separately from renderer setters.
package.path="reframework/autorun/?.lua;"..package.path
local roster=require("MHRS_HotReload.hunter_roster")
local logs, touched={},{}
log={info=function(s) logs[#logs+1]=s end}
local now=0
os.clock=function() return now end
local seq=0
local function object(props)
    seq=seq+1
    local obj={id=seq}
    function obj:get_address() return self.id end
    function obj:call(name,...)
        local f=props[name]
        if type(f)=="function" then return f(...) end
        assert(f~=nil,name)
        return f
    end
    function obj:get_field(name) return props[name] end
    return obj
end
local list=function(rows) return object({get_Count=function() return #rows end,get_Item=function(i) return rows[i+1] end}) end
local mesh_path,mdf_path="player/mod/f/pl279/f_arm279.mesh","player/mod/f/pl279/f_arm279.mdf2"
local function holder(path,pointer)
    local h=object({get_ResourcePath=path})
    h.pointer=pointer
    function h:read_qword() return self.pointer end
    return h
end
local function actor(idx,role,guid,wear_chain)
    local a={index=idx,role=role,guid=guid,slots={},chains=wear_chain}
    local root_tr=object({get_Child=function() return nil end,get_GameObject=function() return a.root end})
    a.root=object({get_Valid=true,get_Draw=true,get_Transform=root_tr,
        ["getComponent(System.Type)"]=function(t) return t=="via.motion.Chain" and a.chains or nil end})
    a.player=object({getPlayerIndex=idx,isMasterPlayer=role=="master",isServant=role=="follower",
        get_GameObject=a.root,getPartsGameObject=function(i) return a.slots[i] end,mSex=1})
    a.info=object({_memberIndex=idx,_HunterUniqueId=object({["ToString()"]=guid})})
    a.mh,a.dh=holder(mesh_path,100),holder(mdf_path,200)
    a.renderer=object({getMesh=a.mh,get_Material=a.dh,get_MeshReady=true,get_MaterialReady=true,
        get_MaterialNum=1,getMaterialName="slot"})
    a.slots[2]=object({get_Name="f_arm279",get_Valid=true,get_Update=true,
        ["getComponent(System.Type)"]=function(t) return t=="via.render.Mesh" and a.renderer or nil end})
    return a
end
local master=actor(0,"master","00000000-0000-0000-0000-000000000001")
local b=actor(1,"peer","00000000-0000-0000-0000-000000000002")
local c=actor(2,"peer","00000000-0000-0000-0000-000000000003",true)
local follower=actor(3,"follower","00000000-0000-0000-0000-000000000004")
local avatar=actor(4,"unconfirmed","00000000-0000-0000-0000-000000000005")
local players={master.player,b.player,c.player,follower.player,avatar.player}
local infos={master.info,b.info,c.info,follower.info}
local current=master
for slot=0,4 do
    if not master.slots[slot] then master.slots[slot]=object({get_Valid=true}) end
end
local status=2
local pm=object({findMasterPlayer=function() return current and current.player end,getMasterPlayerID=0,
    PlayerList=list(players),getPlayer=function(i) return players[i+1] end,isReadyPlayer=true})
local map=1
local mission=object({})
local managers={["snow.player.PlayerManager"]=pm,["snow.SnowGameManager"]=object({getStatus=function()return status end}),
    ["snow.QuestManager"]=object({getQuestNo=11,getMapNo=function()return map end,getActiveQuestData=mission}),
    ["snow.VillageAreaManager"]=object({getCurrentAreaNo=3}),
    ["snow.LobbyManager"]=object({_questHunterInfo=list(infos),_hunterInfo=list({master.info})})}
sdk={get_managed_singleton=function(n) return managers[n] end,typeof=function(n)return n end}
local function row(a)
    return {go=a.slots[2],comp=a.renderer,expected={"slot"},
        mesh={path=mesh_path,original=a.mh.pointer},mdf2={path=mdf_path,original=a.dh.pointer}}
end
local function candidates(...)
    local rows={}
    for _,a in ipairs({...}) do rows[a.renderer.id]=row(a) end
    return rows
end
local function resource(ptr) return {get_address=function()return ptr end} end
local resources={[mesh_path]=resource(111),[mdf_path]=resource(222)}
package.loaded["MHRS_HotReload.worn_armor"]={advance=function(batch)
    if batch.touched then return false end
    batch.touched={}
    for _,r in pairs(batch.candidates) do
        if not r.mesh.keep then r.comp:call("getMesh").pointer=111 end
        r.comp:call("get_Material").pointer=222
        touched[r.go]=true
    end
    return true
end,abort=function()end}
package.loaded["MHRS_HotReload.shadow_skeleton"]={capture=function()return nil end}
local peer=require("MHRS_HotReload.peer_equipment")
local snapshot=roster.read()
local same_master=roster.guard(snapshot.parts[master.slots[2].id].entry)
assert(same_master(master.slots[2]))
assert(snapshot.by_index[1].player==b.player and snapshot.by_index[2].player==c.player)
assert(snapshot.parts[follower.slots[2].id].entry.role=="follower" and snapshot.parts[avatar.slots[2].id].entry.role=="unconfirmed")
-- Missing/partial PlayerList still discovers the master's exact five slots independently.
local get_field=pm.get_field
pm.get_field=function(_,name) if name=="PlayerList" then error("list is being replaced") end end
local missing_list=roster.read()
assert(not next(missing_list.by_index))
for slot=0,4 do assert(missing_list.parts[master.slots[slot].id].entry.role=="master") end
local foreign=candidates(master,b)
assert(#peer.partition(foreign,{}, {},function()return true end)==0)
assert(foreign[master.renderer.id] and not foreign[b.renderer.id])
pm.get_field=get_field
status=1
assert(not next(roster.read().by_index),"quest members leaked into the lobby")
status=2
current=nil
assert(not next(roster.read().by_index),"self left but remote mirror still writable")
current=master
local rows=candidates(master,b,c,follower,avatar)
local request={peer_meshes={[mesh_path]=true}}
local tasks,receipt=peer.partition(rows,{[mesh_path]=true},request,function()return true end)
assert(#tasks==2 and #receipt==2 and rows[master.renderer.id] and next(rows,master.renderer.id)==nil)
assert(peer.advance(tasks,nil,resources))
assert(touched[b.slots[2]] and not touched[c.slots[2]] and not touched[follower.slots[2]])
assert(not peer.advance(tasks,nil,resources))
assert(b.mh.pointer==111 and c.mh.pointer==100)
-- The game naturally creates the same member's new local render components.
local c2=actor(2,"peer",c.guid,true)
players[3]=c2.player
c2.mh.pointer,c2.dh.pointer=111,222
peer.tick()
assert(logs[#logs]:find("Peer 2") and logs[#logs]:find("verified on this client"))
-- MDF-only follows the two actual renderers even when one has active physics.
for _,a in ipairs({b,c2}) do a.dh.pointer=200 end
tasks=peer.partition(candidates(b,c2),{},request,function()return true end)
assert(peer.advance(tasks,nil,resources))
assert(not peer.advance(tasks,nil,resources))
assert(b.dh.pointer==222 and c2.dh.pointer==222)
-- A combined equipment and CHAIN change cannot publish a partial MDF.
b.dh.pointer=200
tasks=peer.partition(candidates(b),{[mdf_path]=true,[mesh_path:gsub("%.mesh$",".chain")]=true},
    request,function()return true end)
assert(not peer.advance(tasks,nil,resources) and b.dh.pointer==200)
assert(logs[#logs]:find("awaiting normal equipment rebuild"))
-- Reuse an index after capture; a new member's old renderer must remain intact.
c2.dh.pointer=200
tasks=peer.partition(candidates(c2),{},request,function()return true end)
local replacement=actor(2,"peer","00000000-0000-0000-0000-000000000009",true)
players[3],infos[3]=replacement.player,replacement.info
assert(not peer.advance(tasks,nil,resources) and replacement.dh.pointer==200)
assert(logs[#logs]:find("member left or slot changed"))
-- The previous pending combined update for b was never verified. It must
-- retire on a map change even if every equipment pointer and member id persists.
map=2;now=3;peer.tick()
assert(not same_master(master.slots[2]),"same local actor and slot were accepted on a different map")
assert(logs[#logs]:find("Peer 1") and logs[#logs]:find("scene changed"))
print("PASS separate wearer outcomes, partial roster, quest/lobby directory, follower, spectator, reused slot and cross-map cancellation")
