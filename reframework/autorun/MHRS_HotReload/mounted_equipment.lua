-- Use the manager's indexed armor factories and the master's original parent.
-- PlayerMaterialParts.start registers a new part on the next game update.
local M={}
local roster=require("MHRS_HotReload.hunter_roster")
local party=require("MHRS_HotReload.mounted_party")
local heads=require("MHRS_HotReload.mounted_head")
local colors=require("MHRS_HotReload.mounted_colors")
local armor=require("MHRS_HotReload.equipped_parts")
local hunter=require("MHRS_HotReload.equipped_hunter")
local shadow=require("MHRS_HotReload.mounted_shadow")
local skeleton=require("MHRS_HotReload.shadow_skeleton")
local elements=require("MHRS_HotReload.array_elements")
local slots={0,4,3,2,1} -- game's creation order: body, head, legs, waist, arms
local packs={[0]=2,[1]=3,[2]=4,[3]=5,[4]=1}
local factory_params={"via.Transform","snow.player.PlayerRequestEquipsData.EquipPack","snow.player.PlayerRequestEquipsData","via.vec3"}
local add_params={"snow.player.PlayerMaterialParts","System.Int32"}
local destroy_params={"via.GameObject"}
local function method(td,name,params,result,is_static)
    while td do
        for _,m in ipairs(td:get_methods()) do
            if m:get_name()==name and m:is_static()==is_static and m:get_return_type():get_full_name()==result then
                local types,match=m:get_param_types(),true
                if #types==#params then
                    for i,t in ipairs(types) do if t:get_full_name()~=params[i] then match=false;break end end
                    if match then return m end
                end
            end
        end
        td=td:get_parent_type()
    end
    error("[normal equip] Missing equipment method "..name)
end
local function component(go,t) return go:call("getComponent(System.Type)",sdk.typeof(t)) end
local function norm(name) return name and name:lower():gsub("^@",""):gsub("\\","/") end
local function close(a,b) return math.abs(a.x-b.x)<.002 and math.abs(a.y-b.y)<.002 and math.abs(a.z-b.z)<.002 end
local function at_slot(j,slot,go,material)
    return j.ctrl:get_field("_MaterialParts"):get_element(slot)==material
        and j.player:call("getPartsGameObject",slot)==go and j.ctrl:call("getPartsGameObject",slot)==go
        and j.player:call("getPartsMaterial",slot)==material and j.ctrl:call("getPartsMaterial",slot)==material
end
local function owned(j,go,row)
    return go and go:call("get_Valid") and go:call("get_Name")==row.expected.name
        and go:call("get_Transform"):call("get_Parent")==j.tr
end
-- A Lua reference can outlive the native GameObject after destroy().
-- Only follow Transform nodes that Rise still exposes on this living root.
-- Never invoke a game method on a retired wrapper to test whether it died.
local function children(j)
    local found={}
    local tr=j.tr:call("get_Child")
    while tr do
        local go=tr:call("get_GameObject")
        if go then found[go:get_address()]=go end
        tr=tr:call("get_Next")
    end
    return found
end
local function same_actor(j)
    local pm=sdk.get_managed_singleton("snow.player.PlayerManager")
    if pm~=j.pm then return false end
    local p=pm:call("findMasterPlayer")
    if p~=j.player then return false end
    local root=p:call("get_GameObject")
    if root~=j.root or not root:call("get_Valid") or not p:call("isMasterPlayer")
            or pm:call("getMasterPlayerID")~=j.index or p:call("getPlayerIndex")~=j.index
            or p:get_field("_RefPlayerMaterialCtrl")~=j.ctrl or pm:call("get_PlayerParam"):get_element(j.index)~=j.request
            or p:call("get_RefWeaponParts")~=j.weapon or hunter.equip_indices(pm)~=j.indices then return false end
    local valid,reserved,uncertain=party.check(j)
    j.reserved,j.uncertain=reserved,uncertain
    return valid
end
local function selected_factory(pm,slot,indices,get,sex,weapon)
    local pack=packs[slot]
    local index=get:call(indices,pack)
    local list=pm:call("getPartsPrefabList",pack,weapon,sex,false)
    if list and type(index)=="number" and index>=0 and index<list:call("get_Count") then
        return list:call("get_Item",index),pack
    end
end
local function shared_cold(factory,reserved,uncertain)
    return (uncertain or reserved[factory]) and not factory:call("get_Standby")
        and not (factory:call("get_Ready") and factory:call("get_Valid"))
end
-- Poll a blocked shared factory without warming it or retiring resources.
function M.factories_available(pm,p,root)
    local i=pm:call("getMasterPlayerID")
    local req=pm:call("get_PlayerParam"):get_element(i)
    local j={pm=pm,player=p,root=root,index=i,ctrl=p:get_field("_RefPlayerMaterialCtrl"),scope=roster.context(),request=req,rows={}}
    local indices=req:call("get_EquipIndex")
    local get=indices:get_type_definition():get_method("Get(System.Int32)")
    local sex,weapon=pm:call("getPlayerSexType",req),pm:call("getPlayerWeaponType",req)
    for _,slot in ipairs(slots) do
        local f,pack=selected_factory(pm,slot,indices,get,sex,weapon)
        if not f then return false end
        j.rows[#j.rows+1]={factory=f,pack=pack}
    end
    local valid,reserved,uncertain=party.check(j)
    if not valid then return false end
    for _,r in ipairs(j.rows) do if shared_cold(r.factory,reserved,uncertain) then return false end end
    return true
end
local function row_at(j,slot,tx,indices,get,sex,weapon,resources)
    local e=tx.parts[slot]
    local go=j.player:call("getPartsGameObject",slot)
    local mp=j.player:call("getPartsMaterial",slot)
    assert(go and go:call("get_Valid") and go:call("get_Update") and go:get_address()==e.object
        and mp and at_slot(j,slot,go,mp) and mp:get_field("_ParentMaterialCtrl")==j.ctrl and mp:call("get_plPartsNo")==slot)
    local tr=go:call("get_Transform")
    assert(tr:call("get_Parent")==j.tr)
    local row={slot=slot,expected=e,old=go,old_id=go:get_address(),old_material=mp,old_material_id=mp:get_address()}
    if e.requested then
        assert(resources[e.mesh_name] and resources[e.mdf_name],"Worn mesh/material generation not staged")
        local f,pack=selected_factory(j.pm,slot,indices,get,sex,weapon)
        local path=e.mesh:gsub("^player/mod/","player/prefab/mod/"):gsub("%.mesh$",".pfb")
        assert(f and f:call("get_Exist") and norm(f:call("get_Path"))==path,"Factory does not match worn item")
        row.factory,row.pack=f,pack
        row.factory_path=path
        row.local_position=tr:call("get_LocalPosition")
        row.same_joints=tr:call("get_SameJointsConstraint")
        local chain=component(go,"via.motion.Chain")
        row.chain_enabled=chain and chain:call("get_Enabled") or false
        if row.chain_enabled then row.chain_frozen=chain:call("get_FreezePose") end
    end
    return row
end
function M.capture(tx,pm,p,root,resources,components)
    if tx.mount_blocked then return end
    local scope=roster.context()
    if not scope then return end
    local request=assert(pm:call("get_PlayerParam"):get_element(tx.index))
    local ctrl=assert(p:get_field("_RefPlayerMaterialCtrl"))
    local j={pm=pm,player=p,root=root,tr=root:call("get_Transform"),request=request,ctrl=ctrl,
        index=tx.index,scope=scope,indices=hunter.equip_indices(pm),weapon=p:call("get_RefWeaponParts"),
        rows={},originals={},resources=resources,phase="warm",next_update=true,deadline=os.clock()+3}
    assert(j.indices and ctrl:call("get_GameObject")==root and same_actor(j))
    local indices=request:call("get_EquipIndex")
    local get=assert(indices:get_type_definition():get_method("Get(System.Int32)"))
    local weapon,sex=pm:call("getPlayerWeaponType",request),pm:call("getPlayerSexType",request)
    j.create=method(pm:get_type_definition(),"instantiatePlayerParts",factory_params,"via.GameObject",false)
    j.add=method(ctrl:get_type_definition(),"addMaterialParts",add_params,"System.Void",false)
    j.destroy=method(sdk.find_type_definition("via.GameObject"),"destroy",destroy_params,"System.Void",true)
    for _,slot in ipairs(slots) do
        local row=row_at(j,slot,tx,indices,get,sex,weapon,resources)
        j.originals[row.old]=true
        j.rows[#j.rows+1]=row
    end
    assert(same_actor(j),"Local equipment or material controller is shared with another actor")
    for _,r in ipairs(j.rows) do
        if r.factory and shared_cold(r.factory,j.reserved,j.uncertain) then
            error("Shared cold armor factory: "..r.factory_path)
        end
        if r.slot==4 and r.factory then j.head=heads.capture(j,r) end
    end
    j.shadow_target,j.components=tx.shadow,components
    return j
end
local function restore_factories(j)
    local ok,valid,reserved,uncertain=pcall(party.check,j)
    for _,r in ipairs(j.rows) do
        if r.warmed then
            -- A joining hunter can have claimed our formerly private factory.
            -- Leave its standby state to the game's loader in that case.
            if ok and valid and not uncertain and not reserved[r.factory] and r.factory:call("get_Standby") then
                r.factory:call("set_Standby",false)
            end
            r.warmed=nil
        end
    end
end

function M.release(j)
    -- An abort can outlive the file worker. Returning private standby flags
    -- must not depend on successful shadow or slot recovery.
    restore_factories(j)
    if not j.retiring and j.shadow then return shadow.abort(j.shadow) end
    return false
end
local function warm(j)
    local ready=true
    for _,r in ipairs(j.rows) do
        if r.factory then
            if not r.factory:call("get_Standby") and not (r.factory:call("get_Ready") and r.factory:call("get_Valid")) then
                assert(not j.uncertain and not j.reserved[r.factory],"Another hunter can use cold armor factory "..r.factory_path)
                r.warmed=true;r.factory:call("set_Standby",true)
            end
            if not r.factory:call("get_Ready") or not r.factory:call("get_Valid") then
                ready=false;j.waiting=r.factory_path.." ready="..tostring(r.factory:call("get_Ready")).." valid="..tostring(r.factory:call("get_Valid"))
            else assert(norm(r.factory:call("get_ResourcePath"))==r.factory_path,"Warmed factory resource differs from equipped item") end
        end
    end
    return ready
end
local function spawn(j)
    for _,r in ipairs(j.rows) do assert(at_slot(j,r.slot,r.old,r.old_material),"Equipment changed while warming factories") end
    for _,r in ipairs(j.rows) do
        if r.factory then
            local pos=r.old:call("get_Transform"):call("get_Position")
            local go=assert(j.create:call(j.pm,j.tr,r.pack,j.request,pos),"Armor factory did not return a part")
            assert(not j.originals[go],"Factory returned an original part")
            r.new,r.new_id=go,go:get_address()
            assert(owned(j,go,r),"New part attached to a different parent")
            r.created_material=component(go,"snow.player.PlayerMaterialParts")
            r.created_material_id=r.created_material and r.created_material:get_address()
        end
    end
end
local function generation_ready(j,r)
    local go,e=r.new,r.expected
    if not owned(j,go,r) or not go:call("get_Update") then return false,"parent or update changed" end
    local tr=go:call("get_Transform")
    if not close(tr:call("get_LocalPosition"),r.local_position) or tr:call("get_SameJointsConstraint")~=r.same_joints then
        local a,b=tr:call("get_LocalPosition"),r.local_position
        return false,("local=(%.4f,%.4f,%.4f) expected=(%.4f,%.4f,%.4f) same_joints=%s expected=%s")
            :format(a.x,a.y,a.z,b.x,b.y,b.z,tostring(tr:call("get_SameJointsConstraint")),tostring(r.same_joints))
    end
    local mp=component(go,"snow.player.PlayerMaterialParts")
    local mesh,mh,dh=roster.render_part(go)
    if not mp or not mesh or mp:get_field("_ParentMaterialCtrl")~=j.ctrl or mp:call("get_plPartsNo")~=r.slot
            or mp:call("get_RefMesh")~=mesh or not mesh:call("get_MeshReady") or not mesh:call("get_MaterialReady") then
        return false,("part=%s ctrl=%s/%s slot=%s/%d mesh=%s mdf=%s"):format(tostring(mp~=nil),tostring(mp and mp:get_field("_ParentMaterialCtrl")),
            tostring(j.ctrl),tostring(mp and mp:call("get_plPartsNo")),r.slot,tostring(mesh and mesh:call("get_MeshReady")),tostring(mesh and mesh:call("get_MaterialReady")))
    end
    local ma,da=mh:read_qword(0x10),dh:read_qword(0x10)
    local mt,dt=j.resources[e.mesh_name]:get_address(),j.resources[e.mdf_name]:get_address()
    if ma~=mt or da~=dt then return false,("mesh=%s/%s mdf=%s/%s"):format(tostring(ma),tostring(mt),tostring(da),tostring(dt)) end
    local chain=component(go,"via.motion.Chain")
    if mp:get_field("_RefChain")~=chain then return false,"material RefChain differs from component" end
    local h=chain and chain:call("get_ChainAsset")
    if e.incoming_chain==false and h and h:read_qword(0x10)~=0 then return false,"unexpected CHAIN asset" end
    if type(e.incoming_chain)=="number" then
        local path=e.mesh:gsub("%.mesh$",".chain")
        local res=j.resources[path] or (h and j.resources[h:call("get_ResourcePath")])
        if not h or norm(h:call("get_ResourcePath"))~=path or not res or h:read_qword(0x10)~=res:get_address()
                or chain:call("get_ResourceGroupCount")~=e.incoming_chain then
            return false,("chain=%s/%s resource=%s/%s groups=%s/%d"):format(tostring(h and h:call("get_ResourcePath")),path,
                tostring(h and h:read_qword(0x10)),tostring(res and res:get_address()),tostring(chain and chain:call("get_ResourceGroupCount")),e.incoming_chain)
        end
    end
    if h and h:read_qword(0x10)~=0 then
        if r.chain_enabled and not chain:call("get_Enabled") then return false,"previous CHAIN enabled, new CHAIN disabled" end
        if r.chain_enabled and chain:call("get_FreezePose")~=r.chain_frozen then
            return false,"CHAIN freeze differs from original: expected "..tostring(r.chain_frozen)
        end
        if chain:call("get_Enabled") and (not chain:call("get_Setuped") or chain:call("getGroupCount")~=chain:call("get_ResourceGroupCount")) then
            return false,("chain setup=%s active=%s/%s"):format(tostring(chain:call("get_Setuped")),tostring(chain:call("getGroupCount")),tostring(chain:call("get_ResourceGroupCount")))
        end
        if e.terminals and not r.local_names then
            r.local_names={}
            for _,n in pairs(elements(mesh:call("getJointNameList",mh),"new equipment joints")) do
                r.local_names[type(n)=="string" and n or n:call("ToString()")]=true
            end
        end
        for _,n in ipairs(e.terminals or {}) do
            -- Some PAK chains retain a terminal absent from the mod mesh
            -- (Mei body_chain_end still simulates one group). Insist that
            -- every terminal authored on the new mesh exists on its Transform.
            if r.local_names[n] and not tr:call("getJointByName(System.String)",n) then
                return false,"missing CHAIN terminal "..n
            end
        end
    end
    r.material,r.material_id=mp,mp:get_address()
    return armor.part_ready(go,e,j.resources)
end
local function ready(j,after)
    if j.shadow_target and not skeleton.matches(j.player,j.shadow_target.expected) then j.waiting="shadow rests";return false end
    for _,r in ipairs(j.rows) do
        j.waiting=r.expected.name
        if not r.factory then
            if not at_slot(j,r.slot,r.old,r.old_material) or not armor.part_ready(r.old,r.expected,j.resources) then return false end
        else
            local ok,why=generation_ready(j,r)
            if not ok then j.waiting=r.expected.name.." "..tostring(why);return false end
            if not at_slot(j,r.slot,r.new,r.material) then
                if after then
                    local raw=j.ctrl:get_field("_MaterialParts"):get_element(r.slot)
                    -- The handover phase has already checked that every
                    -- original left the Transform tree before calling ready.
                    if not raw or raw==r.old_material then j.add:call(j.ctrl,r.material,r.slot) end
                end
                if not at_slot(j,r.slot,r.new,r.material) then
                    local raw=j.ctrl:get_field("_MaterialParts"):get_element(r.slot)
                    j.waiting=("%s registered=%s expected=%s"):format(r.expected.name,tostring(raw and raw:get_address()),tostring(r.material:get_address()))
                    return false
                end
            end
            if not after and not owned(j,r.old,r) then return false end
            local dyed,detail=colors.ready(j,r,after)
            if not dyed then j.waiting=r.expected.name.." "..tostring(detail);return false end
        end
    end
    local head_ready,why=heads.ready(j,j.head)
    if not head_ready then j.waiting=why;return false end
    j.waiting=nil
    return true
end

function M.repair_registry(j)
    if not j.retiring or not same_actor(j) then return end
    j.step="registry: current children"
    local attached=children(j)
    for _,r in ipairs(j.rows) do
        j.step="registry: slot "..r.slot
        local survivor=r.new_id and attached[r.new_id]
        if r.retired and not attached[r.old_id] and owned(j,survivor,r) and r.material then
            local raw=j.ctrl:get_field("_MaterialParts"):get_element(r.slot)
            if (not raw or raw==r.old_material) and component(survivor,"snow.player.PlayerMaterialParts")==r.material
                    and r.material:get_field("_ParentMaterialCtrl")==j.ctrl and r.material:call("get_plPartsNo")==r.slot then
                j.add:call(j.ctrl,r.material,r.slot)
            end
        end
    end
end
function M.advance(j)
    j.next_update=nil
    j.step=j.phase..": check master"
    assert(same_actor(j),"[village changed] Master, scene or equipment changed while mounting armor")
    assert(os.clock()<j.deadline,"Worn armor did not complete "..j.phase.." ("..tostring(j.waiting)..")")
    if j.phase=="warm" then
        if not warm(j) then return true end
        j.shadow=shadow.begin(j.shadow_target,j.resources,j.components)
        j.phase="shadow";j.deadline=os.clock()+4
    end
    if j.phase=="shadow" then
        if j.shadow then
            local pending,next_update=shadow.advance(j.shadow)
            j.next_update=next_update
            if pending then return true end
        end
        spawn(j);j.phase="stage";j.deadline=os.clock()+3
        j.next_update=true -- PlayerMaterialParts.start registers on a later update.
        return true
    end
    if j.phase=="stage" then
        j.step="stage: verify new parts"
        if not ready(j,false) then j.stable=0;return true end
        j.stable=(j.stable or 0)+1
        if j.stable<2 then j.next_update=true;return true end
        -- No original is retired until all slots have naturally registered
        -- and their renderer, CHAIN and resource generations are verified.
        j.retiring=true
        for _,r in ipairs(j.rows) do
            if r.new then
                j.step="retire: slot "..r.slot
                local draw=r.old:call("get_DrawSelf")
                if r.new:call("get_DrawSelf")~=draw then r.new:call("set_DrawSelf",draw) end
                j.destroy:call(nil,r.old)
                r.retired=true
            end
        end
        j.phase="handover";j.deadline=os.clock()+2;j.stable=0
        j.next_update=true
        return true
    end
    j.step="handover: current children"
    local attached=children(j)
    for _,r in ipairs(j.rows) do
        if r.retired and attached[r.old_id] then return true end
        if r.retired and not attached[r.new_id] then error("Registered replacement left root: "..r.expected.name) end
    end
    j.step="handover: verify current slots"
    if not ready(j,true) then j.stable=0;return true end
    j.stable=j.stable+1
    if j.stable<2 then j.next_update=true;return true end
    restore_factories(j)
    return false
end

-- Before retirement, discard only our generated parts; re-register surviving
-- originals after destruction. Once retirement has started, preserve the new
-- slots and let the normal game loader finish any partial handover.
function M.rollback(j)
    j.step="rollback: check master"
    if not same_actor(j) then
        if not j.retiring and j.shadow then
            local ok,pending=pcall(shadow.abort,j.shadow)
            if ok and pending then return true end
        end
        restore_factories(j)
        return false
    end
    local waiting=false
    j.step="rollback: current children"
    local attached=children(j)
    for _,r in ipairs(j.rows) do
        j.step="rollback: remove slot "..r.slot
        local generated=r.new_id and attached[r.new_id]
        if r.retired and attached[r.old_id] then waiting=true
        elseif not r.retired and generated then
            if owned(j,generated,r) and not r.cancelling and
                    (not r.created_material or component(generated,"snow.player.PlayerMaterialParts")==r.created_material) then
                j.destroy:call(nil,generated);r.cancelling=true
            end
            if r.cancelling then waiting=true end
        end
    end
    if waiting then return true end
    for _,r in ipairs(j.rows) do
        if r.new then
            j.step="rollback: register slot "..r.slot
            local keep=attached[r.retired and r.new_id or r.old_id]
            local mp=r.retired and r.material or r.old_material
            local raw=j.ctrl:get_field("_MaterialParts"):get_element(r.slot)
            if owned(j,keep,r) and component(keep,"snow.player.PlayerMaterialParts")==mp and
                    raw~=mp and (not raw or raw==(r.retired and r.old_material or r.created_material)) then
                j.add:call(j.ctrl,mp,r.slot)
            end
        end
    end
    j.step="rollback: appearance"
    if j.head and not j.head.row.retired then heads.abort(j,j.head) end
    if not j.retiring and j.shadow and shadow.abort(j.shadow) then return true end
    j.step="rollback: factory standby"
    restore_factories(j)
    return false
end

local function address(o) return o and tostring(o:get_address()) end

-- Reset Scripts can discard Lua references before deferred destruction takes
-- effect. Keep only process-local identities, then rediscover actual children
-- through the current master's Transform before finishing that rollback.
function M.reset_record(j,pid)
    if not pid or not same_actor(j) then return end
    local r={pid=pid,expires=os.time()+18,scope=j.scope,root=address(j.root),request=address(j.request),
        ctrl=address(j.ctrl),index=j.index,rows={}}
    local h=j.head
    if h and h.applied and not h.row.retired then
        r.head={target=h.target,old_body=h.old_body,old_face=h.old_face,old_hair=h.old_hair,
            hair=address(h.hair),hair_mat=address(h.hair_mat),face=address(h.face),face_mat=address(h.face_mat)}
    end
    local bound=j.shadow and j.shadow.batch.shadow
    if not j.retiring and bound and bound.owner and bound.fresh then
        r.expires=os.time()+85
        r.replay={id=table.concat({pid,r.root,address(bound.fresh),os.clock()},"/"),
            indices=j.indices,weapon=address(j.weapon),slots={},shadow=bound.canonical,suit=bound.suit_request}
    end
    local attached=r.replay and children(j)
    for _,row in ipairs(j.rows) do
        if r.replay then
            local e=row.expected
            local old=attached[row.old_id]
            local mp=old and component(old,"snow.player.PlayerMaterialParts")
            if not mp or mp:get_address()~=row.old_material_id then r.replay=nil
            else
                local u=row.slot==4 and mp:get_field("_PlayerUserDataParts")
                r.replay.slots[#r.replay.slots+1]={slot=row.slot,go=tostring(row.old_id),mp=tostring(row.old_material_id),
                    mesh=e.mesh,mdf=e.mdf,chain=e.chain,helmet_user=u and norm(u:call("get_Path")),requested=e.requested}
            end
        end
        if row.new then
            local keep=row.retired and row.new_id or row.old_id
            local drop=row.retired and row.old_id or row.new_id
            local keep_mp=row.retired and row.material_id or row.old_material_id
            local drop_mp=row.retired and row.old_material_id or (row.material_id or row.created_material_id)
            r.rows[#r.rows+1]={slot=row.slot,name=row.expected.name,keep=tostring(keep),drop=tostring(drop),
                keep_material=tostring(keep_mp),drop_material=drop_mp and tostring(drop_mp),retired=row.retired or false}
        end
    end
    if #r.rows>0 or r.replay then return r end
end

function M.reset_cleanup(j)
    -- The next VM cannot balance a previous VM's standby acquisition.
    -- Restoring it is independent of the game's deferred part destruction.
    pcall(M.rollback,j)
    restore_factories(j)
end

function M.recover_record(r)
    local pm=sdk.get_managed_singleton("snow.player.PlayerManager")
    local p=pm and pm:call("findMasterPlayer")
    if not p then return true end
    if pm:call("getMasterPlayerID")~=r.index or p:call("getPlayerIndex")~=r.index or not p:call("isMasterPlayer")
            or pm:call("getPlayer",r.index)~=p then return false end
    local root=p:call("get_GameObject")
    local ctrl=p:get_field("_RefPlayerMaterialCtrl")
    if not root or not root:call("get_Valid") or address(root)~=r.root or address(ctrl)~=r.ctrl then return false end
    local request=pm:call("get_PlayerParam"):get_element(r.index)
    if address(request)~=r.request then return false end
    local recovery={pm=pm,player=p,index=r.index,scope=r.scope,root=root,request=request,ctrl=ctrl,rows={}}
    local ids={}
    local tr=root:call("get_Transform")
    recovery.tr=tr
    local child=tr:call("get_Child")
    while child do
        local go=child:call("get_GameObject")
        if go and go:call("get_Valid") then ids[address(go)]=go end
        child=child:call("get_Next")
    end
    for _,row in ipairs(r.rows) do
        local keep,drop=ids[row.keep],ids[row.drop]
        recovery.rows[#recovery.rows+1]={old_material=keep and component(keep,"snow.player.PlayerMaterialParts"),
            created_material=drop and component(drop,"snow.player.PlayerMaterialParts")}
    end
    if r.head then
        local h=r.head
        local hair,face=ids[h.hair],ids[h.face]
        local hm=hair and component(hair,"snow.player.PlayerMaterialParts")
        local fm=face and component(face,"snow.player.PlayerMaterialParts")
        if not hm or not fm or address(hm)~=h.hair_mat or address(fm)~=h.face_mat then return false end
        recovery.head={applied=true,old_body=h.old_body,old_face=h.old_face,old_hair=h.old_hair,target=h.target,
            hair=hair,hair_mat=hm,face=face,face_mat=fm}
    end
    if not party.check(recovery) then return false end
    local waiting=false
    for _,row in ipairs(r.rows) do
        local keep,drop=ids[row.keep],ids[row.drop]
        if not keep or keep:call("get_Name")~=row.name then return false end
        local keep_mp=component(keep,"snow.player.PlayerMaterialParts")
        if not keep_mp or address(keep_mp)~=row.keep_material or keep_mp:get_field("_ParentMaterialCtrl")~=ctrl then return false end
        if drop then
            local mp=component(drop,"snow.player.PlayerMaterialParts")
            if drop:call("get_Name")~=row.name or not mp or address(mp)~=row.drop_material or mp:call("get_plPartsNo")~=row.slot then return false end
            if not row.retired and not row.destroying then
                method(sdk.find_type_definition("via.GameObject"),"destroy",destroy_params,"System.Void",true):call(nil,drop)
                row.destroying=true
            end
            waiting=true
        else
            local raw=ctrl:get_field("_MaterialParts"):get_element(row.slot)
            if raw~=keep_mp then
                if raw and address(raw)~=row.drop_material then return false end
                method(ctrl:get_type_definition(),"addMaterialParts",add_params,"System.Void",false):call(ctrl,keep_mp,row.slot)
            end
            if not at_slot({player=p,ctrl=ctrl},row.slot,keep,keep_mp) then waiting=true end
        end
    end
    if not waiting and recovery.head then heads.abort(recovery,recovery.head) end
    return waiting,not waiting
end

function M.replay_state(r)
    local v=r.replay
    local pm=sdk.get_managed_singleton("snow.player.PlayerManager")
    local p=pm and pm:call("findMasterPlayer")
    if not v or not p or not p:call("isMasterPlayer") or pm:call("getMasterPlayerID")~=r.index or p:call("getPlayerIndex")~=r.index then return end
    local root,ctrl=p:call("get_GameObject"),p:get_field("_RefPlayerMaterialCtrl")
    local req=pm:call("get_PlayerParam"):get_element(r.index)
    if not root or not root:call("get_Valid") or address(root)~=r.root or address(ctrl)~=r.ctrl or address(req)~=r.request
            or hunter.equip_indices(pm)~=v.indices or address(p:call("get_RefWeaponParts"))~=v.weapon then return end
    local j={pm=pm,index=r.index,player=p,ctrl=ctrl,request=req,root=root,scope=r.scope,rows={}}
    local paths,worn={},{}
    paths[v.shadow]=true
    for _,row in ipairs(v.slots) do
        local mp=ctrl:get_field("_MaterialParts"):get_element(row.slot)
        if address(mp)~=row.mp then return end
        local go=p:call("getPartsGameObject",row.slot)
        if not go or not go:call("get_Valid") or address(go)~=row.go or not at_slot(j,row.slot,go,mp)
                or go:call("get_Transform"):call("get_Parent")~=root:call("get_Transform")
                or mp:get_field("_ParentMaterialCtrl")~=ctrl then return end
        j.rows[#j.rows+1]={old_material=mp}
        if row.requested then
            local _,h=roster.render_part(go)
            if not h or type(row.mdf)~="string" or norm(h:call("get_ResourcePath"))~=row.mesh then return end
            paths[row.mesh],paths[row.mdf]=true,true
            if row.chain then paths[row.chain]=true end
            if row.helmet_user then paths[row.helmet_user]=true end
            worn[row.mesh]=tostring(h:read_qword(0x10))
        end
    end
    if #j.rows==5 and next(worn) and party.check(j) then return {id=v.id,paths=paths,suit=v.suit,worn=worn} end
end

function M.rebase(j,tx)
    assert(same_actor(j),"[village changed] Master changed during armor recovery")
    local attached=children(j)
    for _,r in ipairs(j.rows) do
        local go,mp=attached[r.old_id],r.old_material
        if r.retired then go,mp=attached[r.new_id],r.material end
        assert(owned(j,go,r) and at_slot(j,r.slot,go,mp),"[village changed] Wearer changed during armor recovery")
        local e=tx.parts[r.slot]
        e.object=go:get_address()
        local _,h=roster.render_part(go)
        assert(h,"[village changed] Missing equipped renderer after recovery")
        e.before=h:read_qword(0x10)
    end
end
return M
