-- Regression for uninstall when create_userdata_global returns a valid typed
-- object whose optional face and hair data have not finished loading.
package.path="reframework/autorun/?.lua;"..package.path
local physics=require("MHRS_HotReload.equipment_physics")
local armor=require("MHRS_HotReload.worn_armor")
local path="player/mod/f/pl279/f_helm279.user"
local id=0
local function root(face,shape)
    id=id+1
    local obj={id=id,face=face,shape=shape}
    function obj:get_address() return self.id end
    function obj:call() return path end
    function obj:get_type_definition() return {get_full_name=function() return "snow.player.PlayerUserDataPartsHelm" end} end
    function obj:get_field(k)
        if k=="_FaceInfo" and self.face~=nil then return {} end
        if k=="_HairInfo" and self.shape~=nil then
            return {get_size=function() return 1 end,[0]={get_field=function() return {get_size=function() return 1 end} end}}
        end
    end
    return obj
end
local function access(r,e)
    local key=e.field=="FullBody" and "face" or e.field=="HairShapeData" and "shape"
    assert(key and r[key]~=nil,"Missing helm data entry")
    return function() return r[key] end,function(v)
        if r.fail and key=="shape" then error("unavailable shape storage") end
        r[key]=v
    end
end
local function component(r) return {get_field=function() return r end} end
local function edits(body,v)
    return {{section="face",index=-1,field="FullBody",element=-1,value=body},
            {section="hair",index=0,field="HairShapeData",element=0,value=v}}
end
local fresh
sdk={create_userdata_global=function() return fresh end}
local a,b,sparse=root(false,0.75),root(true,0.2),root(false,nil)
local parts={component(a),component(b),component(sparse)}
local function run(spec)
    local p=physics.new({helmets={[path]=spec}},function() return parts end,access)
    p:request({[path]=not spec.removed},{})
    local batch={candidates={},physics=p}
    local busy=armor.advance(batch,function() error("No meshes expected") end,{},nil,nil)
    if busy then assert(not armor.advance(batch,function() return {} end,{},nil,nil)) end
    p:commit()
end
fresh=root(nil,nil)
run({fields=edits(true,0)})
assert(a.face and a.shape==0 and b.face and b.shape==0 and sparse.face and sparse.shape==nil)
sparse.shape=0.6
fresh.face=false;fresh.shape=0.5
physics.update(os.clock()+0.3)
assert(sparse.shape==0 and fresh.face and fresh.shape==0)
-- A new empty global root cannot furnish stock values. Existing roots each
-- restore their own values, including a field that initialized a frame later.
fresh=root(nil,nil)
run({removed=true})
assert(not a.face and a.shape==0.75 and b.face and b.shape==0.2 and not sparse.face and sparse.shape==0.6)
physics.update(os.clock()+5)
assert(fresh.face==nil and fresh.shape==nil)

-- With PAK fields the packaged values are authoritative for every compatible
-- slot. A failure on one root rolls back that root while others still finish.
fresh=root(nil,nil)
a.face=true;a.shape=0;a.fail=true
b.face=true;b.shape=0
run({removed=true,fields=edits(false,0.75)})
assert(a.face and a.shape==0 and not b.face and b.shape==0.75)
a.fail=false
physics.update(os.clock()+0.3)
assert(not a.face and a.shape==0.75)
-- A newer generation cancels every late write left by the previous one.
local old_global=fresh
fresh=root(false,0.3)
run({deferred=true,fields=edits(true,0)})
old_global.face=true;old_global.shape=0.1
physics.update(os.clock()+4)
assert(old_global.face and old_global.shape==0.1 and not a.face and a.shape==0.75)
physics.reset()
print("Sparse/late managed helmets, per-instance undo, setter isolation and stale retry cancellation passed")
