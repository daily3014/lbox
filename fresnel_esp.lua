---@class Vector2
---@field x number
---@field y number

---@param x number X Cord
---@param y number Y Cord
---@return Vector2 vector
local function Vector2(x, y)
	return {x = x, y = y}
end

---@class Color
---@field r number
---@field g number
---@field b number
---@field a number

---@param r number Red
---@param g number Green
---@param b number Blue
---@param a? number Alpha
---@return Color color
local function Color(r, g, b, a)
	return {r = r, g = g, b = b, a = a or 255}
end

---@class EspSettings
---@field primaryColor Color
---@field secondaryColor Color
---@field rgbBrightness Color
---@field intensity number
---@field outlineIntensity number
---@field useTeamColor number?
---@field name string

---@type EspSettings[]
local config = {
	localPlayer = {
		useTeammateSettings = false,
		friendsUseLocalPlayer = true,

		primaryColor = Color(111, 41, 217),
		secondaryColor = Color(30, 30, 30),
		rgbBrightness = Color(70, 70, 70),
		intensity = .1,
		outlineIntensity = 1,

		name = "LocalPlayer"
	},

	teammate = {
		useTeamColor = true,

		primaryColor = Color(33, 156, 222),
		secondaryColor = Color(30, 30, 30),
		rgbBrightness = Color(70, 70, 70),
		intensity = .1,
		outlineIntensity = 1,

		name = "Teammate"
	},

	enemy = {
		useTeamColor = true,

		primaryColor = Color(180, 0, 0),
		secondaryColor = Color(30, 30, 30),
		rgbBrightness = Color(70, 70, 70),
		intensity = .1,
		outlineIntensity = 1,

		name = "Enemy"
	},

	cheater = {
		primaryColor = Color(255, 0, 0),
		secondaryColor = Color(0, 0, 0),
		rgbBrightness = Color(255, 255, 255),
		intensity = .045,
		outlineIntensity = 1,

		name = "Cheater"
	},
}

---@param player Entity
local function isCheater(player)
	return playerlist.GetPriority(player) > 0
end

---@param player Entity
local function isFriend(player)
	local playerInfo = client.GetPlayerInfo(player:GetIndex())
	local steamID = playerInfo.SteamID

	local partyMembers = party.GetMembers()

	if playerlist.GetPriority(player) < 0 then
		return true
	elseif steam.IsFriend(steamID) then
		return true
	else
		if partyMembers then
			for i, partySteamID in pairs(partyMembers) do
				if partySteamID == steamID then
					return true
				end
			end
		end
	end

	return false
end

---@type Material[]
local espMaterials = {}

---@param material Material
---@param primaryColor Color
---@param secondaryColor Color
---@param rgbBrightness Color
---@param intensity number [0 - 1]
---@param outlineIntensity number [0 - 1]
local function changeFresnelSettings(material, primaryColor, secondaryColor, rgbBrightness, intensity, outlineIntensity)
	material:SetShaderParam("$phongfresnelranges", Vector3(0, intensity, outlineIntensity))
	material:SetShaderParam("$envmaptint", Vector3(primaryColor.r/255, primaryColor.g/255, primaryColor.b/255))
	material:SetShaderParam("$selfillumtint", Vector3(secondaryColor.r/255, secondaryColor.g/255, secondaryColor.b/255))
	material:SetShaderParam("$selfillumfresnelminmaxexp", Vector3(rgbBrightness.r/255, rgbBrightness.g/255, rgbBrightness.b/255))
end

---@param name string
---@param colorSettings EspSettings
local function createFresnelMaterial(name, colorSettings)
	if espMaterials[name] then
		espMaterials[name] = nil
	end

	espMaterials[name] = materials.Create("fresnelMaterial", [["VertexLitGeneric" {
		"$basetexture"  				"vgui/white_additive"
		"$bumpmap"						"models/player/shared/shared_normal"
		"$envmap"						"skybox/sky_dustbowl_01"
	
		"$selfillum"					"1"
		"$phong"						"1"
	
		"$selfillumfresnel"				"1"	
		"$envmapfresnel"				"1"
	}]])

	changeFresnelSettings(
		espMaterials[name],
		colorSettings.primaryColor,
		colorSettings.secondaryColor,
		colorSettings.rgbBrightness,
		colorSettings.intensity,
		colorSettings.outlineIntensity
	)
end

createFresnelMaterial(config.localPlayer.name, config.localPlayer)
createFresnelMaterial(config.teammate.name, config.teammate)
createFresnelMaterial(config.enemy.name, config.enemy)
createFresnelMaterial(config.cheater.name, config.cheater)

--[[
---@param topLeft Vector2
---@param bottomRight Vector2
---@param color Color
local function outLinedBox(topLeft, bottomRight, color)
	local outlineTransparency = color.a // 1.3
	if outlineTransparency < 30 then
		outlineTransparency = 30
	end

	draw.Color(color.r, color.g, color.b, color.a)
	draw.OutlinedRect(topLeft.x, topLeft.y, bottomRight.x, bottomRight.y)
	draw.Color(0, 0, 0, outlineTransparency)
	draw.OutlinedRect(topLeft.x - 1, topLeft.y - 1, bottomRight.x + 1, bottomRight.y + 1)
	draw.Color(0, 0, 0, 160)
	draw.OutlinedRect(topLeft.x + 1, topLeft.y + 1, bottomRight.x - 1, bottomRight.y - 1)
end
--]]


local localPlayerCounter = 0
local marked = {}

---@param context DrawModelContext
callbacks.Register("DrawModel", function(context)
	local entity = context:GetEntity()
	local localPlayer = entities.GetLocalPlayer()

    if entity and localPlayer and (entity:GetClass() == "CTFPlayer" or entity:GetClass() == "CTFWearable") then
		local player = entity:GetClass() == "CTFPlayer" and entity or entity:GetPropEntity("m_hOwnerEntity")

		if player:GetIndex() == localPlayer:GetIndex() then
			if entity:GetClass() == "CTFPlayer" then
				if gui.GetValue("anti aim indicator") == 1 and gui.GetValue("anti aim") == 1 then
					localPlayerCounter = localPlayerCounter + 1
					if localPlayerCounter > 1 then
						localPlayerCounter = 0
						context:ForcedMaterialOverride(espMaterials["Cheater"])
						return
					end
				else
					localPlayerCounter = 0
				end
			end

			if config.localPlayer.useTeammateSettings then
				context:ForcedMaterialOverride(espMaterials["Teammate"])
			else
				context:ForcedMaterialOverride(espMaterials["LocalPlayer"])
			end
		elseif (isFriend(player) and config.localPlayer.friendsUseLocalPlayer) then
			if config.localPlayer.useTeammateSettings then
				context:ForcedMaterialOverride(espMaterials["Teammate"])
			else
				context:ForcedMaterialOverride(espMaterials["LocalPlayer"])
			end
		elseif isCheater(player) then
			context:ForcedMaterialOverride(espMaterials["Cheater"])
		else
			local colorSettings = player:GetTeamNumber() == localPlayer:GetTeamNumber() and config.teammate or config.enemy

			if colorSettings.useTeamColor then
				local newColor = {Color(70, 70, 70), Color(180, 0, 0), Color(33, 156, 222)}

				changeFresnelSettings(
					espMaterials[colorSettings.name],
					newColor[player:GetTeamNumber()],
					colorSettings.secondaryColor,
					colorSettings.rgbBrightness,
					colorSettings.intensity,
					colorSettings.outlineIntensity
				)
			end
		
			context:ForcedMaterialOverride(espMaterials[colorSettings.name])
		end
	end
end)
