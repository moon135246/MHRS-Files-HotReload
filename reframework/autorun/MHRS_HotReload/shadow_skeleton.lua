-- Select the local hunter's normal or complete-first-natives-equipment shadow.
-- Retire/reload the resource before passing the new MeshResource to bind().
local M = {}
local retain_holder = require("MHRS_HotReload.retained_holder")
local slots={"body","arm","wst","leg","helm"}

local function scope(player, transform, sex, variants)
    local suit,matched=nil,true
    for i,part in ipairs(slots) do
        -- During a factory swap the departing and incoming parts may both
        -- be children of this Transform. Only the registered slot is worn.
        local go=player:call("getPartsGameObject",i-1)
        if not go or not go:call("get_Valid") then return nil,"Equipment slot unavailable: "..part end
        local tr=go:call("get_Transform")
        if not tr or tr:call("get_Parent")~=transform then return nil,"Equipment slot left hunter: "..part end
        local number=go:call("get_Name"):lower():match("^"..sex.."_"..part.."(%d+)$")
        if not number or (suit and number~=suit) then matched=false end
        suit=suit or number
    end
    local selected=matched and suit and ("pl"..suit) or nil
    return selected and variants[selected] and selected or "bone",selected
end

local function intact(tx)
    return tx.root:call("get_Valid") and tx.player:call("get_GameObject")==tx.root
        and tx.root:call("get_Transform")==tx.tr and (not tx.owns_root or tx.owns_root())
end

local function near(a,b)
    return math.abs(a.x-b[1])<0.00002 and math.abs(a.y-b[2])<0.00002 and math.abs(a.z-b[3])<0.00002
end

-- Validate names and parent links before touching the root's owner. Report
-- actual rest positions; a change to the animation pose alone cannot pass.
local function inspect(tr, expected, snapshot,tx)
    local found, changed = {}, 0
    if tx then tx.api="Transform.get_Joints" end
    for _,joint in pairs(tr:call("get_Joints")) do
        if tx then tx.api="Joint.get_Name" end
        local name = joint:call("get_Name")
        local row = expected[name]
        if not row then return nil, "Unexpected live shadow joint: "..tostring(name) end
        if tx then tx.api=name.." Joint.get_Parent" end
        local parent = joint:call("get_Parent")
        if found[name] or (parent and parent:call("get_Name") or "") ~= row.parent then
            return nil, "Different or duplicate live shadow joint: " .. name
        end
        found[name] = true
        if tx then tx.api=name.." Joint.get_BaseLocalPosition" end
        local pos=joint:call("get_BaseLocalPosition")
        if snapshot then snapshot[name]={parent=row.parent,position={pos.x,pos.y,pos.z}} end
        if not near(pos,row.position) then changed = changed + 1 end
    end
    for name in pairs(expected) do
        if not found[name] then return nil, "Missing live shadow joint: " .. name end
    end
    return changed
end

local function source_for(mesh, sex)
    local holder = mesh and mesh:call("getMesh")
    local name = holder and holder:call("get_ResourcePath")
    local base = "player/mod/" .. sex .. "/"
    local path = name and name:lower():gsub("^@", ""):gsub("\\", "/")
    if path and (path==base.."bone/"..sex.."_shadow.mesh" or path:match("^"..base.."pl%d+/"..sex.."_shadow%.mesh$")) then
        return holder
    end
end

-- Read-only completion check for a hunter rebuilt by the game's ordinary
-- equipment workflow. Accept the same joint map captured by this module.
function M.matches(player,expected)
    if not player or not expected or not next(expected) then return false,"No hunter or expected shadow joints" end
    local go=player:call("get_GameObject")
    if not go or not go:call("get_Valid") or not go:call("get_Draw") then return false,"Local hunter is not visible" end
    local tr=go:call("get_Transform")
    if not tr then return false,"Local hunter transform is unavailable" end
    local remaining,reason=inspect(tr,expected)
    if remaining==0 then return true end
    return false,reason or (remaining.." rest positions still pending")
end

function M.capture(player, targets)
    if not player then return nil,"Local hunter is unavailable" end
    local sex=({[0]="m",[1]="f"})[player:get_field("mSex")]
    local variants=targets and targets[sex]
    if not variants then return nil,"No shadow change for this hunter" end
    local go=player:call("get_GameObject")
    if not go or not go:call("get_Valid") or not go:call("get_Draw") then return nil,"Local hunter is not visible" end
    local tr=go and go:call("get_Transform")
    if not tr then return nil,"Local hunter transform is unavailable" end
    local key,suit=scope(player,tr,sex,variants)
    if not key then return nil,suit end
    local target=variants[key]
    if not target or not target.joints then
        return nil,target and target.deferred and ("[normal equip] "..target.deferred) or "No target shadow skeleton"
    end
    local before={}
    local count,reason=inspect(tr,target.joints,before)
    if count==nil then return nil,reason end
    local prefix="player/mod/"..sex.."/"
    local suffix="/"..sex.."_shadow.mesh"
    return {player=player,root=go,tr=tr,sex=sex,expected=target.joints,previous=before,changed=count,scope=key,
            request=prefix..key..suffix,canonical=prefix.."bone"..suffix,suit_request=suit and (prefix..suit..suffix)}
end

-- Call with the new cached resource after the engine has accepted the
-- requested generation. Keep a separate rollback holder across later frames.
function M.bind(tx,resource)
    if tx.changed==0 then return true end
    tx.api="root and motion ownership"
    if not intact(tx) then return nil,"Local hunter changed" end
    -- A hunter's shadow mesh is on the same root GO as the 79-joint
    -- transform. A child of this root might instead be a face or weapon.
    local mesh=tx.root:call("getComponent(System.Type)",sdk.typeof("via.render.Mesh"))
    local previous=source_for(mesh,tx.sex)
    if not previous then return nil,"Current hunter root does not own a shadow mesh" end
    local motion=tx.root:call("getComponent(System.Type)",sdk.typeof("via.motion.Motion"))
    if not motion or not motion:call("get_JointsConstructed") then return nil,"Hunter motion skeleton is not constructed" end
    local before=previous:read_qword(0x10)
    if not before or before==0 then return nil,"The current shadow mesh has no resource" end
    tx.api="pin current and new shadow mesh"
    local old=sdk.to_resource(sdk.to_ptr(before))
    local original=old and retain_holder(old,"via.render.MeshResourceHolder",before,previous)
    local next_holder=resource and retain_holder(resource,"via.render.MeshResourceHolder",resource:get_address())
    if not original or not next_holder then
        return nil,"Could not acquire both shadow mesh holders"
    end
    local path=next_holder:call("get_ResourcePath"):lower():gsub("^@","")
    -- A loader may service the ordinary logical request from a suit-specific
    -- physical file. Both names denote this hunter; final rest readback must
    -- still match the selected file's complete skeleton.
    if path~=tx.request and path~=tx.canonical then return nil,"Unexpected new shadow resource: "..path end
    if next_holder:read_qword(0x10)==before then return nil,"Shadow resource generation is unchanged" end
    tx.api="inspect attached CHAIN before binding"
    if tx.can_change and not tx.can_change() then return nil,"Attached hunter physics changed before binding the shadow" end
    tx.owner,tx.original,tx.fresh={go=tx.root,mesh=mesh,motion=motion},original,next_holder
    tx.forward={samples=0}
    tx.api="via.render.Mesh.setMesh "..path
    mesh:call("setMesh",next_holder)
    return true
end

local function verify(tx, expected, bound, state)
    tx.api="root mesh and motion ownership"
    if not intact(tx) then
        return nil,"Local hunter changed"
    end
    if not tx.root:call("get_Draw") then return false,"Local hunter is not visible" end
    if tx.owner then
        local go=tx.owner.go
        if not go:call("get_Valid") or tx.owner.mesh:call("get_GameObject")~=go then return nil,"Shadow owner changed" end
        local holder=tx.owner.mesh:call("getMesh")
        if not holder or holder:read_qword(0x10)~=bound:read_qword(0x10) then return nil,"Shadow owner binding changed" end
        if not tx.owner.mesh:call("get_MeshReady") then return false,"Shadow mesh is loading" end
        if go:call("getComponent(System.Type)",sdk.typeof("via.motion.Motion"))~=tx.owner.motion then
            return nil,"Hunter motion component changed"
        end
    end
    local remaining,reason=inspect(tx.tr,expected,nil,tx)
    -- Rebuilding the render owner can make the joint list transiently empty
    -- after MeshReady. The caller bounds retries to its transaction deadline.
    if not remaining then return false,reason end
    if remaining==0 then
        if tx.owner and not tx.owner.motion:call("get_JointsConstructed") then return false,"Motion is constructing joints" end
        return true
    end
    if state then
        state.samples=state.samples+1
        -- Give normal setMesh two ready frames. resetSekeleton is the
        -- exact name exposed by Rise's via.motion.Motion. Do not repeat it
        -- or assume it worked until a later frame reads all rest positions.
        if state.samples>2 and not state.reset then
            tx.api="inspect attached CHAIN before motion reset"
            if tx.can_change and not tx.can_change() then return nil,"Attached hunter physics changed before resetting Motion" end
            state.reset=true
            tx.api="via.motion.Motion.resetSekeleton"
            tx.owner.motion:call("resetSekeleton")
        end
    end
    return false, remaining.." rest positions still pending"
end

function M.verify(tx)
    local ok,reason=verify(tx,tx.expected,tx.fresh,tx.forward)
    if ok and tx.owner and not tx.rest_reported then
        tx.rest_reported=true
        require("MHRS_HotReload.lua_bone_system").rest_changed(tx.root)
    end
    return ok,reason
end

function M.abort(tx)
    if not tx.owner or not intact(tx) then return true end
    local comp=tx.owner.mesh
    local holder=comp:call("get_GameObject")==tx.owner.go and comp:call("getMesh")
    if holder and holder:read_qword(0x10)==tx.fresh:read_qword(0x10) then
        if tx.can_change and not tx.can_change() then return false,false end
        tx.reverse={samples=0}
        comp:call("setMesh",tx.original)
        local restored=comp:call("getMesh")
        if not restored or restored:read_qword(0x10)~=tx.original:read_qword(0x10) then
            return false,false
        end
        return true,true
    end
    if tx.reverse and holder and holder:read_qword(0x10)==tx.original:read_qword(0x10) then
        return true,true
    end
    return true,false
end

function M.verify_rollback(tx)
    if not tx.reverse then return true end
    local ok,reason=verify(tx,tx.previous,tx.original,tx.reverse)
    if ok and not tx.reverse.rest_reported then
        tx.reverse.rest_reported=true
        require("MHRS_HotReload.lua_bone_system").rest_changed(tx.root)
    end
    return ok,reason
end

return M
