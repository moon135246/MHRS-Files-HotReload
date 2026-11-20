local M = {}
local equipped_parts = require("MHRS_HotReload.equipped_parts")
local equipped_hunter = require("MHRS_HotReload.equipped_hunter")
local quest_context = require("MHRS_HotReload.quest_context")
local game_update = require("MHRS_HotReload.game_update")
local mounted
local mesh_type = "via.render.Mesh"
local slots={0,1,2,3,4}
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

local function child(go,t)
    return go and go:call("getComponent(System.Type)",sdk.typeof(t))
end

local function path(holder)
    local name=holder and holder:call("get_ResourcePath")
    return name and name:lower():gsub("^@",""):gsub("\\","/")
end

local function scene(legacy)
    local pm=sdk.get_managed_singleton("snow.player.PlayerManager")
    local p=pm and pm:call("findMasterPlayer")
    local game=sdk.get_managed_singleton("snow.SnowGameManager")
    local status=game and game:call("getStatus")
    if not p then return end
    local td=p:get_type_definition()
    if status==1 then
        if td:get_full_name()=="snow.player.PlayerLobbyBase" or td:is_a("snow.player.PlayerLobbyBase") then
            return pm,p,p:call("get_GameObject")
        end
        if td:is_a("snow.player.PlayerQuestBase") then
            return pm,p,p:call("get_GameObject"),true
        end
    elseif status==2 and td:is_a("snow.player.PlayerQuestBase") then
        return pm,p,p:call("get_GameObject"),false,quest_context.read(legacy~=nil)
    end
end

local function ready(pm,p,go,training,quest)
    if saved_mount or cancelled_mount or saved_recovery or not go or not go:call("get_Valid") or not go:call("get_Draw") then return end
    local index=pm:call("getMasterPlayerID")
    if not pm:call("isReadyPlayer",index) or not p:call("isActivePlayer") or
            not p:call("isMasterPlayer") or p:call("getPlayerIndex")~=index then return end
    if quest and not quest.data then return end
    local place=quest or sdk.get_managed_singleton("snow.VillageAreaManager")
    if not place then return end
    if training or quest then
        local equipment=equipped_hunter.equip_indices(pm)
        if not equipment then return end
        return place,index,equipment
    end
    return place,index
end

-- Only copy identities from the master's five worn parts. A hidden preview,
-- another hunter, or a mesh with the same path in a new generation must
-- never authorize a deferred armor update. No holder or GO survives this call.
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
    local covered,known=0,0
    for _,i in ipairs(slots) do
        local part=p:call("getPartsGameObject",i)
        if part and part:call("get_Valid") then
            local mesh=child(part,mesh_type)
            local holder=mesh and mesh:call("getMesh")
            local key=path(holder)
            if key then known=known+1 end
            if key and (wanted[key] or wanted[key:gsub("%.mesh$",".mdf2")]) then
                covered=covered+1
                observed[key]=tostring(holder:read_qword(0x10))
                owners[key]=mesh:get_address()
                if part:call("get_Update") and mesh:call("get_MeshReady") and mesh:call("get_MaterialReady") then available[key]=true end
            end
        end
    end
    if complete and wait_factory and covered>0 then
        mounted=mounted or require("MHRS_HotReload.mounted_equipment")
        local ok,available_now=pcall(mounted.factories_available,pm,p,go,wanted)
        complete=ok and available_now
    end
    return {ready=complete and (known==5 or covered>0),slots_known=known==5,observed=observed,available=available,training=training,quest=quest~=nil,
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
        shadow=shadow,indices=gear,training=training,mount_blocked=mount_blocked,
        full_outfit=full,scope=scope(quest),missing_binding=missing_binding,shadow_reason=shadow_reason}
end

-- Drop the live transaction and let the host schedule a new attempt from
-- current files. Only scalar identities cross that boundary.
local function defer_mount(tx,reason)
    local wanted={}
    for _,s in ipairs(slots) do
        local row=tx.parts[s]
        if (tx.full_outfit or row.requested) and row.mesh then wanted[row.mesh]=true end
    end
    local state={observed={}}
    if not reason:find("[normal equip]",1,true) then state=M.worn_state(wanted) end
    local rediscover=not tx.reset_replay and
        not reason:find("[normal equip]",1,true) and (state.root~=tx.old_address or state.scope~=tx.scope)
    local retry=state.root==tx.old_address
        and state.scope==tx.scope and next(state.observed)~=nil
    if retry then
        for _,s in ipairs(slots) do
            local row=tx.parts[s]
            if wanted[row.mesh] and (not state.observed[row.mesh] or (row.before and state.observed[row.mesh]~=tostring(row.before))) then retry=false;break end
        end
    end
    tx.deferred_mount={retry=rediscover or retry==true,reason=reason,root=tx.old_address,scope=tx.scope,
        discover=rediscover or nil,partial=not tx.full_outfit,worn=rediscover and wanted or state.observed,
        wait_factory=reason:find("cold armor factory",1,true)~=nil}
    if log then log.info("[MHRS-Files-HotReload] "..(tx.deferred_mount.retry and "Waiting for in-place equipment: " or "Equipment deferred to natural equip: ")..reason) end
    return false
end

-- A model created outside the equipment menu starts without the old
-- hunter's area participation flag. It controls both rendering and input.
-- Finish only a same-process recovery receipt written by a previous plugin version.
local function resume_hunter(tx,pm,p,go,quest)
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
        json.dump_file(recovery_path,tx)
        return false
    end
    return go:call("get_Draw") and p:call("isActivePlayer") and p:call("isInput")
end

local function location(tx)
    if tx.quest then return ("quest %d on map %d"):format(tx.quest.no,tx.quest.map) end
    if tx.training then return "training area" end
    return "village area "..tx.area
end

function M.advance(tx,resources,scene_components)
    resources=resources or tx.resources
    local pm,p,go,training,quest=scene()
    if tx.mount then
        local job=tx.mount
        if not tx.mount_error then
            local ok,pending=pcall(mounted.advance,job)
            if ok then
                if not pending then
                    tx.stable,tx.new_address=2,tx.old_address
                    tx.mount,current_mount=nil,nil
                    if tx.reset_replay then saved_replay=nil;json.dump_file(mount_path,{}) end
                    if log then log.info("[MHRS-Files-HotReload] Mounted and verified armor on existing hunter "..tx.old_address) end
                end
                return pending
            end
            tx.mount_error=(job.step or job.phase)..": "..tostring(pending)
            if log then log.warn("[MHRS-Files-HotReload] Armor mounting: "..tx.mount_error) end
        end
        local ok,pending=pcall(mounted.rollback,job)
        if not ok then
            if not tx.reset_replay then
                M.abort(tx)
                return defer_mount(tx,"[normal equip] Pending worn part recovery "..tostring(job.step)..": "..tostring(pending))
            end
            error("[village changed] Worn part recovery "..tostring(job.step)..": "..tostring(pending))
        end
        if pending then return true end
        local rebased,why=pcall(mounted.rebase,job,tx)
        tx.mount,current_mount=nil,nil
        if not tx.reset_replay then
            return defer_mount(tx,rebased and tx.mount_error or "[normal equip] "..tostring(why))
        end
        error("[village changed] Reset part recovery: "..tostring(rebased and tx.mount_error or why))
    end
    local place,index,gear=ready(pm,p,go,training,quest)
    if not place or go~=tx.old or index~=tx.index or
            (tx.quest and not quest_context.same_instance(tx.quest,quest)) or
            (not tx.quest and (quest or place:call("getCurrentAreaNo")~=tx.area)) then
        if not tx.reset_replay then return defer_mount(tx,"Local hunter is no longer ready in "..location(tx)) end
        error("[village changed] Local hunter is no longer ready in "..location(tx))
    end
    if tx.indices and tx.indices~=gear then
        if not tx.reset_replay then return defer_mount(tx,"Equipment indices changed") end
        error("[village changed] Equipment indices changed")
    end
    local unchanged,why=equipped_parts.unchanged(p,tx.parts)
    if not unchanged then
        if not tx.reset_replay then return defer_mount(tx,why) end
        error("[village changed] "..why.." ("..location(tx)..")")
    end
    if tx.reset_replay then
        assert(M.replay_state(tx.reset_replay).id==tx.reset_replay,"[village changed] Reset recovery no longer belongs to this equipment")
    end
    if tx.full_outfit and tx.missing_binding and not tx.reset_replay then return defer_mount(tx,"Waiting for all requested worn render components") end
    mounted=mounted or require("MHRS_HotReload.mounted_equipment")
    local ok,job=pcall(mounted.capture,tx,pm,p,go,resources,scene_components)
    if ok and job then
        tx.mount,current_mount=job,tx
        return true
    end
    local reason=tostring((tx.mount_blocked and tx.shadow_reason) or job or "Worn armor factory unavailable")
    if tx.reset_replay then error("[village changed] Reset part recovery: "..reason) end
    return defer_mount(tx,reason)
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

game_update.register(function()
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
    local tx=saved_recovery
    if not tx then return end
    local pm,p,go,_,quest=scene(tx)
    if os.time()>tx.expires or (pm and tostring(pm:get_address())~=tx.manager) or resume_hunter(tx,pm,p,go,quest) then
        json.dump_file(recovery_path,{})
        saved_recovery=nil
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
