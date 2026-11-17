-- A newly attached armor prefab starts with its MDF defaults. Its native
-- material component needs the same two symbol colors as normal player creation.
local M={}
-- PlParts (body, arm, waist, leg, helm) -> PlArmorPartsTypes (head first).
local armor_index={[0]=1,[1]=2,[2]=3,[3]=4,[4]=0}
local channel_name={S_col_R=1,S_col_G=2}
local function element(array,i)
    assert(array and array:get_size()==5,"Local armor color array does not cover five slots")
    return array:get_type_definition():get_method("Get(System.Int32)"):call(array,i)
end
local function close(a,b)
    return a and b and math.abs(a.x-b.x)<.00001 and math.abs(a.y-b.y)<.00001
        and math.abs(a.z-b.z)<.00001 and math.abs(a.w-b.w)<.00001
end
local function fixed_color(v)
    -- Only ordinary opaque RGB is comparable to a live shader value. Other
    -- native encodings, including dynamic colors, stay under Rise's control.
    return v and v.w==1 and v.x>=0 and v.x<=1 and v.y>=0 and v.y<=1 and v.z>=0 and v.z<=1
end
local function dye_mask(mesh,slot)
    for i=0,mesh:call("getMaterialTextureNum",slot)-1 do
        if mesh:call("getMaterialTextureName",slot,i)=="UserColorchangeMap" then
            local h=mesh:call("getMaterialTexture",slot,i)
            local path=h and h:call("get_ResourcePath")
            if not path or path=="" then return false end
            return path:lower():gsub("^@",""):gsub("\\","/")~="systems/rendering/nullblack.tex"
        end
    end
    return false
end
local function bindings(mesh)
    local refs={}
    for slot=0,mesh:call("get_MaterialNum")-1 do
        if dye_mask(mesh,slot) then
            for i=0,mesh:call("getMaterialVariableNum",slot)-1 do
                local channel=channel_name[mesh:call("getMaterialVariableName",slot,i)]
                if channel and mesh:call("getMaterialVariableType",slot,i)==4 then
                    refs[#refs+1]={slot=slot,index=i,channel=channel}
                end
            end
        end
    end
    return refs
end
local function fields_match(mat,desired)
    for n=1,2 do
        if desired[n] and not close(mat:get_field("_symbolColor"..n),desired[n]) then return false end
    end
    return true
end
local function shaders_match(mesh,refs,desired)
    for _,r in ipairs(refs) do
        local v=desired[r.channel]
        if fixed_color(v) and not close(mesh:call("getMaterialFloat4",r.slot,r.index),v) then return false end
    end
    return true
end
function M.ready(j,row,after)
    local i=armor_index[row.slot]
    local mat=row.material
    if not i or not mat or row.new==row.old or mat:call("get_GameObject")~=row.new
            or mat:get_field("_ParentMaterialCtrl")~=j.ctrl or mat:call("get_plPartsNo")~=row.slot
            or j.ctrl:get_field("_MaterialParts"):get_element(row.slot)~=mat
            or j.pm:call("get_PlayerParam"):get_element(j.index)~=j.request then
        return false,"Local armor color owner changed"
    end
    local base=j.pm:call("get_PlayerBaseData"):get_element(j.index)
    if not base then return false,"Local armor colors are unavailable" end
    local desired={}
    for n=1,2 do
        local enabled=element(base:get_field("_IsEnableSymbolColor"..n),i)
        assert(type(enabled)=="boolean","Local armor dye flag is unavailable")
        -- Disabled channels retain the new prefab's authored defaults. A
        -- null or unusual shader layout still receives native component state.
        if enabled then desired[n]=assert(element(base:get_field("_SymbolColor"..n),i)) end
    end
    local s=row.colors
    if s and (s.first~=(desired[1]~=nil) or s.second~=(desired[2]~=nil)) then
        return false,"Local armor dye selection changed during replacement"
    end
    if not desired[1] and not desired[2] then return true end
    local mesh=mat:call("get_RefMesh")
    if not mesh or mesh:call("get_GameObject")~=row.new or not mesh:call("get_MaterialReady") then
        return false,"Local dyed material is not ready"
    end
    if not s then
        s={mesh=mesh,material=mat,refs=bindings(mesh),first=desired[1]~=nil,second=desired[2]~=nil}
        row.colors=s
    end
    if s.mesh~=mesh or s.material~=mat then return false,"Local dyed part generation changed" end
    if fields_match(mat,desired) and shaders_match(mesh,s.refs,desired) then
        s.checked=true
        return true
    end
    if after or s.checked or s.applied then return false,"Local armor dyes differ from current player creation data" end
    s.applied=true
    for n=1,2 do
        if desired[n] and not close(mat:get_field("_symbolColor"..n),desired[n]) then
            mat:call("setSymbolColor",n==1,desired[n])
        end
    end
    mat:call("updateSymbolColor")
    if fields_match(mat,desired) and shaders_match(mesh,s.refs,desired) then
        s.checked=true
        return true
    end
    j.next_update=true
    return false,"Waiting for local armor dye readback"
end
return M
