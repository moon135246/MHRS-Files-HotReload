-- Let Rise construct the five worn parts together when their meshes and
-- physics change. The village hunter can be recreated at its current position.
local M = {}
local shadow_skeleton = require("MHRS_HotReload.shadow_skeleton")
local mesh_type,chain_type = "via.render.Mesh","via.motion.Chain"
local slots={0,1,2,3,4}
local cancelled

local function child(go,t)
    return go and go:call("getComponent(System.Type)",sdk.typeof(t))
end

local function path(holder)
    local name=holder and holder:call("get_ResourcePath")
    return name and name:lower():gsub("^@",""):gsub("\\","/")
end

local function scene()
    local pm=sdk.get_managed_singleton("snow.player.PlayerManager")
    local p=pm and pm:call("findMasterPlayer")
    if p and p:get_type_definition():get_full_name()=="snow.player.PlayerLobbyBase" then
        return pm,p,p:call("get_GameObject")
    end
end

function M.capture(candidates, physics, materials, shadow, missing)
    local pm,p,go=scene()
    if cancelled or not go or not go:call("get_Valid") or not go:call("get_Draw") then return end
    local area=sdk.get_managed_singleton("snow.VillageAreaManager")
    if not area or not area:call("isIdle") then return end
    local eq=sdk.get_managed_singleton("snow.data.EquipDataManager")
    if not eq then return end
    local index=pm:call("getMasterPlayerID")
    if not pm:call("isReadyPlayer",index) or not pm:call("isReadyPlayerLoadState") or
            not p:call("isActivePlayer") or not p:call("isInput") then return end
    local by_object={}
    for _,r in pairs(candidates) do by_object[r.go:get_address()]=r end
    local tx={old=go,parts={},index=index,area=area:call("getCurrentAreaNo"),
        area_flag=p:call("get_AreaMoveFlag"),shadow=shadow}
    local impacted=false
    for _,i in ipairs(slots) do
        local part=p:call("getPartsGameObject",i)
        if not part or not part:call("get_Valid") then return end
        local mesh=child(part,mesh_type)
        local mesh_path=mesh and path(mesh:call("getMesh"))
        local mdf=mesh and path(mesh:call("get_Material"))
        local chain=child(part,chain_type)
        local chain_path=chain and path(chain:call("get_ChainAsset"))
        local groups=chain_path and (physics.chains or {})[chain_path]
        if groups==nil and chain_path then groups=chain:call("get_ResourceGroupCount") end
        local row=by_object[part:get_address()]
        if row then by_object[part:get_address()]=nil end
        if row and not row.mesh.keep then impacted=true end
        tx.parts[i]={name=part:call("get_Name"),mesh=mesh_path,mdf=mdf,chain=chain_path,
            touched=row~=nil and not row.mesh.keep,slots=(row and row.expected) or (mdf and materials[mdf]),
            groups=type(groups)=="number" and groups or nil}
    end
    if impacted then return tx end
end

local function model_ready(tx,p,resources)
    for _,i in ipairs(slots) do
        local expected=tx.parts[i]
        local go=p:call("getPartsGameObject",i)
        if not go or not go:call("get_Valid") then return false,"Equipment part is being built" end
        if go:call("get_Name")~=expected.name then return nil,"The player changed equipped items" end
        local mesh=child(go,mesh_type)
        if expected.mesh then
            if not mesh or not mesh:call("get_MeshReady") or not mesh:call("get_MaterialReady") then
                return false,"Equipment mesh is loading"
            end
            local mh,dh=mesh:call("getMesh"),mesh:call("get_Material")
            if path(mh)~=expected.mesh or path(dh)~=expected.mdf then return false,"Equipment resource path changed" end
            if expected.touched and resources then
                for _,entry in ipairs({{expected.mesh,mh},{expected.mdf,dh}}) do
                    local fresh=resources[entry[1]]
                    if fresh and entry[2]:read_qword(0x10)~=fresh:get_address() then
                        return false,"Equipment still uses an earlier resource: "..entry[1]
                    end
                end
            end
            if expected.slots then
                if mesh:call("get_MaterialNum")~=#expected.slots then return false,"Material slot count changed" end
                for j,name in ipairs(expected.slots) do
                    if mesh:call("getMaterialName",j-1)~=name then return false,"Material slots differ: "..expected.mdf end
                end
            end
        end
        if expected.groups then
            local chain=child(go,chain_type)
            if not chain or path(chain:call("get_ChainAsset"))~=expected.chain or
                    chain:call("get_ResourceGroupCount")~=expected.groups then
                return false,"Physics resource groups differ: "..expected.chain
            end
            if chain:call("get_Enabled") and go:call("get_Update") and
                    (not chain:call("get_Setuped") or chain:call("getGroupCount")~=expected.groups) then
                return false,"Physics simulation is initializing: "..expected.chain
            end
        end
    end
    return true
end

local function request(eq,tx)
    local method=eq:get_type_definition():get_method("reloadPlayerModel")
    local value=eq:call("getMasterPlayerIndex")
    assert(value:call("get_HasValue") and value:call("get_Value")==tx.index,
           "Cannot identify the local player for model reload")
    method:call(eq,false,value)
end

-- A model created outside the equipment menu starts without the old
-- hunter's area participation flag. It controls both rendering and input.
local function resume_hunter(tx,pm,p,go)
    local area=sdk.get_managed_singleton("snow.VillageAreaManager")
    if not area or not area:call("isIdle") or area:call("getCurrentAreaNo")~=tx.area or
            not go or go==tx.old or not go:call("get_Valid") or not p:call("isMasterPlayer") or
            pm:call("getMasterPlayerID")~=tx.index or not pm:call("isReadyPlayer",tx.index) or
            not pm:call("isReadyPlayerLoad") or not pm:call("isReadyPlayerLoadState") then return false end
    if tx.new and tx.new~=go then return false end
    tx.new=go
    if not tx.resumed then
        if p:call("get_AreaMoveFlag")~=tx.area_flag then p:call("setAreaMoveFlag",tx.area_flag) end
        tx.resumed=true
        return false
    end
    return go:call("get_Draw") and p:call("isActivePlayer") and p:call("isInput")
end

local function skeleton_ready(tx,p,resources,scene_components)
    local target=tx.shadow
    if not target then return true end
    if not tx.repair then
        if shadow_skeleton.matches(p,target.expected) then return true end
        local profiles={[target.sex]={[target.scope]={joints=target.expected}}}
        local fresh,reason=shadow_skeleton.capture(p,profiles)
        assert(fresh,reason)
        assert(resources[fresh.request],"Missing prepared skeleton: "..fresh.request)
        local parts={{go=fresh.root}}
        local chains=require("MHRS_HotReload.worn_chain").capture(
            scene_components("via.motion.Chain"),parts,{},{},{},{})
        assert(chains and chains:covers(parts[1]),"Cannot observe the rebuilt hunter's physics")
        tx.repair={candidates={},shadow=fresh,chains=chains}
    end
    local pending=require("MHRS_HotReload.worn_armor").advance(tx.repair,scene_components,resources)
    return not pending,"Waiting for the rebuilt hunter's rest skeleton"
end

function M.advance(tx,resources,scene_components)
    resources=resources or tx.resources
    local pm,p,go=scene()
    if not tx.started then
        if go~=tx.old or not go:call("get_Draw") then error("[live equipment rejected] Village hunter changed") end
        local eq=assert(sdk.get_managed_singleton("snow.data.EquipDataManager"))
        tx.started=true
        tx.deadline=os.clock()+7
        request(eq,tx)
        return true
    end
    local reason="Waiting for the village hunter model"
    if resume_hunter(tx,pm,p,go) then
        local ready
        ready,reason=model_ready(tx,p,resources)
        if ready and not tx.skeleton_done then
            ready,reason=skeleton_ready(tx,p,resources,scene_components)
            if ready then tx.repair=nil;tx.skeleton_done=true end
        end
        if ready then
            tx.stable=(tx.stable or 0)+1
            return tx.stable<2
        end
        tx.stable=0
    end
    if os.clock()>=tx.deadline then error("[live equipment rejected] "..(reason or "Village model not ready")) end
    return true
end

function M.abort(tx)
    if not tx.started then return end
    cancelled=tx
    tx.cancel_deadline=os.clock()+12
    if tx.repair then
        require("MHRS_HotReload.worn_armor").abort(tx.repair)
        tx.repair=nil
    end
end

re.on_application_entry("UpdateBehavior",function()
    if not cancelled then return end
    local pm,p,go=scene()
    if resume_hunter(cancelled,pm,p,go) or os.clock()>=cancelled.cancel_deadline then cancelled=nil end
end)

return M
