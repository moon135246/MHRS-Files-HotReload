-- Promote the new Lua-visible holder explicitly. On Rise, create_holder_global
-- can return an already released wrapper with an empty resource pointer.
return function(resource, kind, pointer, current)
    local holder = resource:create_holder(kind)
    if not holder or holder:read_qword(0x10) ~= pointer
            or (current and current:get_address() == holder:get_address()) then
        return nil
    end
    holder:add_ref()
    if holder:read_qword(0x10) == pointer then return holder end
end
