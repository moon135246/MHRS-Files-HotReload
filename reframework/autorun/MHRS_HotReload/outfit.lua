-- Bind resources through their current scene or equipped component slots.
local M = {}
local worn_armor = require("MHRS_HotReload.worn_armor")
local worn_chain = require("MHRS_HotReload.worn_chain")
local shadow_skeleton = require("MHRS_HotReload.shadow_skeleton")
local equipment_physics = require("MHRS_HotReload.equipment_physics")
local hunter_roster = require("MHRS_HotReload.hunter_roster")
local peer_equipment = require("MHRS_HotReload.peer_equipment")
local peer_physics = require("MHRS_HotReload.peer_physics")
local kinds = {
    mesh={"via.render.Mesh","via.render.MeshResource","getMesh","setMesh"},
    chain={"via.motion.Chain","via.motion.ChainResource","get_ChainAsset","set_ChainAsset"},
    jcns={"via.motion.JointConstraints","via.motion.JointConstraintsResource","get_JointConstraintsAsset","set_JointConstraintsAsset"},
    mot={"via.motion.Motion","via.motion.MotionResource","get_Resource","set_Resource"},
    motbank={"via.motion.Motion","via.motion.MotionBankResource","get_MotionBankAsset","set_MotionBankAsset"},
    motlist={"via.motion.Motion","via.motion.MotionListResource","get_MotionList","set_MotionList"},
    efx={"via.effect.EffectPlayer","via.effect.EffectResource","get_Resource","set_Resource"},
    rcol={"via.physics.RequestSetCollider","via.physics.RequestSetColliderResource","get_Resource","set_Resource"},
    uvs={"via.gui.GUI","via.uvsequence.UVSequenceResource","get_UVSequence","set_UVSequence"},
    rtex={"via.gui.GUI","via.render.RenderTargetTextureResource","get_RenderTarget","set_RenderTarget"},
    uvar={"via.motion.Motion","via.userdata.UserVariablesResource","get_UserVariables","set_UserVariables"},
    fbxskel={"via.motion.CustomSkeleton","via.motion.FbxSkeletonResource","get_SkeletonResourceHandle","set_SkeletonResourceHandle"},
    tex={"via.render.Mesh","via.render.TextureResource"},
    mdf2={"via.render.Mesh","via.render.MeshMaterialResource","get_Material","set_Material(via.render.MeshMaterialResourceHolder)"},
    user={"snow.player.PlayerMaterialParts"}
}

local function parts(class)
    local manager=sdk.get_managed_singleton("snow.player.PlayerManager")
    local player=manager and manager:call("findMasterPlayer")
    assert(player,"Local hunter unavailable")
    local list={}
    local component_type=sdk.typeof(class)
    local function visit(t)
        local go=t:call("get_GameObject")
        local comp=go:call("getComponent(System.Type)",component_type)
        if comp then list[#list+1]=comp end
        local child=t:call("get_Child")
        while child do visit(child); child=child:call("get_Next") end
    end
    visit(player:call("get_GameObject"):call("get_Transform"))
    return list
end

local function holder(b)
    if b.preview then return b.preview:call("get_Item",b.index) end
    if b.i then return b.comp:call("getMaterialTexture",b.i,b.j) end
    local owner=b.element or b.layer or b.bank or b.group or b.comp
    return owner:call(b.kind[3])
end

local function assign(b,h)
    if b.preview then b.preview:call("set_Item",b.index,h)
    elseif b.i then b.comp:call("setMaterialTexture",b.i,b.j,h)
    else
        local owner=b.element or b.layer or b.bank or b.group or b.comp
        owner:call(b.kind[4],h)
    end
end

local array_elements = require("MHRS_HotReload.array_elements")

local function scene_components(class,cache)
    if cache and cache[class] then return cache[class] end
    local scene=sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
        sdk.find_type_definition("via.SceneManager"),"get_CurrentScene")
    assert(scene,"Current scene unavailable")
    local component_type=sdk.typeof(class)
    local components=array_elements(scene:call("findComponents(System.Type)",component_type),class)
    if cache then cache[class]=components end
    return components
end

local function gui_textures(comp,visit)
    for _,class in ipairs({"via.gui.Texture","via.gui.TextureSet"}) do
        local class_type=sdk.typeof(class)
        local objects=array_elements(comp:call("findObjects(System.Type)",class_type),class)
        for _,obj in ipairs(objects) do visit(obj) end
    end
end

local function hunter_asset(path,ext)
    return (ext=="mesh" or ext=="mdf2" or ext=="chain") and path:lower():gsub("\\","/"):match("^@?player/mod/")
end
local function ordinary_owner(actors,go)
    local owner=hunter_roster.owner(actors,go)
    if owner.role=="master" or owner.role=="scene" then return owner.root:get_address() end
end
local function bindings(path,kind,ext,include_dormant,cache)
    local found={}
    local wanted=type(path)=="table" and path or {[path:lower()]=true}
    local actors
    local function consider(b)
        local h=holder(b)
        local p=h and h:call("get_ResourcePath")
        if p and wanted[p:lower()] then
            if not include_dormant and hunter_asset(p,ext) then
                actors=actors or hunter_roster.read()
                b.wearer=ordinary_owner(actors,b.comp:call("get_GameObject"))
                if not b.wearer then return end
            end
            b.old=h
            b.path=p
            if ext=="rtex" then b.slot_key=tostring(b.comp:get_address()).."/"..tostring(b.index) end
            if ext=="uvs" then b.slot_key=b.element:get_address() end
            found[#found+1]=b
        end
    end
    if ext=="rtex" then
        local manager=sdk.get_managed_singleton("snow.gui.GuiManager")
        local list=manager and manager:get_field("previewTextureList")
        for i=0,(list and list:call("get_Count") or 0)-1 do
            consider({comp=manager,preview=list,index=i,kind=kind})
        end
        for _,class in ipairs({"via.render.RenderOutput","via.render.RenderTargetOperator"}) do
            for _,comp in ipairs(scene_components(class,cache)) do
                if include_dormant or comp:call("get_GameObject"):call("get_Update") then
                    consider({comp=comp,kind=kind})
                end
            end
        end
    end
    local components=scene_components(kind[1],cache)
    local visited={}
    local function inspect(comp)
        if ext=="uvs" then
            if comp:call("get_Ready") then
                gui_textures(comp,function(obj)
                    if not visited[obj:get_address()] then
                        visited[obj:get_address()]=true
                        consider({comp=comp,element=obj,kind=kind})
                    end
                end)
            end
        elseif ext=="tex" then
            if comp:call("get_MaterialReady") then
                for i=0,comp:call("get_MaterialNum")-1 do
                    for j=0,comp:call("getMaterialTextureNum",i)-1 do
                        consider({comp=comp,i=i,j=j,kind=kind})
                    end
                end
            end
        elseif ext=="mot" then
            for i=0,comp:call("getLayerCount")-1 do
                local layer=comp:call("getLayer",i)
                if layer then consider({comp=comp,kind=kind,layer=layer,layer_index=i}) end
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
    for _,comp in ipairs(components) do
        local ok,go=pcall(comp.call,comp,"get_GameObject")
        if ok and go then
            if go:call("get_Update") then inspect(comp)
            elseif include_dormant then pcall(inspect,comp) end
        end
    end
    return found
end

local function binding_report(list,ext)
    local result={}
    for _,b in ipairs(list) do
        local r={object=b.preview and "GuiManager.previewTextureList" or b.comp:call("get_GameObject"):call("get_Name"),path=b.path,
            component=tostring(b.comp:get_address()),resource=tostring(holder(b):read_qword(0x10))}
        if ext=="chain" then r.groups=b.comp:call("getGroupCount");r.resource_groups=b.comp:call("get_ResourceGroupCount") end
        if b.layer then
            r.layer=b.layer_index
            if ext=="mot" then r.frame=b.layer:call("get_Frame");r.end_frame=b.layer:call("get_EndFrame")
            else r.targets=b.layer:call("get_OutputTargetCount") end
        end
        if ext=="mesh" then r.ready=b.comp:call("get_MeshReady");r.lods=b.comp:call("get_LodCount") end
        if ext=="mesh" or ext=="mdf2" then
            local model=b.comp:call("getMesh")
            r.mesh_path=model and model:call("get_ResourcePath")
            r.material_names={}
            if b.comp:call("get_MaterialReady") then
                for i=0,b.comp:call("get_MaterialNum")-1 do
                    r.material_names[#r.material_names+1]=b.comp:call("getMaterialName",i)
                end
            end
        end
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

local variable_access={
    [0]={"getMaterialBool","setMaterialBool"},
    [1]={"getMaterialFloat","setMaterialFloat"},
    [4]={"getMaterialFloat4","setMaterialFloat4"},
}

local function material_state(mesh,policy)
    local result,parts,pins={}
    if policy=="vertices" then
        parts,pins={},{}
        for i=0,mesh:call("getPartsEnableCount")-1 do parts[i+1]=mesh:call("getPartsEnable",i) end
    end
    for i=0,mesh:call("get_MaterialNum")-1 do
        local name=mesh:call("getMaterialName",i)
        local slot={enabled=mesh:call("getMaterialsEnable",i),variables={},textures={}}
        result[name]=slot
        local keep=parts~=nil or policy==true or (policy and policy[name])
        if keep then
            for j=0,mesh:call("getMaterialVariableNum",i)-1 do
                local key=mesh:call("getMaterialVariableName",i,j)
                local kind=mesh:call("getMaterialVariableType",i,j)
                if variable_access[kind] and (keep==true or keep.variables[key]) then
                    local value=mesh:call(variable_access[kind][1],i,j)
                    if kind==4 then value=Vector4f.new(value.x,value.y,value.z,value.w) end
                    slot.variables[key]={kind=kind,value=value}
                end
            end
            for j=0,mesh:call("getMaterialTextureNum",i)-1 do
                local key=mesh:call("getMaterialTextureName",i,j)
                if keep==true or keep.textures[key] then
                    local h=mesh:call("getMaterialTexture",i,j)
                    if parts and h then
                        local ptr=h:read_qword(0x10)
                        if ptr~=0 then
                            if not pins[ptr] then
                                local r=assert(sdk.to_resource(sdk.to_ptr(ptr)))
                                pins[ptr]=assert(r:create_holder_global("via.render.TextureResourceHolder"))
                                assert(pins[ptr]:read_qword(0x10)==ptr,"Could not retain worn texture")
                            end
                            h=pins[ptr]
                        end
                    end
                    slot.textures[key]={holder=h}
                end
            end
        end
    end
    return result,parts
end

local function restore_material(mesh,prior,parts)
    if parts and #parts==mesh:call("getPartsEnableCount") then
        for i,enabled in ipairs(parts) do
            if mesh:call("getPartsEnable",i-1)~=enabled then mesh:call("setPartsEnable",i-1,enabled) end
        end
    end
    for i=0,mesh:call("get_MaterialNum")-1 do
        local slot=prior[mesh:call("getMaterialName",i)]
        if slot then
            if slot.enabled~=mesh:call("getMaterialsEnable",i) then mesh:call("setMaterialsEnable",i,slot.enabled) end
            for j=0,mesh:call("getMaterialVariableNum",i)-1 do
                local saved=slot.variables[mesh:call("getMaterialVariableName",i,j)]
                if saved and saved.kind==mesh:call("getMaterialVariableType",i,j) then
                    local same=false
                    if parts then
                        local value=mesh:call(variable_access[saved.kind][1],i,j)
                        local old=saved.value
                        if saved.kind==4 then
                            same=value.x==old.x and value.y==old.y and value.z==old.z and value.w==old.w
                        else same=value==old end
                    end
                    if not same then mesh:call(variable_access[saved.kind][2],i,j,saved.value) end
                end
            end
            for j=0,mesh:call("getMaterialTextureNum",i)-1 do
                local saved=slot.textures[mesh:call("getMaterialTextureName",i,j)]
                if saved then
                    local current=mesh:call("getMaterialTexture",i,j)
                    local old_path=saved.holder and saved.holder:call("get_ResourcePath")
                    local new_path=current and current:call("get_ResourcePath")
                    if (old_path and old_path:lower())~=(new_path and new_path:lower()) then
                        mesh:call("setMaterialTexture",i,j,saved.holder)
                    end
                end
            end
        end
    end
end

local deferred_materials={}
local retired_visuals={}
local function current_geometry(comp)
    local key=comp:get_address()
    local prior=retired_visuals[key]
    if not prior then return true end
    for _,ext in ipairs({"mesh","mdf2"}) do
        if prior[ext] then
            local h=comp:call(kinds[ext][3])
            if h and tostring(h:read_qword(0x10))==prior[ext] then return false end
        end
    end
    retired_visuals[key]=nil
    return true
end
local function restore_when_ready(b)
    if not b.switches then return end
    if b.parts and b.wearer_owns and not b.wearer_owns(b.comp:call("get_GameObject")) then return end
    local id=b.comp:get_address()
    deferred_materials[id]=nil
    if b.comp:call("get_MaterialReady") then
        restore_material(b.comp,b.switches,b.parts)
    else
        local h=holder(b)
        if h then
            deferred_materials[id]={mesh=b.comp,go=b.comp:call("get_GameObject"),
                resource=h:read_qword(0x10),values=b.switches,parts=b.parts,wearer_owns=b.wearer_owns,wearer=b.wearer}
        end
    end
end
re.on_application_entry("UpdateBehavior",function()
    for id,entry in pairs(deferred_materials) do
        local ok,finished=pcall(function()
            if not entry.go:call("get_Valid") then return true end
            if entry.wearer_owns and not entry.wearer_owns(entry.go) then return true end
            if entry.wearer and ordinary_owner(hunter_roster.read(),entry.go)~=entry.wearer then return true end
            local h=entry.mesh:call("get_Material")
            if not h or h:read_qword(0x10)~=entry.resource then return true end
            if entry.mesh:call("get_MaterialReady") then
                restore_material(entry.mesh,entry.values,entry.parts)
                return true
            end
        end)
        if not ok then log.error("[MHRS-Files-HotReload] "..tostring(finished)) end
        if not ok or finished then deferred_materials[id]=nil end
    end
end)

local function user_field(root,edit)
    local function invalid(why)
        local ok,path=pcall(root.call,root,"get_Path")
        error(string.format("%s: %s %s[%s].%s[%s]",why,ok and tostring(path) or "helmet USER",
            tostring(edit.section),tostring(edit.index),tostring(edit.field),tostring(edit.element)))
    end
    local target
    if edit.section=="face" then
        if edit.field~="FullFace" and edit.field~="FullBody" then invalid("Unknown face field") end
        target=root:get_field("_FaceInfo")
    elseif edit.section=="hair" then
        local arr=root:get_field("_HairInfo")
        if not arr or edit.index<0 or edit.index>=arr:get_size() then invalid("Hair entry unavailable") end
        target=arr[edit.index]
        if edit.field~="HairShapeData" and edit.field~="HairDispOffParts" and edit.field~="HairDispOff"
                and edit.field~="HairChainStop" then invalid("Unknown hair field") end
    else invalid("Unknown helm data section") end
    if not target then invalid("Missing helm data entry") end
    if edit.field=="HairShapeData" then
        local arr=target:get_field(edit.field)
        if not arr or edit.element<0 or edit.element>=arr:get_size() then invalid("Hair shape element unavailable") end
        local function boxed()
            local value=arr:call("GetValue(System.Int32)",edit.element)
            if not value then invalid("Hair shape value unavailable") end
            return value
        end
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
        local typ=req.user_type or camera_type
        local td=assert(sdk.find_type_definition(typ),"Unknown USER type")
        assert(td:is_a("via.UserData"),"Expected via.UserData")
        local keys=camera_keys
        if req.user_type then
            keys={}
            for k,t in pairs(req.fields) do
                local f=assert(td:get_field(k),"USER field unavailable")
                assert(not f:is_static() and f:get_type():get_full_name()==t,"USER field type differs")
                keys[k]=true
            end
        end
        local root=assert(sdk.create_userdata(typ,req.path),"USER unavailable")
        assert(root:get_type_definition():get_full_name()==typ and root:call("get_Path"):lower()==req.path:lower(),"Unexpected camera USER")
        pending_camera={root=root,path=req.path,keys=keys}
        return {}
    end
    assert(pending_camera and pending_camera.path==req.path,"Camera USER has not been prepared")
    local root=pending_camera.root
    local values={}
    for k in pairs(req.edits) do
        assert(pending_camera.keys[k],"Unknown camera field")
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
-- Keep path provenance from the engine's prefab factory for otherwise identical instances.
local prefab_instances,prefab_values={},{}
local prefab_generations={}
local tracked={}
local function track_instance(map,address,entry)
    entry.map,entry.address=map,address
    map[address]=entry
    tracked[#tracked+1]=entry
end
-- Keep a factory reachable while its instance is alive. Other observed
-- factories are weak so tracking does not keep inactive scene assets loaded.
local prefab_factories=setmetatable({},{__mode="v"})
local function track_factory(prefab)
    local name=prefab and prefab:call("get_ResourcePath")
    if name and name~="" then prefab_factories[prefab:get_address()]=prefab end
    return name
end
local function pin_prefab_instances(wanted)
    local groups={}
    for _,entry in pairs(prefab_instances) do
        if wanted[entry.path] and not entry.generation and entry.go:call("get_Valid") then
            local factory=entry.factory
            if factory and factory:call("get_Valid") and factory:call("get_Ready") then
                local name=factory:call("get_ResourcePath")
                local group=groups[name]
                if name and not group then
                    local res=sdk.create_resource("via.PrefabResource",name)
                    if res then
                        group={resource=res,count=0}
                        groups[name]=group
                        prefab_generations[group]=true
                    end
                end
                if group then group.count=group.count+1;entry.generation=group end
            end
        end
    end
end
local prefab_keys={DrawSelf=true,UpdateSelf=true,TimeScale=true}
local marker_path="gui/01_common/prefab/pl_headmessage.pfb"
local function apply_prefab(go,edits)
    local previous={}
    for key in pairs(edits) do
        assert(prefab_keys[key],"Unsupported prefab root property")
        previous[key]=go:call("get_"..key)
    end
    local ok,err=pcall(function()
        for key,value in pairs(edits) do
            go:call("set_"..key,value)
            assert(go:call("get_"..key)==value,"Prefab root property mismatch")
        end
    end)
    if not ok then
        for key,value in pairs(previous) do go:call("set_"..key,value) end
        error(err)
    end
    return previous
end

local function update_prefab(path,edits)
    path=path:lower()
    local targets={}
    for address,entry in pairs(prefab_instances) do
        if entry.path==path and entry.go:call("get_Valid") then targets[address]=entry.go end
    end
    if path==marker_path then
        for _,gui in ipairs(scene_components("via.gui.GUI")) do
            local go=gui:call("get_GameObject")
            local h=gui:call("get_Asset")
            if go:call("get_Name")=="PlHeadMessage" and h and h:call("get_ResourcePath"):lower()=="gui/01_common/overhead.gui"
                and go:call("getComponent(System.Type)",sdk.typeof("snow.gui.GuiCommonHeadMessage")) then
                targets[go:get_address()]=go
            end
        end
    end
    local undo={}
    local ok,err=pcall(function()
        for _,go in pairs(targets) do
            undo[#undo+1]={go=go,previous=apply_prefab(go,edits)}
        end
    end)
    if not ok then
        for i=#undo,1,-1 do apply_prefab(undo[i].go,undo[i].previous) end
        error(err)
    end
    local values=prefab_values[path] or {}
    for key,value in pairs(edits) do values[key]=value end
    prefab_values[path]=values
    return {count=#undo}
end

for _,method in ipairs(sdk.find_type_definition("via.Prefab"):get_methods()) do
    if method:get_name()=="instantiate" then
        sdk.hook(method,function(args)
            local storage=thread.get_hook_storage()
            storage.prefab_path=nil
            storage.factory=nil
            local ok,prefab=pcall(sdk.to_managed_object,args[2])
            if not ok or not prefab or prefab:get_type_definition():get_full_name()~="via.Prefab" then return end
            storage.prefab_path=track_factory(prefab)
            storage.factory=prefab
        end,function(retval)
            local storage=thread.get_hook_storage()
            local path=storage.prefab_path
            if not path or path=="" then return retval end
            local go=sdk.to_managed_object(retval)
            if path and path~="" and go then
                path=path:lower()
                local address=go:get_address()
                local entry=prefab_instances[address]
                if not entry or entry.go~=go or entry.path~=path then
                    track_instance(prefab_instances,address,{go=go,path=path,factory=storage.factory})
                else
                    entry.factory=storage.factory
                end
                if prefab_values[path] then
                    local ok,err=pcall(apply_prefab,go,prefab_values[path])
                    if not ok then log.error("[MHRS-Files-HotReload] "..tostring(err)) end
                end
            end
            return retval
        end)
    end
end
-- Walk backwards so deleting by swapping the last slot is constant time. Entries
-- added during a pass are picked up on the next pass. Pinned old roots stay
-- tracked even if a new instance has since claimed the same map entry.
local next_cleanup,cleanup_cursor=0,0
re.on_application_entry("UpdateBehavior",function()
    if cleanup_cursor==0 then
        if #tracked==0 or os.clock()<next_cleanup then return end
        cleanup_cursor=#tracked
    end
    for _=1,math.min(cleanup_cursor,8) do
        local i=cleanup_cursor
        cleanup_cursor=i-1
        local entry=tracked[i]
        local current=entry.map[entry.address]==entry
        if (not current and not entry.generation) or not entry.go:call("get_Valid") then
            if current then entry.map[entry.address]=nil end
            local group=entry.generation
            if group then
                group.count=group.count-1
                if group.count==0 then group.resource:release();prefab_generations[group]=nil end
            end
            tracked[i]=tracked[#tracked]
            tracked[#tracked]=nil
        end
    end
    if cleanup_cursor==0 then next_cleanup=os.clock()+5 end
end)

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
                local elements={}
                for id,value in pairs(edits) do
                    local class,name,prop=id:match("^([^|]+)|([^|]+)|([^|]+)$")
                    local key=prop or id
                    assert(view_fields[key],"Unsupported GUI property")
                    local targets={view}
                    if class then
                        assert(class:match("^via%.gui%.[%w_]+$"),"Invalid GUI class")
                        if not elements[class] then
                            local all=c:call("findObjects(System.Type)",sdk.typeof(class))
                            elements[class]=array_elements(all,class)
                        end
                        targets={}
                        for _,el in ipairs(elements[class]) do
                            if el:call("get_Name")==name and el:get_type_definition():get_full_name()==class then
                                table.insert(targets,el)
                            end
                        end
                    end
                    for _,target in ipairs(targets) do
                        local old=target:call("get_"..key)
                        assert(old~=nil,"GUI property unavailable")
                        table.insert(ops,{view=target,key=key,id=id,value=value,old=old,row=row})
                        row.values[id]=old
                    end
                end
            end
        end
    end
    assert(#values>0 and (#ops>0 or not next(edits)),"No matching ready GUI object for this path")
    for id in pairs(edits) do
        local matched=false
        for _,op in ipairs(ops) do if op.id==id then matched=true;break end end
        assert(matched,"No GUI object matched "..id)
    end
    if apply then
        local touched=0
        local ok,err=pcall(function()
            for i,op in ipairs(ops) do
                touched=i
                op.view:call("set_"..op.key,op.value)
                local actual=op.view:call("get_"..op.key)
                assert(actual==op.value or (op.key=="BaseFps" and math.abs(actual-op.value)<0.0001),"GUI readback mismatch")
                op.row.values[op.id]=actual
            end
        end)
        if not ok then
            for i=touched,1,-1 do local op=ops[i];op.view:call("set_"..op.key,op.old) end
            error(err)
        end
    end
    return {views=#values,bindings=values}
end
local function finish_materials(group,commit,native)
    if not commit then
        local state=native("abort_materials")
        assert(state=="rolled back",state)
        return state
    end
    local touched={}
    local ok,state=pcall(function()
        -- Re-enumerate after async loading. A changed preview or newly equipped
        -- part must invalidate the whole group before any mesh setter runs.
        for _,owner in ipairs(group.owners) do
            owner.list=bindings(owner.path,kinds.mdf2,"mdf2")
            assert(#owner.list==owner.count,"MDF users changed during template reload")
            local resource=assert(sdk.create_resource(kinds.mdf2[2],owner.path))
            local address=tostring(resource:get_address())
            local h=resource:create_holder(kinds.mdf2[2].."Holder")
            resource:release()
            assert(h and address==owner.fresh and tostring(h:read_qword(0x10))==owner.fresh,"Staged MDF cache mismatch")
            owner.holder=h
            for _,b in ipairs(owner.list) do
                assert(current_geometry(b.comp),"Previous equipment generation is still attached")
                local expected=owner.slots[b.comp:get_address()]
                assert(expected==b.old:read_qword(0x10),"MDF holder changed during template reload")
                if b.comp:call("get_MaterialReady") then b.switches=material_state(b.comp,true) end
            end
        end
        for _,owner in ipairs(group.owners) do
            for _,b in ipairs(owner.list) do
                touched[#touched+1]=b
                assign(b,owner.holder)
                assert(tostring(holder(b):read_qword(0x10))==owner.fresh,"MDF holder readback failed")
                restore_when_ready(b)
            end
        end
        local result=native("commit_materials")
        assert(result=="committed",result)
        return result
    end)
    if not ok then
        local rollback_error
        for i=#touched,1,-1 do
            local b=touched[i]
            local restored,err=pcall(function()
                assign(b,b.old)
                restore_when_ready(b)
            end)
            if not restored then rollback_error=err end
        end
        error(rollback_error and (tostring(state).."; rollback: "..tostring(rollback_error)) or state)
    end
    return state
end

function M.active() return job~=nil or master~=nil end
local sleeping={}
local warming={}
local equipment_refs={}
-- A later prefab requests the ordinary spelling. Keep the indexed platform
-- generation alive even when no render component has taken a reference yet.
local platform_pins={}
local equipment_pending=false
local equipment_batch
local armor_instances,armor_origins={},{}
local function armor_instance(id,go)
    local entry=armor_instances[id]
    if not entry or entry.go~=go then
        entry={go=go}
        track_instance(armor_instances,id,entry)
    end
    return entry
end
local gui_sequences,gui_assets={},{}
local next_gui_check,gui_scan=0,nil
local check_preview_targets=true
local texture_classes={"via.gui.Texture","via.gui.TextureSet"}
local waiting_uvs,seen_uvs,waiting_gui_assets={},{},{}
local watch_expires,next_broad_check=0,0
local gui_notice="MHRS-Files-HotReload/gui-ready.json"
local notify_ready=false
-- A watcher with a pending view can re-register immediately after a script reset.
json.dump_file(gui_notice,{state="loaded"})

-- Opening a preview can restore the camera prefab's original RTEX even when
-- GuiManager and the menu's UV sequence already use a newer generation.
local function repair_preview_camera(camera,slots)
    if not camera:call("get_IsReady") then return end
    local go=camera:call("get_GameObject")
    if not go or not go:call("get_Valid") or not go:call("get_Update") then return end
    local index=camera:get_field("_NowTextureType")
    if index<0 or index>=slots:call("get_Count") then return end
    local slot=slots:call("get_Item",index)
    local path=slot and slot:call("get_ResourcePath")
    if not path or slot:read_qword(0x10)==0 then return end
    for _,field in ipairs({"_RefRenderOutput","_RefRenderTargetOperator"}) do
        local comp=camera:get_field(field)
        local bound=comp and comp:call("get_RenderTarget")
        local old_path=bound and bound:call("get_ResourcePath")
        if old_path and old_path:lower()==path:lower() and bound:read_qword(0x10)~=slot:read_qword(0x10) then
            comp:call("set_RenderTarget",slot)
        end
    end
end

local function repair_preview_targets()
    local manager=sdk.get_managed_singleton("snow.gui.GuiManager")
    local slots=manager and manager:get_field("previewTextureList")
    if not slots then return end
    local cameras=scene_components("snow.camera.PreviewCamera")
    for _,camera in ipairs(cameras) do pcall(repair_preview_camera,camera,slots) end
end

local preview_setup=sdk.find_type_definition("snow.camera.PreviewCamera"):get_method("SetRenderTargetTexture")
sdk.hook(preview_setup,nil,function(retval)
    check_preview_targets=true
    return retval
end)

local function update_gui_assets()
    gui_assets={}
    for _,sequence in pairs(gui_sequences) do
        for name in pairs(sequence.owners) do gui_assets[name]=true end
    end
end

-- Views can survive a scene change or be created later from the same cached
-- GUI definition. Only keep the latest holder and visit ready, active views.
local function remember_gui_sequence(job,list,h)
    local owners={}
    for _,name in ipairs(job.gui_owners or {}) do owners[name:lower()]=true end
    for _,b in ipairs(list) do
        local ok,name=pcall(function()
            local asset=b.comp:call("get_Asset")
            return asset and asset:call("get_ResourcePath")
        end)
        if ok and name then owners[name:lower()]=true end
    end
    if next(owners) then
        gui_sequences[job.path:lower()]={holder=h,address=job.fresh,owners=owners}
        update_gui_assets()
    end
end

local function relevant_gui(comp,broad)
    local asset=comp:call("get_Asset")
    local name=asset and asset:call("get_ResourcePath")
    if not name then return false end
    name=name:lower()
    if not (gui_assets[name] or waiting_gui_assets[name] or broad) or not comp:call("get_Ready") then return false end
    local go=comp:call("get_GameObject")
    return go and go:call("get_Valid") and go:call("get_Update")
end

local function active_gui_at(components,index,broad)
    local comp=components[index]
    if comp and relevant_gui(comp,broad) then return comp end
end

local function repair_gui_item(objects,index)
    -- Both indexing a closed window's collection and calling its item can fail.
    local obj=objects[index]
    local old=obj:call("get_UVSequence")
    local name=old and old:call("get_ResourcePath")
    if not name then return end
    local path=name:lower()
    if waiting_uvs[path] and not seen_uvs[path] then
        local first=not next(seen_uvs)
        seen_uvs[path]=true
        if first and notify_ready then json.dump_file(gui_notice,{state="ready",path=path}) end
    end
    local saved=gui_sequences[path]
    if saved and tostring(old:read_qword(0x10))~=saved.address then
        obj:call("set_UVSequence",saved.holder)
    end
end

-- Enumerate once per pass. Spread ready views, their two object queries and
-- individual UV bindings across frames, including on an unchanged HUD.
re.on_application_entry("UpdateBehavior",function()
    if not M.active() and not equipment_batch then equipment_physics.update(os.clock()) end
    if M.active() then gui_scan=nil;return end
    if check_preview_targets then
        check_preview_targets=false
        pcall(repair_preview_targets)
    end
    if next(waiting_uvs) and os.clock()>watch_expires then waiting_uvs,seen_uvs,waiting_gui_assets={},{},{} end
    if not next(gui_sequences) and not next(waiting_uvs) then gui_scan=nil;return end
    if not gui_scan then
        if os.clock()<next_gui_check then return end
        local ok,components=pcall(scene_components,kinds.uvs[1])
        next_gui_check=os.clock()+1
        if ok then
            local broad=next(waiting_uvs) and os.clock()>=next_broad_check
            if broad then next_broad_check=os.clock()+10 end
            gui_scan={components=components,count=#components,index=1,broad=broad}
        end
        return
    end
    local scan=gui_scan
    if scan.comp then
        local valid,ready=pcall(relevant_gui,scan.comp,scan.broad)
        if not valid or not ready then scan.comp,scan.objects=nil,nil;return end
        if not scan.objects then
            local class=texture_classes[scan.class]
            local ok,objects=pcall(function()
                return array_elements(scan.comp:call("findObjects(System.Type)",sdk.typeof(class)),class)
            end)
            if not ok then scan.comp=nil;return end
            scan.objects,scan.item,scan.item_count=objects,1,#objects
        end
        for i=scan.item,math.min(scan.item_count,scan.item+23) do
            scan.item=i+1
            pcall(repair_gui_item,scan.objects,i)
        end
        if scan.item>scan.item_count then
            scan.objects=nil
            scan.class=scan.class+1
            if not texture_classes[scan.class] then scan.comp=nil end
        end
        return
    end
    for i=scan.index,math.min(scan.count,scan.index+7) do
        scan.index=i+1
        local ok,comp=pcall(active_gui_at,scan.components,i,scan.broad)
        if ok and comp then scan.comp,scan.class=comp,1;return end
    end
    if scan.index>scan.count then gui_scan=nil;next_gui_check=os.clock()+1 end
end)

local function release_equipment()
    local restored,reason=true,nil
    if equipment_batch then
        local batch=equipment_batch
        equipment_batch=nil
        peer_equipment.abort(batch.peers,restore_when_ready)
        peer_physics.abort(batch.peer_physics,restore_when_ready)
        restored,reason=pcall(worn_armor.abort,batch,restore_when_ready)
    end
    for _,resource in pairs(equipment_refs) do resource:release() end
    equipment_refs={}
    equipment_pending=false
    assert(restored,reason)
end

local function request_equipment(equipment,platform,expected)
    local batch={platform=platform,materials={}}
    -- The first request after retirement determines the source for all users
    -- of that spelling. Publish texture keys before the MDF requests them.
    for _,ext in ipairs({"tex","mesh","mdf2","chain","mot"}) do
        for name,kind in pairs(equipment) do
            if name:lower():sub(-#ext-1)=="."..ext then
                local path=platform[name] and "@"..name or name
                equipment_refs[name]=assert(sdk.create_resource(kind,path),"Could not load equipment: "..path)
                if ext=="mdf2" then batch.materials[name]=expected[name:lower()] or false end
            end
        end
    end
    for _,file in ipairs({"equipment-paths.txt","equipment-platform.txt"}) do
        local f=assert(io.open("MHRS-Files-HotReload/"..file,"wb"))
        local ok,err=pcall(function()
            for name,resource in pairs(equipment_refs) do
                if file=="equipment-paths.txt" then
                    if not name:lower():match("%.tex$") then assert(f:write(name,"\n")) end
                elseif platform[name] then
                    assert(f:write(name,"\t",tostring(resource:get_address()),"\n"))
                end
            end
        end)
        local closed,why=f:close()
        assert(ok,err)
        assert(closed,why)
    end
    return batch
end

local function equipment_factories(wanted,visit)
    local parts={}
    local names={arm="Arm",body="Body",helm="Helm",leg="Leg",wst="Wst"}
    for path in pairs(wanted) do
        local part=path:match("^player/prefab/mod/[fm]/pl%d+/[fm]_(%a+)%d+%.pfb$")
        if names[part] then parts[names[part]]=true end
    end
    if not next(parts) then return end
    local pm=sdk.get_managed_singleton("snow.player.PlayerManager")
    if not pm or not pm:call("findMasterPlayer") then return end
    local player=pm:call("get_PlayerParam")[pm:call("getMasterPlayerID")]
    if not player then return end
    local enum=sdk.find_type_definition("snow.player.PlayerRequestEquipsData.EquipPack")
    for part in pairs(parts) do
        local field=enum:get_field(part)
        if field then
            local prefabs=pm:call("getPartsPrefabList",field:get_data(nil),pm:call("getPlayerWeaponType",player),
                pm:call("getPlayerSexType",player),false)
            if prefabs then
                for i=0,prefabs:call("get_Count")-1 do visit(prefabs:call("get_Item",i)) end
            end
        end
    end
end
local function awakened(done)
    local ready={}
    local actors
    for path,entries in pairs(sleeping) do
        for i=#entries,1,-1 do
            local b=entries[i]
            local ok,state=pcall(function()
                if not b.go:call("get_Valid") then return "drop" end
                if b.wearer then
                    actors=actors or hunter_roster.read()
                    if ordinary_owner(actors,b.go)~=b.wearer then return "drop" end
                end
                if not b.go:call("get_Update") then return "sleep" end
                if done[path] then return "drop" end
                local h=holder(b)
                if h and h:call("get_ResourcePath"):lower()==path and
                        tostring(h:read_qword(0x10))==b.address then return "awake" end
                return "drop"
            end)
            if not ok or state=="drop" then table.remove(entries,i)
            elseif state=="awake" then ready[path]=true end
        end
        if #entries==0 then sleeping[path]=nil end
    end
    return {paths=ready,pending=next(sleeping)~=nil}
end
function M.reset(native)
    if job then M.run("asset_abort",{},native) end
    while master do M.run("asset_master_abort",{},native) end
    release_equipment()
    for _,resource in pairs(platform_pins) do resource:release() end
    platform_pins={}
    equipment_physics.reset()
    peer_equipment.reset()
    peer_physics.reset()
    armor_instances,armor_origins={},{}
    gui_scan=nil
    for group in pairs(prefab_generations) do group.resource:release() end
    prefab_generations={}
    tracked,prefab_instances,retired_visuals={},{},{}
    cleanup_cursor=0
end
function M.run(action,req,native)
    if action=="asset_hunter_roster" then
        return {hunters=hunter_roster.describe(hunter_roster.read()),peer_last_events=peer_equipment.status(),
            peer_physics_events=peer_physics.status()}
    end
    if action=="asset_peer_meshes" then
        local wanted={}
        for _,path in ipairs(req.paths or {}) do wanted[path:lower()]=true end
        local peers,master=hunter_roster.mesh_paths(wanted)
        return {paths=peers,master=master}
    end
    if action=="asset_gui_ready" then
        local wanted,found,assets={},{},{}
        for path,names in pairs(req.owners) do
            path=path:lower()
            if seen_uvs[path] then found[#found+1]=path else
                wanted[path]=true
                for _,name in ipairs(names) do assets[name:lower()]=true end
            end
        end
        waiting_uvs,seen_uvs,waiting_gui_assets=wanted,{},assets
        notify_ready=req.notify==true
        watch_expires=os.clock()+(notify_ready and 120 or 5)
        return {paths=found,notifications=notify_ready}
    end
    if action=="asset_awake" then return awakened(req.done or {}) end
    if action=="asset_worn_state" then
        return (require("MHRS_HotReload.village_equipment").worn_state(req.paths,req.wait_factory,req.wait_rebuild))
    end
    if action=="asset_part_recovery" then return require("MHRS_HotReload.village_equipment").replay_state() end
    if action=="asset_equipment_abort" then
        release_equipment()
        return {pending=false}
    end
    if action=="asset_factories_ready" then
        local next_update,mount_outcome
        if equipment_pending then
            local state=native("equipment_ready")
            if state=="equipment platform source mismatch" then
                local f=io.open("MHRS-Files-HotReload/equipment-wait.txt","rb")
                local detail=f and f:read("*a") or state
                if f then f:close() end
                release_equipment()
                return {pending=false,source_mismatch=detail~="" and detail or state}
            end
            if state=="invalid equipment material slots" then
                release_equipment()
                return {pending=false,source_mismatch="Could not read names from the loaded equipment MDF"}
            end
            assert(state=="ready" or state=="pending",state)
            equipment_pending=state=="pending"
            if not equipment_pending and equipment_batch then
                local stream=io.open("MHRS-Files-HotReload/equipment-slots.txt","rb")
                local reason="Equipment material slot report is unavailable"
                if stream then
                    local ok,value=pcall(worn_armor.check_sources,equipment_batch,equipment_refs,stream)
                    stream:close()
                    reason=ok and value or nil
                    if not ok then reason=tostring(value) end
                end
                if reason then
                    release_equipment()
                    return {pending=false,source_mismatch=reason}
                end
            end
        end
        for key,entry in pairs(warming) do
            local factory=entry.factory
            if not factory:call("get_Valid") or not factory:call("get_Standby") then warming[key]=nil
            elseif factory:call("get_Ready") then
                if entry.reopen then
                    factory:call("set_Standby",false)
                    factory:call("set_Standby",true)
                    entry.reopen=false
                else warming[key]=nil end
            end
        end
        if equipment_batch and not equipment_pending and (not equipment_batch.village or not next(warming)) then
            local batch=equipment_batch
            local ok,pending=pcall(function()
                local peers=peer_equipment.advance(batch.peers,scene_components,equipment_refs,material_state,restore_when_ready)
                local physics=peer_physics.advance(batch.peer_physics,scene_components,equipment_refs,material_state,restore_when_ready)
                if not batch.local_done then
                    batch.local_done=not worn_armor.advance(batch,scene_components,equipment_refs,material_state,restore_when_ready)
                elseif batch.vertex_fallback and not batch.village and not worn_armor.vertices_ready(batch) then
                    return true
                end
                return peers or physics or not batch.local_done
            end)
            if not ok or not pending then
                if ok then
                    mount_outcome=batch.village and batch.village.deferred_mount
                    if batch.physics then batch.physics:commit() end
                    if batch.village and not mount_outcome and batch.stock_meshes and next(batch.stock_meshes) then
                        local recorded,why=pcall(worn_armor.remember_stock,batch,hunter_roster.read(),equipment_refs,armor_instance)
                        if recorded then log.info(("[MHRS-Files-HotReload] Recorded %d restored worn PAK meshes"):format(why))
                        else log.warn("[MHRS-Files-HotReload] Worn PAK source unavailable: "..tostring(why)) end
                    end
                    for _,row in ipairs(batch.touched or {}) do
                        if row.mesh.fresh~=row.mesh.original then
                            local entry=armor_instance(row.comp:get_address(),row.go)
                            entry.direct,entry.defer=row.mesh.fresh,nil
                            entry.queued_vertex=nil
                            entry.stock=nil
                            if row.vertex_owner then
                                log.info(("[MHRS-Files-HotReload] Updated worn vertices %s on existing renderer %s (%s -> %s)")
                                    :format(row.mesh.path,tostring(row.comp:get_address()),tostring(row.mesh.original),tostring(row.mesh.fresh)))
                            end
                        end
                    end
                    local updated={}
                    for name,res in pairs(equipment_refs) do
                        local key=name:lower()
                        if key:match("%.mesh$") then
                            peer_equipment.generation(key,res:get_address(),(batch.peer_meshes or {})[key])
                            local loose=batch.loose[key] or batch.loose[key:gsub("%.mesh$",".chain")] or false
                            updated[key]=updated[key] or {}
                            updated[key][res:get_address()]=loose
                        end
                    end
                    for key,origins in pairs(updated) do armor_origins[key]=origins end
                    for name in pairs(batch.platform) do
                        platform_pins[name]=equipment_refs[name]
                        equipment_refs[name]=nil
                    end
                end
                if not ok then
                    if batch.local_done and batch.vertex_fallback and not batch.aborted then
                        local restored,why=pcall(worn_armor.abort,batch,restore_when_ready)
                        if not restored then pending=tostring(pending).."; rollback: "..tostring(why) end
                    end
                    peer_equipment.abort(batch.peers,restore_when_ready)
                    peer_physics.abort(batch.peer_physics,restore_when_ready)
                end
                equipment_batch=nil
                release_equipment()
            end
            if not ok then error(pending) end
            local tx=equipment_batch and equipment_batch.village
            if tx and tx.mount and not tx.mount_error and not equipment_batch.local_done then
                next_update=tx.mount.next_update
                tx.mount.next_update=nil
            end
        end
        return {pending=equipment_pending or equipment_batch~=nil or next(warming)~=nil,next_update=next_update,worn_mount=mount_outcome}
    end
    if action=="asset_removed" then
        assert(not M.active(),"Resource transaction active")
        if req.reset_replay then
            local state=require("MHRS_HotReload.village_equipment").replay_state(req.reset_replay)
            assert(state.id==req.reset_replay and req.worn_retry,"[village changed] Reset equipment recovery expired")
            for path,old in pairs(state.worn) do assert(req.worn_retry[path]==old,"[village changed] Worn recovery generation changed") end
        end
        local paths=assert(req.paths)
        if #paths==0 then return {results={}} end
        release_equipment()
        local names,seen,by_ext={},{},{}
        local warm,dormant={},{}
        local dormant_actors
        local equipment,retiring_visuals,preview_targets={},{},{}
        local physics_spec=req.physics or {}
        local physics
        if next(physics_spec.helmets or {}) then
            physics=equipment_physics.new(physics_spec,parts,user_field)
        end
        local armor_candidates,armor_count={},0
        local startup,loose={},{}
        for _,name in ipairs(req.startup_equipment or {}) do startup[name:lower()]=true end
        for _,name in ipairs(req.loose_equipment or {}) do loose[name:lower()]=true end
        -- Synchronous discovery only. A later frame, bind or player rebuild
        -- must enumerate the scene again before it can publish any resources.
        local components_by_type={}
        local live={}
        local armor_mesh_requested=false
        for _,p in ipairs(req.live_reentry or paths) do
            local key=p:lower()
            live[key]=true
            if key:match("^player/mod/.+%.mesh$") and not key:match("/[fm]_shadow%.mesh$") then
                armor_mesh_requested=true
            end
        end
        local waiting,pause_hunter,retry_owners,training_rebuild,full_wait,full_owner
        if armor_mesh_requested then
            local state,owners=require("MHRS_HotReload.village_equipment").worn_state(live)
            if req.worn_guard then
                assert(req.worn_retry and state.root==req.worn_guard.root and state.scope==req.worn_guard.scope,
                    "[village changed] Queued outfit owner changed")
            end
            training_rebuild=(state.training or state.quest) and next(state.observed)~=nil
            if state.complete_outfit and not req.reset_replay then full_owner=state end
            if req.worn_retry then
                retry_owners=owners
                assert(state.ready,"[village changed] Hunter is not ready for the queued change")
                for key,old in pairs(req.worn_retry) do
                    assert(state.observed[key]==old and state.available[key],"[village changed] Equipment or its generation changed")
                end
            end
            for key,old in pairs(state.observed) do
                if (not state.ready or not state.available[key]) and not (req.missing or {})[key] then
                    waiting=waiting or {}
                    waiting[key]=old
                end
            end
            pause_hunter=waiting and not state.ready
            if waiting and state.complete_outfit and not req.reset_replay then
                full_wait={root=state.root,scope=state.scope,worn=state.observed,retry=true,reason="Local worn outfit is not ready"}
                pause_hunter=true
            end
        end
        local compound=#(req.live_reentry or paths)>1
        -- A whole-outfit swap changes the skeleton under an existing Chain.
        -- Its normal prefab creation can acquire the preloaded replacement.
        local function add(name)
            if not seen[name] then seen[name]=true;names[#names+1]=name end
        end
        local platform_paths,retired_paths={},{}
        local function add_path(path)
            add(path)
            retired_paths[path:lower()]=true
            for _,alias in ipairs((req.aliases or {})[path] or {}) do
                if alias:lower()==path:lower() then add(alias) end
            end
            local ext=path:lower():match("%.([a-z0-9]+)$")
            by_ext[ext]=by_ext[ext] or {}
            by_ext[ext][path:lower()]=true
        end
        for _,path in ipairs(paths) do add_path(path) end
        for _,path in ipairs(req.platform_files or {}) do
            local key=path:lower()
            local ext=key:match("%.([a-z0-9]+)$")
            assert((ext=="tex" or ext=="mesh" or ext=="mdf2" or ext=="chain" or ext=="user" or ext=="mot") and not key:match("^streaming/"),
                "Unexpected equipment platform path: "..path)
            if not (req.missing or {})[key] then
                platform_paths[key]=true
                add_path(path)
            end
        end
        for name in pairs(platform_pins) do
            if retired_paths[name:lower()] then add(name) end
        end
        for ext,wanted in pairs(by_ext) do
            if kinds[ext] and ext~="user" then
                local ok,owners=pcall(bindings,wanted,kinds[ext],ext,true,components_by_type)
                if ok then
                    for _,owner in ipairs(owners) do
                        add(owner.path)
                        if owner.preview then preview_targets[owner.path:lower()]=owner.path end
                        local go=not owner.preview and owner.comp:call("get_GameObject")
                        if go and (ext=="mesh" or ext=="mdf2") then
                            local id=owner.comp:get_address()
                            local previous=retiring_visuals[id] or {go=go}
                            previous[ext]=tostring(owner.old:read_qword(0x10))
                            retiring_visuals[id]=previous
                        end
                        if go and go:call("get_Update") and
                                (ext=="mesh" or ext=="mdf2") and owner.path:lower():match("^player/mod/") then
                            local id=owner.comp:get_address()
                            if not armor_candidates[id] then
                                local row=worn_armor.capture(owner.comp,go,kinds,req.missing or {},equipment,req.expected_materials or {})
                                if row then
                                    armor_candidates[id]=row
                                    armor_count=armor_count+1
                                end
                            end
                        end
                        -- A partially constructed outfit can temporarily have an
                        -- inactive component. Its prefab owns the whole new set.
                        if live[owner.path:lower()] and not ((compound or armor_mesh_requested) and (ext=="mesh" or ext=="mdf2" or ext=="chain" or ext=="jcns"))
                                and go and not go:call("get_Update") then
                            local key=owner.path:lower()
                            owner.address=tostring(owner.old:read_qword(0x10))
                            owner.go=go
                            owner.old=nil
                            local hunter=hunter_asset(key,ext)
                            if hunter then
                                dormant_actors=dormant_actors or hunter_roster.read()
                                owner.wearer=ordinary_owner(dormant_actors,go)
                            end
                            if not hunter or owner.wearer then
                                dormant[key]=dormant[key] or {}
                                dormant[key][#dormant[key]+1]=owner
                            end
                        end
                    end
                end
            elseif ext=="pfb" then
                pin_prefab_instances(wanted)
                local function visit(factory)
                    if not factory or not factory:call("get_Valid") then return end
                    local name=factory:call("get_ResourcePath")
                    if name and wanted[name:lower()] then
                        add(name)
                        if factory:call("get_Standby") then warm[factory:get_address()]=factory end
                    end
                end
                for _,factory in pairs(prefab_factories) do visit(factory) end
                equipment_factories(wanted,visit)
            elseif ext=="gui" then
                local ok,components=pcall(scene_components,"via.gui.GUI",components_by_type)
                if ok then
                    for _,gui in ipairs(components) do
                        local h=gui:call("get_Asset")
                        local name=h and h:call("get_ResourcePath")
                        if name and wanted[name:lower()] then add(name) end
                    end
                end
            end
        end
        -- Replacing a mesh under a custom skeleton first instantiated by the
        -- game has terminated Rise after setters reported success. Keep the
        -- current renderers intact until the game rebuilds these equipment parts.
        if req.worn_retry then
            for key,old in pairs(req.worn_retry) do
                local row=armor_candidates[retry_owners[key]]
                assert(row and tostring(row.mesh.original)==old,"[village changed] Waiting for local worn mesh discovery")
            end
        end
        local shadow,shadow_reason,shadow_layout
        if next(req.shadow_skeletons or {}) then
            local manager=sdk.get_managed_singleton("snow.player.PlayerManager")
            shadow,shadow_reason=shadow_skeleton.capture(manager and manager:call("findMasterPlayer"),req.shadow_skeletons)
            shadow_layout=shadow
            if shadow and (shadow.changed>0 or req.reset_replay) then
                add_path(shadow.request)
                if shadow.request~=shadow.canonical then add_path(shadow.canonical) end
                equipment[shadow.request]=kinds.mesh[2]
            else
                shadow=nil
            end
        end
        local chains,village
        local peer_tasks,peer_receipt={},{}
        if req.reset_replay or req.worn_guard then
            local keep={}
            for path in pairs(req.worn_retry) do keep[assert(retry_owners[path])]=true end
            for id in pairs(armor_candidates) do if not keep[id] then armor_candidates[id]=nil end end
        else
            peer_tasks,peer_receipt=peer_equipment.partition(armor_candidates,live,req,function(row,id)
                return not worn_armor.needs_reentry(row,armor_instances[id],armor_origins,startup)
            end)
        end
        if #peer_tasks>0 then
            for _,t in ipairs(peer_tasks) do
                if type(t.groups)=="number" and not (req.missing or {})[t.chain] then
                    add_path(t.chain)
                    equipment[t.chain]=kinds.chain[2]
                end
            end
        end
        armor_count=0
        for _ in pairs(armor_candidates) do armor_count=armor_count+1 end
        local chain_components={}
        local peer_effects,chain_actors
        local rebuild,positions_only=false,false
        if not req.reset_replay and not req.worn_guard and (next(armor_candidates) or next(req.shadow_skeletons or {}) or next(physics_spec.chains or {})) then
            chain_components=scene_components("via.motion.Chain",components_by_type)
            peer_effects,chain_components,chain_actors=peer_physics.capture(chain_components,req,live,equipment,function(path,ext)
                add_path(path)
                equipment[path]=kinds[ext][2]
            end)
        end
        if next(armor_candidates) then
            local pm=sdk.get_managed_singleton("snow.player.PlayerManager")
            local master=pm and pm:call("findMasterPlayer")
            local hunter=master and master:call("get_GameObject")
            local only=next(live)
            local prior,retained,stock,slot_no
            if chain_actors and only and not next(live,only) and armor_count==1 and (req.peer_meshes or {})[only]
                    and not next(req.shadow_skeletons or {}) and not next(physics_spec.chains or {}) then
                for id,row in pairs(armor_candidates) do
                    local part=chain_actors.parts[row.go:get_address()]
                    local instance=armor_instances[id]
                    retained=instance and instance.go==row.go and instance.queued_vertex
                        and instance.queued_vertex:read_qword(0x10)==row.mesh.original
                    stock=worn_armor.resident_stock(row,instance,part)
                    prior=retained or stock or peer_equipment.stock_layout(only,row.mesh.original,
                        not worn_armor.needs_reentry(row,instance,armor_origins,startup))
                    slot_no=part and part.slot
                    if row.mesh.path:lower()==only and part and part.entry and part.entry.role=="master"
                            and part.entry.scope and row.wearer_owns and part.entry.player==master and part.go==row.go and prior then
                        local slot=part.slot
                        row.vertex_owner=function(go)
                            return (not go or go==row.go) and row.wearer_owns(row.go)
                                and pm:call("findMasterPlayer")==master and master:call("get_GameObject")==hunter
                                and master:call("getPartsGameObject",slot)==row.go and hunter_roster.render_part(row.go)==row.comp
                        end
                    end
                end
            end
            local reason
            rebuild,positions_only,reason=worn_armor.requires_model_rebuild(armor_candidates,live,chain_components,hunter,physics_spec.chains or {})
            rebuild=rebuild or full_owner~=nil or req.reset_replay~=nil or (training_rebuild and not positions_only)
            if only and not next(live,only) and only:match("^player/mod/.+%.mesh$") then
                log.info(("[MHRS-Files-HotReload] Worn mesh route %s candidates=%d slot=%s incoming=%s old=%s queued_old=%s worn_pak=%s wait=%s rebuild=%s (%s)")
                    :format(only,armor_count,tostring(slot_no),tostring((req.peer_meshes or {})[only]==true),
                    tostring(prior==true),tostring(retained==true),tostring(stock==true),tostring(pause_hunter==true),
                    tostring(rebuild==true),tostring(reason)))
            end
            if positions_only and not rebuild then
                for id,row in pairs(armor_candidates) do
                    row.mdf2.keep=true
                    if pause_hunter and not retained then
                        local resource=assert(sdk.to_resource(sdk.to_ptr(row.mesh.original)))
                        local pin=assert(resource:create_holder_global(row.mesh.kind[2].."Holder"))
                        assert(pin:read_qword(0x10)==row.mesh.original,"Could not retain queued vertex source")
                        armor_instance(id,row.go).queued_vertex=pin
                    end
                end
            end
        end
        if not pause_hunter and not rebuild and not positions_only
                and (shadow or next(armor_candidates) or next(physics_spec.chains or {})) then
            local protected=armor_candidates
            if shadow then
                protected={}
                for id,row in pairs(armor_candidates) do protected[id]=row end
                protected.shadow={go=shadow.root}
            end
            chains=worn_chain.capture(chain_components,
                protected,physics_spec.chains or {},req.missing or {},equipment,physics_spec.chain_terminals or {})
            for _,row in ipairs(chains and chains.rows or {}) do
                local wearer=hunter_roster.owner(chain_actors,row.go)
                if wearer.role=="master" or wearer.role=="scene" then row.wearer_owns=hunter_roster.guard(wearer) end
            end
            if shadow and not (chains and chains:covers(protected.shadow)) then
                shadow_reason="Could not observe the hunter's attached physics"
                shadow=nil
            end
        end
        local deferred_paths=(pause_hunter or rebuild or full_owner) and {} or nil
        for id,row in pairs(armor_candidates) do
            if not row.mesh.keep and worn_armor.needs_reentry(row,armor_instances[id],armor_origins,startup)
                    and not row.vertex_owner and not (chains and chains:covers(row)) then
                deferred_paths={}
                break
            end
        end
        if deferred_paths then
            village=not pause_hunter and require("MHRS_HotReload.village_equipment").capture(
                armor_candidates,physics_spec,req.expected_materials or {},shadow_layout,req.missing or {},
                next(req.shadow_skeletons or {})~=nil and not shadow_layout and shadow_reason~="No shadow change for this hunter",live,shadow_reason)
            if full_owner and not village and not full_wait then
                full_wait={root=full_owner.root,scope=full_owner.scope,worn=full_owner.observed,retry=true,
                    reason="Waiting to capture the five worn parts"}
            end
            if village and full_owner then village.full_outfit=true end
            assert(not req.worn_retry or village or full_wait,"[village changed] Local equipment rebuild is not ready")
            if req.reset_replay then
                assert(shadow_layout,"Reset recovery cannot verify the current shadow source")
                village.reset_replay=req.reset_replay
            end
            for _,name in ipairs(names) do
                local key=name:lower()
                if physics_spec.chains and physics_spec.chains[key] and not (req.missing or {})[key] then
                    equipment[name]=kinds.chain[2]
                end
            end
            local deferred={}
            for id,row in pairs(armor_candidates) do
                armor_instance(id,row.go).defer=row.mesh.original
                deferred[row.mesh.path],deferred[row.mdf2.path]=true,true
            end
            for path in pairs(deferred) do deferred_paths[#deferred_paths+1]=path end
            table.sort(deferred_paths)
            armor_candidates={}
            chains=nil
            if shadow and not village then shadow_reason="Worn components require normal re-equip" end
            shadow=nil
            if physics then physics.defer_live=true end
            if village then deferred_paths=nil end
        end
        local f=assert(io.open("MHRS-Files-HotReload/asset-paths.txt","wb"))
        f:write(table.concat(names,"\n"),"\n")
        f:close()
        local state=native("forget_batch")
        assert(state=="retired batch",state)
        local platform={}
        for _,name in ipairs(names) do
            local old=platform_pins[name]
            if old then old:release();platform_pins[name]=nil end
            if platform_paths[name:lower()] then
                local ext=name:lower():match("%.([a-z0-9]+)$")
                if ext~="user" then
                    equipment[name]=kinds[ext][2]
                    platform[name]=true
                end
            end
        end
        if next(equipment) or physics or chains or village or (peer_effects and #peer_effects>0) then
            local ok,batch=pcall(request_equipment,equipment,platform,req.expected_materials or {})
            if not ok then release_equipment();error(batch) end
            if physics then
                local loaded,why=pcall(physics.request,physics,platform_paths,req.missing or {})
                if not loaded then release_equipment();error(why) end
                batch.physics=physics
            end
            batch.candidates=armor_candidates
            if positions_only and not rebuild then
                batch.vertex_fallback=function()
                    return require("MHRS_HotReload.village_equipment").capture(armor_candidates,physics_spec,
                        req.expected_materials or {},nil,req.missing or {})
                end
            end
            batch.peers=peer_tasks
            batch.peer_physics=peer_effects
            batch.peer_meshes=req.peer_meshes
            if armor_mesh_requested and next(armor_candidates) then batch.mesh_changes=live end
            batch.chains=chains
            batch.village=village
            batch.stock_meshes=req.stock_meshes
            batch.stock_scope=chain_actors and chain_actors.scope
            batch.shadow=shadow
            batch.loose=loose
            equipment_batch=batch
            equipment_pending=true
        end
        if by_ext.uvs then
            for path in pairs(by_ext.uvs) do gui_sequences[path]=nil end
            update_gui_assets()
        end
        for path in pairs(by_ext.pfb or {}) do prefab_values[path]=nil end
        for id,entry in pairs(retiring_visuals) do
            local previous=retired_visuals[id]
            if previous and previous.go==entry.go then
                previous.mesh=entry.mesh or previous.mesh
                previous.mdf2=entry.mdf2 or previous.mdf2
            else
                track_instance(retired_visuals,id,entry)
            end
            deferred_materials[id]=nil
        end
        -- A ready via.Prefab can retain its previous serialized hierarchy even
        -- after the resource key is retired. Reopen the existing factory as
        -- well so its next instantiate() uses the replacement hierarchy.
        local factory_count=0
        for key,factory in pairs(warm) do
            local ready=factory:call("get_Ready")
            if ready then
                factory:call("set_Standby",false)
                factory:call("set_Standby",true)
            end
            warming[key]={factory=factory,reopen=not ready}
            factory_count=factory_count+1
        end
        local counts=assert(io.open("MHRS-Files-HotReload/retired-counts.txt","r"))
        local results,totals={},{}
        for _,name in ipairs(names) do
            local n=tonumber(counts:read("*l"))
            if not n then counts:close();error("Incomplete retirement receipt") end
            totals[name:lower()]=(totals[name:lower()] or 0)+n
        end
        for i,path in ipairs(paths) do
            local n=totals[path:lower()]
            sleeping[path:lower()]=dormant[path:lower()]
            prefab_values[path:lower()]=nil
            results[i]={path=path,state=n>0 and "retired" or "not cached",generations=n}
        end
        counts:close()
        return {results=results,factories=factory_count,equipment=equipment_pending,
            equipment_bindings=deferred_paths and 0 or armor_count,deferred_equipment=deferred_paths,
            waiting_equipment=not full_wait and waiting or nil,worn_mount=full_wait,peer_equipment=peer_receipt,shadow_deferred=shadow_reason,sleeping=next(sleeping)~=nil,
            preview_targets=preview_targets}
    end
    if action=="asset_prefab_forget" then prefab_values[req.path:lower()]=nil;return {} end
    if action=="asset_prefab" then return update_prefab(req.path,req.edits) end
    if action=="asset_marker" or action=="asset_marker_inspect" then
        return player_marker(req.path,req.edits,action=="asset_marker")
    end
    if action=="asset_camera_prepare" or action=="asset_camera_release" or action=="asset_camera_inspect" or action=="asset_camera" then
        return camera_data(action,req)
    end
    if action=="asset_gui" or action=="asset_gui_inspect" then
        return gui_views(req.path,req.edits or {},action=="asset_gui")
    end
    if action=="asset_active_consumers" then
        local groups,seen,paths={},{},{}
        for _,path in ipairs(req.paths) do
            local ext=path:match("%.([a-z0-9]+)$")
            assert(ext=="efx" or ext=="uvs" or ext=="motlist","Unsupported dependent type")
            groups[ext]=groups[ext] or {}
            groups[ext][path:lower()]=true
        end
        for ext,wanted in pairs(groups) do
            for _,b in ipairs(bindings(wanted,kinds[ext],ext)) do
                local path=b.path:lower()
                if not seen[path] then seen[path]=true;paths[#paths+1]=path end
            end
        end
        return {paths=paths}
    end
    if action=="asset_gui_links" then
        local wanted,seen,records={},{},{}
        for _,p in ipairs(req.paths) do wanted[p:lower()]=true end
        local ok,users=pcall(bindings,wanted,kinds.uvs,"uvs",not req.active_only)
        if ok then
            for _,b in ipairs(users) do
                local h=b.comp:call("get_Asset")
                local p=h and h:call("get_ResourcePath")
                if p and p:lower():match("%.gui$") and not seen[p.."\t"..b.path] then
                    seen[p.."\t"..b.path]=true
                    records[#records+1]={owner=p,child=b.path}
                end
            end
        end
        return {links=records}
    end
    if action=="asset_material_paths" or action=="asset_material_links" then
        local paths,seen={},{}
        local ok,meshes=pcall(scene_components,kinds.mdf2[1])
        if not ok then
            if action=="asset_material_links" then return {links={}} end
            error(meshes)
        end
        for _,comp in ipairs(meshes) do
            local go=comp:call("get_GameObject")
            if go and ((action=="asset_material_links" and comp:call("get_MaterialReady")) or go:call("get_Update")) then
                local h=comp:call("get_Material")
                local path=h and h:call("get_ResourcePath")
                if path and not seen[path] then paths[#paths+1]=path;seen[path]=true end
            end
        end
        if action=="asset_material_links" then
            local f=assert(io.open("MHRS-Files-HotReload/material-paths.txt","wb"))
            for _,path in ipairs(req.paths) do f:write(path,"\n") end
            for _,path in ipairs(paths) do f:write(path,"\n") end
            f:close()
            local state=native("material_links")
            assert(state=="material links",state)
            local records={}
            for line in io.lines("MHRS-Files-HotReload/material-links.txt") do
                local owner,child=line:match("^([^\t]+)\t(.+)$")
                if owner then records[#records+1]={owner=owner,child=child} end
            end
            return {links=records}
        end
        return {paths=paths}
    end
    if action=="asset_master_begin" then
        local ext=req.path:lower():match("%.([a-z0-9]+)$")
        local allowed={mmtr=true,uvs=true,uvar=true,tex=true,mot=true,rtex=true,mesh=true,mdf2=true}
        assert(not job and (not master or (master.held and ext=="uvs" and master.ext=="tex")) and allowed[ext],"Invalid dependency transaction")
        local f=assert(io.open("MHRS-Files-HotReload/asset-path.txt","wb"))
        f:write(req.platform and "@" or "",req.path); f:close()
        local state,address=native("asset")
        assert(state=="pending",state)
        master={held=false,parent=master,ext=ext,owners=ext=="mmtr" and {} or nil}
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
        if master.owners and master.held then
            local state=finish_materials(master,action=="asset_master_commit",native)
            master=master.parent
            return {state=state}
        end
        if master.held then assert(native("resume_master")=="resumed");master.held=false end
        local commit=action=="asset_master_commit"
        local state=native(commit and "commit" or "abort")
        assert(state==(commit and "committed" or "rolled back"),state)
        master=master.parent
        return {state=state}
    end
    if action=="asset_abort" then
        if not job then return {state="idle"} end
        local restore_error
        if job.effects or job.chains then
            local actors
            for _,b in ipairs(job.effects or job.chains) do
                local ok,err=pcall(function()
                    local go=b.comp:call("get_GameObject")
                    if b.wearer then
                        actors=actors or hunter_roster.read()
                        if ordinary_owner(actors,go)~=b.wearer then return end
                    end
                    if go and go:call("get_Valid") and
                            (not job.chains or tostring(holder(b):read_qword(0x10))==job.fresh) then
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
        if job.effects or job.chains then
            local pending_bindings=job.effects or job.chains
            for _,b in ipairs(pending_bindings) do
                local h=holder(b)
                if not h or tostring(h:read_qword(0x10))~=job.fresh then return {state="pending"} end
                if job.chains and job.expected_groups and
                        (b.comp:call("get_ResourceGroupCount")~=job.expected_groups or
                         b.comp:call("getGroupCount")~=job.expected_groups) then
                    assert(os.clock()<job.chain_deadline,"Chain groups differ from "..job.path)
                    return {state="pending"}
                end
            end
            local count,address=#pending_bindings,job.fresh
            assert(native("commit")=="committed")
            job=nil
            return {state="committed",resource=address,bindings=count}
        end
        local list=bindings(job.path,job.kind,job.ext)
        assert(#list>0,"Resource no longer equipped")
        for _,b in ipairs(list) do
            local expected=job.old
            if job.mdf_slots then
                expected=job.mdf_slots[b.comp:get_address()]
            elseif job.holder_slots then
                expected=job.holder_slots[b.slot_key]
            end
            assert(b.old:read_qword(0x10)==expected,"Equipped binding changed")
        end
        if job.ext=="mdf2" and master and master.owners then
            assert(#list==job.count,"MDF users changed before staging")
            local state=native("stage_mdf")
            assert(state=="staged",state)
            table.insert(master.owners,{path=job.path,count=#list,slots=job.mdf_slots,fresh=job.fresh})
            local owner_address=job.fresh
            job=nil
            return {state=state,resource=owner_address,bindings=#list}
        end
        local res=assert(sdk.create_resource(job.kind[2],job.path))
        local address=tostring(res:get_address())
        local holder_type=job.ext=="motlist" and "via.motion.MotionListBaseResourceHolder" or job.kind[2].."Holder"
        if job.ext=="mot" then holder_type="via.motion.MotionBaseResourceHolder" end
        local h=res:create_holder(holder_type)
        res:release()
        assert(h and address==job.fresh,"Cache resource mismatch")
        if job.ext=="chain" then
            -- A standalone chain change leaves the model in place. Check the
            -- new resource and simulated groups after the engine update.
            for _,b in ipairs(list) do
                local ptr=b.old:read_qword(0x10)
                local old=assert(sdk.to_resource(sdk.to_ptr(ptr)))
                b.old=assert(old:create_holder(holder_type))
                assert(b.old:read_qword(0x10)==ptr,"Could not pin current chain")
            end
            job.chains,job.chain_deadline={},os.clock()+4
            job.holder=h
            for _,b in ipairs(list) do
                job.chains[#job.chains+1]=b
                assign(b,h)
            end
            return {state="pending"}
        end
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
                if job.ext=="mdf2" and b.comp:call("get_MaterialReady") then b.switches=material_state(b.comp,job.preserve) end
                assign(b,h)
                assert(tostring(holder(b):read_qword(0x10))==address,"Binding did not take effect")
                restore_when_ready(b)
            end

            local state=native("commit")
            assert(state=="committed",state)
        end)
        if not ok then
            for i=touched,1,-1 do
                local b=list[i]
                assign(b,b.old)
                restore_when_ready(b)
            end
            error(err)
        end
        if job.ext=="mot" then
            -- The next layer requesting this path should share the published
            -- platform generation even after the current waterwheel/actor leaves.
            local old=platform_pins[job.path]
            platform_pins[job.path]=job.platform and sdk.create_resource(job.kind[2],job.path) or nil
            if old then old:release() end
        end
        if job.ext=="uvs" then remember_gui_sequence(job,list,h) end
        job=nil
        return {state="committed",resource=address,bindings=#list}
    end
    local path=assert(req.path)
    local ext=path:lower():match("%.([a-z0-9]+)$")
    local kind=assert(kinds[ext],"Unsupported asset")
    if ext=="user" then return user_data(path,req.edits or {},action=="asset_user") end
    local list=bindings(path,kind,ext)
    if action=="asset_preview_size" then
        assert(ext=="rtex" and #list>0,"No active render target")
        local f=assert(io.open("MHRS-Files-HotReload/asset-path.txt","wb"))
        f:write(list[1].path);f:close()
        local dimensions,address=native("preview_size")
        local width,height=dimensions:match("^(%d+) (%d+)$")
        assert(width and tostring(list[1].old:read_qword(0x10))==address,"Preview target changed or is not ready")
        return {path=list[1].path,resource=address,width=tonumber(width),height=tonumber(height)}
    end
    if action=="asset_inspect" then return {bindings=binding_report(list,ext)} end
    assert(action=="asset_begin" and not job and (not master or (master.held and
        (ext=="mdf2" or ext=="efx" or ext=="motlist" or (ext=="uvs" and master.ext=="rtex")))),"Invalid asset request")
    assert(#list>0,"No matching active resource user")
    if ext=="mesh" or ext=="mdf2" or ext=="tex" then
        for _,b in ipairs(list) do assert(current_geometry(b.comp),"Previous equipment generation is still attached") end
    end
    local f=assert(io.open("MHRS-Files-HotReload/asset-path.txt","wb"))
    f:write(req.platform and "@" or "",list[1].path); f:close()
    local state,address=native("asset")
    assert(state=="pending",state)
    job={kind=kind,ext=ext,path=list[1].path,old=list[1].old:read_qword(0x10),fresh=address,
        expected_outputs=ext=="jcns" and req.expected_outputs,expected_groups=ext=="chain" and req.expected_groups,
        preserve=req.preserve,gui_owners=req.gui_owners,platform=req.platform}
    if ext=="mdf2" then
        job.count=#list
        job.mdf_slots={}
        for _,b in ipairs(list) do job.mdf_slots[b.comp:get_address()]=b.old:read_qword(0x10) end
    elseif ext=="rtex" or ext=="uvs" then
        -- Cameras, preview slots and GUI elements need not share the same
        -- prior generation. Validate each live slot against its own snapshot.
        job.holder_slots={}
        for _,b in ipairs(list) do
            job.holder_slots[b.slot_key]=b.old:read_qword(0x10)
        end
    end
    return {state=state,address=address,bindings=#list}
end
re.on_application_entry("UpdateBehavior",peer_equipment.tick)
re.on_application_entry("UpdateBehavior",peer_physics.tick)
return M
