--[[
    Custom Aimbot for Lmaobox
    Author: github.com/lnx00
]]

if UnloadLib then UnloadLib() end

---@alias AimTarget { entity : Entity, angles : EulerAngles, factor : number }

---@type boolean, lnxLib
local libLoaded, lnxLib = pcall(require, "lnxLib")
assert(libLoaded, "lnxLib not found, please install it!")
assert(lnxLib.GetVersion() >= 0.987, "lnxLib version is too old, please update it!")

local Math, Conversion = lnxLib.Utils.Math, lnxLib.Utils.Conversion
local WPlayer, WWeapon = lnxLib.TF2.WPlayer, lnxLib.TF2.WWeapon
local Helpers = lnxLib.TF2.Helpers
local Fonts = lnxLib.UI.Fonts
local simulationTimes = {}


local Hitbox = {
    Head = 1,
    Neck = 2,
    Pelvis = 4,
    Body = 5,
    Chest = 7
}

local options = {
    AimKey = MOUSE_MIDDLE,
    AutoShoot = true,
    Silent = true,
    AimPos = { Hitscan = Hitbox.Body },
    AimFov = 40,
    DebugInfo = true
}

local latency = 0
local lerp = 0

local function clamp(value, min, max)
	if value < min then return min end
	if value > max then return max end

	return value
end

local function getNextPredictedChoke(chokedPackets)
	if chokedPackets == 0 then
		return 1
	end

	return 22
	--return clamp(chokedPackets + math.random(-3, 6), 3, 22)
end

local env = physics.CreateEnvironment()
env:SetGravity(physics.DefaultEnvironment():GetGravity())
env:SetAirDensity(physics.DefaultEnvironment():GetAirDensity())
env:SetSimulationTimestep(globals.TickInterval())

local solid, collisionModel = physics.ParseModelByName("models/player/scout.mdl")
local simulatedPlayer = env:CreatePolyObject(collisionModel, solid:GetSurfacePropName(), solid:GetObjectParameters())

local function predictPlayerPosition(player, ticks)
	simulatedPlayer:Wake()
	
	simulatedPlayer:SetPosition(player:GetAbsOrigin(), Vector3(0, 0, 0), true)
	simulatedPlayer:SetVelocity(player:EstimateAbsVelocity(), Vector3(0, 0, 0))

	local tickInteval = globals.TickInterval()
	local simulationEnd = env:GetSimulationTime() + ticks * globals.TickInterval()

	while env:GetSimulationTime() < simulationEnd do
		env:Simulate(tickInteval)
	end

	local playerEndPosition = simulatedPlayer:GetPosition()

	env:ResetSimulationClock()

	return playerEndPosition
end

local function getHitboxPos(player)
	local aimPos = player:GetHitboxPos(options.AimPos.Hitscan)
	if not simulationTimes[player] then print("0") return aimPos end

	local playerSimulationData = simulationTimes[player]

	if playerSimulationData.lastMovementTick == globals.TickCount() then
		print("1")
		return aimPos
	end

	if globals.TickCount() ~= playerSimulationData.nextTick then
		print("2")
		return aimPos
	end
	
	local predictedPosition = predictPlayerPosition(player, playerSimulationData.nextTickRaw)
	predictedPosition.z = aimPos.z

	warn("3")
	return predictedPosition
end

-- Finds the best position for hitscan weapons
---@param me WPlayer
---@param weapon WWeapon
---@param player WPlayer
---@return AimTarget?
local function CheckHitscanTarget(me, weapon, player)

    local aimPos = getHitboxPos(player)
    if not aimPos then return nil end
    local angles = Math.PositionAngles(me:GetEyePos(), aimPos)
    local fov = Math.AngleFov(angles, engine.GetViewAngles())

    if not Helpers.VisPos(player:Unwrap(), me:GetEyePos(), aimPos) then return nil end

    local target = { entity = player, angles = angles, factor = fov }
    return target
end

-- Checks the given target for the given weapon
---@param me WPlayer
---@param weapon WWeapon
---@param entity Entity
---@return AimTarget?
local function CheckTarget(me, weapon, entity)
    if not entity then return nil end
    if not entity:IsAlive() then return nil end
    if entity:GetTeamNumber() == me:GetTeamNumber() then return nil end

    local player = WPlayer.FromEntity(entity)

    -- FOV check
    local angles = Math.PositionAngles(me:GetEyePos(), player:GetAbsOrigin())
    local fov = Math.AngleFov(angles, engine.GetViewAngles())
    if fov > options.AimFov then return nil end

    if weapon:IsShootingWeapon() then
        local projType = weapon:GetWeaponProjectileType()

        if projType == 1 then
            return CheckHitscanTarget(me, weapon, player)
        end
    elseif weapon:IsMeleeWeapon() then
        -- TODO: Melee Aimbot
    end

    return nil
end

-- Returns the best target for the given weapon
---@param me WPlayer
---@param weapon WWeapon
---@return AimTarget? target
local function GetBestTarget(me, weapon)
    local players = entities.FindByClass("CTFPlayer")
    local bestTarget = nil
    local bestFactor = math.huge

    -- Check all players
    for _, entity in pairs(players) do
		local targetSimulationData = simulationTimes[entity]
		if targetSimulationData then
			if targetSimulationData.nextTick then
				if globals.TickCount() ~= data.nextTick then
					goto continue
				end
			end
		end

        local target = CheckTarget(me, weapon, entity)
        if not target then goto continue end

        if target.factor < bestFactor then
            bestFactor = target.factor
            bestTarget = target
        end

        break

        ::continue::
    end

    return bestTarget
end



---@param userCmd UserCmd
local function OnCreateMove(userCmd)
    if not input.IsButtonDown(options.AimKey) then return end

    local me = WPlayer.GetLocal()
    if not me or not me:IsAlive() then return end

    local weapon = me:GetActiveWeapon()
    if not weapon then return end
    if weapon:GetWeaponProjectileType() ~= 1 then return end

    -- Get current latency
    local latIn, latOut = clientstate.GetLatencyIn(), clientstate.GetLatencyOut()
    latency = (latIn or 0) + (latOut or 0)

    -- Get current lerp
    lerp = client.GetConVar("cl_interp") or 0

    -- Get the best target
    local currentTarget = GetBestTarget(me, weapon)
    if not currentTarget then return end

    -- Aim at the target
    userCmd:SetViewAngles(currentTarget.angles:Unpack())
    if not options.Silent then
        engine.SetViewAngles(currentTarget.angles)
    end

    -- Auto Shoot
    if options.AutoShoot then
        if weapon:GetWeaponID() ~= TF_WEAPON_COMPOUND_BOW and weapon:GetWeaponID() ~= TF_WEAPON_PIPEBOMBLAUNCHER then
            userCmd.buttons = userCmd.buttons | IN_ATTACK
        end
    end
end

local function OnDraw()
    if not options.DebugInfo then return end

    draw.SetFont(Fonts.Verdana)
    draw.Color(255, 255, 255, 255)

    -- Draw current latency and lerp
    draw.Text(20, 140, string.format("Latency: %.2f", latency))
    draw.Text(20, 160, string.format("Lerp: %.2f", lerp))

    local me = WPlayer.GetLocal()
    if not me or not me:IsAlive() then return end

    local weapon = me:GetActiveWeapon()
    if not weapon then return end

    -- Draw current weapon
    draw.Text(20, 180, string.format("Weapon: %s", weapon:GetName()))
    draw.Text(20, 200, string.format("Weapon ID: %d", weapon:GetWeaponID()))
    draw.Text(20, 220, string.format("Weapon DefIndex: %d", weapon:GetDefIndex()))
end

callbacks.Unregister("CreateMove", "LNX.Aimbot.CreateMove")
callbacks.Register("CreateMove", "LNX.Aimbot.CreateMove", OnCreateMove)
callbacks.Register("CreateMove", "Aimbot.Fakelag", function()
	for entity, data in pairs(simulationTimes) do
		local currentSimulationTime = entity:GetPropFloat("m_flSimulationTime")

		if not data.lastSimulationTime then
			goto continue
		end

		if data.lastSimulationTime == currentSimulationTime then
			if not data.lastSimulationWasSame then
				data.lastSimulationWasSame = true
				data.fakeLagStartTick = globals.TickCount()
			end

			local last = data.consecutiveSimulationTimes or 0
			data.consecutiveSimulationTimes = last + 1
		else
			data.lastMovementTick = globals.TickCount()
			local chokedPackets = data.consecutiveSimulationTimes

			data.consecutiveSimulationTimes = 0
			data.lastSimulationWasSame = false
			data.fakeLagStartTick = 0

			if chokedPackets then
				local nextTick = getNextPredictedChoke(chokedPackets)

				data.nextTickRaw = nextTick
				data.nextTick = globals.TickCount() + nextTick
			end
		end

		::continue::
		data.lastSimulationTime = currentSimulationTime
	end

	local players = entities.FindByClass("CTFPlayer")

    for idx, entity in pairs(players) do
        if not entity then goto continue end
        if entity:GetTeamNumber() == entities.GetLocalPlayer():GetTeamNumber() then goto continue end

		if not simulationTimes[entity] then
			simulationTimes[entity] = { lastSimulationWasSame = false, nextTick = 0, fakeLagStartTick = 0, isUsingFakeLag = false, lastChokedPackets = {}, fakeLag = false }
		end

		::continue::
	end
end)


callbacks.Unregister("Draw", "LNX.Aimbot.Draw")
callbacks.Register("Draw", "LNX.Aimbot.Draw", OnDraw)