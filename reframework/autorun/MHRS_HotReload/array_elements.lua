-- REFramework may return a Lua table, a typed array wrapper, or a regular
-- managed System.Array object. Copy the last representation before yielding.
return function(objects,label)
    if not objects then return {} end
    if objects.get_elements then return objects:get_elements() end
    if type(objects)=="table" then return objects end
    local td=objects:get_type_definition()
    local get=td:is_a("System.Array") and td:get_method("Get(System.Int32)")
    assert(get,"Unable to enumerate "..label)
    local result={}
    for i=0,objects:call("get_Length")-1 do
        local element=get:call(objects,i)
        if element then result[#result+1]=element end
    end
    return result
end
