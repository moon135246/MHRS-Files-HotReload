-- Each local rendering of a teammate has an independent outcome. Never send
-- equipment requests to PlayerManager or forward input to another hunter.
local roster=require("MHRS_HotReload.hunter_roster")
local armor=require("MHRS_HotReload.worn_armor")
local shadow=require("MHRS_HotReload.shadow_skeleton")
local M={}
local waiting,known,latest={},{},{}
local next_check=0
local function report(task,status)
    if task.status~=status then
        task.status=status
        latest[task.index..":"..task.slot]={index=task.index,slot=task.slot,path=task.path,status=status}
        log.info(("[MHRS-Files-HotReload] Peer %d slot %d: %s (%s)"):format(
            task.index,task.slot,status,task.path))
    end
end
local function key(task) return task.index..":"..task.slot end
local function normalized(path) return path:lower():gsub("^@",""):gsub("\\","/") end

local function no_chain(root)
    local stack={root:call("get_Transform")}
    local seen={}
    local chain=sdk.typeof("via.motion.Chain")
    while #stack>0 do
        local tr=table.remove(stack)
        if seen[tr] then return false end
        seen[tr]=true
        local go=tr:call("get_GameObject")
        if not go or not go:call("get_Valid") or go:call("getComponent(System.Type)",chain) then return false end
        local child=tr:call("get_Child")
        while child do
            stack[#stack+1]=child
            child=child:call("get_Next")
        end
    end
    return true
end

function M.partition(candidates, live, req, prior)
    local tasks,receipt={},{}
    if not next(candidates) then return tasks,receipt end
    local actors=roster.read()
    local defer_member={}
    local geometry,physics=false,false
    for path in pairs(live) do
        if path:match("%.chain$") or path:match("/[fm]_shadow%.mesh$") then physics=true
        elseif path:match("%.mesh$") or path:match("%.mdf2$") then geometry=true end
    end
    for id,row in pairs(candidates) do
        local slot=actors.parts[row.go:get_address()]
        local holder=roster.owner(actors,row.go)
        if holder.role=="master" or holder.role=="scene" or (slot and holder.role=="peer") then
            row.wearer_owns=roster.guard(holder)
        end
        if holder.role~="master" and holder.role~="scene" then
            candidates[id]=nil
            if slot and holder.role=="peer" and (geometry or not physics) then
                local o=slot.entry
                local path=normalized(row.mesh.path)
                local mesh_change=live[path]==true
                row.mesh.keep=not mesh_change
                -- Track only the observed member, body part and resources.
                -- Comparison of the opaque membership token stays in memory.
                local task={owner=o,slot=slot.slot,index=o.index,guid=o.guid,scope=actors.scope,
                    path=path,mdf=normalized(row.mdf2.path),row=row,mesh_change=mesh_change,
                    part_name=row.go:call("get_Name"),material_names=row.expected}
                task.chain=path:gsub("%.mesh$",".chain")
                local chains=req.physics and req.physics.chains or {}
                task.groups=chains[task.chain]
                task.shadows=req.shadow_skeletons and next(req.shadow_skeletons) and req.shadow_skeletons or nil
                local direct=not mesh_change
                if mesh_change and (req.peer_meshes or {})[path] and not next(chains) and not task.shadows then
                    local old=known[path]
                    local layout=old and old[row.mesh.original] or (not old and prior(row,id))
                    local ok,clear=pcall(no_chain,o.root)
                    direct=layout and ok and clear
                end
                if not direct or (geometry and physics) then defer_member[o]=true
                else task.batch={candidates={[id]=row}} end
                tasks[#tasks+1]=task
            end
        end
    end
    for _,task in ipairs(tasks) do
        if defer_member[task.owner] then task.batch=nil end
        report(task,task.batch and "awaiting renderer validation" or "awaiting normal equipment rebuild")
        receipt[#receipt+1]=latest[key(task)]
    end
    return tasks,receipt
end

local function valid(task,actors)
    return roster.same(actors,task.owner,task.slot,task.row.go)
        and task.owner.root:call("get_Draw")
        and task.row.go:call("get_Valid") and task.row.go:call("get_Update")
        and roster.render_part(task.row.go)==task.row.comp
end

local function verify(task,e)
    local go=e.slots[task.slot]
    if not e.root:call("get_Draw") or not go or not go:call("get_Valid") or not go:call("get_Update") then return end
    if go:call("get_Name")~=task.part_name then return "equipped item changed" end
    local comp,mh,dh=roster.render_part(go)
    if not comp or not comp:call("get_MeshReady") or not comp:call("get_MaterialReady") then return end
    if normalized(mh:call("get_ResourcePath"))~=task.path or normalized(dh:call("get_ResourcePath"))~=task.mdf then
        return "equipped item changed"
    end
    local mesh_id=tostring(mh:read_qword(0x10))
    if (mesh_id~=task.mesh_target and mesh_id~=task.equivalent_mesh) or tostring(dh:read_qword(0x10))~=task.mdf_target then return end
    if task.material_names then
        if comp:call("get_MaterialNum")~=#task.material_names then return end
        for i,n in ipairs(task.material_names) do if comp:call("getMaterialName",i-1)~=n then return end end
    end
    if task.groups~=nil then
        local ch=go:call("getComponent(System.Type)",sdk.typeof("via.motion.Chain"))
        if task.groups==false then
            if ch and ch:call("get_ChainAsset") then return end
        else
            local h=ch and ch:call("get_ChainAsset")
            if not h or not task.chain_target or tostring(h:read_qword(0x10))~=task.chain_target
                or ch:call("get_ResourceGroupCount")~=task.groups then return end
            if ch:call("get_Enabled") and (not ch:call("get_Setuped") or ch:call("getGroupCount")~=task.groups) then return end
        end
    end
    if task.shadows then
        local sex=({[0]="m",[1]="f"})[e.player:get_field("mSex")]
        if task.shadows[sex] then
            local spec=shadow.capture(e.player,task.shadows)
            if not spec or not shadow.matches(e.player,spec.expected) then return end
        end
    end
    return "verified on this client"
end

local function defer(task)
    report(task,"awaiting normal equipment rebuild")
    -- Long-lived checks keep only plain values, never an obsolete actor/GO.
    task.row,task.owner,task.batch=nil,nil,nil
    waiting[key(task)]=task
end

function M.advance(tasks,ctx,resources,state,restore)
    if not tasks or #tasks==0 then return false end
    local actors=roster.read()
    local pending=false
    for _,t in ipairs(tasks) do
        if not t.done then
            local row=t.row
            local e=actors.by_index[t.index]
            local function target(path)
                local resource=resources[path]
                return resource and tostring(resource:get_address())
            end
            if not t.targets_read then
                t.targets_read=true
                if t.mesh_change then t.mesh_target=target(row.mesh.path)
                else
                    t.mesh_target=tostring(row.mesh.original)
                    t.equivalent_mesh=target(row.mesh.path)
                end
                t.mdf_target=target(row.mdf2.path)
                t.chain_target=target(t.chain)
                waiting[key(t)]=nil
            end
            if actors.scope~=t.scope then report(t,"scene changed");t.done=true
            elseif not e and actors.members[t.index]==t.guid then defer(t);t.done=true
            elseif not e or e.guid~=t.guid then
                report(t,"member left or slot changed")
                t.done=true
            elseif not t.batch then defer(t);t.done=true
            else
                local ok,result=pcall(function()
                    if not valid(t,actors) or (t.mesh_change and not no_chain(e.root)) then return "defer" end
                    if armor.advance(t.batch,ctx,resources,state,restore) then return "pending" end
                    return verify(t,e) or "defer"
                end)
                if ok and result=="pending" then pending=true
                else
                    -- armor.advance rolls back its own exceptions synchronously.
                    -- Once a member or part is replaced, do not write it again.
                    if ok and result=="verified on this client" then report(t,result) else defer(t) end
                    t.done=true
                end
            end
        end
    end
    return pending
end

function M.abort(tasks,restore)
    local actors=tasks and #tasks>0 and roster.read()
    for _,t in ipairs(tasks or {}) do
        if not t.done and t.batch and t.batch.touched then
            pcall(function() if valid(t,actors) and (not t.mesh_change or no_chain(t.owner.root)) then
                armor.abort(t.batch,restore)
            end end)
        end
    end
end

function M.generation(path,address,compatible)
    known[path]=compatible and {[address]=true} or {}
end

function M.tick()
    if not next(waiting) or os.clock()<next_check then return end
    next_check=os.clock()+1
    local actors=roster.read()
    for k,t in pairs(waiting) do
        local e=actors.by_index[t.index]
        if actors.scope~=t.scope then
            report(t,"scene changed");waiting[k]=nil
        elseif not e and actors.members[t.index]==t.guid then
            -- The same lobby member can temporarily have no equipment GO
            -- while the engine constructs its replacement.
        elseif not e or e.guid~=t.guid then
            report(t,"member left or slot changed");waiting[k]=nil
        else
            local ok,status=pcall(verify,t,e)
            if ok and status then report(t,status);waiting[k]=nil end
        end
    end
end
function M.status()
    local result={}
    for _,row in pairs(latest) do result[#result+1]=row end
    table.sort(result,function(a,b)
        if a.index==b.index then return a.slot<b.slot end
        return a.index<b.index
    end)
    return result
end
function M.reset() waiting,known,latest={},{},{} end
return M
