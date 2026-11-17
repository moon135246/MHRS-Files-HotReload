-- Apply the worn FirstNatives rest skeleton before Rise creates any new
-- armor parts. Use the same reversible root/physics transaction as a
-- standalone shadow save. No worn renderer participates in this transaction.
local shadow=require("MHRS_HotReload.shadow_skeleton")
local chain=require("MHRS_HotReload.worn_chain")
local armor=require("MHRS_HotReload.worn_armor")
local elements=require("MHRS_HotReload.array_elements")
local M={}
local slots={body=0,arm=1,wst=2,leg=3,helm=4}

local function below(go,root)
    local t=go:call("get_Transform")
    local seen={}
    while t and not seen[t] do
        if t:call("get_GameObject")==root then return true end
        seen[t]=true
        t=t:call("get_Parent")
    end
    return false
end

-- During a village transition a scene-wide CHAIN query can include
-- despawning NPCs. Only the live hunter's Transform tree can own a chain
-- affected by changing this root mesh. Include secondary components and
-- descendants, not just the five slots' primary CHAIN references.
local function simulations(target)
    local components,seen={},{}
    local function collect(tr)
        local go=assert(tr:call("get_GameObject"))
        local id=go:get_address()
        assert(not seen[id] and go:call("get_Valid"),"Hunter attachment changed during CHAIN inspection")
        seen[id]=true
        local list=assert(go:call("get_Components"),"Hunter GameObject component array unavailable")
        for _,c in pairs(elements(list,"hunter components")) do
            if c:get_type_definition():is_a("via.motion.Chain") then components[#components+1]=c end
        end
        local child=tr:call("get_Child")
        while child do collect(child);child=child:call("get_Next") end
    end
    collect(target.tr)
    return components
end

function M.begin(target,resources,scene_components)
    if not target then return nil end
    local pm=assert(sdk.get_managed_singleton("snow.player.PlayerManager"))
    local player=target.player
    local function owner()
        return pm:call("findMasterPlayer")==player and player:call("get_GameObject")==target.root
            and target.root:call("get_Valid") and target.root:call("get_Transform")==target.tr
    end
    assert(owner(),"Shadow belongs to another hunter")
    local profiles={[target.sex]={[target.scope]={joints=target.expected}}}
    -- Resource preloading can span multiple game updates. Capture the actual
    -- previous rest now, while the original five parts still own their slots.
    local fresh,why=shadow.capture(player,profiles)
    assert(fresh,why)
    assert(fresh.scope==target.scope and fresh.suit_request==target.suit_request,"Worn shadow selection changed")
    if fresh.changed==0 then return nil end
    assert(resources[fresh.request],"Missing prepared shadow source: "..fresh.request)
    local worn={}
    for slot=0,4 do worn[slot]=assert(player:call("getPartsGameObject",slot)) end
    local function only_worn()
        local child=target.tr:call("get_Child")
        while child do
            local go=child:call("get_GameObject")
            local part=go:call("get_Name"):lower():match("^[fm]_([a-z]+)%d+$")
            local slot=slots[part]
            if slot and worn[slot]~=go then return false end
            child=child:call("get_Next")
        end
        return true
    end
    assert(only_worn(),"An unregistered armor part is still attached to the hunter")
    fresh.owns_root=function()
        if not owner() then return false end
        for slot=0,4 do if player:call("getPartsGameObject",slot)~=worn[slot] then return false end end
        return true
    end
    local root_part={go=target.root}
    local chains=chain.capture(simulations(target),{root_part},{},{},{},{})
    assert(chains and chains:covers(root_part),"Could not capture physics attached to the original hunter")
    local captured={}
    for _,row in ipairs(chains.rows) do
        captured[row.comp]=row
        row.wearer_owns=function(go) return target.root:call("get_Valid") and below(go,target.root) end
    end
    local function same_chains()
        if not chains:covers(root_part) or not only_worn() then return false end
        local count=0
        for _,c in ipairs(simulations(target)) do
            local go=c:call("get_GameObject")
            if go and go:call("get_Valid") and below(go,target.root) then
                local row=captured[c]
                local h=c:call("get_ChainAsset")
                if not row or row.go~=go or not h or h:read_qword(0x10)~=row.original then return false end
                count=count+1
            end
        end
        return count==#chains.rows
    end
    local function paused()
        if not same_chains() then return false end
        for _,row in ipairs(chains.rows) do
            if not row.paused or not row.comp:call("get_FreezePose") then return false end
        end
        return true
    end
    fresh.can_change=paused
    local batch={candidates={},shadow=fresh,chains=chains}
    return {batch=batch,resources=resources,scene_components=scene_components}
end

function M.advance(state)
    if not state then return false end
    local b=state.batch
    assert(b.shadow.owns_root(),"Hunter or registered parts changed before the shadow update")
    local paused,ready,bound,resumed=b.chains_paused,b.shadow_ready,b.chain_bound,b.chain_resumed
    local stable=b.chains.stable
    local pending=armor.advance(b,state.scene_components,state.resources)
    -- A completed transition needs one independent game update. Loading
    -- the root MESH and waiting for actual motion/CHAIN readiness can take
    -- longer and keep the worker's normal background polling interval.
    local next_update=b.chains_paused~=paused or b.shadow_ready~=ready or b.chain_bound~=bound
        or b.chain_resumed~=resumed or (stable==0 and b.chains.stable==1)
    return pending,pending and not b.aborted and next_update
end

-- The owner calls this after its newly created parts are gone and the five
-- original slots restored. UpdateBehavior performs any pending rest readback
-- before resuming the old physics, even if the file worker is cancelled.
function M.abort(state)
    if not state then return false end
    local b=state.batch
    armor.abort(b)
    if armor.recovery_pending(b) then return true end
    assert(not b.rollback_error,b.rollback_error)
    if b.shadow.owner then
        assert(b.shadow.owns_root() and shadow.matches(b.shadow.player,b.shadow.previous),
            "Previous hunter rest is no longer owned or verified; ordinary equipment load required")
    end
    return false
end

return M
