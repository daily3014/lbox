local last = globals.CurTime()

callbacks.Register("CreateMove", "MEDIC", function(cmd)
	local localPlayer = entities.GetLocalPlayer()
	if not localPlayer or not localPlayer:IsAlive() then
		return
	end

	local players = entities.FindByClass("CTFPlayer")
	for _, player in ipairs(players) do
		if player == localPlayer then goto continue end
		if player:GetTeamNumber() ~= localPlayer:GetTeamNumber() then goto continue end
		if player:IsDormant() then goto continue end

		local distance = (localPlayer:GetAbsOrigin() - player:GetAbsOrigin()):Length()
		if distance <= 1500 then
			if player:GetPropInt("m_PlayerClass", "m_iClass") == 5 then
				if localPlayer:GetHealth() < localPlayer:GetMaxHealth() then
					if globals.CurTime() - last > 2 then
						last = globals.CurTime()
						client.Command("voicemenu 0 0", true)
						break
					end
				end
			end
		end

		::continue::
	end
end)