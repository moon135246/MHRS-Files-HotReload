package.path="reframework/autorun/?.lua;"..package.path
local colors=require("MHRS_HotReload.mounted_colors")
local function vec(n,w) return {x=n/10,y=.02,z=.08,w=w or 1} end
local function object(data)
    function data:call(n,...)
        local value=assert(self[n],n)
        if type(value)=="function" then return value(...) end
        return value
    end
    function data:get_field(n) return self[n] end
    return data
end
local function array(values)
    return {get_size=function()return 5 end,get_type_definition=function()return {
        get_method=function(_,sig)
            assert(sig=="Get(System.Int32)")
            return {call=function(_,_,i)return values[i+1] end}
        end}
    end}
end
local function setup(slot,mask,enable1,enable2)
    local a,b={},{}
    for i=1,5 do a[i]=vec(i);b[i]=vec(i+1) end
    local e1,e2={},{}
    for i=1,5 do e1[i]=enable1;e2[i]=enable2 end
    local base=object({_IsEnableSymbolColor1=array(e1),_IsEnableSymbolColor2=array(e2),
        _SymbolColor1=array(a),_SymbolColor2=array(b)})
    local j={index=2,request={}}
    local param={get_element=function(_,i)assert(i==2);return j.request end}
    j.pm=object({get_PlayerParam=param,get_PlayerBaseData={get_element=function(_,i)assert(i==2);return base end}})
    local row={slot=slot,new={},old={}}
    local default1,default2=vec(.3,0),vec(.4,0)
    local gpu={vec(.1),vec(.2)}
    local mat=object({get_GameObject=row.new,get_plPartsNo=slot,_symbolColor1=default1,_symbolColor2=default2,writes=0,updates=0})
    j.ctrl=object({_MaterialParts={get_element=function(_,s)assert(s==slot);return row.material end}})
    row.material=mat;mat._ParentMaterialCtrl=j.ctrl
    local mesh=object({get_GameObject=row.new,get_MaterialReady=true,get_MaterialNum=1,getMaterialTextureNum=1,
        getMaterialTextureName="UserColorchangeMap",getMaterialTexture=object({get_ResourcePath=mask}),
        getMaterialVariableNum=3,getMaterialVariableName=function(_,i)return ({"S_col_R","S_col_G","Untouched"})[i+1] end,
        getMaterialVariableType=function()return 4 end,getMaterialFloat4=function(_,i)return gpu[i+1] end})
    mat.get_RefMesh=mesh
    mat.setSymbolColor=function(first,value)
        mat[first and "_symbolColor1" or "_symbolColor2"]=value
        mat.writes=mat.writes+1
    end
    mat.updateSymbolColor=function()
        if not mat.no_gpu then gpu[1],gpu[2]=mat._symbolColor1,mat._symbolColor2 end
        mat.updates=mat.updates+1
    end
    return j,row,mat,gpu,a,b,e1,e2,mesh
end
local real_mask="player/mod/f/pl279/f_body279_CMM.tex"
for s,i in pairs({[0]=2,[1]=3,[2]=4,[3]=5,[4]=1}) do
    local j,r,m,_,a,b=setup(s,real_mask,true,true)
    assert(colors.ready(j,r,false))
    assert(m._symbolColor1==a[i] and m._symbolColor2==b[i] and m.updates==1 and m.writes==2)
    assert(colors.ready(j,r,false) and colors.ready(j,r,true) and m.updates==1 and m.writes==2)
end
-- An unselected pigment keeps its new prefab value even though base contains a color for it.
local j,r,m,gpu,a,b,e1,e2,mesh=setup(0,real_mask,true,false)
local default=m._symbolColor2
assert(colors.ready(j,r,false) and m.writes==1 and m._symbolColor2==default)
e1[2]=false
assert(not colors.ready(j,r,false) and m.writes==1)
j,r,m=setup(0,real_mask,false,false)
assert(colors.ready(j,r,false) and m.updates==0 and m.writes==0)
-- The game's setter also initializes color on a non-dyeable mesh. A custom shader,
-- null CMM or animation may retain its own shader values.
for _,mode in ipairs({"black","unbound","incompatible","rainbow"}) do
    j,r,m,gpu,a,b,e1,e2,mesh=setup(0,mode=="black" and "@Systems\\Rendering\\NullBlack.tex" or real_mask,true,false)
    m.no_gpu=true
    if mode=="unbound" then mesh.getMaterialTextureName="BaseDielectricMap" end
    if mode=="incompatible" then mesh.getMaterialVariableType=function()return 1 end end
    if mode=="rainbow" then a[2]=vec(0,2) end
    local before=gpu[1]
    assert(colors.ready(j,r,false) and m.writes==1 and m._symbolColor1==a[2] and gpu[1]==before)
    assert(colors.ready(j,r,true) and m.updates==1)
end
-- A frame-delayed regular shader must match before commit. Do not repeatedly
-- override an independent owner or a newly changed creation request.
j,r,m,gpu,a,b=setup(0,real_mask,true,true)
m.no_gpu=true
assert(not colors.ready(j,r,false) and j.next_update and m.updates==1)
assert(not colors.ready(j,r,false) and m.updates==1)
gpu[1],gpu[2]=a[2],b[2]
assert(colors.ready(j,r,false) and colors.ready(j,r,true))
gpu[2]=vec(.1)
assert(not colors.ready(j,r,true) and m.updates==1)
j,r,m=setup(0,real_mask,true,true)
assert(not colors.ready(j,r,true) and m.updates==0)
m._ParentMaterialCtrl={}
assert(not colors.ready(j,r,false) and m.updates==0)
j,r,m=setup(0,real_mask,true,true)
j.pm.get_PlayerParam.get_element=function()return {} end
assert(not colors.ready(j,r,false) and m.writes==0)
print("Five actual armor indices, native pigment defaults, dynamic/custom shaders, verification and owner isolation passed")
