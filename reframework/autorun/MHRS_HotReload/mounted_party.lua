-- Only the local request and parent are passed to instantiatePlayerParts.
-- Other hunters can however use the same manager-owned via.Prefab. Their
-- current requests are read only to avoid changing a shared standby flag.
local roster=require("MHRS_HotReload.hunter_roster")
local M={}

local function reserve_factories(j,request,reserved)
    local indices=request:call("get_EquipIndex")
    local get=indices and indices:get_type_definition():get_method("Get(System.Int32)")
    if not get then return false end
    local pm=j.pm
    local weapon,sex=pm:call("getPlayerWeaponType",request),pm:call("getPlayerSexType",request)
    for _,r in ipairs(j.rows) do
        if r.factory then
            local index=get:call(indices,r.pack)
            local list=pm:call("getPartsPrefabList",r.pack,weapon,sex,false)
            if not list or type(index)~="number" or index<0 or index>=list:call("get_Count") then return false end
            local other=list:call("get_Item",index)
            if not other then return false end
            if other==r.factory or other:call("get_Path")==r.factory:call("get_Path") then reserved[r.factory]=true end
        end
    end
    return true
end

function M.check(j)
    local scope,members=roster.context()
    if scope~=j.scope then return false end
    local pm=j.pm
    if sdk.get_managed_singleton("snow.player.PlayerManager")~=pm or pm:call("getPlayer",j.index)~=j.player
            or j.player:call("get_GameObject")~=j.root or j.player:get_field("_RefPlayerMaterialCtrl")~=j.ctrl
            or j.ctrl:call("get_GameObject")~=j.root then return false end
    local own_parts={}
    for _,r in ipairs(j.rows) do
        if r.old_material then own_parts[r.old_material]=true end
        if r.created_material then own_parts[r.created_material]=true end
        if r.material then own_parts[r.material]=true end
    end
    if j.head then
        own_parts[j.head.face_mat]=true
        own_parts[j.head.hair_mat]=true
    end
    local parameters=pm:call("get_PlayerParam")
    local own_slots=j.ctrl:get_field("_MaterialParts")
    local players=roster.players(pm)
    local seen,reserved={},{}
    local uncertain=players==nil
    for _,p in pairs(players or {}) do
        if p~=j.player then
            local i,root,ctrl=p:call("getPlayerIndex"),p:call("get_GameObject"),p:get_field("_RefPlayerMaterialCtrl")
            if i==j.index or root==j.root or ctrl==j.ctrl or p:call("isMasterPlayer") then return false end
            local raw=ctrl and ctrl:get_field("_MaterialParts")
            if raw and raw==own_slots then return false end
            if raw then
                local last=j.head and math.min(6,raw:get_size()-1) or 4
                for slot=0,last do if own_parts[raw:get_element(slot)] then return false end end
            end
            if not root or not ctrl or not raw or seen[i] or not root:call("get_Valid") or ctrl:call("get_GameObject")~=root then
                uncertain=true
            end
            seen[i]=true
            local request
            if type(i)=="number" and i>=0 and i<parameters:get_size() then request=parameters:get_element(i) end
            if request and request==j.request then return false end
            if not request or (not p:call("isServant") and (not members[i] or pm:call("getPlayer",i)~=p or not pm:call("isReadyPlayer",i)))
                    or not pm:call("isReadyPlayerLoadState") then uncertain=true
            else
                local ok,complete=pcall(reserve_factories,j,request,reserved)
                if not ok or not complete then uncertain=true end
            end
        end
    end
    for i in pairs(members) do if i~=j.index and not seen[i] then uncertain=true end end
    return true,reserved,uncertain
end
return M
