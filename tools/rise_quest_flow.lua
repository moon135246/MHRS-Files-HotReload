-- Local QA only. The host first observes the current hunter and scene, then
-- requests the game's normal departure or return for that same solo session.
if _G.MHRS_game_qa_quest_flow then return end
_G.MHRS_game_qa_quest_flow = true
local prefix = "MHRS-Files-HotReload/qa-quest-flow-"
local roster = require("MHRS_HotReload.hunter_roster")
local maps = {[101]=1, [308]=3}
local previous = (json.load_file(prefix.."request.json") or {}).id
local next_poll = 0

local function run(request)
    local pm = sdk.get_managed_singleton("snow.player.PlayerManager")
    local p = assert(pm:call("findMasterPlayer"), "Local hunter is unavailable")
    local current = roster.read()
    local entry = current.entries[1]
    assert(entry and #current.entries == 1 and entry.role == "master" and entry.player == p and
        entry.root == p:call("get_GameObject") and entry.root:call("get_Valid") and entry.root:call("get_Draw") and
        p:call("isMasterPlayer") and entry.index == pm:call("getMasterPlayerID"), "Solo local hunter required")
    for i in pairs(current.members) do assert(i == entry.index, "Another player is present") end
    local qm = sdk.get_managed_singleton("snow.QuestManager")
    local gui = sdk.get_managed_singleton("snow.gui.GuiManager")
    local gm = sdk.get_managed_singleton("snow.SnowGameManager")
    local state = {hunter=tostring(entry.root:get_address()), scope=current.scope, quest=qm:call("getQuestNo")}
    if request.action == "inspect" then return state end
    assert(request.hunter == state.hunter and request.scope == state.scope and
        maps[request.quest] and request.quest == state.quest, "Hunter, scene or quest changed")
    if request.action == "depart" then
        local vm = sdk.get_managed_singleton("snow.VillageAreaManager")
        assert(gm:call("getStatus") == 1 and vm:call("isIdle") and state.scope == "village/0" and
            gui:call("isQuestOrderReceived"), "Accept the village quest at Hinoa first")
        local handler = assert(gui:call("get_refQuestStartFlowHandler"), "Departure is unavailable")
        assert(not handler:call("isExecute"), "Departure already in progress")
        handler:call("requestGoQuest", false)
    else
        assert(request.action == "return", "Unsupported quest action")
        assert(gm:call("getStatus") == 2 and qm:call("getMapNo") == maps[state.quest] and
            qm:call("getStatus") == 2 and not qm:call("isPhaseResult") and not qm:call("isWaitQuestEnd") and
            p:call("isActivePlayer") and p:call("isInput") and not p:call("isDie") and
            not gui:call("IsPlayerAllInputDisable") and not gui:call("IsStartMenuAndSubmenuOpen"),
            "Wait for the hunter to be controllable and close the game menus")
        assert(qm:call("isTourQuest") == (state.quest == 101), "Unexpected quest type")
        if state.quest == 101 then qm:call("notifyTourReturn") else qm:call("notifyReturn") end
    end
    state.requested = request.action
    return state
end

re.on_application_entry("UpdateBehavior", function()
    if os.clock() < next_poll then return end
    next_poll = os.clock() + .2
    local request = json.load_file(prefix.."request.json")
    if type(request) ~= "table" or type(request.id) ~= "string" or #request.id ~= 32 or
        not request.id:match("^%x+$") or request.id == previous then return end
    previous = request.id
    local ok, result = pcall(run, request)
    json.dump_file(prefix.."reply.json", {id=previous, ok=ok, data=ok and result or nil,
        error=not ok and tostring(result) or nil})
end)
