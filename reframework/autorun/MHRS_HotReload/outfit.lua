-- Bind resources through their current scene or equipped component slots.
local M = {}
local kinds = {
    mesh={"via.render.Mesh","via.render.MeshResource","getMesh","setMesh"},
    chain={"via.motion.Chain","via.motion.ChainResource","get_ChainAsset","set_ChainAsset"},
    jcns={"via.motion.JointConstraints","via.motion.JointConstraintsResource","get_JointConstraintsAsset","set_JointConstraintsAsset"},
    motbank={"via.motion.Motion","via.motion.MotionBankResource","get_MotionBankAsset","set_MotionBankAsset"},
    motlist={"via.motion.Motion","via.motion.MotionListResource","get_MotionList","set_MotionList"},
    efx={"via.effect.EffectPlayer","via.effect.EffectResource","get_Resource","set_Resource"},
    rcol={"via.physics.RequestSetCollider","via.physics.RequestSetColliderResource","get_Resource","set_Resource"},
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
    local owner=b.layer or b.bank or b.group or b.comp
    return owner:call(b.kind[3])
end

local function assign(b,h)
    if b.i then b.comp:call("setMaterialTexture",b.i,b.j,h)
    else
        local owner=b.layer or b.bank or b.group or b.comp
        owner:call(b.kind[4],h)
    end
end

local function scene_components(class)
    local scene=sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
        sdk.find_type_definition("via.SceneManager"),"get_CurrentScene")
    assert(scene,"Current scene unavailable")
    local components=scene:call("findComponents(System.Type)",sdk.typeof(class))
    return components and components:get_elements() or {}
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
    local scene_scope=ext=="chain" or ext=="jcns" or ext=="motbank" or ext=="motlist" or ext=="efx" or ext=="rcol"
    local components=scene_scope and scene_components(kind[1]) or parts(kind[1])
    for _,comp in ipairs(components) do
        if scene_scope and not comp:call("get_GameObject"):call("get_Update") then
            -- A dormant NPC has no running simulation to refresh.
        elseif ext=="tex" then
            if comp:call("get_MaterialReady") then
                for i=0,comp:call("get_MaterialNum")-1 do
                    for j=0,comp:call("getMaterialTextureNum",i)-1 do
                        consider({comp=comp,i=i,j=j,kind=kind})
                    end
                end
            end
        elseif ext=="jcns" then
            for i=0,comp:call("getLayerCount")-1 do
                local layer=comp:call("getLayer",i)
                if layer then consider({comp=comp,kind=kind,layer=layer,layer_index=i}) end
            end
        elseif ext=="rcol" then
            for i=0,comp:call("getRequestSetGroupsCount")-1 do
                local group=comp:call("getRequestSetGroups",i)
                if group then consider({comp=comp,kind=kind,group=group,index=i}) end
            end
        elseif ext=="motlist" then
            for i=0,comp:call("getActiveMotionBankCount")-1 do
                local bank=comp:call("getActiveMotionBank",i)
                if bank then consider({comp=comp,kind=kind,bank=bank}) end
            end
        elseif ext=="efx" then
            local state=comp:call("get_State")
            consider({comp=comp,kind=kind,restart=(state==1 or state==2) and not comp:call("get_Paused")})
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
        if b.layer then
            r.layer=b.layer_index
            r.targets=b.layer:call("get_OutputTargetCount")
        end
        if ext=="mesh" then r.ready=b.comp:call("get_MeshReady");r.lods=b.comp:call("get_LodCount") end
        if ext=="motbank" then
            local banks={}
            for i=0,b.comp:call("getActiveMotionBankCount")-1 do
                local bank=b.comp:call("getActiveMotionBank",i)
                if bank then banks[#banks+1]=bank:call("get_BankID") end
            end
            r.banks=banks
        end
        if b.i then r.material=b.i;r.slot=b.j end
        if b.group then
            r.group=b.index
            r.spheres={}
            for s=0,b.comp:call("getNumRequestSetsFromIndex",b.index)-1 do
                local count=b.comp:call("getNumCollidablesFromIndex(System.UInt32, System.UInt32)",b.index,s)
                for i=0,count-1 do
                    local col=b.comp:call("getCollidableFromIndex(System.UInt32, System.UInt32, System.UInt32)",b.index,s,i)
                    local shape=col and col:call("get_Shape")
                    if shape and shape:get_type_definition():get_full_name()=="via.physics.SphereShape" then
                        table.insert(r.spheres,shape:call("get_Radius"))
                    end
                end
            end
        elseif b.bank then
            r.bank=b.bank:call("get_BankID")
            r.motions=b.comp:call("getMotionCount",r.bank)
        elseif ext=="efx" then
            r.running=b.comp:call("get_Running")
            r.jobs=b.comp:call("get_JobCount")
            r.emitters=b.comp:call("get_EmitterInstanceNum")
        end
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
local camera_type="snow.camera.FixedCamera.FixedCameraUserData_End"
local camera_keys={_InterpolationTime=true,_InterpolationType=true,_IsCurveInterpolation=true,_InterpolationTargetCamera=true}
local pending_camera
local function camera_data(action,req)
    if action=="asset_camera_release" then pending_camera=nil;return {} end
    if action=="asset_camera_prepare" then
        local root=assert(sdk.create_userdata(camera_type,req.path),"Camera USER unavailable")
        assert(root:get_type_definition():get_full_name()==camera_type and root:call("get_Path"):lower()==req.path:lower(),"Unexpected camera USER")
        pending_camera={root=root,path=req.path}
        return {}
    end
    assert(pending_camera and pending_camera.path==req.path,"Camera USER has not been prepared")
    local root=pending_camera.root
    local values={}
    for k in pairs(req.edits) do
        assert(camera_keys[k],"Unknown camera field")
        values[k]=root:get_field(k)
    end
    if action=="asset_camera" then
        local ok,err=pcall(function()
            for k,value in pairs(req.edits) do
                root:set_field(k,value)
                assert(root:get_field(k)==value,"Camera USER readback mismatch")
            end
        end)
        if not ok then for k,v in pairs(values) do root:set_field(k,v) end;error(err) end
        values=req.edits
    end
    return {values=values,root=tostring(root:get_address())}
end

local function player_marker(path,edits,apply)
    assert(path:lower()=="gui/01_common/prefab/pl_headmessage.pfb","Unsupported prefab")
    local target
    for _,gui in ipairs(scene_components("via.gui.GUI")) do
        local go=gui:call("get_GameObject")
        if go:call("get_Name")=="PlHeadMessage" and go:call("getComponent(System.Type)",sdk.typeof("snow.gui.GuiCommonHeadMessage")) then
            local h=gui:call("get_Asset")
            if h and h:call("get_ResourcePath"):lower()=="gui/01_common/overhead.gui" then
                assert(not target,"Player marker is ambiguous")
                target=go
            end
        end
    end
    assert(target,"No matching player marker instance")
    local old=target:call("get_TimeScale")
    if apply then
        target:call("set_TimeScale",edits.TimeScale)
        if target:call("get_TimeScale")~=edits.TimeScale then
            target:call("set_TimeScale",old)
            error("Player marker readback mismatch")
        end
    end
    return {count=1,root=tostring(target:get_address()),time=target:call("get_TimeScale")}
end
local view_fields={BaseFps=true,Priority=true,Visible=true,HitVisible=true,Overlay=true,DepthTest=true,
    StencilTest=true,GUISortTarget=true,Detonemap=true,DegammaVertexColor=true,UseGUIPostImage=true}
local function gui_views(path,edits,apply)
    local ops,values={},{}
    for _,c in ipairs(scene_components("via.gui.GUI")) do
        local h=c:call("get_Asset")
        local p=h and h:call("get_ResourcePath")
        if p and p:lower()==path:lower() and c:call("get_Ready") then
            local view=c:call("get_View")
            if view then
                local row={component=tostring(c:get_address()),values={}}
                table.insert(values,row)
                for key,value in pairs(edits) do
                    assert(view_fields[key],"Unsupported GUI property")
                    local old=view:call("get_"..key)
                    assert(old~=nil,"GUI property unavailable")
                    table.insert(ops,{view=view,key=key,value=value,old=old,row=row})
                    row.values[key]=old
                end
            end
        end
    end
    assert(#values>0,"No ready GUI views for this path")
    if apply then
        local touched=0
        local ok,err=pcall(function()
            for i,op in ipairs(ops) do
                touched=i
                op.view:call("set_"..op.key,op.value)
                local actual=op.view:call("get_"..op.key)
                assert(actual==op.value or (op.key=="BaseFps" and math.abs(actual-op.value)<0.0001),"GUI readback mismatch")
                op.row.values[op.key]=actual
            end
        end)
        if not ok then
            for i=touched,1,-1 do local op=ops[i];op.view:call("set_"..op.key,op.old) end
            error(err)
        end
    end
    return {views=#values,bindings=values}
end
function M.active() return job~=nil or master~=nil end
function M.reset(native)
    if job then M.run("asset_abort",{},native) end
    if master then M.run("asset_master_abort",{},native) end
end
function M.run(action,req,native)
    if action=="asset_marker" or action=="asset_marker_inspect" then
        return player_marker(req.path,req.edits,action=="asset_marker")
    end
    if action=="asset_camera_prepare" or action=="asset_camera_release" or action=="asset_camera_inspect" or action=="asset_camera" then
        return camera_data(action,req)
    end
    if action=="asset_gui" or action=="asset_gui_inspect" then
        return gui_views(req.path,req.edits or {},action=="asset_gui")
    end
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
        local restore_error
        if job.effects then
            for _,b in ipairs(job.effects) do
                local ok,err=pcall(function()
                    local go=b.comp:call("get_GameObject")
                    if go and go:call("get_Valid") then
                        assign(b,b.old)
                        if b.restart then b.comp:call("set_Action",1) end
                    end
                end)
                if not ok then restore_error=err end
            end
        end
        local state=native("abort")
        assert(state=="rolled back",state)

        job=nil
        if restore_error then error(restore_error) end
        return {state=state}
    end
    if action=="asset_poll" then
        assert(job,"No asset transaction")
        local state=native("poll")
        return {state=state}
    end
    if action=="asset_bind" then
        assert(job and native("poll")=="ready","Resource not ready")
        if job.expected_outputs then
            local state,outputs=native("joint_outputs")
            assert(state=="outputs" and tonumber(outputs)==job.expected_outputs,
                "JCNS output count differs from the loose file. Turn off LooseFileLoader > Debug > Enable file cache and save again.")
        end
        if job.effects then
            for _,b in ipairs(job.effects) do
                local h=holder(b)
                if not h or tostring(h:read_qword(0x10))~=job.fresh then return {state="pending"} end
            end
            local count,address=#job.effects,job.fresh
            assert(native("commit")=="committed")
            job=nil
            return {state="committed",resource=address,bindings=count}
        end
        local list=bindings(job.path,job.kind,job.ext)
        assert(#list>0,"Resource no longer equipped")
        for _,b in ipairs(list) do assert(b.old:read_qword(0x10)==job.old,"Equipped binding changed") end
        local res=assert(sdk.create_resource(job.kind[2],job.path))
        local address=tostring(res:get_address())
        local holder_type=job.ext=="motlist" and "via.motion.MotionListBaseResourceHolder" or job.kind[2].."Holder"
        local h=res:create_holder(holder_type)
        res:release()
        assert(h and address==job.fresh,"Cache resource mismatch")
        if job.ext=="efx" then
            job.effects={}
            job.holder=h
            for _,b in ipairs(list) do
                table.insert(job.effects,b)
                assign(b,h)
                if b.restart then b.comp:call("set_Action",1) end
            end
            return {state="pending"}
        end
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
    local ext=path:lower():match("%.([a-z0-9]+)$")
    local kind=assert(kinds[ext],"Unsupported asset")
    if ext=="user" then return user_data(path,req.edits or {},action=="asset_user") end
    local list=bindings(path,kind,ext)
    if action=="asset_inspect" then return {bindings=binding_report(list,ext)} end
    assert(action=="asset_begin" and not job and (not master or (master.held and ext=="mdf2")),"Invalid asset request")
    assert(#list>0,"No matching active resource user")
    local f=assert(io.open("MHRS-Files-HotReload/asset-path.txt","wb"))
    f:write(list[1].path); f:close()
    local state,address=native("asset")
    assert(state=="pending",state)
    job={kind=kind,ext=ext,path=list[1].path,old=list[1].old:read_qword(0x10),fresh=address,
        expected_outputs=ext=="jcns" and req.expected_outputs}
    return {state=state,address=address,bindings=#list}
end
return M
