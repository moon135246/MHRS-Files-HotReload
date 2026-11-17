package.path="reframework/autorun/?.lua;"..package.path
local heads=require("MHRS_HotReload.mounted_head")
local function object(properties)
    local o={props=properties or {}}
    function o:call(n,...)
        local v=self.props[n]
        if type(v)=="function" then return v(...) end
        assert(v~=nil,n)
        return v
    end
    function o:get_field(n) return self.props[n] end
    function o:set_field(n,v) self.props[n]=v end
    return o
end
local function setup(old,target)
    local mats,gos={},{}
    local j={tr=object(),index=2,request=object()}
    local base=object()
    j.pm=object({get_PlayerBaseData={get_element=function(_,i)assert(i==2);return base end},getPlayerSexType=1,
        get_PlayerParam={get_element=function(_,i)assert(i==2);return j.request end}})
    j.ctrl=object({_MaterialParts={get_element=function(_,s)return mats[s] end},getPartsGameObject=function(s)return gos[s] end})
    j.player=object({getPartsGameObject=function(s)return gos[s] end})
    j.ctrl.props.setPartsEnable=function(i,female,data,req)
        assert(i==2 and female and data==base and req==j.request)
        j.native=(j.native or 0)+1
        mats[6].props._IsFullBody=true;gos[5].props.get_DrawSelf=false
    end
    for s=4,6 do
        local g=object({get_Valid=true,get_UpdateSelf=true,get_DrawSelf=s==4 or not old,get_Transform=object({get_Parent=j.tr})})
        g.props.set_DrawSelf=function(v) g.props.get_DrawSelf=v end
        mats[s]=object({_ParentMaterialCtrl=j.ctrl,get_plPartsNo=s,get_GameObject=g,get_IsNpcFace=false,_IsFullFace=false,_IsFullBody=s==6 and old})
        gos[s]=g
    end
    local function userdata(full)
        return object({_FaceInfo=object({FullBody=full,FullFace=false}),
            _HairInfo={[0]=object({HairDispOff=false,HairDispOffParts=-1}),get_size=function()return 1 end}})
    end
    local row={expected={helmet={fields={{section="face",field="FullBody",value=target}}}},old=gos[4],old_material=mats[4]}
    row.old_material.props._PlayerUserDataParts=userdata(old)
    local function register_new()
        mats[4]=object({_PlayerUserDataParts=userdata(target)})
        row.material=mats[4]
    end
    return j,row,mats,gos,register_new
end
for _,mode in ipairs({false,true}) do
    local j,row,mats,gos,register=setup(mode,not mode)
    local h=heads.capture(j,row)
    assert(not heads.ready(j,h))
    register()
    if not mode then assert(not heads.ready(j,h) and j.native==1) else assert(not j.native) end
    assert(heads.ready(j,h) and heads.ready(j,h))
    assert(mats[6].props._IsFullBody==not mode and gos[5].props.get_DrawSelf==mode and gos[6].props.get_DrawSelf==mode)
    assert(gos[4].props.get_DrawSelf)
    heads.abort(j,h)
    assert(mats[6].props._IsFullBody==mode and gos[5].props.get_DrawSelf==not mode and gos[6].props.get_DrawSelf==not mode)
end
local j,row,mats,gos,register=setup(true,false)
local h=heads.capture(j,row);register();assert(heads.ready(j,h))
-- A different actor/slot cannot become an undo target.
mats[6].props._ParentMaterialCtrl=object()
heads.abort(j,h);assert(not mats[6].props._IsFullBody and gos[6].props.get_DrawSelf)
j,row,mats,gos,register=setup(false,true);gos[5].props.get_DrawSelf=false
assert(not pcall(heads.capture,j,row))
j,row=setup(false,true);row.expected.helmet.fields[2]={section="hair",field="HairDispOff",value=true}
assert(not pcall(heads.capture,j,row))
j,row,mats,gos,register=setup(false,true)
h=heads.capture(j,row);register();row.material.props._PlayerUserDataParts.props._FaceInfo.props.FullBody=false
assert(not heads.ready(j,h) and not mats[6].props._IsFullBody and gos[6].props.get_DrawSelf)
print("FullBody install, cold removal, rollback, user overrides and local face/hair ownership passed")
