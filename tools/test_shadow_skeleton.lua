package.path="reframework/autorun/?.lua;"..package.path
local shadow=require("MHRS_HotReload.shadow_skeleton")
local expected={Root={parent="",position={0,0,0}},Head={parent="Root",position={0,0.125,0}}}
local positions={Root={x=0,y=0,z=0},Head={x=0,y=0.25,z=0}}
local function object(calls)
    return {call=function(_,name,...) return assert(calls[name],name)(...) end}
end
local function joint(name, parent)
    return object({get_Name=function() return name end,get_Parent=function() return parent end,
                   get_BaseLocalPosition=function() return positions[name] end})
end
local root_joint=joint("Root")
local joints={root_joint,joint("Head",root_joint)}
local function resource(id,path)
    local r={}
    function r:create_holder_global()
        local h=object({get_ResourcePath=function() return path end})
        function h:read_qword(offset) assert(offset==0x10);return id end
        return h
    end
    return r
end
local old=resource(1,"player/mod/f/bone/f_shadow.mesh")
local fresh=resource(2,"player/mod/f/pl279/f_shadow.mesh")
local unrelated=resource(3,"player/mod/f/pl279/f_shadow.mesh")
local current=old:create_holder_global()
local root, mesh, tr
local reset_count, constructed=0,true
local motion=object({get_JointsConstructed=function() return constructed end,
                     resetSekeleton=function() reset_count=reset_count+1 end})
mesh=object({getMesh=function() return current end,setMesh=function(h) current=h end,
             get_GameObject=function() return root end,get_MeshReady=function() return true end})
local names={"f_body279","f_arm279","f_wst279","f_leg279","f_helm279","f_body119"}
local children={}
local registered={}
for i=1,#names do
    local go=object({get_Name=function() return names[i] end,get_Valid=function() return true end,
        get_Transform=function() return children[i] end,["getComponent(System.Type)"]=function() return nil end})
    registered[i]=go
    children[i]=object({get_GameObject=function() return go end,get_Parent=function() return tr end,get_Child=function() return nil end,
        get_Next=function() return children[i+1] end})
end
tr=object({get_Joints=function() return joints end, get_Child=function() return children[1] end,
                 get_GameObject=function() return root end})
root=object({get_Valid=function() return true end,get_Draw=function() return true end,get_Transform=function() return tr end,
             ["getComponent(System.Type)"]=function(t) return t=="via.render.Mesh" and mesh or motion end})
local player=object({get_GameObject=function() return root end,
    getPartsGameObject=function(slot) return registered[slot+1] end})
function player:get_field(k) assert(k=="mSex");return 1 end
sdk={typeof=function(k) return k end,to_ptr=function(p) return p end,to_resource=function(p) assert(p==1);return old end}
local profiles={f={bone={joints=expected},pl279={joints=expected}}}
local txn=assert(shadow.capture(player,profiles))
assert(txn.changed==1 and txn.scope=="pl279")
assert(not shadow.matches(player,expected))
assert(shadow.bind(txn,fresh) and current:read_qword(0x10)==2)
-- A renderer accepting the resource does not prove the live bind pose changed.
assert(shadow.verify(txn)==false)
positions.Head.y=0.125
assert(shadow.verify(txn))
assert(shadow.matches(player,expected))
assert(reset_count==0)
local restored,pending=shadow.abort(txn)
assert(restored and pending and current:read_qword(0x10)==1)
-- Rebinding the previous holder is separate from adopting its old rest.
for _=1,4 do assert(shadow.verify_rollback(txn)==false) end
assert(reset_count==1)
positions.Head.y=.25
constructed=false;assert(shadow.verify_rollback(txn)==false)
constructed=true;assert(shadow.verify_rollback(txn))
-- A ready new mesh can require Motion to rebuild the same transform.
txn=assert(shadow.capture(player,profiles))
assert(shadow.bind(txn,fresh))
for _=1,4 do assert(shadow.verify(txn)==false) end
assert(reset_count==2)
positions.Head.y=.125;assert(shadow.verify(txn))
-- Avoid overwriting an equipment choice that superseded the old operation.
current=unrelated:create_holder_global();shadow.abort(txn);assert(current:read_qword(0x10)==3)
names[1]="f_body088"
assert(shadow.capture(player,profiles).scope=="bone")
expected.Head.parent="Foreign"
assert(not shadow.capture(player,profiles))
assert(not shadow.matches(player,expected))
expected.Head.parent="Root"
joints[3]=joint("Extra",root_joint)
assert(not shadow.matches(player,expected))
print("Shadow mesh owner, complete-set scope, live rest readback and rollback passed")
