-- Change both resource holders on the existing render component in one game
-- update. Keep the previous pair until a later update verifies the renderer.
local M = {}
local extensions = {"mesh", "mdf2"}

local function address(holder)
    return holder and holder:read_qword(0x10)
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

function M.capture(comp, go, kinds, missing, resources, expected)
    local row = {comp=comp, go=go}
    for _, ext in ipairs(extensions) do
        local kind = kinds[ext]
        local holder = comp:call(kind[3])
        local path = holder and holder:call("get_ResourcePath")
        if not path or path == "" or missing[path:lower()] then return end
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
    return row.go:call("get_Valid") and row.comp:call("get_GameObject") == row.go
end

local function current(row, ext)
    return address(row.comp:call(row[ext].kind[3]))
end

local function restore(row, restore_when_ready)
    for _, ext in ipairs(extensions) do
        local slot = row[ext]
        assert(address(slot.old) == slot.original, "Rollback holder changed: " .. slot.path)
        if current(row, ext) ~= slot.original then row.comp:call(slot.kind[4], slot.old) end
    end
    assert(current(row, "mesh") == row.mesh.original and current(row, "mdf2") == row.mdf2.original,
        "Could not restore equipment holders")
    restore_when_ready({comp=row.comp, kind=row.mdf2.kind, switches=row.rollback_material})
end

function M.abort(batch, restore_when_ready, synchronous)
    local failures = {}
    if batch.physics then
        local ok,reason=pcall(batch.physics.abort,batch.physics)
        if not ok then failures[#failures+1]=tostring(reason) end
    end
    for i = #(batch.touched or {}), 1, -1 do
        local row = batch.touched[i]
        local ok, err = pcall(function()
            if not live(row) then return end
            -- After yielding, the game may have equipped a different item.
            -- Restore only a pair still owned by this transaction.
            if not synchronous then
                for _, ext in ipairs(extensions) do
                    local value, slot = current(row, ext), row[ext]
                    if value ~= slot.fresh and value ~= slot.original then return end
                end
            end
            restore(row, restore_when_ready)
        end)
        if not ok then failures[#failures+1] = tostring(err) end
    end
    batch.touched = nil
    assert(#failures == 0, table.concat(failures, " / "))
end

local function stage(batch, components, resources, material_state)
    local staged, holders = {}, {}
    for _, comp in ipairs(components) do
        local row = batch.candidates[comp:get_address()]
        if row and row.comp == comp and live(row) and row.go:call("get_Update")
                and current(row, "mesh") == row.mesh.original and current(row, "mdf2") == row.mdf2.original then
            for _, ext in ipairs(extensions) do
                local slot = row[ext]
                -- getMesh()/get_Material() can expose the component's mutable
                -- holder. A separately allocated holder takes its own strong
                -- resource reference and survives replacing that component.
                local current_holder = comp:call(slot.kind[3])
                local old_resource = assert(sdk.to_resource(sdk.to_ptr(slot.original)))
                slot.old = assert(old_resource:create_holder(slot.kind[2] .. "Holder"))
                assert(slot.old:get_address() ~= current_holder:get_address() and address(slot.old) == slot.original,
                    "Could not pin current equipment resource: " .. slot.path)
                local resource = assert(resources[slot.path], "Missing equipment resource: " .. slot.path)
                slot.fresh = resource:get_address()
                if not holders[slot.path] then
                    local canonical = assert(sdk.create_resource(slot.kind[2], slot.path))
                    local actual = canonical:get_address()
                    canonical:release()
                    assert(actual == slot.fresh, "Equipment resource changed: " .. slot.path)
                    holders[slot.path] = resource:create_holder(slot.kind[2] .. "Holder")
                end
                slot.holder = holders[slot.path]
                assert(address(slot.holder) == slot.fresh, "Incorrect equipment holder: " .. slot.path)
            end
            if comp:call("get_MaterialReady") then
                row.rollback_material = material_state(comp, true)
                row.switches = material_state(comp, false)
            end
            staged[#staged + 1] = row
        end
    end
    return staged
end

local function verify(row)
    local comp = row.comp
    if not live(row) or not row.go:call("get_Update") then return true end
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

function M.advance(batch, scene_components, resources, material_state, restore_when_ready)
    if not next(batch.candidates) and not batch.physics then return false end
    local synchronous = not batch.touched
    local ok, pending = pcall(function()
        if synchronous then
            local staged = next(batch.candidates) and
                stage(batch, scene_components("via.render.Mesh"), resources, material_state) or {}
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
            return #staged>0 or changed==true
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
        for _, row in ipairs(batch.touched) do
            if live(row) and row.go:call("get_Update") then
                restore_when_ready({comp=row.comp, kind=row.mdf2.kind, switches=row.switches})
            end
        end
        return false
    end)
    if not ok then
        local restored, failure = pcall(M.abort, batch, restore_when_ready, synchronous)
        error(restored and pending or (tostring(pending) .. "; rollback: " .. tostring(failure)))
    end
    return pending
end

return M
