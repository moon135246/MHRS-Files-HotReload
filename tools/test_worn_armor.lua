-- Run from the repository root with Lua 5.4: lua tools/test_worn_armor.lua
package.path = "reframework/autorun/?.lua;" .. package.path
local armor = require("MHRS_HotReload.worn_armor")

local kinds = {
    mesh={"component","MeshResource","getMesh","setMesh"},
    mdf2={"component","MaterialResource","getMaterial","setMaterial"},
}
local snapshots, resources, next_holder = {}, {}, 0
local setters, restored = 0, 0

local function holder(path, ptr)
    next_holder = next_holder + 1
    return {
        ptr=ptr, id=next_holder,
        get_address=function(h) return h.id end,
        read_qword=function(h) return h.ptr end,
        call=function(_, key) assert(key=="get_ResourcePath"); return path end,
    }
end
local function resource(path, ptr)
    return {
        get_address=function() return ptr end,
        release=function() end,
        create_holder_global=function() return holder(path,ptr) end,
    }
end
for _, spec in ipairs({{"sample.mesh",1},{"sample.mdf2",2},{"sample.mesh",3},{"sample.mdf2",4}}) do
    local r = resource(spec[1],spec[2])
    snapshots[spec[2]], resources[spec[1]] = r,r
end
sdk = {
    create_resource=function(_,path) return resources[path] end,
    to_ptr=function(n) return n end,
    to_resource=function(n) return snapshots[n] end,
}

local go = {call=function(_,key) assert(key=="get_Valid" or key=="get_Update");return true end}
local function component(id)
    local c = {mesh=holder("sample.mesh",1), mdf=holder("sample.mdf2",2), names={"M1","M2"}}
    function c:get_address() return id end
    function c:call(key,arg)
        if key=="getMesh" then return self.mesh
        elseif key=="getMaterial" then return self.mdf
        elseif key=="setMesh" or key=="setMaterial" then
            setters=setters+1
            if self.fail and key=="setMaterial" then self.fail=nil;error("setter failed") end
            -- The returned holder object is stable and its resource pointer is
            -- overwritten by setters, as observed on Rise armor.
            (key=="setMesh" and self.mesh or self.mdf).ptr=arg.ptr
        elseif key=="get_GameObject" then return go
        elseif key=="getJointNameList" then return arg.ptr==3 and self.new_joints or {[0]="Root",[1]="Leg"}
        elseif key=="get_MeshReady" or key=="get_MaterialReady" then return true
        elseif key=="get_MaterialNum" then return #self.names
        elseif key=="getMaterialName" then return self.names[arg+1]
        else error(key) end
    end
    return c
end
local function batch(parts)
    local b={candidates={}}
    for _,c in ipairs(parts) do
        b.candidates[c:get_address()] = armor.capture(c,go,kinds,{}, {},{["sample.mdf2"]={"M1","M2"}})
    end
    return b
end
local function report(names,ptr)
    local f=assert(io.tmpfile())
    for _,name in ipairs(names) do f:write("sample.mdf2\t",ptr or 4,"\t",name,"\n") end
    f:seek("set")
    return f
end
local function check(b,names,ptr)
    local f=report(names,ptr)
    local mismatch=armor.check_sources(b,resources,f)
    f:close()
    return mismatch
end
local function restore() restored=restored+1 end
local function advance(b,parts)
    return armor.advance(b,function() return parts end,resources,function() return {} end,restore)
end

local parts={component(1),component(2)}
local b=batch(parts)
local current=b.candidates[1]
local origin={["sample.mesh"]={[1]=true}}
assert(armor.needs_reentry(current,nil,{}, {["sample.chain"]=true}))
assert(armor.needs_reentry(current,nil,origin,{}))
assert(not armor.needs_reentry(current,{go=go,direct=1},origin,{}))
assert(armor.needs_reentry(current,{go={},direct=1},origin,{}))
assert(armor.needs_reentry(current,{go=go,defer=1},{},{}))
assert(not armor.needs_reentry(current,nil,{["sample.mesh"]={[1]=false}},{["sample.mesh"]=true}))
assert(check(b,{"Arm","Hand"}):match("expected %[%s*M1, M2%], loaded %[Arm, Hand%]"))
assert(check(b,{"M1","M2"},888):match("requested resource"))
assert(check(b,{"M1","M2"})==nil)
armor.abort(b,restore)
assert(setters==0 and restored==0)

b=batch(parts)
b.candidates[1].wearer_owns=function() return false end
assert(advance(b,parts) and parts[1].mesh.ptr==1 and parts[1].mdf.ptr==2)
assert(parts[2].mesh.ptr==3 and parts[2].mdf.ptr==4)
b.candidates[2].wearer_owns=function() return false end
armor.abort(b,restore)
assert(parts[2].mesh.ptr==3 and parts[2].mdf.ptr==4,"former owner's rollback wrote to a reassigned renderer")
parts={component(1),component(2)}

b=batch(parts)
assert(advance(b,parts))
assert(not advance(b,parts))
for _,c in ipairs(parts) do assert(c.mesh.ptr==3 and c.mdf.ptr==4) end
parts={component(1),component(2)}
b=batch(parts);parts[2].fail=true
local ok,err=pcall(advance,b,parts)
assert(not ok and err:find("setter failed",1,true))
for _,c in ipairs(parts) do assert(c.mesh.ptr==1 and c.mdf.ptr==2) end

b=batch(parts)
assert(advance(b,parts))
parts[1].names={"PAK stock"}; b.deadline=-1
ok,err=pcall(advance,b,parts)
assert(not ok and err:find("slots differ",1,true))
for _,c in ipairs(parts) do assert(c.mesh.ptr==1 and c.mdf.ptr==2) end

b=batch(parts)
parts[1].mesh.ptr=899
assert(advance(b,parts))
assert(parts[1].mesh.ptr==899 and parts[1].mdf.ptr==2)
parts[2].mdf.ptr=777
armor.abort(b,restore)
assert(parts[2].mdf.ptr==777)

local function part(parent)
    local g,t={},{}
    function g:call(key) assert(key=="get_Transform");return t end
    function t:call(key)
        if key=="get_GameObject" then return g end
        assert(key=="get_Parent");return parent and parent:call("get_Transform")
    end
    return g
end
local root=part()
local body,arm=part(root),part(root)
local model={go=body,mesh={path="sample.mesh"}}
local chains={{call=function(_,key) assert(key=="get_GameObject");return arm end}}
local changed={["sample.mesh"]=true}
assert(armor.requires_part_assembly({model},changed,chains,root,{}))
assert(not armor.requires_part_assembly({model},changed,{},root,{}))
assert(armor.requires_part_assembly({model},changed,{},part(),{}))
assert(armor.requires_part_assembly({model},changed,{},root,{["sample.chain"]=1}))
assert(not armor.requires_part_assembly({model},{["sample.mdf2"]=true},chains,root,{}))
assert(model.mesh.keep)

model.vertex_owner=function() return true end
local rebuild,positions=armor.requires_part_assembly({model},changed,chains,root,{})
assert(not rebuild and positions,"a sibling's chain must not change during a vertex edit")
for _,attached in ipairs({root,body,part(body)}) do
    local comp={call=function() return attached end}
    assert(armor.requires_part_assembly({model},changed,{comp},root,{}))
end
model.vertex_owner=function() return false end
assert(armor.requires_part_assembly({model},changed,{},root,{}))

parts={component(1)}
b=batch(parts)
b.candidates[1].vertex_owner=function() return true end
b.candidates[1].mdf2.keep=true
local before=setters
assert(advance(b,parts))
local normal_call=go.call
function go:call(key) if key=="get_Update" then return false end;return normal_call(self,key) end
assert(advance(b,parts) and not armor.vertices_ready(b),"inactive worn vertices were reported as committed")
go.call=normal_call
assert(not advance(b,parts) and armor.vertices_ready(b))
assert(parts[1].mesh.ptr==3 and parts[1].mdf.ptr==2 and setters==before+1)
before=setters
b.candidates[1].vertex_owner=function() return false end
assert(not pcall(armor.vertices_ready,b),"a changed owner must cancel the late commit")
assert(not pcall(advance,b,parts) and setters==before,"rollback wrote to a new owner")

-- A different runtime joint at index zero must select the ordinary equipment
-- loader without making a speculative mesh call.
parts={component(1)}
parts[1].new_joints={[0]="Other",[1]="Leg"}
b=batch(parts)
b.candidates[1].vertex_owner=function() return true end
b.vertex_fallback=function() return {source="normal equipment"} end
before=setters
assert(advance(b,parts) and b.village.source=="normal equipment" and setters==before)

-- A material-only request can find a newer canonical mesh left by another
-- actor. Keep this hunter's skeleton and running chains on their own mesh.
parts={component(1)}
b=batch(parts)
b.candidates[1].mesh.keep=true
assert(advance(b,parts) and not advance(b,parts))
assert(parts[1].mesh.ptr==1 and parts[1].mdf.ptr==4)

-- The same object may gain a new simulation after the direct setter ran.
-- A late cancellation cannot put the previous mesh under that simulation.
parts={component(1)}
local get=go.call
local tr={call=function(_,key) assert(key=="get_GameObject");return go end}
function go:call(key) if key=="get_Transform" then return tr end;return get(self,key) end
local player={call=function(_,key) assert(key=="get_GameObject");return go end}
sdk.get_managed_singleton=function() return {call=function() return player end} end
local late=false
local function components(typ)
    if typ=="via.motion.Chain" then return late and {player} or {} end
    return parts
end
b=batch(parts)
b.mesh_changes={["sample.mesh"]=true}
assert(armor.advance(b,components,resources,function() return {} end,restore))
assert(parts[1].mesh.ptr==3)
late=true
ok,err=pcall(armor.abort,b,restore)
assert(not ok and tostring(err):find("Restore deferred") and parts[1].mesh.ptr==3 and parts[1].mdf.ptr==4)

local village={calls=0}
package.loaded["MHRS_HotReload.village_equipment"]={advance=function(tx)
    assert(tx==village and tx.resources==resources)
    tx.calls=tx.calls+1
    return tx.calls<2
end}
local invalid=function() error("A natural rebuild attempted a component setter") end
b={candidates={},village=village}
assert(armor.advance(b,invalid,resources,invalid,invalid))
assert(not armor.advance(b,invalid,resources,invalid,invalid))
print("Equipment MDF source checks, paired bind and independent-holder rollback passed")
