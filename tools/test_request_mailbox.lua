package.path = "reframework/autorun/?.lua;" .. package.path

local phases, executed, responses = {}, {}, {}
local now, raw, unreadable, dirty = 0, "initial", false, false
local reads = 0
local requests = {
    initial = {id="initial", action="asset_inspect"},
    lost = {id="lost", action="asset_material_links"},
    retry = {id="retry", action="asset_peer_meshes"},
    remove = {id="remove", action="asset_removed"},
    next = {id="next", action="asset_inspect"},
}
local noop = function() end
os.clock = function() return now end
io.open = function(name, mode)
    assert(name == "MHRS-Files-HotReload/request.json" and mode == "rb")
    reads = reads + 1
    if not unreadable then return {read=function() return raw end, close=noop} end
end
json = {
    load_string=function(value) return assert(requests[value]) end,
    dump_file=function(_, status) responses[#responses + 1] = status end,
}
re = {
    on_application_entry=function(phase, callback) phases[phase] = callback end,
    on_script_reset=noop,
}
log = {info=noop, warn=error, error=error}
sdk = {typeof=noop}
package.loaded["MHRS_HotReload.arm_mdf"] = {}
package.loaded["MHRS_HotReload.lua_bone_system"] = {install=noop}
package.loaded["MHRS_HotReload.village_equipment"] = {install=noop}
local scan_finished = false
package.loaded["MHRS_HotReload.outfit"] = {
    start_equipment_loads=noop,
    begin_texture_scan=function() return {} end,
    advance_texture_scan=function() if scan_finished then return {} end end,
    run=function(_, request)
        executed[#executed + 1] = request.id
        return {}
    end,
}
assert(loadfile("reframework/autorun/MHRS_Files_HotReload.lua"))({
    request_changed=function()
        local value = dirty
        dirty = false
        return value
    end,
    start_watcher=function() return true end,
    close_request_watch=noop,
})
local function frame(time)
    now = time
    phases.UpdateBehavior()
end

frame(0)
assert(#executed == 0, "Replayed a request left over from the previous session")
local before_idle = reads
raw = "lost"
for i=1,90 do frame(i/100) end
assert(#executed == 0 and reads == before_idle, "Idle notifications should not read the mailbox")
frame(1)
assert(executed[1] == "lost" and responses[2].id == "lost")

raw, unreadable, dirty = "retry", true, true
frame(1.01)
assert(reads == before_idle + 2 and #executed == 1, "Did not check the notification on the next update")
unreadable = false
frame(1.07)
assert(#executed == 2 and executed[2] == "retry" and responses[3].id == "retry")

raw, dirty = "remove", true
frame(1.09)
assert(#executed == 2)
raw, scan_finished, dirty = "next", true, true
frame(1.10)
frame(1.11)
assert(#executed == 3 and executed[3] == "next" and responses[4].id == "next")

raw, scan_finished, dirty = "remove", false, true
frame(1.2)
unreadable, scan_finished = true, true
frame(1.21)
assert(#executed == 3)
unreadable = false
frame(1.22)
assert(#executed == 4 and executed[4] == "remove" and responses[5].id == "remove")
frame(2.3)
assert(#responses == 5)
print("Mailbox wakes on the next update, stays idle without I/O, and reconciles lost or partial messages")
