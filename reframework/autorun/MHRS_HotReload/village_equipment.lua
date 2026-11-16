-- Let Rise construct the five worn parts together when their meshes and
-- physics change. The game builds the replacement at the local hunter's position.
local M = {}
local shadow_skeleton = require("MHRS_HotReload.shadow_skeleton")
local equipped_parts = require("MHRS_HotReload.equipped_parts")
local equipped_hunter = require("MHRS_HotReload.equipped_hunter")
local quest_context = require("MHRS_HotReload.quest_context")
local mounted
local mesh_type = "via.render.Mesh"
local slots={0,1,2,3,4}
local cancelled
local current_mount,cancelled_mount
local session_pid,saved_recovery
local recovery_path="MHRS-Files-HotReload/model-recovery.json"
local mount_path="MHRS-Files-HotReload/part-recovery.json"
local saved_mount,saved_replay

-- Reset Scripts discards all Lua objects while Rise may still be building the
-- replacement. Carry only enough identity to restore control in this process.
function M.install(pid)
    session_pid=pid
    local recovery=json.load_file(mount_path)
    if type(recovery)=="table" and recovery.pid==pid and type(recovery.expires)=="number"
            and os.time()<=recovery.expires and recovery.expires<=os.time()+90 and type(recovery.rows)=="table"
            and #recovery.rows<=5 and (#recovery.rows>0 or recovery.replay) then saved_mount=recovery end
    local r=json.load_file(recovery_path)
    if type(r)=="table" and r.pid==(pid or false) and type(r.expires)=="number" and
            os.time()<=r.expires and r.expires<=os.time()+25 and type(r.manager)=="string" and
            type(r.old_address)=="string" and (type(r.area)=="number" or (r.quest and r.quest.data)) and type(r.index)=="number" and
            type(r.area_flag)=="number" and type(r.class)=="string" then
        saved_recovery=r
    end
end

local function save_recovery(tx,pm)
    if not json or not json.dump_file then return end
    local s=tx.gear
    local r={pid=session_pid or false,manager=tostring(pm:get_address()),expires=os.time()+22,
        index=tx.index,area=tx.area,quest=tx.quest,area_flag=tx.area_flag,class=tx.class,old_address=tx.old_address,
        gear=s}
    json.dump_file(recovery_path,r)
    assert((json.load_file(recovery_path) or {}).old_address==r.old_address,"Could not record local hunter recovery")
    tx.recovery=r
end

local function clear_recovery(tx)
    if tx.recovery or tx==saved_recovery then
        json.dump_file(recovery_path,{})
        tx.recovery=nil
        saved_recovery=nil
    end
end

local function child(go,t)
    return go and go:call("getComponent(System.Type)",sdk.typeof(t))
end

local function path(holder)
    local name=holder and holder:call("get_ResourcePath")
    return name and name:lower():gsub("^@",""):gsub("\\","/")
end

local function scene(rebuild)
    local pm=sdk.get_managed_singleton("snow.player.PlayerManager")
    local p=pm and pm:call("findMasterPlayer")
    if not p then return end
    local td=p:get_type_definition()
    local class=td:get_full_name()
    if class=="snow.player.PlayerLobbyBase" then
        return pm,p,p:call("get_GameObject")
    end
    if td:is_a("snow.player.PlayerQuestBase") then
        local game=sdk.get_managed_singleton("snow.SnowGameManager")
        local status=game and game:call("getStatus")
        if status==2 then
            if not p:call("get_IsInTrainingArea") then return pm,p,p:call("get_GameObject"),false,quest_context.read() end
            return
        end
        if status~=1 then return end
        local area=sdk.get_managed_singleton("snow.VillageAreaManager")
        if area and area:call("getCurrentAreaNo")==5 and area:call("checkCurrentArea_TrainingArea") and
                (p:call("get_IsInTrainingArea") or (rebuild and rebuild.gear and not rebuild.quest)) then
            return pm,p,p:call("get_GameObject"),true
        end
    end
end

local function ready(pm,p,go,training,quest)
    if saved_mount or cancelled_mount or cancelled or saved_recovery or not go or not go:call("get_Valid") or not go:call("get_Draw") then return end
    local place=quest
    if quest then
        if not quest_context.available(quest,p) then return end
    else
        place=sdk.get_managed_singleton("snow.VillageAreaManager")
        if not place or not place:call("isIdle") then return end
    end
    local eq=sdk.get_managed_singleton("snow.data.EquipDataManager")
    if not eq then return end
    local index=pm:call("getMasterPlayerID")
    if not pm:call("isReadyPlayer",index) or not pm:call("isReadyPlayerLoadState") or
            not p:call("isActivePlayer") or not p:call("isInput") then return end
    if training or quest then
        local s=equipped_hunter.ready(pm,p,go,index,quest and quest.data)
        if not s then return end
        return place,index,s
    end
    return place,index
end

-- Only copy identities from the master's five worn parts. A hidden preview,
-- another hunter, or a mesh with the same path in a new generation must
-- never trigger a deferred model rebuild. No holder or GO survives this call.
local function scope(quest)
    if quest and quest.data then return table.concat({"quest",quest.no,quest.map,quest.data},"/") end
    local area=sdk.get_managed_singleton("snow.VillageAreaManager")
    return area and "village/"..area:call("getCurrentAreaNo")
end

function M.worn_state(wanted,wait_factory)
    local pm,p,go,training,quest=scene()
    local observed,available,owners={},{},{}
    if not go or not go:call("get_Valid") then return {observed=observed} end
    local complete=ready(pm,p,go,training,quest)~=nil
    local covered=0
    for _,i in ipairs(slots) do
        local part=p:call("getPartsGameObject",i)
        if not part or not part:call("get_Valid") then complete=false
        else
            local mesh=child(part,mesh_type)
            local holder=mesh and mesh:call("getMesh")
            local key=path(holder)
            if key and (wanted[key] or wanted[key:gsub("%.mesh$",".mdf2")]) then
                covered=covered+1
                observed[key]=tostring(holder:read_qword(0x10))
                owners[key]=mesh:get_address()
                if part:call("get_Update") and mesh:call("get_MeshReady") then available[key]=true end
            elseif mesh and not holder then complete=false end
        end
    end
    if complete and wait_factory and covered==5 then
        mounted=mounted or require("MHRS_HotReload.mounted_equipment")
        local ok,available_now=pcall(mounted.factories_available,pm,p,go)
        complete=ok and available_now
    end
    return {ready=complete,observed=observed,available=available,training=training,quest=quest~=nil,
        root=tostring(go:get_address()),scope=scope(quest),complete_outfit=covered==5},owners
end

function M.replay_state(id)
    if saved_mount then return {pending=true} end
    if not saved_replay or (id and saved_replay.replay.id~=id) then return {} end
    if os.time()>saved_replay.expires then saved_replay=nil;json.dump_file(mount_path,{});return {} end
    local state=mounted.replay_state(saved_replay)
    if not state then saved_replay=nil;json.dump_file(mount_path,{});return {} end
    local worn=M.worn_state(state.worn)
    if not worn.ready then return {pending=true} end
    for path,old in pairs(state.worn) do
        if not worn.available[path] or worn.observed[path]~=old then return {pending=true} end
    end
    return state
end

function M.capture(candidates, physics, materials, shadow, missing,mount_blocked,live,shadow_reason)
    local pm,p,go,training,quest=scene()
    local place,index,gear=ready(pm,p,go,training,quest)
    if not place then return end
    local parts=equipped_parts.capture(p,candidates,physics,materials)
    if not parts then return end
    local covered,changed,missing_binding=0,0,false
    for _,s in ipairs(slots) do
        local row=parts[s]
        if live and row.mesh and row.mdf and (live[row.mesh] or live[row.mdf]) then
            covered=covered+1
            if not row.requested then missing_binding=true end
        end
        if row.touched then changed=changed+1 end
    end
    local full=covered==5 or (changed>1 and shadow and shadow.suit_request and shadow.request==shadow.suit_request)
    return {old=go,old_address=tostring(go:get_address()),class=p:get_type_definition():get_full_name(),
        parts=parts,index=index,area=not quest and place:call("getCurrentAreaNo") or nil,quest=quest,
        area_flag=p:call("get_AreaMoveFlag"),shadow=shadow,gear=gear,mount_blocked=mount_blocked,
        full_outfit=full,scope=scope(quest),missing_binding=missing_binding,shadow_reason=shadow_reason}
end

-- Drop the live transaction and let the host schedule a new attempt from
-- current files. Only scalar identities cross that boundary.
local function defer_mount(tx,reason)
    local wanted={}
    for _,s in ipairs(slots) do
        local row=tx.parts[s]
        if row.mesh then wanted[row.mesh]=true end
    end
    local state={observed={}}
    if not reason:find("[normal equip]",1,true) then state=M.worn_state(wanted) end
    local retry=state.root==tx.old_address
        and state.scope==tx.scope and state.complete_outfit
    if retry then
        for _,s in ipairs(slots) do
            local row=tx.parts[s]
            if not state.observed[row.mesh] or (row.before and state.observed[row.mesh]~=tostring(row.before)) then retry=false;break end
        end
    end
    tx.deferred_mount={retry=retry==true,reason=reason,root=tx.old_address,scope=tx.scope,worn=state.observed,
        wait_factory=reason:find("cold armor factory",1,true)~=nil}
    if log then log.info("[MHRS-Files-HotReload] "..(retry and "Waiting for in-place equipment: " or "Equipment deferred to natural equip: ")..reason) end
    return false
end

local function request(eq,tx)
    local method=eq:get_type_definition():get_method("reloadPlayerModel")
    local value=eq:call("getMasterPlayerIndex")
    assert(value:call("get_HasValue") and value:call("get_Value")==tx.index,
           "Cannot identify the local player for model reload")
    method:call(eq,false,value)
end

-- A model created outside the equipment menu starts without the old
-- hunter's area participation flag. It controls both rendering and input.
local function resume_hunter(tx,pm,p,go,quest,recovering)
    if tx.quest then
        if not quest_context.same(tx.quest,quest) then return false,"Quest or stage changed" end
    else
        if quest then return false end
        local area=sdk.get_managed_singleton("snow.VillageAreaManager")
        if not area or not area:call("isIdle") or area:call("getCurrentAreaNo")~=tx.area then return false end
        if tx.gear and not area:call("checkCurrentArea_TrainingArea") then return false end
    end
    if not go or tostring(go:get_address())==tx.old_address or not go:call("get_Valid") or
            p:get_type_definition():get_full_name()~=tx.class or not p:call("isMasterPlayer") or
            pm:call("getMasterPlayerID")~=tx.index or not pm:call("isReadyPlayer",tx.index) or
            not pm:call("isReadyPlayerLoad") or not pm:call("isReadyPlayerLoadState") then return false end
    if tx.new_address and tx.new_address~=tostring(go:get_address()) then return false end
    if tx.gear then
        if p:call("getPlayerIndex")~=tx.index then return false end
        if not equipped_hunter.same_hunter(tx.gear,equipped_hunter.identity(p)) then
            return false,"Waiting for the original local hunter data and weapon"
        end
    end
    tx.new_address=tostring(go:get_address())
    if not tx.resumed then
        local flag=p:call("get_AreaMoveFlag")
        if tx.quest then
            -- Unlike the village, a quest owns its player lifecycle. First let
            -- it restore its own control. Only a persistently hidden, inactive
            -- replacement with the original equipped identities is eligible for
            -- restoring the exact participation flag sampled before the request.
            local draw,active,input=go:call("get_Draw"),p:call("isActivePlayer"),p:call("isInput")
            if not (draw and active and input) then
                tx.hidden_since=tx.hidden_since or os.clock()
                if draw or active or input or os.clock()-tx.hidden_since<1 or flag==tx.area_flag or
                        not quest_context.available(quest,p) or p:call("isWeaponOn") then return false end
                local gui=sdk.get_managed_singleton("snow.gui.GuiManager")
                if not gui or gui:call("IsPlayerAllInputDisable") or
                        equipped_hunter.equip_indices(pm)~=tx.gear.indices then return false,"Waiting for the original quest equipment" end
                p:call("setAreaMoveFlag",tx.area_flag)
            end
        elseif flag~=tx.area_flag then p:call("setAreaMoveFlag",tx.area_flag) end
        tx.resumed=true
        local record=tx.recovery or (tx==saved_recovery and tx)
        if record then
            record.new_address=tx.new_address
            record.resumed=true
            json.dump_file(recovery_path,record)
        end
        return false
    end
    if not (go:call("get_Draw") and p:call("isActivePlayer") and p:call("isInput")) then return false end
    clear_recovery(tx)
    if tx.gear and not recovering then
        if (not tx.quest and not p:call("get_IsInTrainingArea")) or p:call("isWeaponOn") then return false,"Hunter has not returned to idle" end
        local difference=equipped_hunter.difference(tx.gear,equipped_hunter.read(pm,p,go))
        if difference then return false,difference end
    end
    return true
end

local function skeleton_ready(tx,p,resources,scene_components)
    local target=tx.shadow
    if not target then return true end
    if not tx.repair then
        if shadow_skeleton.matches(p,target.expected) then return true end
        local profiles={[target.sex]={[target.scope]={joints=target.expected}}}
        local fresh,reason=shadow_skeleton.capture(p,profiles)
        assert(fresh,reason)
        assert(resources[fresh.request],"Missing prepared skeleton: "..fresh.request)
        local parts={{go=fresh.root}}
        local chains=require("MHRS_HotReload.worn_chain").capture(
            scene_components("via.motion.Chain"),parts,{},{},{},{})
        assert(chains and chains:covers(parts[1]),"Cannot observe the rebuilt hunter's physics")
        tx.repair={candidates={},shadow=fresh,chains=chains}
    end
    local pending=require("MHRS_HotReload.worn_armor").advance(tx.repair,scene_components,resources)
    return not pending,"Waiting for the rebuilt hunter's rest skeleton"
end

local function location(tx)
    if tx.quest then return ("quest %d on map %d"):format(tx.quest.no,tx.quest.map) end
    if tx.gear then return "training area" end
    return "village area "..tx.area
end

function M.advance(tx,resources,scene_components)
    resources=resources or tx.resources
    local pm,p,go,training,quest=scene(tx.started and tx or nil)
    if tx.mount then
        local job=tx.mount
        if not tx.mount_error then
            local ok,pending=pcall(mounted.advance,job)
            if ok then
                if not pending then
                    tx.stable,tx.new_address=2,tx.old_address
                    tx.mount,current_mount=nil,nil
                    if log then log.info("[MHRS-Files-HotReload] Mounted and verified armor on existing hunter "..tx.old_address) end
                end
                return pending
            end
            tx.mount_error=(job.step or job.phase)..": "..tostring(pending)
            if log then log.warn("[MHRS-Files-HotReload] Armor mounting: "..tx.mount_error) end
        end
        local ok,pending=pcall(mounted.rollback,job)
        if not ok then
            if tx.full_outfit and not tx.reset_replay then
                M.abort(tx)
                return defer_mount(tx,"[normal equip] Pending worn part recovery "..tostring(job.step)..": "..tostring(pending))
            end
            error("[village changed] Worn part recovery "..tostring(job.step)..": "..tostring(pending))
        end
        if pending then return true end
        local rebased,why=pcall(mounted.rebase,job,tx)
        tx.mount,current_mount=nil,nil
        if tx.full_outfit and not tx.reset_replay then
            return defer_mount(tx,rebased and tx.mount_error or "[normal equip] "..tostring(why))
        end
        assert(rebased,why)
    end
    if not tx.started then
        local place,index,gear=ready(pm,p,go,training,quest)
        if not place or go~=tx.old or index~=tx.index or
                (tx.quest and not quest_context.same(tx.quest,quest)) or
                (not tx.quest and (quest or place:call("getCurrentAreaNo")~=tx.area)) then
            if tx.full_outfit and not tx.reset_replay then return defer_mount(tx,"Local hunter is no longer ready in "..location(tx)) end
            error("[village changed] Local hunter is no longer ready in "..location(tx))
        end
        if tx.gear then
            local changed=equipped_hunter.difference(tx.gear,gear)
            if changed then
                if tx.full_outfit and not tx.reset_replay then return defer_mount(tx,changed) end
                error("[village changed] "..changed.." ("..location(tx)..")")
            end
            tx.gear=gear
            tx.area_flag=p:call("get_AreaMoveFlag")
        end
        local unchanged,why=equipped_parts.unchanged(p,tx.parts)
        if not unchanged then
            if tx.full_outfit and not tx.reset_replay then return defer_mount(tx,why) end
            error("[village changed] "..why.." ("..location(tx)..")")
        end
        if tx.reset_replay then
            assert(M.replay_state(tx.reset_replay).id==tx.reset_replay,"[village changed] Reset recovery no longer belongs to this equipment")
        end
        if not tx.mount_attempted and not tx.reset_replay then
            tx.mount_attempted=true
            if tx.full_outfit and tx.missing_binding then return defer_mount(tx,"Waiting for all requested worn render components") end
            local ok,job=pcall(function()
                mounted=mounted or require("MHRS_HotReload.mounted_equipment")
                return mounted.capture(tx,pm,p,go,resources,scene_components)
            end)
            if ok and job then
                tx.mount,current_mount=job,tx
                return true
            elseif tx.full_outfit then return defer_mount(tx,tostring((tx.mount_blocked and tx.shadow_reason) or job or "Worn armor factory unavailable"))
            elseif not ok and log then log.info("[MHRS-Files-HotReload] Normal armor load: "..tostring(job)) end
        end
        assert(not tx.full_outfit or tx.reset_replay,"Full outfit requires an in-place mount")
        local eq=assert(sdk.get_managed_singleton("snow.data.EquipDataManager"))
        save_recovery(tx,pm)
        tx.started=true
        tx.deadline=os.clock()+(tx.quest and 9 or 7)
        request(eq,tx)
        if tx.reset_replay then
            saved_replay=nil;json.dump_file(mount_path,{})
            if log then log.info("[MHRS-Files-HotReload] Requested normal local hunter reconstruction after interrupted FirstNatives part assembly") end
        end
        return true
    end
    local resumed,reason=resume_hunter(tx,pm,p,go,quest)
    if resumed then
        local ready
        ready,reason=equipped_parts.ready(p,tx.parts,resources)
        if ready and not tx.skeleton_done then
            ready,reason=skeleton_ready(tx,p,resources,scene_components)
            if ready then tx.repair=nil;tx.skeleton_done=true end
        end
        if ready then
            tx.stable=(tx.stable or 0)+1
            return tx.stable<2
        end
        tx.stable=0
    end
    if os.clock()>=tx.deadline then
        error("[live equipment rejected] "..(reason or "Local hunter model not ready").." ("..location(tx)..")")
    end
    return true
end

function M.abort(tx)
    if tx.mount then
        cancelled_mount=tx.mount
        local j=cancelled_mount
        j.cancel_deadline=os.clock()+5
        local ok,record=pcall(mounted.reset_record,j,session_pid)
        if ok then j.cancel_record=record end
        tx.mount,current_mount=nil,nil
        return
    end
    if not tx.started then return end
    cancelled=tx
    tx.cancel_deadline=os.clock()+12
    if tx.repair then
        require("MHRS_HotReload.worn_armor").abort(tx.repair)
        tx.repair=nil
    end
end

local function recover_cancelled(j)
    local now=os.clock()
    if now>=j.cancel_deadline then
        local ok,why=pcall(mounted.release,j)
        if log then log.warn("[MHRS-Files-HotReload] Worn part recovery expired at "..tostring(j.step)
            ..(ok and "" or ": "..tostring(why))) end
        return false
    end
    if j.retry_at and now<j.retry_at then return true end
    local ok,pending
    if j.use_record then
        if not j.reconciled then
            ok,pending=pcall(mounted.recover_record,j.cancel_record)
            if ok and not pending then j.reconciled=true end
        end
        if j.reconciled then ok,pending=pcall(mounted.release,j) end
    else
        ok,pending=pcall(mounted.rollback,j)
    end
    if ok then return pending end
    if not j.cancel_warned and log then
        log.warn("[MHRS-Files-HotReload] Worn part recovery "..tostring(j.step)..": "..tostring(pending))
    end
    j.cancel_warned=true
    j.use_record=j.cancel_record~=nil
    j.retry_at=now+.15
    return true
end

re.on_application_entry("UpdateBehavior",function()
    if current_mount and current_mount.mount and current_mount.mount.retiring then
        local ok,why=pcall(mounted.repair_registry,current_mount.mount)
        if not ok and not current_mount.registry_warned then
            current_mount.registry_warned=true
            if log then log.warn("[MHRS-Files-HotReload] Pending armor registry "..tostring(current_mount.mount.step)..": "..tostring(why)) end
        end
    end
    if saved_mount then
        if os.time()>saved_mount.expires then saved_mount=nil;json.dump_file(mount_path,{})
        else
            mounted=mounted or require("MHRS_HotReload.mounted_equipment")
            local ok,pending,restored=pcall(mounted.recover_record,saved_mount)
            if ok and not pending then
                if restored and saved_mount.replay then saved_replay=saved_mount else json.dump_file(mount_path,{}) end
                saved_mount=nil
            end
        end
    end
    if cancelled_mount then
        if not recover_cancelled(cancelled_mount) then cancelled_mount=nil end
    end
    local tx=cancelled or saved_recovery
    if not tx then return end
    local pm,p,go,_,quest=scene(tx)
    if (tx.cancel_deadline and os.clock()>=tx.cancel_deadline) or
            (tx.expires and (os.time()>tx.expires or (pm and tostring(pm:get_address())~=tx.manager))) then
        clear_recovery(tx)
        cancelled=nil
    elseif resume_hunter(tx,pm,p,go,quest,true) then
        cancelled=nil
    end
end)

if re.on_script_reset then re.on_script_reset(function()
    local job=cancelled_mount or (current_mount and current_mount.mount)
    if not job then return end
    local ok,record=pcall(mounted.reset_record,job,session_pid)
    if ok and record then json.dump_file(mount_path,record) end
    pcall(mounted.reset_cleanup,job)
end) end

return M
