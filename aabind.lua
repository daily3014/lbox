local toggleKey = KEY_E --https://lmaobox.net/lua/Lua_Constants/
local toggled = false

local function getAntiAimValue()
	return gui.GetValue("anti aim") == 0 and 1 or 0
end

callbacks.Register("CreateMove", function(cmd)
	if input.IsButtonDown(toggleKey) then
		if toggled then 
			return 
		end
		toggled = true
		gui.SetValue("anti aim", getAntiAimValue())
	else
		toggled = false
	end
end)