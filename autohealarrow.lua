local config = {
	debug = true,

	announceInChat = true, -- announces when it tries to heal arrow in chat with reason

	controlAimbot = true, -- disable aimbot when not shooting crossbow
	minimumHealthLostToHeal = 70, -- minimum health lost before it tries to heal arrow

	criticalHeal = true, -- heal regardless of circumstances if healing target is very low hp
	runLogic = true, -- run logic before trying to heal arrow
	onlyVaccinator = true, -- only try to heal arrow if you're using vaccinator

	autoVaccinator = {
		lookForwardTicks = 0, -- check for dangers in the future, set to 0 to disable
		requireHealingTarget = false, -- only run auto vaccinator if you're healing someone

		projectileCheck = {
			ticksToSimulate = 20, -- how many ticks to simulate and check for
		},

		ignoreSeverity = {
			false, -- ignore threats with severity low
			false, -- ignore threats with severity medium
			false, -- ignore threats with severity high
		},

		checkForProjectiles = true, -- check for projectiles
		checkForEnemies = true, -- check for enemies
	},

	ignoreWhileUbercharged = true, -- don't try to heal arrow if you're ubercharged
	ignoreAboveChargeMeter = 80, -- don't try to heal arrow if you're using a regular medigun and charge meter is above threshold

	healingCooldownTime = 1.2, -- cooldown before shooting another heal arrow, if you use vaccinator, it will wait 150% of the current cooldown time
}

local scriptName = "AutoHealArrow"
local registeredCallbacks = {}
local unloads = {}

local CROSSBOW_ITEMINDEX = 305
local VACCINATOR_ITEMINDEX = 998
local ROCKETJUMPER_ITEMINDEX = 237
local STICKYJUMPER_ITEMINDEX = 265
local HUNTSMAN_INDEX = TF_WEAPON_COMPOUND_BOW or 61
local STICKYLAUNCHER_INDEX = TF_WEAPON_PIPEBOMBLAUNCHER or 24
local GRENADELAUNCHER_INDEX = TF_WEAPON_GRENADELAUNCHER or 23
local LOOSECANNON_INDEX = TF_WEAPON_CANNON or 91

---@enum ResistTypes
local RESIST_TYPES = {
	AMMO_RESIST = 0,
	BLAST_RESIST = 1,
	FIRE_RESIST = 2
}

---@enum Severity
local severityEnums = {
    LOW = 0,
    MEDIUM = 1,
    HIGH = 2
}


local distanceCheck = {
	default = 100,

	[TF2_Heavy] = 150,
	[TF2_Scout] = 150,

	[TF2_Sniper] = 70,
}

local damageReceived = {}

local M_RADPI = 180 / math.pi

local lastPop = 0
local lastChargeMeter = 0
local lastCharge = 0
local resistSwitchCooldown = 0

local aimbotKey
local healingCooldown = 0

local lastCommand = globals.TickCount()
local switchBack = false
local tryingToShoot = false
local shootTarget = nil
local currentHealingTarget = nil

local lastConsecutiveShots = {}

---@param callbackID string
---@param identifier string
---@param func function
local function addCallback(callbackID, identifier, func)
	assert(registeredCallbacks[identifier] == nil and unloads[identifier] == nil, "A callback with this identifier was already registered")

	if callbackID == "Unload" then
		unloads[identifier] = func
		return
	end

	local fullIdentifier = ("%s.%s"):format(scriptName, identifier)
	callbacks.Unregister(callbackID, fullIdentifier)
	callbacks.Register(callbackID, fullIdentifier, func)

	registeredCallbacks[identifier] = callbackID
end

callbacks.Register("Unload", "AutoHealArrow.Unload", function()
	for _, unloadFunc in pairs(unloads) do
		coroutine.wrap(unloadFunc)()
	end

	for identifier, id in pairs(registeredCallbacks) do
		local fullIdentifier = ("%s.%s"):format(scriptName, identifier)
		callbacks.Unregister(id, fullIdentifier)
	end

	registeredCallbacks = {}
	unloads = {}
end)

-- Multiples two vectors
---@param a Vector3
---@param b Vector3
---@return Vector3 multiplied_vector
local function vectorMulitply(a, b)
	return Vector3(a.x * b.x, a.y * b.y, a.z * b.z)
end

---@param msg string
local function announce(msg)
	client.ChatPrintf(string.format("\x073475c9[Auto Heal Arrow] \x01%s", msg))
end

-- returns whether the number is NaN
---@param x number
---@return boolean
local function isNaN(x)
	return x ~= x
end

-- Calculates the angle between two vectors
---@param source Vector3
---@param dest Vector3
---@return EulerAngles angles
local function positionAngles(source, dest)
    local delta = source - dest

    local pitch = math.atan(delta.z / delta:Length2D()) * M_RADPI
    local yaw = math.atan(delta.y / delta.x) * M_RADPI

    if delta.x >= 0 then
        yaw = yaw + 180
    end

    if isNaN(pitch) then pitch = 0 end
    if isNaN(yaw) then yaw = 0 end

    return EulerAngles(pitch, yaw, 0)
end

---@param cmd UserCmd
local function isTryingToShoot(cmd)
	if cmd and (cmd.buttons ~ (IN_ATTACK)) == 0 then
		return false
	end

	if gui.GetValue("aim bot") then
		if gui.GetValue("aim key") == 0 then
			return true -- automatic
		end

		local keyMode = gui.GetValue("aim key mode")

		if keyMode == "press-to-toggle" then
			return true
		elseif keyMode == "hold-to-use" then
			if input.IsButtonDown(gui.GetValue("aim key")) then
				return true
			end
		end
	end

	return false
end

---@param cmd UserCmd
---@param player Entity
local function playerShot(cmd, player)
	local player = player or entities.GetLocalPlayer()

	local weapon = player:GetPropEntity("m_hActiveWeapon")
	if not isTryingToShoot(cmd) then return false end

	local id = weapon:GetWeaponID()

	local shots = weapon:GetPropInt("m_iConsecutiveShots")

	if not lastConsecutiveShots[id] then
		lastConsecutiveShots[id] = shots
	end

	if shots ~= 0 then
		if lastConsecutiveShots[id] < shots then
			lastConsecutiveShots[id] = shots
			return true
		end

		return false
	else
		lastConsecutiveShots[id] = 0
	end

	return false
end

-- Returns the player's chosen class
---@param player Entity
---@return integer player_class
local function getPlayerClass(player)
	return player:GetPropInt("m_PlayerClass", "m_iClass")
end

-- Returns an array of nearby projectiles
---@param localPlayer Entity
---@param maxDistance number
---@return Entity[] projectiles
local function getNearbyProjectiles(localPlayer, maxDistance)
	local projectiles = {}
	local localPlayerPosition = localPlayer:GetAbsOrigin()

	---@param projectile Entity
	local function addProjectile(projectile)
		local owner = projectile:GetPropEntity("m_hLauncher"):GetPropEntity("m_hOwner")
		if not owner then
			return
		end

		if localPlayer:GetTeamNumber() == owner:GetTeamNumber() then
			return
		end

		local distance = (localPlayerPosition - projectile:GetAbsOrigin()):Length()
		if distance > maxDistance then
			return
		end

		table.insert(projectiles, projectile)
	end

	for _, projectile in pairs(entities.FindByClass("CTFProjectile_Rocket")) do
		addProjectile(projectile)
	end

	for _, projectile in pairs(entities.FindByClass("CTFGrenadePipebombProjectile")) do
		addProjectile(projectile)
	end

	for _, projectile in pairs(entities.FindByClass("CTFProjectile_Arrow")) do
		addProjectile(projectile)
	end

	for _, projectile in pairs(entities.FindByClass("CTFProjectile_SentryRocket")) do
		addProjectile(projectile)
	end

	return projectiles
end

-- Returns an array of nearby enemies
---@param localPlayer Entity
---@param maxDistance number
---@return Entity[] enemies
local function getNearbyEnemies(localPlayer, maxDistance)
	local enemies = {}
	local players = entities.FindByClass("CTFPlayer")
	local localPlayerPosition = localPlayer:GetAbsOrigin()

	for _, player in ipairs(players) do
		if player == localPlayer then goto continue end
		if player:GetTeamNumber() == localPlayer:GetTeamNumber() then goto continue end
		if player:IsDormant() then goto continue end

		local distance = (localPlayerPosition - player:GetAbsOrigin()):Length()
		if distance <= maxDistance then
			table.insert(enemies, player)
		end

		::continue::
	end

	return enemies
end

-- Returns the name of the weapon
---@param weapon Entity
---@return string weapon_name
local function getWeaponName(weapon)
	local activeWeapon = entities.GetLocalPlayer():GetPropEntity("m_hActiveWeapon")
	local weaponID = activeWeapon:GetPropInt("m_iItemDefinitionIndex")

	if weaponID ~= nil then
		local weaponName = itemschema.GetItemDefinitionByID(weaponID):GetName()

		return weaponName
	end

	return ""
end

-- Returns the weapon's position in player's loadout
---@param player Entity
---@param weapon Entity
---@return number loadout_position
local function getWeaponLoadoutPosition(player, weapon)
	local primary = player:GetEntityForLoadoutSlot( LOADOUT_POSITION_PRIMARY )
	if primary:GetPropInt("m_iItemDefinitionIndex") == weapon:GetPropInt("m_iItemDefinitionIndex") then
		return LOADOUT_POSITION_PRIMARY
	end

	local secondary = player:GetEntityForLoadoutSlot( LOADOUT_POSITION_SECONDARY )
	if secondary:GetPropInt("m_iItemDefinitionIndex") == weapon:GetPropInt("m_iItemDefinitionIndex") then
		return LOADOUT_POSITION_SECONDARY
	end

	return LOADOUT_POSITION_MELEE
end

---@param player Entity
---@return number dangerous_damage
local function getDangerousDamage(player)
	local maxHealth = player:GetMaxHealth()
	local health = player:GetHealth()

	if health < maxHealth * 0.4 then
		return 0
	else
		return maxHealth * 0.45
	end
end

-- Returns the eye position of the player
---@param player Entity
---@param customPos Vector3?
---@return Vector3
local function getEyePos(player, customPos)
	local pos = player:GetAbsOrigin()
	if customPos ~= nil then
		pos = customPos
	end

	return pos + player:GetPropVector("localdata", "m_vecViewOffset[0]")
end

-- Returns the position of the player's chest
---@param player Entity
---@param customPos Vector3?
---@return Vector3 chest_position
local function getChestPos(player, customPos)
	local origin = player:GetAbsOrigin()
	if customPos ~= nil then
		origin = customPos
	end

	local eyePos = getEyePos(player, customPos)

	return origin + Vector3(0, 0, (eyePos.z - origin.z) / 2)
end

-- Returns what the player is looking at
---@param player Entity
---@return Trace
local function getViewPos(player)
    local eyePos = getEyePos(player)
	local eyeAngles = player:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")

    local targetPos = eyePos + EulerAngles(eyeAngles.x, eyeAngles.y, eyeAngles.z):Forward() * 8192
    local trace = engine.TraceLine(eyePos, targetPos, MASK_SHOT | CONTENTS_GRATE | MASK_SOLID, function(ent)
		if ent:IsPlayer() and ent:GetIndex() ~= player:GetIndex() then
			return false
		end

		return true
	end)

    return trace
end

-- Returns distance to player's view pos
---@param pos Vector3
---@param enemy Entity
---@return number distance
local function getDistanceToViewPos(pos, enemy)
	local enemyViewPos = getViewPos(enemy)
	local plane = Vector3(enemyViewPos.plane.y, enemyViewPos.plane.x, 0)

	return (vectorMulitply(pos, plane) - vectorMulitply(enemyViewPos.endpos, plane)):Length()
end

-- Returns if target is looking at the player's head
---@param player Entity
---@param target Entity
---@return boolean is_looking
local function isLookingAtPlayerHead(target, player)
	local eyePos = getEyePos(player)
	local eyeAngles = target:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")

    local targetPos = eyePos + EulerAngles(eyeAngles.x, eyeAngles.y, eyeAngles.z):Forward() * -8192
    local trace = engine.TraceLine(eyePos, targetPos, MASK_SHOT | CONTENTS_GRATE, function(ent)
		if ent:IsPlayer() and ent:GetIndex() ~= target:GetIndex() then
			return false
		end

		return true
	end)

    return (trace.entity == target) or (trace.fraction > 0.99)
end

-- Returns if the player is visible
---@param target Entity
---@param from Vector3
---@param to Vector3
---@return boolean
local function visPos(target, from, to)
    local trace = engine.TraceLine(from, to, MASK_SHOT | CONTENTS_GRATE, function(ent)
		if ent:IsPlayer() and ent:GetIndex() ~= target:GetIndex() then
			return false
		end

		return true
	end)

    return (trace.entity == target) or (trace.fraction > 0.99)
end

-- Returns if the player is visible at either feet, chest, head
---@param target Entity
---@param from Vector3
---@param to Vector3? optional
---@return boolean
local function pointVisPos(target, from, to)
	local enemyOrigin = target:GetAbsOrigin()
	local eyePos = getEyePos(target)
	if to then
		eyePos = to + Vector3(0, (eyePos.z - enemyOrigin.z), 0)
	end

	if visPos(target, from, to or enemyOrigin) then
		-- feet
		return true
	end

	if visPos(target, from, (to or enemyOrigin) + Vector3(0, 0, (eyePos.z - enemyOrigin.z) / 2)) then
		-- chest
		return true
	end

	if visPos(target, from, eyePos) then
		-- head
		return true
	end

    return false
end

-- Returns whether enemy is a cheater or not. Function can be replaced by your own checks
---@param enemy Entity
---@return boolean is_cheater
local function isCheater(enemy)
	return playerlist.GetPriority(enemy) > 0
end

-- Returns whether both players are on same ground
---@param localPlayer Entity
---@param enemy Entity
---@return boolean is_on_same_ground
local function isHittable(localPlayer, enemy)
	local class = getPlayerClass(enemy)
	local visible = pointVisPos(localPlayer, getEyePos(enemy))

	if visible then
		return true
	end

	local dist = distanceCheck.default

	if distanceCheck[class] then
		dist = distanceCheck[class]
	end

	local a, b, c, d = pointVisPos(localPlayer, getEyePos(enemy), Vector3(dist, 0, 0)),
		pointVisPos(localPlayer, getEyePos(enemy), Vector3(-dist, 0, 0)),
		pointVisPos(localPlayer, getEyePos(enemy), Vector3(0, dist, 0)),
		pointVisPos(localPlayer, getEyePos(enemy), Vector3(0, -dist, 0))

	return a or b or c or d
end

---@param player Entity
---@return number damage
local function getDamageTakenFromPlayer(player)
	return damageReceived[player:GetIndex()] and damageReceived[player:GetIndex()].damageTaken or 0
end

---@param localPlayer Entity
---@param weapon Entity
---@param projectile Entity
---@param ticks number
---@return Vector3[] positions
local function simulateProjectile(localPlayer, weapon, projectile, ticks)
	if not weapon then
		return {}
	end

	local positions = {}

	local physicsEnv = physics.CreateEnvironment()
	physicsEnv:SetGravity(Vector3( 0, 0, -800 ))
	physicsEnv:SetAirDensity(2.0)
	physicsEnv:SetSimulationTimestep(globals.TickInterval())

	local simulatedPlayer do
		local playerModelName = models.GetModelName(localPlayer:GetModel())
		local solid, collisionModel = physics.ParseModelByName(playerModelName)
		simulatedPlayer = physicsEnv:CreatePolyObject(collisionModel, solid:GetSurfacePropName(), solid:GetObjectParameters())
	end

	local simulatedProjectile do
		local projectileModelName = models.GetModelName(weapon:GetModel())
		local solid, collisionModel = physics.ParseModelByName(projectileModelName)
		simulatedProjectile = physicsEnv:CreatePolyObject(collisionModel, solid:GetSurfacePropName(), solid:GetObjectParameters())
	end
	
	simulatedPlayer:Wake()
	simulatedProjectile:Wake()

	simulatedPlayer:SetPosition(localPlayer:GetAbsOrigin(), Vector3(0, 0, 0), true)
	simulatedProjectile:SetPosition(projectile:GetAbsOrigin(), projectile:GetPropVector("m_angRotation"), true)
	simulatedProjectile:SetVelocity(projectile:EstimateAbsVelocity(), Vector3(0, 0, 0))

	local tickInteval = globals.TickInterval()

	for tick = 1, ticks do
		local currentPos = simulatedProjectile:GetPosition()
		if positions[tick - 1] and (positions[tick - 1] - currentPos):Length() <= 0.05 then
			break
		end

		positions[tick] = currentPos
		physicsEnv:Simulate(tickInteval)
	end

	physicsEnv:ResetSimulationClock()

	if simulatedProjectile ~= nil then
		physicsEnv:DestroyObject(simulatedProjectile)
	end

	if simulatedPlayer ~= nil then
		physicsEnv:DestroyObject(simulatedPlayer)
	end

	physics.DestroyEnvironment(physicsEnv)

	return positions
end


---@param localPlayer Entity
---@param localPlayerPosition Vector3
---@param enemy Entity
---@param distance number
---@return boolean dangerous
---@return Severity severity
---@return string? reason
local function genericDangerCheck(localPlayer, localPlayerPosition, enemy, distance)
	if enemy:InCond(TFCond_Kritzkrieged) and distance <= 800 then
		return true, severityEnums.HIGH, "Enemy has crits"
	end

	if enemy:InCond(TFCond_Ubercharged) and distance <= 600 then
		return true, severityEnums.HIGH, "Enemy is ubercharged"
	end

	if getDamageTakenFromPlayer(enemy) >= getDangerousDamage(localPlayer) then
		return true, severityEnums.LOW, "Player dealt lots of damage"
	end

	return false, severityEnums.LOW
end

---@param localPlayer Entity
---@param localPlayerPosition Vector3
---@param enemy Entity
---@param distance number
---@return boolean dangerous
---@return Severity severity
---@return string? reason
local function scoutDangerCheck(localPlayer, localPlayerPosition, enemy, distance)
	local weapon = enemy:GetPropEntity("m_hActiveWeapon")

	if getWeaponLoadoutPosition(enemy, weapon) == LOADOUT_POSITION_PRIMARY then
		local isForceANature = weapon:GetWeaponData().bulletsPerShot == 10

		if isCheater(enemy) and isForceANature and distance <= 650 then
			return true, severityEnums.HIGH, "Cheater in lethal DT range"
		elseif distance <= 450 then
			return true, severityEnums.MEDIUM, "Nearby scout"
		end

	elseif getWeaponLoadoutPosition(enemy, weapon) == LOADOUT_POSITION_SECONDARY then
		if not weapon:IsShootingWeapon() then
			return false, severityEnums.LOW
		end

		-- TODO: pistol check?
	end

	return false, severityEnums.LOW
end

---@param localPlayer Entity
---@param localPlayerPosition Vector3
---@param enemy Entity
---@param distance number
---@return boolean dangerous
---@return Severity severity
---@return string? reason
local function soldierDangerCheck(localPlayer, localPlayerPosition, enemy, distance)
	local weapon = enemy:GetPropEntity("m_hActiveWeapon")

	if getWeaponLoadoutPosition(enemy, weapon) == LOADOUT_POSITION_PRIMARY then
		if weapon:GetPropInt("m_iItemDefinitionIndex") == ROCKETJUMPER_ITEMINDEX then
			return false, severityEnums.LOW
		end

		if isCheater(enemy) and distance <= 450 then
			return true, severityEnums.HIGH, "Nearby cheating soldier/demo"
		elseif not isCheater(enemy) and ((distance <= 500 and getDistanceToViewPos(getChestPos(localPlayer, localPlayerPosition), enemy) <= 120) or distance <= 300) then
			return true, severityEnums.MEDIUM, "Visible soldier/demo"
		end

	elseif getWeaponLoadoutPosition(enemy, weapon) == LOADOUT_POSITION_SECONDARY then
		if not weapon:IsShootingWeapon() then
			return false, severityEnums.LOW
		end

		if weapon:GetWeaponID() == TF_WEAPON_SHOTGUN_SOLDIER then
			if isCheater(enemy) and distance <= 600 then
				return true, severityEnums.HIGH, "Nearby cheating soldier/demo"
			elseif not isCheater(enemy) and (distance <= 450 or getDistanceToViewPos(getChestPos(localPlayer, localPlayerPosition), enemy) <= 80) then
				return true, severityEnums.MEDIUM, "Visible soldier/demo"
			end
		end
	end

	return false, severityEnums.LOW
end

---@param localPlayer Entity
---@param localPlayerPosition Vector3
---@param enemy Entity
---@param distance number
---@return boolean dangerous
---@return Severity severity
---@return string? reason
local function pyroDangerCheck(localPlayer, localPlayerPosition, enemy, distance)
	local weapon = enemy:GetPropEntity("m_hActiveWeapon")

	if getWeaponLoadoutPosition(enemy, weapon) == LOADOUT_POSITION_PRIMARY then
		if distance <= 700 and enemy:InCond(E_TFCOND.TFCond_CritMmmph) then
			return true, severityEnums.HIGH, "Pyro with phlog crits"
		elseif distance <= 400 then
			return true, severityEnums.MEDIUM, "Nearby pyro"
		end
	elseif getWeaponLoadoutPosition(enemy, weapon) == LOADOUT_POSITION_SECONDARY then
		if not weapon:IsShootingWeapon() then
			return false, severityEnums.LOW
		end

		if weapon:GetWeaponID() == TF_WEAPON_SHOTGUN_PYRO then
			if isCheater(enemy) and distance <= 600 then
				return true, severityEnums.HIGH, "Nearby cheating pyro"
			elseif not isCheater(enemy) and (distance <= 450 or getDistanceToViewPos(getChestPos(localPlayer, localPlayerPosition), enemy) <= 80) then
				return true, severityEnums.MEDIUM, "Visible pyro"
			end
		end
	end

	return false, severityEnums.LOW
end

---@param localPlayer Entity
---@param localPlayerPosition Vector3
---@param enemy Entity
---@param distance number
---@return boolean dangerous
---@return Severity severity
---@return string? reason
local function demoDangerCheck(localPlayer, localPlayerPosition, enemy, distance)
	local weapon = enemy:GetPropEntity("m_hActiveWeapon")

	if getWeaponLoadoutPosition(enemy, weapon) == LOADOUT_POSITION_PRIMARY then
		if weapon:GetWeaponID() ~= GRENADELAUNCHER_INDEX and weapon:GetWeaponID() ~= LOOSECANNON_INDEX then
			return false, severityEnums.LOW
		end

		if isCheater(enemy) and distance <= 600 then
			return true, severityEnums.HIGH, "Nearby soldier/demo"
		elseif not isCheater(enemy) and (distance <= 450 or getDistanceToViewPos(getChestPos(localPlayer, localPlayerPosition), enemy) <= 130) then
			return true, severityEnums.MEDIUM, "Visible soldier/demo"
		end

	elseif getWeaponLoadoutPosition(enemy, weapon) == LOADOUT_POSITION_SECONDARY then
		if not weapon:IsShootingWeapon() then
			return false, severityEnums.LOW
		end

		if weapon:GetWeaponID() == TF_WEAPON_SHOTGUN_SOLDIER then
			if weapon:GetWeaponID() == STICKYJUMPER_ITEMINDEX or weapon:GetWeaponID() ~= STICKYLAUNCHER_INDEX then
				return false, severityEnums.LOW
			end

			if isCheater(enemy) and distance <= 600 then
				return true, severityEnums.HIGH, "Nearby soldier/demo"
			elseif not isCheater(enemy) and (distance <= 450 or getDistanceToViewPos(getChestPos(localPlayer, localPlayerPosition), enemy) <= 130) then
				return true, severityEnums.MEDIUM, "Visible soldier/demo"
			end
		end
	end

	return false, severityEnums.LOW
end

---@param localPlayer Entity
---@param localPlayerPosition Vector3
---@param enemy Entity
---@param distance number
---@return boolean dangerous
---@return Severity severity
---@return string? reason
local function heavyDangerCheck(localPlayer, localPlayerPosition, enemy, distance)
	local weapon = enemy:GetPropEntity("m_hActiveWeapon")
	local visible = visPos(enemy, getChestPos(localPlayer, localPlayerPosition), getChestPos(enemy))

	if getWeaponLoadoutPosition(enemy, weapon) == LOADOUT_POSITION_PRIMARY then
		local minigunState = weapon:GetPropInt("m_iWeaponState")
		local isRevved = minigunState == 1 or minigunState == 3
		
		if isRevved then
			if isCheater(enemy) and visible then
				if distance <= 750 --[[or getDistanceToViewPos(getChestPos(localPlayer), enemy) <= 120--]] then
					return true, severityEnums.HIGH, "Revved cheater heavy nearby"
				end
			elseif not isCheater(enemy) and visible then
				if (distance <= 900 and getDistanceToViewPos(getChestPos(localPlayer, localPlayerPosition), enemy) <= 180) or distance <= 500 then
					return true, severityEnums.MEDIUM, "Revved heavy looking at player"
				end
			end
		end
	elseif getWeaponLoadoutPosition(enemy, weapon) == LOADOUT_POSITION_SECONDARY then
		if not weapon:IsShootingWeapon() then
			return false, severityEnums.LOW
		end

		if isCheater(enemy) and visible then
			if (distance <= 400) or getDistanceToViewPos(getChestPos(localPlayer, localPlayerPosition), enemy) <= 120 then
				return true, severityEnums.HIGH, "Cheater with shotgun in lethal range"
			end
		elseif not isCheater(enemy) and visible then
			if distance <= 320 and getDistanceToViewPos(getChestPos(localPlayer, localPlayerPosition), enemy) <= 120 then
				return true, severityEnums.MEDIUM, "Shotgun in lethal range"
			end
		end

	end

	return false, severityEnums.LOW
end

---@param localPlayer Entity
---@param localPlayerPosition Vector3
---@param enemy Entity
---@param distance number
---@return boolean dangerous
---@return Severity severity
---@return string? reason
local function engineerDangerCheck(localPlayer, localPlayerPosition, enemy, distance)
	local weapon = enemy:GetPropEntity("m_hActiveWeapon")
	local visible = visPos(enemy, getChestPos(localPlayer, localPlayerPosition), getChestPos(enemy))

	if getWeaponLoadoutPosition(enemy, weapon) == LOADOUT_POSITION_PRIMARY then
		if not weapon:IsShootingWeapon() then
			return false, severityEnums.LOW
		end

		if isCheater(enemy) and visible then
			if (distance <= 400) or getDistanceToViewPos(getChestPos(localPlayer, localPlayerPosition), enemy) <= 120 then
				return true, severityEnums.HIGH, "Cheater with shotgun in lethal range"
			end
		elseif not isCheater(enemy) and visible then
			if distance <= 320 and getDistanceToViewPos(getChestPos(localPlayer, localPlayerPosition), enemy) <= 120 then
				return true, severityEnums.MEDIUM, "Shotgun in lethal range"
			end
		end
	end

	return false, severityEnums.LOW
end

---@param localPlayer Entity
---@param localPlayerPosition Vector3
---@param enemy Entity
---@param distance number
---@return boolean dangerous
---@return Severity severity
---@return string? reason
local function sniperDangerCheck(localPlayer, localPlayerPosition, enemy, distance)
	local weapon = enemy:GetPropEntity("m_hActiveWeapon")

	local shooting = enemy:InCond(TFCond_Zoomed) or (enemy:InCond(TFCond_Slowed) and weapon:GetWeaponID() == HUNTSMAN_INDEX)
	if shooting then
		if isCheater(enemy) then
			if visPos(enemy, getEyePos(localPlayer), getEyePos(enemy)) then
				return true, severityEnums.HIGH, "Enemy cheater sniper in sight"
			end
		else
			local lookDistance = getDistanceToViewPos(getEyePos(localPlayer, localPlayerPosition), enemy)
			

			if lookDistance <= 30 then
				return true, severityEnums.MEDIUM, "Enemy sniper looking at head"
			elseif lookDistance <= 120 then
				return true, severityEnums.LOW, "Enemy sniper looking at head"
			end
		end
	end

	return false, severityEnums.LOW
end

---@param localPlayer Entity
---@param localPlayerPosition Vector3
---@param enemy Entity
---@param distance number
---@return boolean dangerous
---@return Severity severity
local function medicDangerCheck(localPlayer, localPlayerPosition, enemy, distance)
	-- TODO: figure smth out?
	return false, severityEnums.LOW
end

---@param localPlayer Entity
---@param localPlayerPosition Vector3
---@param enemy Entity
---@param distance number
---@return boolean dangerous
---@return Severity severity
local function spyDangerCheck(localPlayer, localPlayerPosition, enemy, distance)
	-- TODO: figure smth out?
	return false, severityEnums.LOW
end

---@param class number
---@return ResistTypes resist_type
---@alia
local function getResistTypeForClass(class)
	if class == TF2_Scout or class == TF2_Heavy or class == TF2_Engineer or class == TF2_Sniper or class == TF2_Medic or class == TF2_Spy then
		return RESIST_TYPES.AMMO_RESIST
	elseif class == TF2_Soldier or class == TF2_Demoman then
		return RESIST_TYPES.BLAST_RESIST
	elseif class == TF2_Pyro then
		return RESIST_TYPES.FIRE_RESIST
	end

	return RESIST_TYPES.AMMO_RESIST
end

---@param player Entity
---@param resistType ResistTypes
local function hasResistTypeForClass(player, resistType)
	local resistCondition

	if resistType == RESIST_TYPES.AMMO_RESIST then
		resistCondition = TFCond_UberBulletResist
	elseif resistType == RESIST_TYPES.BLAST_RESIST then
		resistCondition = TFCond_UberBlastResist
	else
		resistCondition = TFCond_UberFireResist
	end

	return player:InCond(resistCondition)
end


---@param localPlayer Entity
---@param localPlayerPosition Vector3
---@param enemy Entity
---@param distance number
---@return boolean dangerous
---@return Severity severity
---@return string? reason
local function classDangerCheck(localPlayer, localPlayerPosition, enemy, distance)
	local class = getPlayerClass(enemy)

	local inDanger, severity, reason

	if class == TF2_Scout then
		inDanger, severity, reason = scoutDangerCheck(localPlayer, localPlayerPosition, enemy, distance)
	elseif class == TF2_Soldier then
		inDanger, severity, reason = soldierDangerCheck(localPlayer, localPlayerPosition, enemy, distance)
	elseif class == TF2_Pyro then
		inDanger, severity, reason = pyroDangerCheck(localPlayer, localPlayerPosition, enemy, distance)
	elseif class == TF2_Demoman then
		inDanger, severity, reason = demoDangerCheck(localPlayer, localPlayerPosition, enemy, distance)
	elseif class == TF2_Heavy then
		inDanger, severity, reason = heavyDangerCheck(localPlayer, localPlayerPosition, enemy, distance)
	elseif class == TF2_Engineer then
		inDanger, severity, reason = engineerDangerCheck(localPlayer, localPlayerPosition, enemy, distance)
	elseif class == TF2_Sniper then
		inDanger, severity, reason = sniperDangerCheck(localPlayer, localPlayerPosition, enemy, distance)
	elseif class == TF2_Medic then
		inDanger, severity, reason = medicDangerCheck(localPlayer, localPlayerPosition, enemy, distance)
	elseif class == TF2_Spy then
		inDanger, severity, reason = spyDangerCheck(localPlayer, localPlayerPosition, enemy, distance)
	end

	local hasDangerResist = hasResistTypeForClass(localPlayer, getResistTypeForClass(class))
	if hasDangerResist then
		return false, severityEnums.LOW
	end

	if inDanger then
		return inDanger, severity, reason
	end

	inDanger, severity, reason = genericDangerCheck(localPlayer, localPlayerPosition, enemy, distance)

	if inDanger then
		return inDanger, severity, reason
	end

	return false, severityEnums.LOW
end

-- Checks if there's a dangerous enemy near player
---@param localPlayer Entity
---@return boolean is_in_danger
---@return Severity? severity
---@return Entity? danger
---@return string? reason
local function checkforEnemies(localPlayer)
	local nearbyEnemies = getNearbyEnemies(localPlayer, 8192)
	local localPlayerPosition = localPlayer:GetAbsOrigin()

	for _, enemy in ipairs(nearbyEnemies) do
		local weapon = enemy:GetPropEntity("m_hActiveWeapon")
		local distance = (localPlayerPosition - enemy:GetAbsOrigin()):Length()

		if not isHittable(localPlayer, enemy) then
			goto continue
		end

		if getWeaponLoadoutPosition(enemy, weapon) == LOADOUT_POSITION_MELEE then
			goto continue
		end

		local danger, severity, reason = classDangerCheck(localPlayer, localPlayerPosition, enemy, distance)

		if danger then
			return true, severity, enemy, reason
		end

		::continue::
	end

	nearbyEnemies = {}

	return false
end

---@param localPlayer Entity
---@return boolean is_in_danger
---@return Severity? severity
---@return Entity? danger
---@return string? reason
local function checkForProjectiles(localPlayer)
	local projectiles = getNearbyProjectiles(localPlayer, 2048)
	if #projectiles == 0 then
		return false, severityEnums.LOW
	end

	local localPlayerPosition = localPlayer:GetAbsOrigin()

	local nearbyStickyCount = 0
	local nearbyPipeCount = 0

	local isInDanger, severity, danger, reason

	---@param rocket Entity
	---@return boolean is_in_danger
	---@return Severity? severity
	---@return Entity? danger
	---@return string? reason
	local function handleRocket(rocket)
		local owner = rocket:GetPropEntity("m_hLauncher"):GetPropEntity("m_hOwner")
		local isCritical = rocket:GetPropBool("m_bCritical")
		local weapon = owner:GetPropEntity("m_hActiveWeapon")

		local nextPositions = simulateProjectile(localPlayer, weapon, rocket, config.autoVaccinator.projectileCheck.ticksToSimulate)
		for index, nextPosition in pairs(nextPositions) do
			local futureDistance = (localPlayerPosition - nextPosition):Length()
			local maxDistance = isCritical and 320 or 100

			if futureDistance <= maxDistance then
				if isCritical then
					return true, severityEnums.HIGH, owner, "Critical rocket within blast radius"
				elseif index <= math.floor(#nextPositions / 2) then
					return true, severityEnums.HIGH, owner, "Rocket within blast radius"
				else
					return true, severityEnums.MEDIUM, owner, "Rocket within blast radius"
				end
			end
		end

		return false, severityEnums.LOW
	end

	---@param sticky Entity
	---@return boolean is_in_danger
	---@return Severity? severity
	---@return Entity? danger
	---@return string? reason
	local function handleSticky(sticky)
		local owner = sticky:GetPropEntity("m_hLauncher"):GetPropEntity("m_hOwner")
		local isCritical = sticky:GetPropBool("m_bCritical")
		local distance = (localPlayerPosition - sticky:GetAbsOrigin()):Length()
		local weapon = owner:GetPropEntity("m_hActiveWeapon")

		if distance <= 430 then
			nearbyStickyCount = nearbyStickyCount + 1

			if isCritical then
				return true, severityEnums.HIGH, owner, "1+ crit sticky within blast radius"
			end

			if nearbyStickyCount >= 2 then
				return true, severityEnums.MEDIUM, owner, "2+ stickies within blast radius"
			end
		end

		local nextPositions = simulateProjectile(localPlayer, weapon, sticky, config.autoVaccinator.projectileCheck.ticksToSimulate)
		for index, nextPosition in pairs(nextPositions) do
			local futureDistance = (localPlayerPosition - nextPosition):Length()
			local maxDistance = isCritical and 230 or 130

			if futureDistance <= maxDistance then
				if isCritical then
					return true, severityEnums.HIGH, owner, "Critical sticky within blast radius"
				elseif index <= math.floor(#nextPositions / 2) then
					return true, severityEnums.HIGH, owner, "Sticky within blast radius"
				else
					return true, severityEnums.MEDIUM, owner, "Sticky within blast radius"
				end
			end
		end

		return false, severityEnums.LOW
	end

	---@param pill Entity
	---@return boolean is_in_danger
	---@return Severity? severity
	---@return Entity? danger
	---@return string? reason
	local function handlePill(pill)
		local owner = pill:GetPropEntity("m_hLauncher"):GetPropEntity("m_hOwner")
		local isCritical = pill:GetPropBool("m_bCritical")
		local weapon = owner:GetPropEntity("m_hActiveWeapon")
		local distance = (localPlayerPosition - pill:GetAbsOrigin()):Length()

		if distance <= 300 then
			nearbyPipeCount = nearbyPipeCount + 1
		end

		if isCritical then
			return true, severityEnums.HIGH, owner, "1+ crit pipe within blast radius"
		end

		local nextPositions = simulateProjectile(localPlayer, weapon, pill, config.autoVaccinator.projectileCheck.ticksToSimulate)
		for index, nextPosition in pairs(nextPositions) do
			local futureDistance = (localPlayerPosition - nextPosition):Length()
			local maxDistance = isCritical and 230 or 130

			if futureDistance <= maxDistance then
				if isCritical then
					return true, severityEnums.HIGH, owner, "Critical pill within blast radius"
				elseif index <= math.floor(#nextPositions / 2) then
					return true, severityEnums.HIGH, owner, "Pill within blast radius"
				else
					return true, severityEnums.MEDIUM, owner, "Pill within blast radius"
				end
			end
		end

		if nearbyPipeCount >= 3 then
			return true, severityEnums.MEDIUM, owner, "3+ pipes within blast radius"
		end

		return false, severityEnums.LOW
	end

	for _, projectile in pairs(projectiles) do
		if projectile:GetClass() == "CTFProjectile_Rocket" then
			isInDanger, severity, danger, reason = handleRocket(projectile)
		elseif projectile:GetClass() == "CTFGrenadePipebombProjectile" then
			local isSticky = projectile:GetPropInt("m_iType") == 1

			if isSticky then
				isInDanger, severity, danger, reason = handleSticky(projectile)
			else
				isInDanger, severity, danger, reason = handlePill(projectile)
			end
		end

		if isInDanger then
			return isInDanger, severity, danger, reason
		end
	end

	projectiles = {}

	return false, severityEnums.LOW
end

---@param localPlayer Entity
---@return boolean is_in_danger
---@return Severity? severity
---@return Entity? danger
---@return string? reason
local function checkForSentries(localPlayer)
	local sentries = entities.FindByClass("CObjectSentrygun")
	
	for _, sentry in pairs(sentries) do
		local owner = sentry:GetPropEntity("m_hBuilder")
		if owner:GetTeamNumber() == localPlayer:GetTeamNumber() then
			goto continue
		end

		if sentry:GetPropBool("m_bHasSapper") then
			goto continue
		end

		local visible = visPos(sentry, getEyePos(localPlayer), sentry:GetAbsOrigin() + Vector3(0, 0, 30))
		if visible then
			return true, severityEnums.MEDIUM, owner, "Visible sentry gun"
		end

		::continue::
	end

	return false, severityEnums.LOW
end

-- Runs an comprehensive check to see if you're in danger
---@param localPlayer Entity
---@param healingTarget Entity?
---@return boolean is_in_danger
---@return Severity? severity
---@return Entity? danger
---@return string? reason
local function inDanger(localPlayer, healingTarget)
	local isInDanger, severity, danger, reason

	local function checkForDanger(user)
		if config.autoVaccinator.checkForEnemies then
			local test_isInDanger, test_severity, test_danger, test_reason = checkforEnemies(user)
			if not severity or (test_isInDanger and test_severity >= severity) then
				isInDanger, severity, danger, reason = test_isInDanger, test_severity, test_danger, test_reason
			end
		end

		if config.autoVaccinator.checkForProjectiles then
			local test_isInDanger, test_severity, test_danger, test_reason = checkForProjectiles(user)
			if not severity or (test_isInDanger and test_severity >= severity) then
				isInDanger, severity, danger, reason = test_isInDanger, test_severity, test_danger, test_reason
			end
		end

		local test_isInDanger, test_severity, test_danger, test_reason = checkForSentries(user)
		if not severity or (test_isInDanger and test_severity >= severity) then
			isInDanger, severity, danger, reason = test_isInDanger, test_severity, test_danger, test_reason
		end
	end

	checkForDanger(localPlayer)
	if healingTarget and healingTarget:IsValid() then
		checkForDanger(healingTarget)
	end

	return isInDanger, severity, danger, reason
end

---@param cmd UserCmd
---@param newResistType ResistTypes
local function switchResistTypes(cmd, newResistType)
	local localPlayer = entities.GetLocalPlayer()
	if not localPlayer or not localPlayer:IsAlive() then
		return
	end

	local weapon = localPlayer:GetPropEntity("m_hActiveWeapon")
	if not weapon:IsMedigun() then
		return
	end

	local isVaccinator = weapon:GetPropInt("m_iItemDefinitionIndex") == VACCINATOR_ITEMINDEX
	if config.onlyVaccinator and not isVaccinator then
		return
	end

	local resistType = weapon:GetPropInt("m_nChargeResistType")
	if resistType ~= newResistType then
		cmd.buttons = cmd.buttons | IN_RELOAD
	end
end

---@param cmd UserCmd
addCallback("CreateMove", "LogicCheck", function(cmd)
	local localPlayer = entities.GetLocalPlayer()
	if not localPlayer or not localPlayer:IsAlive() then
		return
	end

	local weapon = localPlayer:GetPropEntity("m_hActiveWeapon")
	if not weapon:IsMedigun() then
		if switchBack and globals.TickCount() - lastCommand > 5 then
			lastCommand = globals.TickCount()
			client.Command("slot2", true)
		end

		return
	end

	if not weapon:GetPropBool("m_bHealing") then
		if switchBack then
			if config.controlAimbot then
				if aimbotKey then
					gui.SetValue("aim key", aimbotKey)
				end

				gui.SetValue("aim bot", 0)
			end


			if not shootTarget or not shootTarget:IsAlive() or not shootTarget:IsValid() then
				shootTarget = nil
				switchBack = false
				return
			end

			local distance = (localPlayer:GetAbsOrigin() - shootTarget:GetAbsOrigin()):Length()
			if distance >= 250 then
				shootTarget = nil
				switchBack = false
				return
			end

			local localPlayerAngles = localPlayer:GetAbsOrigin() + localPlayer:GetPropVector("localdata", "m_vecViewOffset[0]")
			local shootTargetAngles = shootTarget:GetAbsOrigin() + shootTarget:GetPropVector("localdata", "m_vecViewOffset[0]") / 2

			cmd:SetViewAngles(positionAngles(localPlayerAngles, shootTargetAngles):Unpack())
			cmd.buttons = cmd.buttons | IN_ATTACK
		end

		if config.autoVaccinator.requireHealingTarget then
			return
		end
	end

	local healingTarget = weapon:GetPropEntity("m_hHealingTarget")
	currentHealingTarget = healingTarget:IsValid() and healingTarget or nil
	if config.autoVaccinator.requireHealingTarget then
		if not healingTarget or not healingTarget:IsValid() then
			return
		end
	end

	if switchBack then
		switchBack = false
	end

	local primary = localPlayer:GetPropDataTableEntity("m_hMyWeapons")[1]
	if not primary:IsValid() or primary:GetPropInt("m_iItemDefinitionIndex") ~= CROSSBOW_ITEMINDEX then
		return
	end

	local isVaccinator = weapon:GetPropInt("m_iItemDefinitionIndex") == VACCINATOR_ITEMINDEX
	if config.onlyVaccinator and not isVaccinator then
		return
	end

	if isVaccinator then
		local isInDanger, severity, danger, reason = inDanger(localPlayer, healingTarget)

		if config.autoVaccinator.ignoreSeverity[severity] and severity ~= severityEnums.LOW then
			goto skipAutoVacc
		end

		if isInDanger and danger then
			local dangerResistType = getResistTypeForClass(getPlayerClass(danger))

			resistSwitchCooldown = resistSwitchCooldown - 1
			if resistSwitchCooldown <= 0 then
				resistSwitchCooldown = 3
				switchResistTypes(cmd, dangerResistType)
			end

			if severity == severityEnums.LOW then
				goto skipAutoVacc
			end

			local currentChargeMeter = weapon:GetPropFloat("LocalTFWeaponMedigunData", "m_flChargeLevel")

			if currentChargeMeter >= 0.25 and globals.CurTime() - lastPop > 2 and not hasResistTypeForClass(localPlayer, dangerResistType) then
				if weapon:GetPropInt("m_nChargeResistType") ~= dangerResistType then
					return
				end

				lastPop = globals.CurTime()

				local severityText = (severity == 1 and "MEDIUM" or "HIGH")
				announce(("Popped charge because: %s"):format(reason))
				client.Command(("say_party \"[Auto-Vaccinator]: Popped! Reason for charge: %s. Severity: %s\""):format(reason, severityText or "?"), true)

				cmd.buttons = cmd.buttons | IN_ATTACK2
			end
		end
	end

	::skipAutoVacc::

	if not healingTarget or not healingTarget:IsValid() then
		return
	end

	local targetMaxHealth = healingTarget:GetMaxHealth()
	local targetHealth = healingTarget:GetHealth()
	if targetHealth >= targetMaxHealth then
		return
	end

	local criticalHealing = false

	local healthLost = targetMaxHealth - targetHealth
	if healthLost < config.minimumHealthLostToHeal then
		return
	end

	if config.criticalHeal then
		if targetHealth - (config.minimumHealthLostToHeal / 2) < targetMaxHealth * 0.5 then
			criticalHealing = true
		end
	end

	if not isVaccinator and not config.onlyVaccinator then
		if config.ignoreWhileUbercharged and weapon:GetPropBool("m_bChargeRelease") then
			return
		end
	end

	if config.runLogic and not criticalHealing then
		local currentChargeMeter = weapon:GetPropFloat("LocalTFWeaponMedigunData", "m_flChargeLevel")

		if isVaccinator then
			-- wait for auto vacc to pop a charge
			if (globals.CurTime() - lastPop > 3 or globals.CurTime() - lastPop < 0.75) and currentChargeMeter >= 0.25 then
				return
			end
		else
			-- dont do anything if they get near max charge (ubercharge)
			if currentChargeMeter * 100 >= config.ignoreAboveChargeMeter then
				return
			end
		end
	end

	if tryingToShoot then
		return
	end

	if globals.TickCount() - lastCommand > 5 and globals.CurTime() - healingCooldown > config.healingCooldownTime then
		if config.announceInChat then
			if criticalHealing then
				announce("Shooting heal arrow because healing target is below critical health")
			elseif isVaccinator then
				if globals.CurTime() - lastCharge < 3 then
					announce("Shooting heal arrow because auto vaccinator popped a charge")
				end
			else
				announce("Shooting heal arrow because healing target got hurt")
			end
		end

		if config.controlAimbot then
			gui.SetValue("aim bot", 1)
			local aimbotIsAutomatic = gui.GetValue("aim key") == 0

			if not aimbotIsAutomatic then
				aimbotKey = gui.GetValue("aim key")
				gui.SetValue("aim key", 0)
			end
		end

		tryingToShoot = true
		shootTarget = healingTarget
		lastCommand = globals.TickCount()

		client.Command("slot1", true)

		local extraCooldown = 0

		if isVaccinator then
			extraCooldown = config.healingCooldownTime / 2
		end

		healingCooldown = globals.CurTime() + extraCooldown
	end
end)

---@param cmd UserCmd
addCallback("CreateMove", "CrossbowShooter", function(cmd)
	local localPlayer = entities.GetLocalPlayer()
	if not localPlayer or not localPlayer:IsAlive() then
		return
	end

	local weapon = localPlayer:GetPropEntity("m_hActiveWeapon")
	if not weapon:IsValid() or weapon:GetPropInt("m_iItemDefinitionIndex") ~= CROSSBOW_ITEMINDEX then
		return
	end

	if not tryingToShoot then
		return
	end

	if not shootTarget or not shootTarget:IsValid() then
		tryingToShoot = false
		return
	end

	local distance = (localPlayer:GetAbsOrigin() - shootTarget:GetAbsOrigin()):Length()
	if distance >= 400 then
		tryingToShoot = false
		switchBack = true
		return
	end

	local nextAttack = weapon:GetPropFloat("LocalActiveWeaponData", "m_flNextPrimaryAttack")

	if globals.CurTime() >= nextAttack - 0.5 and playerShot(cmd, localPlayer) then
		tryingToShoot = false
		switchBack = true
	end
end)

addCallback("CreateMove", "ChargeWatcher", function()
	local localPlayer = entities.GetLocalPlayer()
	if not localPlayer or not localPlayer:IsAlive() then
		lastChargeMeter = 0
		return
	end

	local weapon = localPlayer:GetPropEntity("m_hActiveWeapon")
	if not weapon:IsMedigun() then
		return
	end

	local currentChargeMeter = weapon:GetPropFloat("LocalTFWeaponMedigunData", "m_flChargeLevel")

	if currentChargeMeter < lastChargeMeter then
		lastCharge = globals.CurTime()
	end

	lastChargeMeter = currentChargeMeter
end)

---@param event GameEvent
addCallback("FireGameEvent", "PlayerDamageWatcher", function(event)
	if event:GetName() == "player_hurt" then
		local localPlayer = entities.GetLocalPlayer()

		local victim = entities.GetByUserID(event:GetInt("userid"))
		local attacker = entities.GetByUserID(event:GetInt("attacker"))
		local damage = event:GetInt("damageamount")

		if victim and localPlayer and attacker then
			local attackerName = attacker:GetIndex()

			if victim:GetIndex() == localPlayer:GetIndex() or ((currentHealingTarget and currentHealingTarget:IsValid()) and victim:GetIndex() == currentHealingTarget:GetIndex()) then
				if damageReceived[attackerName] then
					damageReceived[attackerName].damageTaken = damageReceived[attackerName].damageTaken + damage
					damageReceived[attackerName].lastDamageTime = globals.CurTime()
				else
					damageReceived[attackerName] = {
						damageTaken = damage or 0,
						lastDamageTime = globals.CurTime()
					}
				end
			end
		end
	end
end)

addCallback("CreateMove", "DamageFalloffWatcher", function()
	for name, data in pairs(damageReceived) do
		if globals.CurTime() - data.lastDamageTime >= 2.5 then
			damageReceived[name] = nil
		end
	end
end)

if config.controlAimbot then
	gui.SetValue("aim bot", 0)
end
