-- Included inside the v2 pose fix, sharing its profile, player and IK caches.
local manifest_path = "MHRS-Files-HotReload/bone-profiles.json"
local next_notice, notice_bytes, revision = 0, nil, 0
local manifest, changed_at, loaded_at, checked_at, retries = nil, {}, {}, {}, {}
local zero_position = {x=0, y=0, z=0}

local function read_bytes(path)
    local f = io.open(path, "rb")
    if not f then return end
    local bytes = f:read("*a")
    f:close()
    return bytes
end

local function receive_profiles()
    local now = os.clock()
    if now < next_notice then return end
    next_notice = now + 0.55
    local pending = retries
    retries = {}
    local bytes = read_bytes(manifest_path)
    if bytes and bytes ~= notice_bytes then
        local ok, data = pcall(json.load_string, bytes)
        if ok and type(data) == "table" and data.version == 1 and type(data.profiles) == "table" then
            local fresh = data.profiles
            for name, hash in pairs(fresh) do
                if not manifest or manifest[name] ~= hash then pending[name] = true end
            end
            for key in pairs(manifest or import_joint_data) do
                local name = key:lower()
                if not fresh[name] then pending[name] = true end
            end
            manifest, notice_bytes = fresh, bytes
        end
    end
    if next(pending) then
        revision = revision + 1
        for name in pairs(pending) do changed_at[name] = revision end
    end
end

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function load_profile(name)
    local key = name:lower()
    local generation = changed_at[key] or 0
    if loaded_at[name] == generation then return import_joint_data[name] end
    if manifest and changed_at[key] and not manifest[key] then
        loaded_at[name], import_joint_data[name] = generation, nil
        return
    end
    if name:find("[/\\:]") then return end
    local raw = read_bytes(custom_dir .. name .. ".json")
    if raw then
        local ok, profile = pcall(json.load_string, raw)
        if ok and type(profile) == "table" and next(profile) then
            for _, v in pairs(profile) do
                if type(v) ~= "table" or not (finite(v.x) and finite(v.y) and finite(v.z)) then
                    ok = false
                    break
                end
            end
            if ok then
                loaded_at[name], import_joint_data[name] = generation, profile
                return profile
            end
        end
    end
    -- An installer may replace the file between the watcher publishing the
    -- manifest and this read. Keep the valid pose and retry at notice cadence.
    if manifest and manifest[key] then retries[key] = true end
    return import_joint_data[name]
end

local function refresh_player_profile(index, transform, current_parts, part_changed)
    local since = checked_at[index] or 0
    local changed = false
    if revision > since then
        for _, obj in pairs(current_parts) do
            if (changed_at[obj:get_Name():lower()] or 0) > since then changed = true; break end
        end
        checked_at[index] = revision
    end
    if not part_changed and not changed then return end
    local before = player_joint[index]
    local chosen = nil
    -- Preserve the v2 system's existing outfit selection order.
    for _, obj in pairs(current_parts) do
        local name = obj:get_Name()
        if load_profile(name) then chosen = name; break end
    end
    player_joint[index] = chosen
    if changed or before ~= chosen then
        local prefix = tostring(transform:get_address()) .. ":"
        ik_initialized[index] = nil
        ik_pending[prefix .. tostring(before)] = nil
        ik_pending[prefix .. tostring(chosen)] = nil
        if changed and log and log.info then
            local digest = chosen and manifest and manifest[chosen:lower()]
            log.info("[LuaBoneSystem] Refreshed player " .. tostring(index) .. " pose " ..
                     tostring(chosen or "stock") .. (digest and (" " .. digest) or ""))
        end
    end
end
