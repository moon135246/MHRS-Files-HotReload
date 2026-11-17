-- Read both sides of an equipment change through Rise's five original armor
-- slots. Both a rebuilt hunter and an in-place parts transaction use these
-- checks, including the running (not merely loaded) CHAIN groups.
local M={}
local slots={0,1,2,3,4}
local mesh_type,chain_type="via.render.Mesh","via.motion.Chain"

local function child(go,t)
    return go and go:call("getComponent(System.Type)",sdk.typeof(t))
end

local function path(holder)
    local name=holder and holder:call("get_ResourcePath")
    return name and name:lower():gsub("^@",""):gsub("\\","/")
end

function M.capture(p,candidates,physics,materials)
    local by_object={}
    for _,r in pairs(candidates) do by_object[r.go:get_address()]=r end
    local parts={}
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
        parts[i]={name=part:call("get_Name"),object=part:get_address(),mesh=mesh_path,mdf=mdf,chain=chain_path,
            touched=row~=nil and not row.mesh.keep,requested=row~=nil,before=row and row.mesh.original,
            mesh_name=row and row.mesh.path,mdf_name=row and row.mdf2 and row.mdf2.path,
            slots=(row and row.expected) or (mdf and materials[mdf]),
            helmet=mesh_path and (physics.helmets or {})[(mesh_path:gsub("%.mesh$",".user"))],
            groups=type(groups)=="number" and groups or nil,
            incoming_chain=mesh_path and (physics.chains or {})[(mesh_path:gsub("%.mesh$",".chain"))],
            terminals=mesh_path and (physics.chain_terminals or {})[(mesh_path:gsub("%.mesh$",".chain"))]}
    end
    if impacted then return parts end
end

function M.unchanged(p,parts)
    for _,i in ipairs(slots) do
        local part=p:call("getPartsGameObject",i)
        if not part or not part:call("get_Valid") or part:get_address()~=parts[i].object or part:call("get_Name")~=parts[i].name then
            return false,"Worn parts changed while preparing the model"
        end
        if parts[i].touched then
            local mesh=child(part,mesh_type)
            local holder=mesh and mesh:call("getMesh")
            if not holder or holder:read_qword(0x10)~=parts[i].before then
                return false,"Worn mesh already changed while preparing the model"
            end
        end
    end
    return true
end

function M.part_ready(go,expected,resources)
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
            for _,entry in ipairs({{expected.mesh,mh,expected.mesh_name},{expected.mdf,dh,expected.mdf_name}}) do
                local fresh=resources[entry[3]] or resources[entry[1]]
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
        local holder=chain and chain:call("get_ChainAsset")
        if path(holder)~=expected.chain or
                chain:call("get_ResourceGroupCount")~=expected.groups then
            return false,"Physics resource groups differ: "..expected.chain
        end
        local fresh=resources and (resources[holder:call("get_ResourcePath")] or resources[expected.chain])
        if fresh and holder:read_qword(0x10)~=fresh:get_address() then
            return false,"Equipment still uses an earlier physics resource: "..expected.chain
        end
        if chain:call("get_Enabled") and go:call("get_Update") and
                (not chain:call("get_Setuped") or chain:call("getGroupCount")~=expected.groups) then
            return false,"Physics simulation is initializing: "..expected.chain
        end
    end
    return true
end

function M.ready(p,parts,resources)
    for _,i in ipairs(slots) do
        local ok,reason=M.part_ready(p:call("getPartsGameObject",i),parts[i],resources)
        if not ok then return ok,reason end
    end
    return true
end

return M
