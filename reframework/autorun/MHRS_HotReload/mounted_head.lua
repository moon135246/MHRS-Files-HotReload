-- A FullBody helmet supplies its own head. On a normal load Rise records
-- that on the face material and suppresses the face and hairstyle objects.
local M={}
local function part(j,slot)
    local mp=j.ctrl:get_field("_MaterialParts"):get_element(slot)
    if not mp or mp:get_field("_ParentMaterialCtrl")~=j.ctrl or mp:call("get_plPartsNo")~=slot then return end
    local go=mp:call("get_GameObject")
    if go and go:call("get_Valid") and go:call("get_UpdateSelf") and go:call("get_Transform"):call("get_Parent")==j.tr
            and j.player:call("getPartsGameObject",slot)==go and j.ctrl:call("getPartsGameObject",slot)==go then return go,mp end
end
local function hair_info(helm)
    local user=helm:get_field("_PlayerUserDataParts")
    local face=user and user:get_field("_FaceInfo")
    if not face or face:get_field("FullFace")~=false then return end
    local hair=user:get_field("_HairInfo")
    local n=hair and hair:get_size()
    if not n or n<1 or n>256 then return end
    -- Every hairstyle must have the same visibility rule, so this does not
    -- guess at the conversion from a hair prefab index to a HairInfo index.
    for i=0,n-1 do
        local h=hair[i]
        if not h or h:get_field("HairDispOff")~=false or h:get_field("HairDispOffParts")~=-1 then return end
    end
    return face:get_field("FullBody")
end
function M.capture(j,row)
    local spec=row.expected.helmet
    if not spec then return end
    local target
    for _,e in ipairs(spec.fields or {}) do
        if e.section=="face" and e.field=="FullBody" then target=e.value end
        if (e.field=="FullFace" or e.field=="HairDispOff") and e.value~=false
                or e.field=="HairDispOffParts" and e.value~=-1 then error("[normal equip] Helmet uses custom face or hair concealment") end
    end
    assert(type(target)=="boolean" and not spec.deferred,"[normal equip] Current helmet USER visibility is unknown")
    assert(type(hair_info(row.old_material))=="boolean","[normal equip] Previous helmet used custom face or hair concealment")
    local hair,hair_mat=part(j,5)
    local face,face_mat=part(j,6)
    assert(hair and face and face_mat:call("get_IsNpcFace")==false and face_mat:get_field("_IsFullFace")==false,
        "Face or hairstyle not owned by this local helmet")
    local old=face_mat:get_field("_IsFullBody")
    local face_draw,hair_draw=face:call("get_DrawSelf"),hair:call("get_DrawSelf")
    assert(type(old)=="boolean" and face_draw==not old and hair_draw==not old,"[normal equip] Independent face or hairstyle visibility override")
    assert(row.old:call("get_DrawSelf") or old==target,"[normal equip] Helmet display option is hiding this part")
    return {row=row,target=target,hair=hair,hair_mat=hair_mat,face=face,face_mat=face_mat,
        old_body=old,old_face=face_draw,old_hair=hair_draw}
end
local function owned(j,h)
    local hair,hm=part(j,5)
    local face,fm=part(j,6)
    return hair==h.hair and hm==h.hair_mat and face==h.face and fm==h.face_mat
end
local function matches(h)
    return h.face_mat:get_field("_IsFullBody")==h.target and h.face:call("get_DrawSelf")==not h.target
        and h.hair:call("get_DrawSelf")==not h.target
end
function M.ready(j,h)
    if not h then return true end
    if not owned(j,h) then return false,"Face or hairstyle changed" end
    local row=h.row
    if not row.material or j.ctrl:get_field("_MaterialParts"):get_element(4)~=row.material then return false,"New helmet not registered" end
    if not h.source_ok then
        if hair_info(row.material)~=h.target then return false,"Worn helmet USER differs from staged visibility" end
        h.source_ok=row.material:get_field("_PlayerUserDataParts")
    end
    if row.material:get_field("_PlayerUserDataParts")~=h.source_ok or h.source_ok:get_field("_FaceInfo"):get_field("FullBody")~=h.target then
        return false,"Worn helmet USER changed"
    end
    if matches(h) then h.finished=h.applied;return true end
    if h.finished then return false,"Face/hair visibility did not persist" end
    if not h.applied then
        assert(h.face_mat:get_field("_IsFullBody")==h.old_body and h.face:call("get_DrawSelf")==h.old_face
            and h.hair:call("get_DrawSelf")==h.old_hair,"Another owner changed the face or hairstyle")
        h.applied=true
        if h.target then
            -- Rise's controller consumes the current helmet and local creation
            -- data. It marks the face FullBody immediately, then hides it on
            -- the following update. The player wrapper does not do this.
            local base=j.pm:call("get_PlayerBaseData"):get_element(j.index)
            local sex=j.pm:call("getPlayerSexType",j.request)
            assert(base and (sex==0 or sex==1) and j.pm:call("get_PlayerParam"):get_element(j.index)==j.request,
                "Local creation request is unavailable for helmet visibility")
            j.ctrl:call("setPartsEnable",j.index,sex==1,base,j.request)
            j.next_update=true
            return false,"Waiting for helmet display update"
        end
    end
    -- The stock controller does not clear the cached FullBody bit when a
    -- previously worn costume is removed. Only the verified local nodes and
    -- the same three flags distinguished the two native appearances.
    if h.face_mat:get_field("_IsFullBody")~=h.target then h.face_mat:set_field("_IsFullBody",h.target) end
    if h.face:call("get_DrawSelf")==h.target then h.face:call("set_DrawSelf",not h.target) end
    if h.hair:call("get_DrawSelf")==h.target then h.hair:call("set_DrawSelf",not h.target) end
    h.finished=true
    return matches(h),"Face/hair visibility readback differs"
end
function M.abort(j,h)
    if not h or not h.applied or not owned(j,h) then return end
    if h.face_mat:get_field("_IsFullBody")==h.target and h.old_body~=h.target then h.face_mat:set_field("_IsFullBody",h.old_body) end
    if h.face:call("get_DrawSelf")==not h.target and h.old_face==h.target then h.face:call("set_DrawSelf",h.old_face) end
    if h.hair:call("get_DrawSelf")==not h.target and h.old_hair==h.target then h.hair:call("set_DrawSelf",h.old_hair) end
    h.applied,h.finished=nil,nil
end
return M
