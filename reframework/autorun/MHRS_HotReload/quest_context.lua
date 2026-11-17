-- The VillageAreaManager can keep its old area number throughout a hunt.
-- Identify a live mission from its own manager and stage.
local M={}

function M.read()
    local qm=sdk.get_managed_singleton("snow.QuestManager")
    if not qm then return {} end
    local no,map=qm:call("getQuestNo"),qm:call("getMapNo")
    local active=qm:call("getActiveQuestData")
    if not active or type(no)~="number" or no<=0 or type(map)~="number" then return {} end
    local status=qm:call("getStatus")
    return {manager=tostring(qm:get_address()),data=tostring(active:get_address()),no=no,map=map,
        status=status,elapsed=qm:call("getQuestElapsedTimeSec"),
        playable=status==2 and not (qm:call("isQuestReset") or qm:call("isQuestTimeOver") or qm:call("isWaitQuestEnd") or
            qm:call("isPhaseResult") or qm:call("isQuestStartEventDemo") or qm:call("isQuestInterruptEventDemo"))}
end

function M.same_instance(before,now)
    return now and before.data and before.manager==now.manager and before.data==now.data and
        before.no==now.no and before.map==now.map
end

function M.same(before,now)
    return M.same_instance(before,now) and before.status==now.status and
        type(before.elapsed)=="number" and type(now.elapsed)=="number" and now.elapsed>=before.elapsed-0.5
end

function M.available(q,p)
    return q.playable and p and not (p:call("get_IsInTrainingArea") or p:call("isDie") or
        p:call("get_IsMarionetteAction") or p:call("get_IsAimModeAction") or
        p:call("isFrozenReaction") or p:call("isFloatingReaction") or p:call("get_IsDuringSlipDamage"))
end

return M
