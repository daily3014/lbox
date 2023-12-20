local INTERVAL_SECONDS = 1
local IGNORE_FRIENDS = true
local IGNORE_TEAM = true
local MESSAGE = "%s, you're a nigga" -- %s is placeholder for the player name

local niggaCooldown = { }

local function getSteamID(player)
	local playerInfo = client.GetPlayerInfo(player:GetIndex())
	return playerInfo.SteamID
end

local function tableFind(tbl, value)
	for idx, val in pairs(tbl) do
		if val == value then
			return idx
		end
	end

	return nil
end

local function isFriends(player)
	local playerSteamID = getSteamID(player)
	local partyMembers = party.GetMembers()

	return playerlist.GetPriority(player) == -1 or tableFind(partyMembers, playerSteamID) ~= nil or steam.IsFriend(playerSteamID)
end

local function isOppositeTeam(player)
	local localPlayer = entities.GetLocalPlayer()

	return player:GetTeamNumber() ~= localPlayer:GetTeamNumber()
end

local function checkForNiggas()
	local localPlayer = entities.GetLocalPlayer()
	local players = entities.FindByClass("CTFPlayer")

	for idx, player in pairs(players) do
		local playerSteamID = getSteamID(player)

		if idx == localPlayer:GetIndex() then
			goto continue 
		end

		if IGNORE_FRIENDS and isFriends(player) then
			goto continue
		end

		if IGNORE_TEAM and not isOppositeTeam(player) then
			goto continue
		end

		if niggaCooldown[playerSteamID] and globals.CurTime() - niggaCooldown[playerSteamID] < INTERVAL_SECONDS then
			goto continue
		end

		niggaCooldown[playerSteamID] = globals.CurTime()

		local msg = MESSAGE:format(player:GetName())
		client.ChatSay(msg)

		::continue::
	end
end

callbacks.Register("PostPropUpdate", "AutoNigga.PostPropUpdate", checkForNiggas)
