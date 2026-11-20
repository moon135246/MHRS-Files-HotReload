-- Restore five pieces normally, then edit only the restored leg. The
-- previous renderer's provenance must belong to the inspected player slot.
package.path="reframework/autorun/?.lua;"..package.path
sdk={typeof=function(t) return t end}
local armor=require("MHRS_HotReload.worn_armor")
local peer=require("MHRS_HotReload.peer_equipment")
local function object(id,parent,name)
    local g={get_address=function() return id end}
    local tr={call=function(_,key)
        if key=="get_GameObject" then return g end
        assert(key=="get_Parent");return parent and parent:call("get_Transform")
    end}
    function g:call(key)
        if key=="get_Valid" or key=="get_Update" then return true end
        if key=="get_Name" then return name end
        if key=="get_Transform" then return tr end
        if key=="getComponent(System.Type)" then return self.mesh end
        error(key)
    end
    return g
end
local function holder(path,id)
    local h = {add_ref=function() end,read_qword=function() return id end,
        call=function(_,k) assert(k=="get_ResourcePath");return path end}
    function h:get_address() return self end
    return h
end
local owner={role="master",scope="village/5",index=0,root=object(80),slots={}}
local actors={entries={owner},parts={},scope=owner.scope}
local tx={stable=2,new_address="80",index=0,parts={}}
local batch={village=tx,stock_scope=owner.scope,stock_meshes={},platform={}}
local resources,instances,rows={},{},{}
local function instance(id,go)
    instances[id]=instances[id] or {go=go}
    return instances[id]
end
for i,part_name in ipairs({"body","arm","waist","leg","helm"}) do
    local slot=i-1
    local name="f_"..part_name.."279"
    local path="player/mod/f/pl279/"..name..".mesh"
    local go=object(100+i,owner.root,name)
    local h=holder(path,300+i)
    go.mesh={get_address=function() return 200+i end,call=function(_,k)
        if k=="getMesh" or k=="get_Material" then return h end
        if k=="get_MeshReady" or k=="get_MaterialReady" then return true end
        error(k)
    end}
    rows[slot]={go=go,comp=go.mesh,mesh={path=path,original=300+i}}
    tx.parts[slot]={touched=true,name=name,mesh=path,mesh_name=path}
    owner.slots[slot]=go
    actors.parts[go:get_address()]={entry=owner,go=go,slot=slot}
    resources[path]={get_address=function() return 300+i end,create_holder=function() return holder(path,300+i) end}
    batch.stock_meshes[path]=true
    batch.platform[path]=true
    peer.generation(path,300+i,nil) -- this was a full outfit, not a vertex-only request
end
local leg=rows[3]
local slot=actors.parts[leg.go:get_address()]
local function trusted()
    return armor.resident_stock(leg,instances[leg.comp:get_address()],slot)
end
assert(not trusted() and not peer.stock_layout(leg.mesh.path,leg.mesh.original,false))
batch.platform[leg.mesh.path]=nil
armor.remember_stock(batch,actors,resources,instance)
assert(not trusted(),"ordinary PAK without the physical-source receipt was trusted")
batch.platform[leg.mesh.path]=true
local loaded=resources[leg.mesh.path]
resources[leg.mesh.path]={get_address=function() return 990 end}
armor.remember_stock(batch,actors,resources,instance)
assert(not trusted(),"a request not attached to the worn renderer acquired provenance")
resources[leg.mesh.path]=loaded
tx.stable=1
armor.remember_stock(batch,actors,resources,instance)
assert(not trusted(),"incomplete model reload was trusted")
tx.stable=2
armor.remember_stock(batch,actors,resources,instance)
assert(trusted() and not peer.stock_layout(leg.mesh.path,leg.mesh.original,false))
leg.vertex_owner=trusted
local sibling={call=function() return rows[1].go end}
local rebuild,vertices=armor.requires_part_assembly({leg},{[leg.mesh.path]=true},{sibling},owner.root,{})
assert(not rebuild and vertices)
leg.mesh.original=999
assert(not trusted())
leg.mesh.original=304
slot.slot=1;assert(not trusted());slot.slot=3
owner.scope="quest/1/2/3";assert(not trusted());owner.scope="village/5"
owner.role="peer";assert(not trusted());owner.role="master"
owner.root=object(81);assert(not trusted())
print("Verified worn PAK mesh supports the next local vertex edit after whole-outfit removal; foreign, stale and ordinary generations are excluded")
