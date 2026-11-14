-- Bind resources through the local hunter's actual component/texture slots.
local M = {}
local kinds = {
    mesh={"via.render.Mesh","via.render.MeshResource","getMesh","setMesh"},
    chain={"via.motion.Chain","via.motion.ChainResource","get_ChainAsset","set_ChainAsset"},
    tex={"via.render.Mesh","via.render.TextureResource"},
    mdf2={"via.render.Mesh","via.render.MeshMaterialResource","get_Material","set_Material"},
    user={"snow.player.PlayerMaterialParts"}
}

local function parts(class)
    local manager=sdk.get_managed_singleton("snow.player.PlayerManager")
    local player=manager and manager:call("findMasterPlayer")
    assert(player,"Local hunter unavailable")
    local list={}
    local function visit(t)
        local go=t:call("get_GameObject")
        local comp=go:call("getComponent(System.Type)",sdk.typeof(class))
        if comp then list[#list+1]=comp end
        local child=t:call("get_Child")
        while child do visit(child); child=child:call("get_Next") end
    end
    visit(player:call("get_GameObject"):call("get_Transform"))
    return list
end

local function holder(b)
    if b.i then return b.comp:call("getMaterialTexture",b.i,b.j) end
    return b.comp:call(b.kind[3])
end

local function assign(b,h)
    if b.i then b.comp:call("setMaterialTexture",b.i,b.j,h)
    else b.comp:call(b.kind[4],h) end
end

local function bindings(path,kind,ext)
    local found={}
    local function consider(b)
        local h=holder(b)
        local p=h and h:call("get_ResourcePath")
        if p and p:lower()==path:lower() then
            b.old=h
            b.path=p
            found[#found+1]=b
        end
    end
    for _,comp in ipairs(parts(kind[1])) do
        if ext=="tex" then
            if comp:call("get_MaterialReady") then
                for i=0,comp:call("get_MaterialNum")-1 do
                    for j=0,comp:call("getMaterialTextureNum",i)-1 do
                        consider({comp=comp,i=i,j=j,kind=kind})
                    end
                end
            end
        else consider({comp=comp,kind=kind}) end
    end
    return found
end

local function binding_report(list,ext)
    local result={}
    for _,b in ipairs(list) do
        local r={object=b.comp:call("get_GameObject"):call("get_Name"),path=b.path,
            component=tostring(b.comp:get_address()),resource=tostring(holder(b):read_qword(0x10))}
        if ext=="chain" then r.groups=b.comp:call("getGroupCount");r.resource_groups=b.comp:call("get_ResourceGroupCount") end
        if ext=="mesh" then r.ready=b.comp:call("get_MeshReady");r.lods=b.comp:call("get_LodCount") end
        if b.i then r.material=b.i;r.slot=b.j end
        result[#result+1]=r
    end
    return result
end

local function switches(mesh)
    local result={}
    for i=0,mesh:call("get_MaterialNum")-1 do
        result[mesh:call("getMaterialName",i)]=mesh:call("getMaterialsEnable",i)
    end
    return result
end

local function restore_switches(mesh,prior)
    for i=0,mesh:call("get_MaterialNum")-1 do
        local enabled=prior[mesh:call("getMaterialName",i)]
        if enabled~=nil and enabled~=mesh:call("getMaterialsEnable",i) then
            mesh:call("setMaterialsEnable",i,enabled)
        end
    end
end

local function user_field(root,edit)
    local target
    if edit.section=="face" then
        assert(edit.field=="FullFace" or edit.field=="FullBody")
        target=root:get_field("_FaceInfo")
    elseif edit.section=="hair" then
        local arr=root:get_field("_HairInfo")
        assert(edit.index>=0 and edit.index<arr:get_size(),"Hair entry unavailable")
        target=arr[edit.index]
        assert(edit.field=="HairShapeData" or edit.field=="HairDispOffParts" or edit.field=="HairDispOff" or edit.field=="HairChainStop")
    else error("Unknown helm data section") end
    assert(target,"Missing helm data entry")
    if edit.field=="HairShapeData" then
        local arr=target:get_field(edit.field)
        assert(edit.element>=0 and edit.element<arr:get_size(),"Hair shape element unavailable")
        local function boxed() return assert(arr:call("GetValue(System.Int32)",edit.element)) end
        return function() return boxed():get_field("mValue") end,function(v)
            arr:call("SetValue(System.Object, System.Int32)",sdk.create_single(v),edit.element)
        end
    end
    return function() return target:get_field(edit.field) end,function(v) target:set_field(edit.field,v) end
end

local function user_data(path,edits,apply)
    local roots,seen={},{}
    for _,comp in ipairs(parts(kinds.user[1])) do
        local v=comp:get_field("_PlayerUserDataParts")
        if v and v:get_type_definition():get_full_name()=="snow.player.PlayerUserDataPartsHelm"
            and v:call("get_Path"):lower()==path:lower() and not seen[v:get_address()] then
            roots[#roots+1]=v
            seen[v:get_address()]=true
        end
    end
    assert(#roots>0,"No matching equipped helm USER")
    local values,operations={},{}
    for _,v in ipairs(roots) do
        for _,edit in ipairs(edits) do
            local get,set=user_field(v,edit)
            local before=get()
            assert(before~=nil,"Unreadable USER field")
            values[#values+1]=before
            operations[#operations+1]={get=get,set=set,old=before,new=edit.value}
        end
    end
    if apply then
        local touched=0
        local ok,err=pcall(function()
            for i,op in ipairs(operations) do
                touched=i
                op.set(op.new)
                assert(op.get()==op.new,"USER field readback mismatch")
                values[i]=op.get()
            end
        end)
        if not ok then
            for i=touched,1,-1 do operations[i].set(operations[i].old) end
            error(err)
        end
    end
    return {roots=#roots,values=values}
end

local job,master
function M.active() return job~=nil or master~=nil end
function M.reset(native)
    if job then M.run("asset_abort",{},native) end
    if master then M.run("asset_master_abort",{},native) end
end
function M.run(action,req,native)
    if action=="asset_master_begin" then
        assert(not job and not master and req.path:lower():match("%.mmtr$"),"Invalid template transaction")
        local f=assert(io.open("MHRS-Files-HotReload/asset-path.txt","wb"))
        f:write(req.path); f:close()
        local state,address=native("asset")
        assert(state=="pending",state)
        master={held=false}
        return {state=state,resource=address}
    end
    if action=="asset_master_poll" then
        assert(master and not master.held)
        local state=native("poll")
        if state=="ready" then
            assert(native("hold_master")=="held")
            master.held=true
        end
        return {state=state}
    end
    if action=="asset_master_commit" or action=="asset_master_abort" then
        assert(master and not job,"Dependent MDF transaction still active")
        if master.held then assert(native("resume_master")=="resumed");master.held=false end
        local commit=action=="asset_master_commit"
        local state=native(commit and "commit" or "abort")
        assert(state==(commit and "committed" or "rolled back"),state)
        master=nil
        return {state=state}
    end
    if action=="asset_abort" then
        if not job then return {state="idle"} end
        local state=native("abort")
        assert(state=="rolled back",state)
        job=nil
        return {state=state}
    end
    if action=="asset_poll" then
        assert(job,"No asset transaction")
        local state=native("poll")
        return {state=state}
    end
    if action=="asset_bind" then
        assert(job and native("poll")=="ready","Resource not ready")
        local list=bindings(job.path,job.kind,job.ext)
        assert(#list>0,"Resource no longer equipped")
        for _,b in ipairs(list) do assert(b.old:read_qword(0x10)==job.old,"Equipped binding changed") end
        local res=assert(sdk.create_resource(job.kind[2],job.path))
        local address=tostring(res:get_address())
        local h=res:create_holder(job.kind[2].."Holder")
        res:release()
        assert(h and address==job.fresh,"Cache resource mismatch")
        local touched=0
        local ok,err=pcall(function()
            for i,b in ipairs(list) do
                touched=i
                if job.ext=="mdf2" and b.comp:call("get_MaterialReady") then b.switches=switches(b.comp) end
                assign(b,h)
                assert(tostring(holder(b):read_qword(0x10))==address,"Binding did not take effect")
                if b.switches and b.comp:call("get_MaterialReady") then restore_switches(b.comp,b.switches) end
            end
            local state=native("commit")
            assert(state=="committed",state)
        end)
        if not ok then
            for i=touched,1,-1 do
                local b=list[i]
                assign(b,b.old)
                if b.switches and b.comp:call("get_MaterialReady") then restore_switches(b.comp,b.switches) end
            end
            error(err)
        end
        job=nil
        return {state="committed",resource=address,bindings=#list}
    end
    local path=assert(req.path)
    local ext=path:match("%.([a-z0-9]+)$")
    local kind=assert(kinds[ext],"Unsupported asset")
    if ext=="user" then return user_data(path,req.edits or {},action=="asset_user") end
    local list=bindings(path,kind,ext)
    if action=="asset_inspect" then return {bindings=binding_report(list,ext)} end
    assert(action=="asset_begin" and not job and (not master or (master.held and ext=="mdf2")),"Invalid asset request")
    assert(#list>0,"No matching equipped resource")
    local f=assert(io.open("MHRS-Files-HotReload/asset-path.txt","wb"))
    f:write(list[1].path); f:close()
    local state,address=native("asset")
    assert(state=="pending",state)
    job={kind=kind,ext=ext,path=list[1].path,old=list[1].old:read_qword(0x10),fresh=address}
    return {state=state,address=address,bindings=#list}
end
return M
