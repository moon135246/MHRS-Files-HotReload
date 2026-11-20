-- Exercise the existing material snapshot/restore helpers with the vertex-only
-- policy, including the case where setMesh leaves every runtime value intact.
package.path="reframework/autorun/?.lua;"..package.path
re={on_application_entry=function() end,on_script_reset=function() end}
json={dump_file=function() end}
local names={[1]="original.tex",[2]="other.tex",[3]="original.tex"}
local function holder(ptr)
    return {read_qword=function() return ptr end,add_ref=function() end,get_address=function(h) return h end,call=function(_,key)
        assert(key=="get_ResourcePath");return names[ptr]
    end}
end
sdk={hook=function() end,find_type_definition=function()
        return {get_method=function() end,get_methods=function() return {} end}
    end,
    to_ptr=function(ptr) return ptr end,to_resource=function(ptr)
        return {create_holder=function() return holder(ptr) end}
    end}
Vector4f={new=function(x,y,z,w) return {x=x,y=y,z=z,w=w} end}
local function upvalue(fn,name)
    for i=1,200 do
        local k,v=debug.getupvalue(fn,i)
        if k==name then return v end
        if k==nil then break end
    end
    error("Cannot find "..name)
end
local outfit=require("MHRS_HotReload.outfit")
local capture=upvalue(outfit.run,"material_state")
local restore=upvalue(upvalue(outfit.run,"restore_when_ready"),"restore_material")
local part,material,texture=false,false,holder(1)
local values={false,0.75,Vector4f.new(1,2,3,4)}
local variables={"enabled","amount","color"}
local writes={}
local mesh={}
function mesh:call(key,slot,index,value)
    if key=="getPartsEnableCount" or key=="get_MaterialNum" or key=="getMaterialTextureNum" then return 1 end
    if key=="getMaterialVariableNum" then return #variables end
    if key=="getPartsEnable" then return part end
    if key=="getMaterialsEnable" then return material end
    if key=="getMaterialName" then return "Armor" end
    if key=="getMaterialTextureName" then return "BaseMap" end
    if key=="getMaterialVariableName" then return variables[index+1] end
    if key=="getMaterialVariableType" then return ({0,1,4})[index+1] end
    if key=="getMaterialTexture" then return texture end
    if key=="getMaterialBool" or key=="getMaterialFloat" or key=="getMaterialFloat4" then return values[index+1] end
    writes[#writes+1]=key
    if key=="setPartsEnable" then part=index
    elseif key=="setMaterialsEnable" then material=index
    elseif key=="setMaterialTexture" then texture=value
    elseif key=="setMaterialBool" or key=="setMaterialFloat" or key=="setMaterialFloat4" then values[index+1]=value
    else error(key) end
end
local saved,parts=capture(mesh,"vertices")
assert(saved.Armor.textures.BaseMap.holder~=texture)
restore(mesh,saved,parts)
assert(#writes==0,"a geometry edit re-wrote unchanged rendering state")
part,material,texture=true,true,holder(2)
values[1],values[2],values[3].w=true,0.5,-1
restore(mesh,saved,parts)
assert(#writes==6 and not part and not material and texture:read_qword(0x10)==1)
assert(not values[1] and values[2]==0.75 and values[3].w==4)
texture=holder(3)
restore(mesh,saved,parts)
assert(#writes==6 and texture:read_qword(0x10)==3,"overwrote another generation of the same texture")
print("Vertex-only mesh binding retained part switches, material switches, named variables and texture overrides")
