local M = {}
local callbacks = {}

local function update()
    for _, callback in ipairs(callbacks) do
        -- A failed job must not exit the shared REFramework callback list.
        local ok, reason = xpcall(callback, debug.traceback)
        if not ok then log.error("[MHRS-Files-HotReload] Game update: " .. tostring(reason)) end
    end
end

function M.register(callback)
    if #callbacks == 0 then
        re.on_application_entry("UpdateBehavior", update)
    end
    callbacks[#callbacks + 1] = callback
end

return M
