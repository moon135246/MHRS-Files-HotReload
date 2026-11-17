-- Reuse the ordinary local renderer and Chain transactions on each confirmed
-- teammate. A change to the whole costume is handled separately by the game.
local roster=require("MHRS_HotReload.hunter_roster")
local armor=require("MHRS_HotReload.worn_armor")
local chain=require("MHRS_HotReload.worn_chain")
local shadow=require("MHRS_HotReload.shadow_skeleton")
local M={}
local waiting,events={},{}
local next_check=0
local function item_key(item) return item.index..":"..item.slot..":"..item.path end

local function event(item,message)
    local tag=item_key(item)
    if not events[tag] or events[tag].status~=message then
        log.info(("[MHRS-Files-HotReload] Peer %d %s: %s"):format(item.index,item.path,message))
    end
    events[tag]={index=item.index,slot=item.slot,path=item.path,status=message}
end

local function independent(live)
    if not next(live) then return false end
    for path in pairs(live) do
        if not (path:match("^player/mod/[fm]/pl%d+/[^/]+%.chain$") or
            path:match("^player/mod/[fm]/[^/]+/[fm]_shadow%.mesh$")) then return false end
    end
    return true
end

local function split(components,actors)
    local by_root,other={},{}
    for _,e in pairs(actors.entries) do
        if e.role~="master" then by_root[e.root]={} end
    end
    for _,c in ipairs(components) do
        local ok,output=pcall(function()
            local owner=roster.owner(actors,c:call("get_GameObject"))
            if owner.role=="master" or owner.role=="scene" then return other end
            if owner.role=="peer" then return by_root[owner.root] end
            if owner.role=="outside" then
                local h=c:call("get_ChainAsset")
                local p=h and h:call("get_ResourcePath")
                if p and not p:lower():gsub("\\","/"):match("^@?player/mod/") then return other end
            end
        end)
        if ok and output then output[#output+1]=c end
    end
    return other,by_root
end

local function current_item(e,item)
    if not e.root:call("get_Draw") then return false end
    if item.slot==-1 then
        if not item.expected then return false end
        for slot=0,4 do
            local go=e.slots[slot]
            if (go and go:call("get_Name"))~=item.parts[slot] then return false,"equipped item changed" end
        end
        if not shadow.matches(e.player,item.expected) then return false end
        if item.changing then
            if not item.target then return false end
            local mesh=e.root:call("getComponent(System.Type)",sdk.typeof("via.render.Mesh"))
            local h=mesh and mesh:call("getMesh")
            if not h or tostring(h:read_qword(0x10))~=item.target then return false end
        end
        return true
    end
    local go=e.slots[item.slot]
    if not go or not go:call("get_Valid") or not go:call("get_Update") then return false end
    if go:call("get_Name")~=item.name then return false,"equipped item changed" end
    local stack,seen,matched={go:call("get_Transform")},{},0
    local td=sdk.typeof("via.motion.Chain")
    while #stack>0 do
        local tr=table.remove(stack)
        if seen[tr] then return false end
        seen[tr]=true
        local part=tr:call("get_GameObject")
        local c=part:call("getComponent(System.Type)",td)
        local h=c and c:call("get_ChainAsset")
        if h and h:call("get_ResourcePath"):lower():gsub("^@","")==item.path then
            matched=matched+1
            if item.groups==false or not item.target or tostring(h:read_qword(0x10))~=item.target
                or c:call("get_ResourceGroupCount")~=item.groups then return false end
            if c:call("get_Enabled") and (not c:call("get_Setuped") or c:call("getGroupCount")~=item.groups) then return false end
        end
        local child=tr:call("get_Child")
        while child do stack[#stack+1]=child;child=child:call("get_Next") end
    end
    return item.groups==false or matched>0
end

local function capture_actor(e,components,req,live,resources,add)
    local group={entry=e,items={}}
    local expected=req.physics and req.physics.chains or {}
    local seen,slot_by_go={},{}
    local function track(slot,p)
        if not p or not live[p] or expected[p]==nil then return end
        local k=slot..":"..p
        if seen[k] then return end
        seen[k]=true
        local item={index=e.index,guid=e.guid,slot=slot,path=p,name=e.slots[slot]:call("get_Name"),groups=expected[p]}
        group.items[#group.items+1]=item
        if type(item.groups)=="number" then add(p,"chain") end
    end
    for slot,go in pairs(e.slots) do
        slot_by_go[go]=slot
        local _,h=roster.render_part(go)
        local p=h and h:call("get_ResourcePath"):lower():gsub("^@",""):gsub("%.mesh$",".chain")
        track(slot,p)
    end
    for _,comp in ipairs(components) do
        local h=comp:call("get_ChainAsset")
        local p=h and h:call("get_ResourcePath"):lower():gsub("^@","")
        if p and live[p] and expected[p]~=nil then
            local tr=comp:call("get_GameObject"):call("get_Transform")
            while tr do
                local slot=slot_by_go[tr:call("get_GameObject")]
                if slot~=nil then track(slot,p);break end
                tr=tr:call("get_Parent")
            end
        end
    end
    local roots={}
    local picked
    if next(req.shadow_skeletons or {}) then
        local sex=({[0]="m",[1]="f"})[e.player:get_field("mSex")]
        if req.shadow_skeletons[sex] then
            local reason
            picked,reason=shadow.capture(e.player,req.shadow_skeletons)
            if picked and (live[picked.request] or (picked.suit_request and live[picked.suit_request])) then
                local item={index=e.index,guid=e.guid,slot=-1,path=picked.request,expected=picked.expected,parts={}}
                for slot,go in pairs(e.slots) do item.parts[slot]=go:call("get_Name") end
                group.items[#group.items+1]=item
                if picked.changed>0 then
                    roots[1]={go=e.root}
                    add(picked.request,"mesh")
                    if picked.request~=picked.canonical then add(picked.canonical,"mesh") end
                    item.changing=true
                else picked=nil end
            elseif not picked then
                for path in pairs(live) do
                    if path:match("^player/mod/"..sex.."/[^/]+/"..sex.."_shadow%.mesh$") then
                        event({index=e.index,slot=-1,path=path},"shadow layout unconfirmed: "..tostring(reason))
                    end
                end
            else picked=nil end
        end
    end
    if #group.items==0 then return end
    local chains=chain.capture(components,roots,expected,req.missing or {},resources,
        req.physics and req.physics.chain_terminals or {})
    local function owns(go)
        if e.player:call("get_GameObject")~=e.root then return false end
        local tr=go:call("get_Transform")
        local visited={}
        while tr and not visited[tr] do
            visited[tr]=true
            local obj=tr:call("get_GameObject")
            local slot=slot_by_go[obj]
            if slot~=nil then return e.player:call("getPartsGameObject",slot)==obj end
            if obj==e.root then return true end
            tr=tr:call("get_Parent")
        end
        return false
    end
    for _,row in ipairs(chains and chains.rows or {}) do row.wearer_owns=owns end
    if picked and not (chains and chains:covers(roots[1])) then picked=nil end
    if picked or chains then group.batch={candidates={},shadow=picked,chains=chains} end
    local refreshed={}
    for _,item in ipairs(group.items) do refreshed[item.slot]=true end
    for key,old in pairs(events) do
        if old.index==e.index and refreshed[old.slot] and not waiting[key] then events[key]=nil end
    end
    for _,item in ipairs(group.items) do
        item.scope=e.scope
        waiting[item_key(item)]=nil
        event(item,"awaiting renderer validation")
    end
    return group
end

function M.capture(components,req,live,resources,add)
    local groups={}
    local actors=roster.read()
    local other,by_root=split(components,actors)
    if not independent(live) then return groups,other,actors end
    for _,e in pairs(actors.by_index) do
        local ok,g=pcall(capture_actor,e,by_root[e.root],req,live,resources,add)
        if ok and g then groups[#groups+1]=g
        elseif not ok then log.warn("[MHRS-Files-HotReload] Peer "..e.index.." physics unavailable: "..tostring(g))
        end
    end
    return groups,other,actors
end

local function watch(item)
    waiting[item_key(item)]=item
    event(item,"awaiting normal equipment rebuild")
end

local function same_actor(actors,owner)
    local e=actors.by_index[owner.index]
    if e and actors.scope==owner.scope and e.guid==owner.guid and e.root==owner.root and e.player==owner.player then
        return e
    end
end

function M.advance(groups,ctx,resources,state,restore)
    if not groups or #groups==0 then return false end
    local actors=roster.read()
    local pending=false
    for _,g in ipairs(groups) do
        if not g.done then
            local owner=g.entry
            local e=same_actor(actors,owner)
            local same=e~=nil
            if same then
                for slot=0,4 do if e.slots[slot]~=owner.slots[slot] then same=false;break end end
            end
            for _,item in ipairs(g.items) do
                if not item.target and ((item.slot==-1 and item.changing) or type(item.groups)=="number") then
                    local target=resources[item.path]
                    item.target=target and tostring(target:get_address())
                end
            end
            local progress=false
            if g.batch and same then
                local ok,value=pcall(armor.advance,g.batch,ctx,resources,state,restore)
                progress=ok and value
                if not ok then log.warn("[MHRS-Files-HotReload] Peer "..owner.index.." physics: "..tostring(value)) end
            elseif g.batch and e then pcall(armor.abort,g.batch,restore) end
            if progress then pending=true
            else
                g.done=true
                for _,item in ipairs(g.items) do
                    if actors.scope~=item.scope then event(item,"scene changed")
                    elseif not same and actors.members[item.index]~=item.guid then event(item,"member left or slot changed")
                    else
                        local ok,verified=false,false
                        if same then ok,verified=pcall(current_item,e,item) end
                        if ok and verified then event(item,"verified on this client")
                        else watch(item) end
                    end
                end
            end
        end
    end
    return pending
end

function M.abort(groups,restore)
    local actors=groups and #groups>0 and roster.read()
    for _,g in ipairs(groups or {}) do
        if not g.done then
            if g.batch and same_actor(actors,g.entry) then pcall(armor.abort,g.batch,restore) end
            for _,item in ipairs(g.items) do event(item,"transaction cancelled") end
            g.done=true
        end
    end
end

function M.tick()
    if not next(waiting) or os.clock()<next_check then return end
    next_check=os.clock()+1
    local actors=roster.read()
    for k,item in pairs(waiting) do
        local e=actors.by_index[item.index]
        if actors.scope~=item.scope then
            event(item,"scene changed");waiting[k]=nil
        elseif actors.members[item.index]~=item.guid then
            event(item,"member left or slot changed");waiting[k]=nil
        elseif e and e.guid==item.guid then
            local ok,verified,reason=pcall(current_item,e,item)
            if ok and (verified or reason) then event(item,reason or "verified on this client");waiting[k]=nil end
        end
    end
end
function M.reset() waiting,events={},{} end
function M.status()
    local result={}
    for _,v in pairs(events) do result[#result+1]=v end
    return result
end
return M
