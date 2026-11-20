-- Change both resource holders on the existing render component in one game
-- update. Keep the previous pair until a later update verifies the renderer.
local M = {}
local array_elements = require("MHRS_HotReload.array_elements")
local roster = require("MHRS_HotReload.hunter_roster")
local shadow_skeleton = require("MHRS_HotReload.shadow_skeleton")
local game_update = require("MHRS_HotReload.game_update")
local retain_holder = require("MHRS_HotReload.retained_holder")
local extensions = {"mesh", "mdf2"}
local recovering = {}
local stopping = false

local function address(holder)
    return holder and holder:read_qword(0x10)
end

-- A normal equipment load may have restored a certified PAK mesh without
-- inspecting vertex buffers. Record only the platform resource actually
-- attached to this master's slot after the five-part verification.
function M.remember_stock(batch,actors,resources,instance)
    local tx=batch.village
    if not tx or not tx.stable or tx.stable<2 or not batch.stock_scope or actors.scope~=batch.stock_scope then return 0 end
    local count=0
    for _,owner in ipairs(actors.entries) do
        if owner.role=="master" and owner.index==tx.index and owner.scope==batch.stock_scope
                and tostring(owner.root:get_address())==tx.new_address then
            for slot,expected in pairs(tx.parts) do
                local path=expected.mesh
                local name=expected.mesh_name
                local go=owner.slots[slot]
                local part=go and actors.parts[go:get_address()]
                if expected.touched and batch.stock_meshes[path]==true and batch.platform[name] and resources[name]
                        and part and part.entry==owner and part.slot==slot and part.go==go
                        and go:call("get_Valid") and go:call("get_Update") and go:call("get_Name")==expected.name then
                    local comp,h=roster.render_part(go)
                    local res=resources[name]
                    if h and h:call("get_ResourcePath"):lower()==path and address(h)==res:get_address()
                            and comp:call("get_MeshReady") and comp:call("get_MaterialReady") then
                        local pin=retain_holder(res,"via.render.MeshResourceHolder",res:get_address(),h)
                        if pin then
                            instance(comp:get_address(),go).stock={path=path,holder=pin,comp=comp,slot=slot,
                                root=owner.root,scope=owner.scope}
                            count=count+1
                        end
                    end
                end
            end
        end
    end
    return count
end

function M.resident_stock(row,instance,part)
    local proof=instance and instance.go==row.go and instance.stock
    local owner=part and part.entry
    return proof and owner and owner.role=="master" and part.go==row.go and proof.slot==part.slot
        and proof.comp==row.comp and proof.root==owner.root and proof.scope==owner.scope
        and proof.path==row.mesh.path:lower() and address(proof.holder)==row.mesh.original
end

-- Pin provenance to the actual resource and scene instance. A preview model
-- and the hunter can independently instantiate the same cached costume.
function M.needs_reentry(row, instance, origins, startup)
    local mesh=row.mesh
    if instance and instance.go==row.go then
        if instance.defer==mesh.original then return true end
        if instance.direct==mesh.original then return false end
    end
    local key=mesh.path:lower()
    local known=origins[key]
    if known and known[mesh.original]~=nil then return known[mesh.original] end
    return startup[key] or startup[key:gsub("%.mesh$",".chain")] or false
end

local function belongs_to(go, root)
    local tr=go and go:call("get_Transform")
    while tr do
        if tr:call("get_GameObject")==root then return true end
        tr=tr:call("get_Parent")
    end
    return false
end

-- Even a mesh on a part with no Chain of its own can share the hunter's
-- joint map with a sibling's running simulation (the stock Mei body does).
function M.requires_part_assembly(candidates, changed, components, hunter, incoming_chains)
    local mesh_changed,foreign,positions_only=false,false,true
    for _,row in pairs(candidates) do
        row.mesh.keep=not changed[row.mesh.path:lower()]
        if not row.vertex_owner or row.mesh.keep then positions_only=false
        else
            local ok,owned=pcall(row.vertex_owner)
            if not ok or not owned then return true,false,"local slot changed" end
        end
        if not row.mesh.keep then
            mesh_changed=true
            if not hunter or not belongs_to(row.go,hunter) then foreign=true end
        end
    end
    if not mesh_changed then return false,false,"material only" end
    if foreign or next(incoming_chains) then return true,false,"foreign part or incoming chain" end
    for _,comp in ipairs(components) do
        local go=comp:call("get_GameObject")
        if belongs_to(go,hunter) then
            if not positions_only then return true,false,"hunter has chain; mesh layout unconfirmed" end
            -- The topology and skinning of this single part are immutable.
            -- Its own simulation, a child simulation or a parent simulation
            -- still makes the live render binding ineligible.
            for _,row in pairs(candidates) do
                if belongs_to(go,row.go) or belongs_to(row.go,go) then return true,false,"chain in renderer hierarchy" end
            end
        end
    end
    return false,positions_only,positions_only and "stock vertex layout" or "no hunter chain"
end

local function physics_changed(batch, candidates)
    if not batch.mesh_changes then return false end
    local pm=sdk.get_managed_singleton("snow.player.PlayerManager")
    local player=pm and pm:call("findMasterPlayer")
    local hunter=player and player:call("get_GameObject")
    return M.requires_part_assembly(candidates,batch.mesh_changes,batch.scene_components("via.motion.Chain"),hunter,{})
end

function M.capture(comp, go, kinds, missing, resources, expected)
    local row = {comp=comp, go=go}
    for _, ext in ipairs(extensions) do
        local kind = kinds[ext]
        local holder = comp:call(kind[3])
        local path = holder and holder:call("get_ResourcePath")
        if not path or path == "" or missing[path:lower()] then return end
        if ext=="mesh" and path:lower():match("/[fm]_shadow%.mesh$") then return end
        row[ext] = {kind=kind, path=path, original=address(holder)}
    end
    for _, ext in ipairs(extensions) do
        local slot = row[ext]
        resources[slot.path] = slot.kind[2]
    end
    row.expected = expected[row.mdf2.path:lower()]
    return row
end

function M.check_sources(batch, resources, stream)
    local slots = {}
    for line in stream:lines() do
        local path, ptr, name = line:match("^([^\t]+)\t(%d+)\t([^\t]+)$")
        if not path then return "Invalid equipment material slot report" end
        local entry = slots[path]
        if not entry then entry = {ptr=ptr, names={}}; slots[path] = entry end
        if entry.ptr ~= ptr then return "Equipment material changed: " .. path end
        entry.names[#entry.names+1] = name
    end
    local materials = {}
    for name, expected in pairs(batch.materials or {}) do materials[name] = expected end
    for _, row in pairs(batch.candidates) do materials[row.mdf2.path] = row.expected or false end
    for path, expected in pairs(materials) do
        local entry = slots[path]
        if not entry or entry.ptr ~= tostring(resources[path]:get_address()) then
            return "Missing material slot report for requested resource: " .. path
        end
        if expected then
            local actual = entry.names
            local matches = #actual == #expected
            for i, name in ipairs(expected) do
                if actual[i] ~= name then matches = false; break end
            end
            if not matches then
                return path .. " expected [" .. table.concat(expected,", ") .. "], loaded [" .. table.concat(actual,", ") .. "]"
            end
        end
    end
end

local function live(row)
    local owns=row.vertex_owner or row.wearer_owns
    return row.go:call("get_Valid") and row.comp:call("get_GameObject") == row.go
        and (not owns or owns(row.go))
end

local function current(row, ext)
    return address(row.comp:call(row[ext].kind[3]))
end

local function material_binding(row,values,geometry)
    local owns=row.wearer_owns
    if row.vertex_owner then
        owns=function(go)
            return row.vertex_owner(go)
                and current(row,"mesh")==geometry and current(row,"mdf2")==row.mdf2.original
        end
    end
    return {comp=row.comp,kind=row.mdf2.kind,switches=values,parts=row.part_switches,wearer_owns=owns}
end

local function restore(row, restore_when_ready)
    for _, ext in ipairs(extensions) do
        local slot = row[ext]
        if current(row, ext) ~= slot.original then
            assert(address(slot.old) == slot.original, "Rollback holder changed: " .. slot.path)
            row.comp:call(slot.kind[4], slot.old)
        end
    end
    assert(current(row, "mesh") == row.mesh.original and current(row, "mdf2") == row.mdf2.original,
        "Could not restore equipment holders")
    restore_when_ready(material_binding(row,row.rollback_material,row.mesh.original))
end

local function restore_chains(batch, failures)
    if batch.chains_paused then
        local ok,reason=pcall(batch.chains.rollback,batch.chains)
        if not ok then failures[#failures+1]=tostring(reason) end
        batch.chains_paused=nil
    end
end

-- The worker can time out or cancel an equipment request while the old mesh
-- is still initializing. The game thread owns these holders and resumes
-- the affected physics even if no more worker polls arrive.
local function finish_recovery(batch, reason)
    local failures=recovering[batch].failures
    if reason then failures[#failures+1]=tostring(reason) end
    restore_chains(batch, failures)
    recovering[batch]=nil
    if #failures>0 then
        batch.rollback_error=table.concat(failures," / ")
        if log then log.error("[MHRS-Files-HotReload] Shadow rollback: "..batch.rollback_error) end
    end
end

function M.recovery_pending(batch)
    return recovering[batch]~=nil
end

function M.update_recoveries()
    for batch,state in pairs(recovering) do
        local ok,ready,reason=pcall(shadow_skeleton.verify_rollback,batch.shadow)
        if ok and ready then finish_recovery(batch)
        elseif not ok or ready==nil or os.clock()>=state.deadline then
            finish_recovery(batch,(not ok and ready) or reason or "Timed out verifying the previous shadow skeleton")
        end
    end
end

if re then
    game_update.register(M.update_recoveries)
    re.on_script_reset(function()
        stopping=true
        for batch in pairs(recovering) do
            finish_recovery(batch,"Script reset before previous shadow skeleton could be verified")
        end
    end)
end

function M.abort(batch, restore_when_ready, synchronous)
    if batch.aborted then return end
    batch.aborted=true
    local failures = {}
    if batch.village then
        local village = require("MHRS_HotReload.village_equipment")
        if village.abort then
            local ok,reason=pcall(village.abort,batch.village)
            if not ok then failures[#failures+1]=tostring(reason) end
        end
    end
    local wait_for_shadow=false
    if batch.chains_paused then
        local ok, reason = pcall(batch.chains.suspend_for_rollback, batch.chains)
        if not ok then failures[#failures+1]=tostring(reason) end
    end
    if batch.shadow_bound then
        local ok, reason, pending=pcall(shadow_skeleton.abort,batch.shadow)
        if not ok or reason==false then failures[#failures+1]="Could not restore shadow skeleton: "..tostring(reason) end
        wait_for_shadow=ok and reason==true and pending==true
        batch.shadow_bound=nil
    end
    if batch.physics then
        local ok,reason=pcall(batch.physics.abort,batch.physics)
        if not ok then failures[#failures+1]=tostring(reason) end
    end
    for i = #(batch.touched or {}), 1, -1 do
        local row = batch.touched[i]
        local ok, err = pcall(function()
            if not live(row) or (row.vertex_owner and not row.go:call("get_Update")) then return end
            -- After yielding, the game may have equipped a different item.
            -- Restore only a pair still owned by this transaction.
            if not synchronous or row.vertex_owner then
                for _, ext in ipairs(extensions) do
                    local value, slot = current(row, ext), row[ext]
                    if value ~= slot.fresh and value ~= slot.original then return end
                end
            end
            if current(row,"mesh")~=row.mesh.original then
                assert(not physics_changed(batch,{row}),
                    "[live equipment rejected] Restore deferred to normal equipment load after a hunter or physics change")
            end
            restore(row, restore_when_ready)
        end)
        if not ok then failures[#failures+1] = tostring(err) end
    end
    batch.touched = nil
    if wait_for_shadow and not stopping then
        recovering[batch]={failures=failures,deadline=os.clock()+3}
        return
    end
    restore_chains(batch,failures)
    assert(#failures == 0, table.concat(failures, " / "))
end

local function same_joints(row)
    local function names(h)
        return array_elements(row.comp:call("getJointNameList",h),"equipment mesh joints")
    end
    local a,b=names(row.mesh.old),names(row.mesh.holder)
    local count=0
    for i,v in pairs(a) do
        if not b[i] then return false end
        local old=type(v)=="string" and v or v:call("ToString()")
        local new=type(b[i])=="string" and b[i] or b[i]:call("ToString()")
        if old~=new then return false end
        count=count+1
    end
    if count==0 then return false end
    for _ in pairs(b) do count=count-1 end
    return count==0
end

local function stage(batch, components, resources, material_state)
    local staged, holders = {}, {}
    for _, comp in ipairs(components) do
        local row = batch.candidates[comp:get_address()]
        if row and row.comp == comp and live(row) and row.go:call("get_Update")
                and current(row, "mesh") == row.mesh.original and current(row, "mdf2") == row.mdf2.original then
            for _, ext in ipairs(extensions) do
                local slot = row[ext]
                if slot.keep then
                    slot.fresh=slot.original
                else
                    -- This getter can expose the component's mutable holder.
                    -- Keep a separate reference to restore the old generation.
                    local current_holder = comp:call(slot.kind[3])
                    local old_resource = assert(sdk.to_resource(sdk.to_ptr(slot.original)))
                    local kind = slot.kind[2] .. "Holder"
                    slot.old = assert(retain_holder(old_resource,kind,slot.original,current_holder),
                        "Could not pin current equipment resource: " .. slot.path)
                    local resource = assert(resources[slot.path], "Missing equipment resource: " .. slot.path)
                    slot.fresh = resource:get_address()
                    if not holders[slot.path] then
                        local canonical = assert(sdk.create_resource(slot.kind[2], slot.path))
                        local actual = canonical:get_address()
                        canonical:release()
                        assert(actual == slot.fresh, "Equipment resource changed: " .. slot.path)
                        holders[slot.path] = assert(retain_holder(resource,kind,slot.fresh),
                            "Incorrect equipment holder: " .. slot.path)
                    end
                    slot.holder = holders[slot.path]
                    assert(address(slot.holder) == slot.fresh, "Incorrect equipment holder: " .. slot.path)
                end
            end
            if row.vertex_owner then
                local ok,matches=pcall(same_joints,row)
                if not ok or not matches then
                    if log then log.info("[MHRS-Files-HotReload] Worn mesh joint check selected normal equipment load: "..
                        row.mesh.path.." ("..tostring(matches)..")") end
                    return nil
                end
            end
            if comp:call("get_MaterialReady") then
                row.rollback_material,row.part_switches=material_state(comp,row.vertex_owner and "vertices" or true)
                row.switches=row.vertex_owner and row.rollback_material or material_state(comp,false)
            end
            staged[#staged + 1] = row
        end
    end
    return staged
end

local function verify(row)
    local comp = row.comp
    if not live(row) then
        assert(not row.vertex_owner,"[village changed] Vertex edit lost its worn renderer")
        return true
    end
    if not row.go:call("get_Update") then
        if row.vertex_owner then return false,"Worn vertex renderer is inactive" end
        return true
    end
    for _, ext in ipairs(extensions) do
        if current(row, ext) ~= row[ext].fresh then
            return false, "Equipment holder changed: " .. row[ext].path
        end
    end
    if not comp:call("get_MeshReady") or not comp:call("get_MaterialReady") then
        return false, "Equipment renderer is still initializing: " .. row.mesh.path
    end
    if row.expected then
        local count = comp:call("get_MaterialNum")
        local matches = count == #row.expected
        for i = 1, #row.expected do
            if not matches or comp:call("getMaterialName", i-1) ~= row.expected[i] then
                matches = false
                break
            end
        end
        if not matches then return false, "Equipped material slots differ from the loose MDF: " .. row.mdf2.path end
    end
    return true
end

function M.vertices_ready(batch)
    for _,row in ipairs(batch.touched or {}) do
        if row.vertex_owner then
            local ready,reason=verify(row)
            if not ready then
                assert(os.clock()<batch.deadline,reason)
                return false
            end
        end
    end
    return true
end

function M.advance(batch, scene_components, resources, material_state, restore_when_ready)
    if next(recovering) then return true end
    if batch.abort_reason then
        error(batch.abort_reason..(batch.rollback_error and ("; rollback: "..batch.rollback_error) or ""))
    end
    if batch.village then
        local village=require("MHRS_HotReload.village_equipment")
        batch.village.resources=resources
        batch.village.platform=batch.platform
        local ok,pending=pcall(function()
            if batch.physics and not batch.village_sources_ready then
                batch.physics:stage()
                batch.physics:bind()
                assert(batch.physics:verify())
                batch.village_sources_ready=true
            end
            return village.advance(batch.village,resources,scene_components)
        end)
        if not ok then
            local restored,reason=pcall(M.abort,batch,restore_when_ready)
            local message=tostring(pending)
            if not message:find("[village changed]",1,true) and not message:find("[live equipment rejected]",1,true) then
                message="[live equipment rejected] "..message
            end
            error(restored and message or (message.."; rollback: "..tostring(reason)))
        end
        return pending
    end
    if not next(batch.candidates) and not batch.physics and not batch.chains and not batch.shadow then return false end
    local synchronous = not batch.touched
    local function context(err)
        local action=batch.action or "worn resources"
        if (action=="bind shadow" or action=="verify shadow") and batch.shadow then
            action=action.." "..tostring(batch.shadow.api or batch.shadow.request)
        elseif batch.chains and batch.chains.current_path then action=action.." "..batch.chains.current_path end
        return debug.traceback(action..": "..tostring(err),2)
    end
    local ok, pending, next_update = xpcall(function()
        if batch.chains and not batch.chains_paused then
            batch.action="stage CHAIN"
            batch.chains:stage(resources)
            batch.chains_paused=true
            batch.action="pause CHAIN"
            batch.chains:pause()
            return true,true
        end
        if batch.shadow then
            if not batch.shadow_bound then
                batch.action="bind shadow"
                batch.shadow_bound=true
                assert(shadow_skeleton.bind(batch.shadow,resources[batch.shadow.request]))
                batch.shadow_deadline=os.clock()+3
                return true,true
            end
            if not batch.shadow_ready then
                batch.action="verify shadow"
                local ready, reason=shadow_skeleton.verify(batch.shadow)
                if not ready then
                    assert(ready~=nil and os.clock()<batch.shadow_deadline,reason)
                    return true
                end
                batch.shadow_ready=true
            end
        end
        if synchronous then
            batch.scene_components=scene_components
            assert(not physics_changed(batch,batch.candidates),
                "[live equipment rejected] Hunter or physics changed while equipment was loading")
            local staged={}
            if next(batch.candidates) then
                staged=stage(batch,scene_components("via.render.Mesh"),resources,material_state)
                if not staged then
                    batch.village=batch.vertex_fallback and batch.vertex_fallback()
                    assert(batch.village,"[live equipment rejected] Worn mesh joint layout could not be confirmed")
                    batch.candidates={}
                    return true,true
                end
            end
            local prepared={}
            for _,row in ipairs(staged) do prepared[row]=true end
            for _,row in pairs(batch.candidates) do
                if row.vertex_owner then
                    assert(prepared[row],"Worn part changed before its renderer update")
                end
            end
            if batch.physics then batch.physics:stage(resources) end
            batch.touched = {}
            for _, row in ipairs(staged) do
                batch.touched[#batch.touched+1] = row
                if current(row, "mesh") ~= row.mesh.fresh then row.comp:call(row.mesh.kind[4], row.mesh.holder) end
                if current(row, "mdf2") ~= row.mdf2.fresh then row.comp:call(row.mdf2.kind[4], row.mdf2.holder) end
                assert(current(row, "mesh") == row.mesh.fresh and current(row, "mdf2") == row.mdf2.fresh,
                    "Equipment holder assignment failed: " .. row.mesh.path)
            end
            batch.deadline = os.clock() + 4
            local changed=batch.physics and batch.physics:bind()
            local pending=#staged>0 or changed==true or batch.chains~=nil
            return pending,pending
        end
        for _, row in ipairs(batch.touched) do
            local ready, reason = verify(row)
            if not ready then
                assert(os.clock() < batch.deadline, reason)
                return true
            end
        end
        if batch.physics then
            local ready,reason=batch.physics:verify()
            if not ready then
                assert(os.clock()<batch.deadline,reason)
                return true
            end
        end
        if batch.chains then
            if not batch.chain_bound then
                batch.action="bind CHAIN"
                batch.chains:bind()
                batch.chain_bound=true
                return true,true
            end
            if not batch.chain_resumed then
                batch.action="resume CHAIN"
                batch.chains:resume()
                batch.chain_resumed=true
                batch.chain_deadline=os.clock()+4
                return true,true
            end
            batch.action="verify CHAIN"
            local ready, reason=batch.chains:verify()
            if not ready then
                assert(os.clock()<batch.chain_deadline,reason)
                return true
            end
        end
        for _, row in ipairs(batch.touched) do
            if live(row) and row.go:call("get_Update") then
                restore_when_ready(material_binding(row,row.switches,row.mesh.fresh))
            end
        end
        return false
    end,context)
    if not ok then
        local applied=batch.chains_paused or batch.shadow_bound
        local restored, failure = pcall(M.abort, batch, restore_when_ready, synchronous)
        local reason=restored and tostring(pending) or (tostring(pending) .. "; rollback: " .. tostring(failure))
        reason=(applied and "[live equipment rejected] " or "")..reason
        if recovering[batch] then batch.abort_reason=reason;return true end
        error(reason)
    end
    return pending,next_update
end

return M
