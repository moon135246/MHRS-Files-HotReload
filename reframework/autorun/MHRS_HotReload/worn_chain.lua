-- The renderer and the chain on a worn part share its joint hierarchy.
-- Hold the simulation across a whole engine update before replacing that
-- hierarchy. The caller resumes only after the replacement mesh is ready.
local M = {}
local array_elements = require("MHRS_HotReload.array_elements")
local retain_holder = require("MHRS_HotReload.retained_holder")
local Chain = {}
Chain.__index = Chain
local resource_type = "via.motion.ChainResource"
local holder_type = resource_type .. "Holder"

local function pointer(holder)
    return holder and holder:read_qword(0x10)
end

local function current(row)
    return pointer(row.comp:call("get_ChainAsset"))
end

local function live(row)
    return row.go:call("get_Valid") and row.comp:call("get_GameObject")==row.go
        and (not row.wearer_owns or row.wearer_owns(row.go))
end

local function owned(row)
    if not live(row) then return false end
    local id = current(row)
    return id == row.original or id == row.fresh
end

local function freeze(row, value)
    if row.comp:call("get_FreezePose") ~= value then
        row.comp:call("set_FreezePose", value)
        assert(row.comp:call("get_FreezePose") == value, "Could not freeze or resume Chain: " .. row.path)
    end
end

-- A CHAIN on a worn renderer can only bind to that renderer or its
-- attachment hierarchy. Other equipment can reuse the same names.
local function check_joints(row, resources)
    if not row.terminals then return end
    local mesh = row.go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
    local current_mesh = mesh and mesh:call("getMesh")
    local target = current_mesh
    if current_mesh and resources then
        local res = resources[current_mesh:call("get_ResourcePath")]
        if res and res:get_address() ~= pointer(current_mesh) then
            target = assert(res:create_holder("via.render.MeshResourceHolder"))
        end
    end
    local names = {}
    if target then
        local list = mesh:call("getJointNameList", target)
        if list then
            local joint_names = array_elements(list,"equipment mesh joints")
            for _,name in pairs(joint_names) do
                names[type(name) == "string" and name or name:call("ToString()")] = true
            end
        end
    end
    for _,name in ipairs(row.terminals) do
        if not names[name] then
            local tr = row.go:call("get_Transform")
            -- Never satisfy a prospective new mesh with the old mesh's joints.
            if target ~= current_mesh then tr = tr:call("get_Parent") end
            while tr and not tr:call("getJointByName(System.String)",name) do tr = tr:call("get_Parent") end
            assert(tr, "Incompatible CHAIN terminal " .. name .. " for " .. row.path)
        end
    end
end

-- Map each part and its children to their render owners. A nested equipment
-- part can belong to more than one renderer. Only mark a subtree covered
-- when its hierarchy and each attached chain can be inspected.
local function subtrees(candidates)
    local members,covered = {},{}
    for _,part in pairs(candidates) do
        local key = part.go:get_address()
        if covered[key] == nil then
            local seen = {}
            local function visit(tr)
                local go = tr:call("get_GameObject")
                local id = go:get_address()
                assert(not seen[id], "Equipment hierarchy changed")
                seen[id] = true
                members[id] = members[id] or {}
                members[id][key] = true
                local child = tr:call("get_Child")
                while child do
                    visit(child)
                    child = child:call("get_Next")
                end
            end
            covered[key] = pcall(function() visit(part.go:call("get_Transform")) end)
        end
    end
    return members,covered
end

function M.capture(components, candidates, expected, missing, requests, terminals)
    local members,covered = subtrees(candidates)
    local rows = {}
    for _,comp in ipairs(components) do
        local go = comp:call("get_GameObject")
        if go and go:call("get_Valid") then
            local owners = members[go:get_address()]
            local holder = comp:call("get_ChainAsset")
            local path = holder and holder:call("get_ResourcePath")
            local key = path and path:lower()
            local groups = key and expected[key]
            local ptr = pointer(holder)
            if owners or (groups ~= nil and key:match("^player/mod/[fm]/pl%d+/")) then
                if not go:call("get_Update") or not key or missing[key] or not ptr or ptr == 0 or groups == false then
                    for owner in pairs(owners or {}) do covered[owner] = false end
                else
                    local old
                    if groups ~= nil then
                        local resource = assert(sdk.to_resource(sdk.to_ptr(ptr)))
                        old = assert(retain_holder(resource,holder_type,ptr,holder),
                            "Could not retain independent chain holder: " .. path)
                        requests[path] = resource_type
                    end
                    rows[#rows+1] = {comp=comp,go=go,path=path,original=ptr,old=old,groups=groups,owners=owners,
                                     terminals=terminals and terminals[key]}
                end
            end
        end
    end
    return (#rows > 0 or next(covered)) and setmetatable({rows=rows,covered=covered,stable=0}, Chain) or nil
end

function Chain:covers(part)
    return self.covered[part.go:get_address()] == true
end

function Chain:stage(resources)
    for _,row in ipairs(self.rows) do
        self.current_path=row.path
        if live(row) and current(row) == row.original then
            row.enabled = row.comp:call("get_Enabled")
            row.frozen = row.comp:call("get_FreezePose")
            assert(type(row.enabled) == "boolean", "Unknown chain enable state: " .. row.path)
            assert(type(row.frozen) == "boolean", "Unknown chain freeze state: " .. row.path)
            check_joints(row, resources)
            if row.old then
                local res = assert(resources[row.path], "Missing chain resource: " .. row.path)
                row.fresh = res:get_address()
                row.new = assert(retain_holder(res,holder_type,row.fresh), "Incorrect replacement chain: " .. row.path)
            else
                row.groups = row.comp:call("get_ResourceGroupCount")
                assert(type(row.groups) == "number", "Cannot verify current chain: " .. row.path)
                row.fresh = row.original
            end
        else
            for owner in pairs(row.owners or {}) do self.covered[owner] = false end
        end
    end
end

function Chain:pause()
    for _,row in ipairs(self.rows) do
        self.current_path=row.path
        if row.enabled ~= nil and live(row) and current(row) == row.original then
            row.paused = true -- record ownership before a possibly failing setter
            if row.owners then freeze(row, true) end
        end
    end
end

function Chain:bind()
    -- Validate every part before the first setter so a partial outfit
    -- copy cannot bind a foreign terminal, even on a different row.
    for _,row in ipairs(self.rows) do
        self.current_path=row.path
        if row.paused and owned(row) then check_joints(row) end
    end
    for _,row in ipairs(self.rows) do
        self.current_path=row.path
        if row.paused and owned(row) then
            if row.owners then
                assert(row.comp:call("get_FreezePose"), "Chain resumed during equipment change: " .. row.path)
            end
            if row.new and current(row) ~= row.fresh then
                assert(pointer(row.new) == row.fresh and pointer(row.old) == row.original,
                    "Chain holder changed before binding: " .. row.path)
                row.assigned = true
                row.comp:call("set_ChainAsset", row.new)
                assert(current(row) == row.fresh, "Could not bind worn chain: " .. row.path)
            end
        end
    end
end

function Chain:resume()
    for _,row in ipairs(self.rows) do
        self.current_path=row.path
        if row.paused and row.owners and owned(row) then
            freeze(row, row.frozen)
        end
    end
end

function Chain:verify()
    for _,row in ipairs(self.rows) do
        self.current_path=row.path
        if row.paused and live(row) then
            local id = current(row)
            -- A replacement supplied by a later real equip owns the part.
            if id == row.original or id == row.fresh then
                if row.comp:call("get_Enabled") ~= row.enabled or row.comp:call("get_FreezePose") ~= row.frozen then
                    self.stable = 0
                    return false, "Chain enable state changed: " .. row.path
                end
                local running = row.enabled and row.go:call("get_Update")
                if id ~= row.fresh or row.comp:call("get_ResourceGroupCount") ~= row.groups or
                        (running and (not row.comp:call("get_Setuped") or row.comp:call("getGroupCount") ~= row.groups)) then
                    self.stable = 0
                    return false, "Chain groups are not ready after equipment change: " .. row.path
                end
                if row.assigned and running and not row.frozen and not row.reset then
                    row.comp:call("resetInertia")
                    row.reset = true
                end
            end
        end
    end
    self.stable = self.stable + 1
    return self.stable >= 2, "Waiting for another simulation update"
end

-- Guard every row independently. A failed restore on one component should
-- not leave the remaining parts paused when a transfer is cancelled.
local function restore_each(rows, action)
    local failures = {}
    for i=#rows,1,-1 do
        local row = rows[i]
        if row.paused then
            local ok, err = pcall(action,row)
            if not ok then failures[#failures+1] = tostring(err) end
        end
    end
    assert(#failures == 0, table.concat(failures," / "))
end

function Chain:suspend_for_rollback()
    restore_each(self.rows,function(row)
        if row.owners and owned(row) then freeze(row,true) end
    end)
end

function Chain:rollback()
    restore_each(self.rows,function(row)
        local restored, restore_error = pcall(function()
            if row.assigned and owned(row) and current(row) ~= row.original then
                assert(pointer(row.old) == row.original, "Original chain holder changed: " .. row.path)
                row.comp:call("set_ChainAsset", row.old)
                assert(current(row) == row.original, "Could not restore chain: " .. row.path)
            end
        end)
        local resumed, resume_error = pcall(function()
            if row.owners and owned(row) then freeze(row,row.frozen) end
        end)
        row.paused = false
        if not restored and not resumed then error(tostring(restore_error) .. " / " .. tostring(resume_error)) end
        assert(resumed,resume_error)
        assert(restored,restore_error)
    end)
end

return M
