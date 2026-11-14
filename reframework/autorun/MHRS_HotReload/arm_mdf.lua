-- Read the physical Rise loose file with the game's file API. The snapshot in
-- REFramework's data directory can then be opened by the Lua standard library.
local M = {}
local source = "natives/stm/player/mod/f/pl279/f_arm279.mdf2.23"
local snapshot = "MHRS-Files-HotReload/arm279-snapshot.bin"
local keys = {"S_col_R", "moon_RimColor"}
local session

local function read_file()
    local file = sdk.find_type_definition("via.io.file")
    assert(file:get_method("copy"):call(nil, source, "reframework/data/" .. snapshot), "Could not read " .. source)
    local f = assert(io.open(snapshot, "rb"))
    local bytes = f:read("*a")
    f:close()
    assert(bytes and bytes:sub(1, 4) == "MDF\0", "Invalid MDF header")
    return bytes
end

local function unpack_at(bytes, format, offset)
    assert(offset >= 0 and offset <= #bytes - string.packsize(format), "MDF field outside file")
    return (string.unpack(format, bytes, offset + 1))
end

local function wide(bytes, offset)
    local chars = {}
    while true do
        local u = unpack_at(bytes, "<I2", offset)
        if u == 0 then return table.concat(chars) end
        offset = offset + 2
        if u >= 0xD800 and u <= 0xDBFF then
            local v = unpack_at(bytes, "<I2", offset)
            assert(v >= 0xDC00 and v <= 0xDFFF, "Invalid MDF name")
            u, offset = 0x10000 + (u - 0xD800) * 1024 + v - 0xDC00, offset + 2
        end
        chars[#chars + 1] = utf8.char(u)
    end
end

local function materials(bytes)
    local out = {}
    local count = unpack_at(bytes, "<I2", 6)
    assert(count > 0 and 16 + count * 80 <= #bytes, "Invalid MDF material table")
    for i = 0, count - 1 do
        local h = 16 + i * 80
        local name = wide(bytes, unpack_at(bytes, "<I8", h))
        local n = unpack_at(bytes, "<I4", h + 16)
        local tab = unpack_at(bytes, "<I8", h + 40)
        local block = unpack_at(bytes, "<I8", h + 64)
        local block_size = unpack_at(bytes, "<I4", h + 12)
        assert(not out[name] and tab >= 0 and tab <= #bytes - n * 24
            and block >= 0 and block <= #bytes - block_size, "Invalid MDF material")
        local props = {}
        for j = 0, n - 1 do
            local p = tab + j * 24
            local key = wide(bytes, unpack_at(bytes, "<I8", p))
            if key == keys[1] or key == keys[2] then
                local rel = unpack_at(bytes, "<I4", p + 16)
                assert(not props[key] and unpack_at(bytes, "<I4", p + 20) == 4
                    and rel <= block_size - 16, "Invalid MDF color")
                local x, y, z, w = string.unpack("<ffff", bytes, block + rel + 1)
                for _, v in ipairs({x, y, z, w}) do assert(math.abs(v) < math.huge, "Non-finite MDF color") end
                props[key] = {x, y, z, w}
            end
        end
        out[name] = props
    end
    return out
end

local function equal(a, b)
    return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] and a[4] == b[4]
end

function M.begin(mesh, live)
    local disk = materials(read_file())
    local entries = {}
    for i, slot in ipairs(live.slots) do
        local props = assert(disk[slot.name], "Material slot missing from file")
        local indices = {}
        for j = 0, mesh:call("getMaterialVariableNum", i-1) - 1 do
            indices[mesh:call("getMaterialVariableName", i-1, j)] = j
        end
        for _, key in ipairs(keys) do
            local idx = indices[key]
            assert(idx and live.slots[i][key] and props[key] and
                mesh:call("getMaterialVariableType", i-1, idx) == 4, "Color binding unavailable: " .. key)
            entries[#entries + 1] = {slot=i-1, name=slot.name, key=key, index=idx,
                original=props[key], previous=props[key], live=slot[key]}
        end
    end
    assert(#entries > 0, "Empty arm mesh")
    session = {mesh=live.mesh, entries=entries, count=#live.slots}
    return {bindings=#entries}
end

function M.refresh(mesh, live)
    assert(session and session.mesh == live.mesh and session.count == #live.slots,
        "Capture the current arm before editing the MDF")
    local disk = materials(read_file())
    local pending = {}
    for _, e in ipairs(session.entries) do
        local slot = live.slots[e.slot+1]
        assert(slot.name == e.name and mesh:call("getMaterialVariableName", e.slot, e.index) == e.key,
            "Arm material layout changed")
        local value = assert(disk[e.name] and disk[e.name][e.key], "Missing MDF color")
        if not equal(value, e.previous) then
            local target = equal(value, e.original) and e.live or value
            pending[#pending+1] = {entry=e, value=value, target=target, before=slot[e.key]}
        end
    end
    local applied = 0
    local function set(p, value)
        mesh:call("setMaterialFloat4", p.entry.slot, p.entry.index, Vector4f.new(table.unpack(value)))
    end
    local ok, err = pcall(function()
        for i, p in ipairs(pending) do set(p, p.target); applied = i end
    end)
    if not ok then
        for i = applied, 1, -1 do set(pending[i], pending[i].before) end
        error(err)
    end
    for _, p in ipairs(pending) do p.entry.previous = p.value end
    return {changed=#pending}
end

return M
