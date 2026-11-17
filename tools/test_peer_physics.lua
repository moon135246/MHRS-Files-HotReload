-- A master's physics transaction must not consume or acknowledge its peers.
package.path="reframework/autorun/?.lua;"..package.path
local chain_path="player/mod/f/pl279/f_body_accessory.chain"
local mesh_path="player/mod/f/pl279/f_body279.mesh"
local shadow_path="player/mod/f/pl279/f_shadow.mesh"
local base_path="player/mod/f/bone/f_shadow.mesh"
local logs={}
log={info=function(v) logs[#logs+1]=v end,warn=function(v) error(v) end}
sdk={typeof=function(t) return t end}
local clock=0
os.clock=function() return clock end
local next_id=0
local function object(fields)
    next_id=next_id+1
    fields.id=fields.id or next_id
    function fields:get_address() return self.id end
    function fields:call(method,...)
        local f=self[method]
        if type(f)=="function" then return f(self,...) end
        return f
    end
    return fields
end
local function holder(path,id)
    return object({get_ResourcePath=path,id=id,read_qword=function(h) return h.id end})
end
local function go(name,parent)
    local g=object({get_Name=name,get_Draw=true,get_Update=true,get_Valid=true})
    g["getComponent(System.Type)"]=function(self,t) return self[t] end
    local tr=object({get_GameObject=g,get_Parent=parent and parent.get_Transform})
    if parent then parent.get_Transform.get_Child=tr end
    g.get_Transform=tr
    return g
end
local function actor(index,role,guid)
    local e={index=index,role=role,guid=guid,root=go("hunter"),slots={}}
    e.slots[2]=go("f_body279",e.root)
    e.part=go("accessory",e.slots[2])
    e.chain=object({get_GameObject=e.part,get_ChainAsset=holder(chain_path,10),get_Enabled=true,
        get_ResourceGroupCount=1,getGroupCount=1,get_Setuped=true})
    e.part["via.motion.Chain"]=e.chain
    e.root["via.render.Mesh"]=object({getMesh=holder(base_path,20)})
    e.player=object({get_GameObject=e.root,getPartsGameObject=function(_,slot) return e.slots[slot] end,
        get_field=function() return 1 end,rest=0,entry=e})
    return e
end
local master=actor(0,"master","a")
local left=actor(1,"peer","b")
local right=actor(2,"peer","c")
local follower=actor(3,"follower","d")
local actors={by_index={[1]=left,[2]=right},members={[1]="b",[2]="c"},entries={master,left,right,follower},scope="quest/1"}
local roster=require("MHRS_HotReload.hunter_roster")
roster.read=function()
    actors.parts,actors.roots,actors.owners={},{},{}
    for _,e in ipairs(actors.entries) do
        e.scope=actors.scope
        actors.roots[e.root:get_address()]=e
    end
    return actors
end
roster.render_part=function() return true,holder(mesh_path,99) end
local wanted_rest=1
package.loaded["MHRS_HotReload.shadow_skeleton"]={
    capture=function(p,targets)
        local path=targets.f.pl279 and shadow_path or base_path
        return {player=p,request=path,canonical=base_path,suit_request=shadow_path,
            expected=wanted_rest,changed=p.rest~=wanted_rest and 1 or 0}
    end,
    matches=function(p,expected) return p.rest==expected end}
package.loaded["MHRS_HotReload.worn_chain"]={capture=function(components,roots,expected)
    return {rows=components,expected=expected,covers=function(_,part) return part==roots[1] end}
end}
local aborted=0
package.loaded["MHRS_HotReload.worn_armor"]={advance=function(tx,ctx,refs)
    if not tx.started then tx.started=true;return true end
    if tx.shadow then
        local p=tx.shadow.player
        p.rest=tx.shadow.expected
        p.entry.root["via.render.Mesh"].getMesh.id=refs[tx.shadow.request]:get_address()
    end
    for _,c in ipairs(tx.chains.rows) do
        local n=tx.chains.expected[chain_path]
        if n and not c.fail then
            c.get_ChainAsset.id=refs[chain_path]:get_address()
            c.get_ResourceGroupCount,c.getGroupCount=n,n
        end
    end
    return false
end,abort=function() aborted=aborted+1 end}
local effects=require("MHRS_HotReload.peer_physics")
local refs={}
for i,path in ipairs({chain_path,shadow_path,base_path}) do
    refs[path]={get_address=function()return 100+i end}
end
local function capture(req,live)
    local components={master.chain,left.chain,right.chain,follower.chain}
    local jobs,global=effects.capture(components,req,live,{},function()end)
    assert(#global==1 and global[1]==master.chain)
    return jobs
end
local function result(index,path)
    for _,r in ipairs(effects.status()) do
        if r.index==index and r.path==path then return r.status end
    end
end
local changed_chain={physics={chains={[chain_path]=7}}}
local first=capture(changed_chain,{[chain_path]=true})
assert(left.chain.wearer_owns(left.part))
local equipped=left.slots[2]
left.slots[2]=nil
assert(not left.chain.wearer_owns(left.part),"previous peer slot still allowed a write")
left.slots[2]=equipped
assert(#first==2 and effects.advance(first,nil,refs))
right.chain.fail=true
assert(not effects.advance(first,nil,refs))
assert(result(1,chain_path)=="verified on this client")
assert(result(2,chain_path)=="awaiting normal equipment rebuild")
assert(master.chain.getGroupCount==1 and follower.chain.getGroupCount==1)
right.chain.get_ChainAsset.id=101
right.chain.get_ResourceGroupCount=7
effects.tick()
assert(result(2,chain_path)=="awaiting normal equipment rebuild")
right.chain.getGroupCount=7;clock=2;effects.tick()
assert(result(2,chain_path)=="verified on this client")
local shadows={shadow_skeletons={f={pl279=true}}}
local jobs=capture(shadows,{[shadow_path]=true})
assert(#jobs==2 and effects.advance(jobs,nil,refs) and not effects.advance(jobs,nil,refs))
assert(result(1,shadow_path)=="verified on this client" and result(2,shadow_path)=="verified on this client")
assert(master.player.rest==0 and follower.player.rest==0)
-- Removing the suit override selects the base file for both wearers.
wanted_rest=0
jobs=capture({shadow_skeletons={f={bone=true}}},{[shadow_path]=true})
assert(#jobs==2 and effects.advance(jobs,nil,refs) and not effects.advance(jobs,nil,refs))
assert(result(1,base_path)=="verified on this client" and left.root["via.render.Mesh"].getMesh.id==103)
assert(#capture(shadows,{[mesh_path]=true,[shadow_path]=true})==0,"whole outfit submitted for direct peer binding")
jobs=capture(changed_chain,{[chain_path]=true})
assert(effects.advance(jobs,nil,refs))
local new=actor(2,"peer","replacement")
actors.by_index[2],actors.members[2],actors.entries[3]=new,new.guid,new
assert(not effects.advance(jobs,nil,refs) and aborted==0 and new.chain.getGroupCount==1)
assert(result(2,chain_path)=="member left or slot changed")
-- An unregistered hunter and a detached armor attachment can coexist with
-- an actual NPC borrowing the same CHAIN and an unrelated world prop.
local stranger=actor(4,"unconfirmed","stranger")
stranger.root["snow.player.PlayerBase"]=true
local npc=go("npc")
npc["snow.npc.NpcBase"]=true
local function component(parent,path)
    return object({get_GameObject=go("attachment",parent),get_ChainAsset=holder(path,10)})
end
local orphan=component(nil,chain_path)
local npc_chain=component(npc,chain_path)
local prop_chain=component(nil,"stage/plant.chain")
actors.entries,actors.by_index={master},{}
local groups,global=effects.capture({master.chain,stranger.chain,orphan,npc_chain,prop_chain},changed_chain,
    {[chain_path]=true},{},function()end)
assert(#groups==0 and #global==3 and global[1]==master.chain and global[2]==npc_chain and global[3]==prop_chain)
-- An unchanged membership token cannot keep a pending check in a different quest.
actors.entries,actors.by_index={master,left},{[1]=left}
left.chain.fail,left.chain.getGroupCount=true,1
jobs=capture(changed_chain,{[chain_path]=true})
assert(effects.advance(jobs,nil,refs) and not effects.advance(jobs,nil,refs))
assert(result(1,chain_path)=="awaiting normal equipment rebuild")
actors.scope="quest/2";clock=5;effects.tick()
assert(result(1,chain_path)=="scene changed")
print("PASS independent peer CHAIN and shadow, nested attachments, incomplete roster, world/NPC physics, scope changes and slot reuse")
