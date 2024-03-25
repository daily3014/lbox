local function dump(msg)
	local bytes = {}
    for i = 1, #msg do
        local byte = string.byte(msg, i)
        bytes[i] = string.format("%02X", byte)
    end

    print(table.concat(bytes, " "))
end

local function subMsg(data, len, start)
	local msg = ""
	for i = 0, len-1 do
		if #data < start+i then break end
		msg = msg .. string.format("%02x", string.byte(data:sub(start+i, start+i)))
	end
	return msg
end

callbacks.Unregister("GCRetrieveMessage", "catt_gc_recv")
callbacks.Register("GCRetrieveMessage", "catt_gc_recv", function(typeID, data)
	if typeID == 6563 then
		if subMsg(data, 5, 22) == "0137363137" or subMsg(data, 4, 23) == "37363137" then
			return E_GCResults.k_EGCResultNoMessage
		else
			print(dump(data))
		end
	end

	return E_GCResults.k_EGCResultOK
end)