-- Run from the project root. Simulate separate engine updates for a worn
-- part, an unchanged child chain and a concurrent genuine re-equip.
package.path = "reframework/autorun/?.lua;" .. package.path
local module = require("MHRS_HotReload.worn_chain")
local path = "player/mod/f/pl279/f_helm279.chain"
local bodypath = "player/mod/f/pl279/f_body279.chain"
local serial = 100
local function address(self) return self.id end
local function holder(res, name)
    serial = serial+1
    return {id=serial, get_address=address, read_qword=function(_,off) assert(off==0x10);return res end,
        call=function(_,m) assert(m=="get_ResourcePath");return name end}
end
local function resource(id)
    return {id=id, get_address=address, create_holder_global=function(_,typ)
        assert(typ=="via.motion.ChainResourceHolder");return holder(id)
    end}
end
sdk = {to_ptr=function(n) return n end,to_resource=resource,typeof=function(s) return s end}

local function object(id)
    local go = {id=id,get_address=address,valid=true,update=true}
    go.tr = {call=function(_,m)
        if m=="get_GameObject" then return go
        elseif m=="get_Child" then return go.child and go.child.tr
        elseif m=="get_Parent" then return nil
        elseif m=="getJointByName(System.String)" then return nil
        elseif m=="get_Next" then return nil end
        error(m)
    end}
    function go:call(m)
        if m=="get_Transform" then return self.tr
        elseif m=="getComponent(System.Type)" then return self.mesh
        elseif m=="get_Valid" then return self.valid
        elseif m=="get_Update" then return self.update end
        error(m)
    end
    return go
end
local groups = {[1]=23,[2]=9,[3]=1,[4]=8}
local function chain(go,name,id,on)
    local c = {res=id, count=groups[id], enabled=on, frozen=false, binds=0}
    function c:call(m,arg)
        if m=="get_GameObject" then return go
        elseif m=="get_ChainAsset" then return holder(self.res,name)
        elseif m=="get_Enabled" then return self.enabled
        elseif m=="get_FreezePose" then return self.frozen
        elseif m=="set_FreezePose" then self.frozen=arg
        elseif m=="getGroupCount" then return self.count
        elseif m=="get_ResourceGroupCount" then return groups[self.res]
        elseif m=="get_Setuped" then return self.count == groups[self.res]
        elseif m=="resetInertia" then self.resets=(self.resets or 0)+1
        elseif m=="set_ChainAsset" then
            assert(self.frozen or self.standalone,"chain simulation active during a mesh change")
            if arg:read_qword(0x10)==self.throw_on then error("Refused chain resource") end
            self.binds=self.binds+1
            self.res=arg:read_qword(0x10)
        else error(m) end
    end
    return c
end

local helm,child,extra = object(10),object(11),object(12)
helm.child=child
local model={go=helm}
local active=chain(helm,path,1,true)
local unchanged=chain(child,bodypath,3,false)
local other=chain(extra,"npc/npc018.chain",4,true)
local named_joints = {"HelmBone_153"}
local use_array = false
helm.mesh = {call=function(_,m)
    if m=="getMesh" then return holder(100,"player/mod/f/pl279/f_helm279.mesh") end
    assert(m=="getJointNameList")
    if use_array then return {get_elements=function() return named_joints end} end
    return named_joints
end}
local function capture()
    local asks = {}
    local tx = module.capture({active,unchanged,other},{[99]=model},{[path]=9},{},asks,{[path]={"HelmBone_153"}})
    assert(tx:covers(model) and #tx.rows==2 and asks[path] and not asks[bodypath])
    return tx
end
local function prepare()
    local tx=capture()
    tx:stage({[path]=resource(2)})
    tx:pause()
    assert(active.enabled and not unchanged.enabled and active.frozen and unchanged.frozen and not other.frozen)
    return tx
end

local t=prepare()
t:bind()
assert(active.res==2 and unchanged.res==3 and unchanged.binds==0)
t:resume()
assert(active.enabled and not unchanged.enabled and not active.frozen and not unchanged.frozen)
assert(not t:verify()) -- resources ready but simulation still running the old groups
active.count=9
assert(not t:verify() and t:verify() and active.resets==1 and not unchanged.resets)
t:suspend_for_rollback()
assert(active.enabled and active.frozen)
t:rollback()
assert(active.res==1 and active.enabled and unchanged.res==3 and not unchanged.enabled and other.binds==0)
assert(unchanged.binds==0, "a retained child chain must not be reassigned")
named_joints={}
t=capture()
local ok, reason=pcall(t.stage,t,{[path]=resource(2)})
assert(not ok and tostring(reason):find("Incompatible CHAIN terminal") and not active.frozen)
named_joints={"HelmBone_153"}
use_array=true

t=prepare()
t:rollback() -- cancel in the frame before touching the mesh
assert(active.enabled and active.res==1)
t=prepare()
t:bind()
active.throw_on=1
ok,reason=pcall(t.rollback,t)
assert(not ok and tostring(reason):find("Refused chain resource") and not active.frozen and not unchanged.frozen)
active.res,active.throw_on=1,nil

t=module.capture({active},{},{[path]=9},{},{},{[path]={"HelmBone_153"}})
active.standalone=true
t:stage({[path]=resource(2)})
t:pause()
assert(not active.frozen)
t:bind()
t:resume()
active.count=9
assert(not t:verify() and t:verify())
t:rollback()
assert(active.res==1 and not active.frozen)
active.standalone=false

-- The same valid engine component/holder can acquire a different owner
-- before a peer transaction rolls back. Do not write the new wearer's part.
t=prepare()
t:bind()
for _,row in ipairs(t.rows) do row.wearer_owns=function() return false end end
active.frozen=false
t:suspend_for_rollback()
t:rollback()
assert(active.res==2 and not active.frozen)
active.res,unchanged.frozen=1,false

t=prepare()
t:bind()
active.res,active.frozen=4,false -- a real equip changed the chain on the same component
child.valid=false
t:suspend_for_rollback()
t:rollback()
assert(active.enabled and active.res==4 and not unchanged.enabled)

active.res=1; child.valid=true;child.update=false
t=module.capture({active,unchanged},{[99]=model},{[path]=9},{},{})
assert(not t:covers(model),"inactive descendant must retain the mesh guard")
print("Worn CHAIN passed paired pause, child coverage, two-frame verification, cancellation and concurrent re-equip")
