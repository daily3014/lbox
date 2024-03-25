local chargePos
local lastChargedTicks = warp.GetChargedTicks()
local charging = false

callbacks.Register("PostPropUpdate", function()
	local localPlayer = entities.GetLocalPlayer()

	if not localPlayer then
		return
	end

	if warp.GetChargedTicks() > lastChargedTicks then
		if not charging then
			charging, chargePos = true, localPlayer:GetAbsOrigin()
			localPlayer:SetPropVector(Vector3(0, 0, 0), "localdata", "m_vecVelocity[0]")
		elseif chargePos then
			localPlayer:SetPropVector(Vector3(0, 0, 0), "localdata", "m_vecVelocity[0]")
			localPlayer:SetPropVector(chargePos, "tfnonlocaldata", "m_vecOrigin")
		end
	else
		if charging then
			localPlayer:SetPropVector(chargePos, "tfnonlocaldata", "m_vecOrigin")
			chargePos = nil
			charging = false
		end
	end

	lastChargedTicks = warp.GetChargedTicks()
end)

callbacks.Register("RenderView", "BetterCharge.ViewHook", function(viewSetup)
	local localPlayer = entities.GetLocalPlayer()
	if charging and chargePos and localPlayer then
		viewSetup.origin = chargePos + localPlayer:GetPropVector("localdata", "m_vecViewOffset[0]")
	end
end)