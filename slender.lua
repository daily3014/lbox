local font = draw.CreateFont( "Verdana", 16, 800 )

local texts = {}
local slenderEntities = {}
local MAX_ENTITY_DISTANCE = 6000
local UPDATE_EVERY_N_SECONDS = 1
local MAX_SECONDS_WITHOUT_UPDATE = 2
local lastEntityUpdate = 0

local function getTimePassed(start)
	return globals.CurTime() - start
end

local function cleanUpEntity(entity)
	slenderEntities[entity] = nil
	texts[entity] = nil
end

local function addEntity(entity, text)
	if not slenderEntities[entity] then
		slenderEntities[entity] = globals.CurTime()
		texts[entity] = text
	end
end

local function isEntityNear(entity)
	local localPlayer = entities.GetLocalPlayer()

	if not localPlayer then
		return false
	end

	if not entity then
		return false
	end

	local distance = vector.Distance(entity:GetAbsOrigin(), localPlayer:GetAbsOrigin())

	return distance < MAX_ENTITY_DISTANCE
end

local function lookForSlenderEntities()
	for i = 33, 3000 do
		local entity = entities.GetByIndex(i)

		if not entity then
			goto continue
		end

		if entity:GetClass() == "NextBotCombatCharacter" then
			if not isEntityNear(entity) then
				goto continue
			end

			addEntity(entity, "[SLENDER BOSS]")
		elseif entity:GetClass() == "CDynamicProp" then
			if entity:GetPropInt("m_nSolidType") ~= 2 then
				goto continue
			end

			if entity:GetPropInt("m_bSimulatedEveryTick") ~= 1 then
				goto continue
			end

			if entity:GetPropInt("m_bAnimatedEveryTick") ~= 0 then
				goto continue
			end

			addEntity(entity, "[PAGE]")
		end

	    ::continue::
	end
end

local function removeOldEntities()
	-- making sure any entities that somehow dont get cleaned up in the draw loop check,
	-- get cleaned up here instead
	-- this should 99.99% of the time never be called

	for entity, lastUpdateTick in pairs(slenderEntities) do
		if not entity then
			goto continue
		end

		if getTimePassed(lastUpdateTick) > MAX_SECONDS_WITHOUT_UPDATE then
			cleanUpEntity(entity)
		end

	    ::continue::
	end
end

local function isEntityValid(entity)
	if not entity or not entity:IsValid() or not isEntityNear(entity) then
		return false
	end

	return true
end

local function slenderDrawLoop()
	if getTimePassed(lastEntityUpdate) >= UPDATE_EVERY_N_SECONDS then -- update entities
		lastEntityUpdate = globals.CurTime()
		lookForSlenderEntities()
		removeOldEntities() -- remove references to entities that haven't been updated
	end

	for entity, _ in pairs(slenderEntities) do
		if not isEntityValid(entity) then
			if entity then
				cleanUpEntity(entity)
			end

			goto continue
		end

		slenderEntities[entity] = globals.CurTime()

		local screenPosition = client.WorldToScreen(entity:GetAbsOrigin())

		if screenPosition then
			draw.SetFont(font)
			draw.Color(255, 0, 0, 255)
			draw.Text(screenPosition[1], screenPosition[2], texts[entity])
		end

	    ::continue::
	end
end

callbacks.Register("Draw", "draw_slender", slenderDrawLoop)