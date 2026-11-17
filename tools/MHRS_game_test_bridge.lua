-- Installed separately for developer testing. The player DLL does not load this bridge.
if _G.MHRS_game_test_bridge then return end
local dir="MHRS-Game-Test/"
local request_path=dir.."request.json"
local initial=json.load_file(request_path)
local previous=initial and initial.id
local next_poll,next_sample=0,0
local tracing=false
local rows,dropped,last={},0,nil

local function call(obj,method,...)
    if not obj then return end
    local ok,value=pcall(obj.call,obj,method,...)
    if ok then return value end
end

local function sample()
    local gm=sdk.get_managed_singleton("snow.SnowGameManager")
    local vm=sdk.get_managed_singleton("snow.VillageAreaManager")
    local qm=sdk.get_managed_singleton("snow.QuestManager")
    local pm=sdk.get_managed_singleton("snow.player.PlayerManager")
    local gui=sdk.get_managed_singleton("snow.gui.GuiManager")
    local p=call(pm,"findMasterPlayer")
    local root=call(p,"get_GameObject")
    local quest=call(qm,"getQuestNo")
    local map=call(qm,"getMapNo")
    local status=call(gm,"getStatus")
    local area=call(vm,"getCurrentAreaNo")
    local s={game=status,area=area,village_idle=call(vm,"isIdle"),quest=quest,map=map,
        phase=call(qm,"getStatus"),elapsed=call(qm,"getQuestElapsedTimeSec"),
        ordered=call(gui,"isQuestOrderReceived"),start_demo=call(qm,"isQuestStartEventDemo"),
        interrupt_demo=call(qm,"isQuestInterruptEventDemo"),
        demo_count=call(call(qm,"getQuestStartEventDemoList"),"get_Count"),
        all_players_loaded=call(pm,"isReadyPlayerLoadState"),input_locked=call(gui,"IsPlayerAllInputDisable"),
        hunter_present=false,ready_parts=0,parts={}}
    if status==1 and area then s.scope="village/"..area end
    if status==2 then
        local data=call(qm,"getActiveQuestData")
        if data and quest and map then s.scope=("quest/%d/%d/%s"):format(quest,map,tostring(data:get_address())) end
    end
    if not call(root,"get_Valid") then return s end
    s.hunter_present=true
    s.hunter=tostring(root:get_address())
    s.class=p:get_type_definition():get_full_name()
    s.draw=call(root,"get_Draw")
    s.input=call(p,"isInput")
    s.active=call(p,"isActivePlayer")
    local mesh_type=sdk.typeof("via.render.Mesh")
    for slot=0,4 do
        local go=call(p,"getPartsGameObject",slot)
        if call(go,"get_Valid") then
            local mesh=call(go,"getComponent(System.Type)",mesh_type)
            local ready=call(mesh,"get_MeshReady") and call(mesh,"get_MaterialReady")
            if ready then s.ready_parts=s.ready_parts+1 end
            s.parts[#s.parts+1]={slot=slot,ready=ready,object=tostring(go:get_address()),
                mesh=call(call(mesh,"getMesh"),"get_ResourcePath"),updating=call(go,"get_Update")}
        end
    end
    return s
end

local trace_keys={"game","scope","area","village_idle","quest","map","phase","ordered","start_demo",
    "interrupt_demo","demo_count","all_players_loaded","input_locked","hunter","draw","active","input","ready_parts"}
local function record()
    local state=sample()
    local values={}
    for i,k in ipairs(trace_keys) do values[i]=tostring(state[k]) end
    local key=table.concat(values,"|")
    if key==last then return end
    last=key
    state.parts=nil
    state.time=os.time()
    state.tick=os.clock()
    if #rows==256 then table.remove(rows,1);dropped=dropped+1 end
    rows[#rows+1]=state
end

local function run(r)
    if r.action=="state" then return sample() end
    if r.action=="trace" then
        if r.mode=="start" then
            if not tracing then rows,dropped,last={},0,nil;record();tracing=true end
        elseif r.mode=="stop" then
            if tracing then record();tracing=false end
        else assert(r.mode=="read","Unknown trace action") end
        return {recording=tracing,rows=rows,dropped=dropped}
    end
    assert(r.action=="depart" or r.action=="return" or r.action=="travel","Unknown test action")
    local state=sample()
    assert(state.hunter_present and state.draw and state.hunter==r.hunter and state.scope==r.scope
        and (r.action=="travel" or (state.quest==r.quest and r.quest>0)),"Hunter, scene or quest changed")
    local roster=require("MHRS_HotReload.hunter_roster").read()
    local e=roster.entries[1]
    assert(e and #roster.entries==1 and e.role=="master" and roster.scope==state.scope
        and tostring(e.root:get_address())==state.hunter,"Solo local hunter required")
    for index in pairs(roster.members) do assert(index==e.index,"Another player is present") end
    if r.action=="travel" then
        local area=r.destination
        assert(type(area)=="number" and area%1==0 and area>=0 and area<=5 and area~=state.area,"Unknown or current village area")
        assert(state.game==1 and state.village_idle and state.input and not state.input_locked,"Village hunter is busy")
        local field=sdk.find_type_definition("snow.stage.StageDef.VillageFastTravelType"):get_field(("v01a0%d_00"):format(area))
        sdk.get_managed_singleton("snow.VillageAreaManager"):call("fastTravel",assert(field):get_data(nil))
        return {requested="travel",origin=state.area,destination=area,hunter=state.hunter}
    elseif r.action=="depart" then
        assert(state.game==1 and state.village_idle and state.ordered,"Accept a quest at the counter first")
        local gui=sdk.get_managed_singleton("snow.gui.GuiManager")
        local handler=assert(gui:call("get_refQuestStartFlowHandler"),"Departure unavailable")
        assert(not handler:call("isExecute"),"Departure already in progress")
        handler:call("requestGoQuest",false)
    else
        local qm=sdk.get_managed_singleton("snow.QuestManager")
        local gui=sdk.get_managed_singleton("snow.gui.GuiManager")
        assert(state.game==2 and state.phase==2 and state.active and state.input and not state.input_locked
            and not e.player:call("isDie") and not qm:call("isPhaseResult") and not qm:call("isWaitQuestEnd")
            and not gui:call("IsStartMenuAndSubmenuOpen"),"Wait for control of the local hunter")
        qm:call(qm:call("isTourQuest") and "notifyTourReturn" or "notifyReturn")
    end
    return {requested=r.action,quest=state.quest,hunter=state.hunter,scope=state.scope}
end

re.on_application_entry("UpdateBehavior",function()
    local now=os.clock()
    if tracing and now>=next_sample then
        next_sample=now+0.1
        local ok,err=pcall(record)
        if not ok then tracing=false;log.error("[MHRS game test] "..tostring(err)) end
    end
    if now<next_poll then return end
    next_poll=now+0.2
    local r=json.load_file(request_path)
    if type(r)~="table" or type(r.id)~="string" or #r.id~=32 or not r.id:match("^%x+$") or r.id==previous then return end
    previous=r.id
    local ok,result=pcall(function()
        assert(type(r.expires)=="number" and os.time()<=r.expires,"Test request expired")
        return run(r)
    end)
    json.dump_file(dir.."status.json",{id=r.id,ok=ok,result=ok and result or tostring(result)})
end)
_G.MHRS_game_test_bridge=true
