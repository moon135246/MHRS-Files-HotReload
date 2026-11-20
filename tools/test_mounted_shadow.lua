package.path="reframework/autorun/?.lua;"..package.path
local mounted=require("MHRS_HotReload.mounted_shadow")
local skeleton=require("MHRS_HotReload.shadow_skeleton")
local armor=require("MHRS_HotReload.worn_armor")
local next_id=0
local function object(fields)
    next_id=next_id+1
    fields.id=next_id
    function fields:call(method,...)
        local value=rawget(self,method)
        if type(value)=="function" then return value(self,...) end
        if value==false then return false end
        return value
    end
    function fields:get_address() return self.id end
    return fields
end
local function holder(id,path)
    local h=object({get_ResourcePath=path})
    function h:read_qword(offset) assert(offset==0x10);return id end
    function h:add_ref() end
    return h
end
local function resource(id,path)
    return {create_holder=function() return holder(id,path) end,get_address=function() return id end}
end
local function fixture()
    local s={writes={},simulations={},pieces={}}
    local root=object({get_Valid=true,get_Draw=true})
    root.get_Components={}
    local tr=object({get_GameObject=root})
    root.get_Transform=tr
    local pelvis=object({get_Name="Root",get_BaseLocalPosition={x=0,y=0,z=0}})
    s.head=object({get_Name="Head",get_Parent=pelvis,get_BaseLocalPosition={x=0,y=.25,z=0}})
    tr.get_Joints={pelvis,s.head}
    local prev
    for i,part in ipairs({"body","arm","wst","leg","helm"}) do
        local go=object({get_Name="f_"..part.."279",get_Valid=true,get_Update=true,get_Components={}})
        local t=object({get_GameObject=go,get_Parent=tr})
        go.get_Transform=t
        s.pieces[i]=go
        if prev then prev.get_Next=t else tr.get_Child=t end
        prev=t
    end
    function s.extra_armor()
        local duplicate=object({get_Name="f_arm119",get_Valid=true})
        prev.get_Next=object({get_GameObject=duplicate,get_Parent=tr})
    end
    local function make_chain()
        return object({get_type_definition=function() return {is_a=function(_,t) return t=="via.motion.Chain" end} end,
            get_GameObject=s.pieces[2],get_ChainAsset=holder(42,"player/mod/f/pl279/f_arm279.chain"),
            get_Enabled=true,get_FreezePose=false,get_Setuped=true,get_ResourceGroupCount=2,getGroupCount=2,
            set_FreezePose=function(self,value) self.get_FreezePose=value end})
    end
    s.chain=make_chain()
    s.simulations={s.chain}
    s.pieces[2].get_Components=s.simulations
    function s.extra_chain() s.simulations[#s.simulations+1]=make_chain() end
    local old_path="player/mod/f/bone/f_shadow.mesh"
    local new_path="player/mod/f/pl279/f_shadow.mesh"
    local old=resource(1,old_path)
    local mesh=object({get_GameObject=root,get_MeshReady=true,getMesh=holder(1,old_path)})
    function mesh:setMesh(h)
        assert(s.chain.get_FreezePose,"setter called while CHAIN running")
        s.writes[#s.writes+1]=h:read_qword(0x10)
        self.getMesh=h
    end
    local motion=object({get_JointsConstructed=true,resetSekeleton=function() s.reset=true end})
    root["getComponent(System.Type)"]=function(_,class)
        if class=="via.render.Mesh" then return mesh end
        if class=="via.motion.Motion" then return motion end
    end
    s.player=object({get_GameObject=root,getPartsGameObject=function(_,slot) return s.pieces[slot+1] end})
    function s.player:get_field(k) assert(k=="mSex");return 1 end
    s.pm=object({findMasterPlayer=s.player})
    sdk={get_managed_singleton=function() return s.pm end,typeof=function(c) return c end,to_ptr=function(p) return p end,
        to_resource=function(p) assert(p==1);return old end}
    s.profiles={f={pl279={joints={Root={parent="",position={0,0,0}},Head={parent="Root",position={0,.125,0}}}}}}
    s.target=assert(skeleton.capture(s.player,s.profiles))
    s.resources={[new_path]=resource(2,new_path)}
    s.components=function() error("must only inspect the local hunter, independent village chains can be despawning") end
    function s.begin() return mounted.begin(s.target,s.resources,s.components) end
    return s
end
local s=fixture()
local state=s.begin()
assert(state and #s.writes==0 and not s.chain.get_FreezePose)
local pending,fast=mounted.advance(state)
assert(pending and fast and s.chain.get_FreezePose and #s.writes==0)
pending,fast=mounted.advance(state)
assert(pending and not fast and s.writes[1]==2)
pending,fast=mounted.advance(state)
assert(pending and not fast and not state.batch.shadow_ready)
s.head.get_BaseLocalPosition.y=.125
for _=1,12 do
    pending,fast=mounted.advance(state)
    if not pending then break end
    assert(fast,"Already verified shadow, CHAIN transition requires one game frame")
end
assert(state.batch.shadow_ready and state.batch.chains.stable>=2 and not s.chain.get_FreezePose)
assert(s.begin()==nil)
assert(mounted.abort(state) and s.chain.get_FreezePose and s.writes[2]==1)
armor.update_recoveries()
assert(mounted.abort(state) and s.chain.get_FreezePose)
s.head.get_BaseLocalPosition.y=.25
armor.update_recoveries()
assert(not mounted.abort(state) and not s.chain.get_FreezePose and #s.writes==2)

s=fixture();s.extra_armor()
assert(skeleton.capture(s.player,s.profiles).scope=="pl279")
assert(not pcall(s.begin) and #s.writes==0 and not s.chain.get_FreezePose)
s=fixture();state=s.begin();assert(mounted.advance(state))
s.extra_chain()
assert(not pcall(mounted.advance,state) and #s.writes==0 and not s.chain.get_FreezePose)
s=fixture();state=s.begin();assert(mounted.advance(state));assert(mounted.advance(state))
s.head.get_BaseLocalPosition.y=.125
s.extra_chain()
assert(not pcall(mounted.abort,state) and #s.writes==1 and not s.chain.get_FreezePose)
s=fixture();state=s.begin();assert(mounted.advance(state));assert(mounted.advance(state))
s.pm.findMasterPlayer=object({})
assert(not pcall(mounted.advance,state))
assert(not pcall(mounted.abort,state) and #s.writes==1 and not s.chain.get_FreezePose)
s=fixture();s.target.expected.Head.parent="unrelated"
assert(not pcall(s.begin) and #s.writes==0)
assert(not mounted.advance(nil) and not mounted.abort(nil) and not mounted.begin(nil))
print("Mounted FirstNatives shadow: same hunter, frozen physics, live rest adoption, asynchronous rollback and supersession passed")
