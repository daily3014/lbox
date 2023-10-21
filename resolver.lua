local config = {
    onlyHeadshots = true,
    maxMisses = 3,

    yawCycle = {
        0,
        45, -45, 
        90, -90,
        125, -125,
        180,
        "Invert"
    }
}

local usesAntiAim = {}
local lastConsecutiveShots = {}
local customAngleData = {}
local awaitingConfirmation = {}
local misses = {}
local headshotWeapons = {[17] = true, [43] = true}

local M_RADPI = 180 / math.pi

local function isNaN(x) return x ~= x end

local function getBool(event, name)
    local bool = event:GetInt(name)
    return bool == 1
end

local function getSteamID(player)
    local playerInfo = client.GetPlayerInfo(player:GetIndex())
    return playerInfo.SteamID
end

local function setupPlayerAngleData(player)
    local steamID = getSteamID(player)

    if customAngleData[steamID] then
        return
    end

    customAngleData[steamID] = {
        plr = player,
        yawCycleIndex = 0,
    }
end

local function resolvePitch(pitch)
    if pitch % 90 == 0 then
        return -pitch
    end

    if pitch % 271 ~= 0 then
        return pitch
    end

    return pitch / 271 * 89
end

local function announceResolve(name, yaw)
    local msg = string.format("\x06[\x07FF1122Lmaobox\x06] \x04Adjusted player '%s' yaw to %s", name, yaw)
    client.ChatPrintf(msg)
end

local function isUsingAntiAim(pitch)
    if pitch > 89.4 or pitch < -89.4 then
        return true
    end

    return false
end

local function getYaw(currentYaw, data)
    local newYaw = config.yawCycle[math.floor(data.yawCycleIndex)]

    if not newYaw then
        return currentYaw
    end

    if newYaw == "Invert" then
        return -currentYaw
    end

    return newYaw
end

local function getYawText(data)
    local newYaw = config.yawCycle[math.floor(data.yawCycleIndex)]

    if newYaw == "Invert" then
        return "Inverted"
    end

    return newYaw .. "°"
end

local function cycleYaw(data)
    if data.yawCycleIndex >= #config.yawCycle then
        data.yawCycleIndex = 1
        goto continue
    end

    data.yawCycleIndex = data.yawCycleIndex + .5

    ::continue::
    announceResolve(client.GetPlayerInfo(data.plr:GetIndex()).Name, getYawText(data))
end

local function tryingToShoot(cmd)
    if cmd and (cmd.buttons ~ IN_ATTACK) == 0 then
        return false
    end

    if gui.GetValue("aim position") == "body" then
        return false
    end

    if gui.GetValue("aim bot") then
        local keyMode = gui.GetValue("aim key mode")

        if keyMode == "press-to-toggle" then
            return true
        elseif keyMode == "hold-to-use" then
            if input.IsButtonDown(gui.GetValue("aim key")) then
                return true
            end
        else
            return true -- automatic aim mode
        end
    end

    return false
end

local function isValidWeapon(weapon)
    if not weapon then return false end
    if not weapon:IsWeapon() then return false end
    if not weapon:IsShootingWeapon() then return false end

    return true
end

local function getHitboxPos(entity, hitboxID)
    local hitbox = entity:GetHitboxes()[hitboxID]
    if not hitbox then return nil end

    return (hitbox[1] + hitbox[2]) * 0.5
end

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

local function angleFov(vFrom, vTo)
    local vSrc = vFrom:Forward()
    local vDst = vTo:Forward()
    
    local fov = math.deg(math.acos(vDst:Dot(vSrc) / vDst:LengthSqr()))
    if isNaN(fov) then fov = 0 end

    return fov
end

local function getEyePos(player)
    return player:GetAbsOrigin() + player:GetPropVector("localdata", "m_vecViewOffset[0]")
end

local function getEyeAngles(player)
    local angles = player:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
    return EulerAngles(angles.x, angles.y, angles.z)
end

local function getBestTarget()
    local localPlayer = entities.GetLocalPlayer()
    local players = entities.FindByClass("CTFPlayer")
    local target = nil
    local lastFov = math.huge

    for _, entity in pairs(players) do
        if not entity then goto continue end
        if not entity:IsAlive() then goto continue end
        if entity:GetTeamNumber() == localPlayer:GetTeamNumber() then goto continue end

        local player = entity
        local aimPos = getHitboxPos(player, 1)
        local angles = positionAngles(getEyePos(localPlayer), aimPos)
        local fov = angleFov(angles, engine.GetViewAngles())
        if fov > gui.GetValue("aim fov") then goto continue end

        --local trace = engine.TraceLine(getEyePos(localPlayer),    , MASK_SHOT | CONTENTS_GRATE)
        --if trace.entity ~= player or trace.fraction < 0.99 then goto continue end

        if fov < lastFov then
            lastFov = fov
            target = { entity = entity, pos = aimPos, angles = angles, factor = fov }
        end

        ::continue::
    end

    return target
end

local function playerShot(cmd, player, maxDifference)
    local player = player or entities.GetLocalPlayer()
    local maxDifference = maxDifference or defaultDifference

    local weapon = player:GetPropEntity("m_hActiveWeapon")
    if not isValidWeapon(weapon) then return false end
    if not tryingToShoot(cmd) then return false end

    local id = weapon:GetWeaponID()
    if onlyHeadshots and not headshotWeapons[id] then return end

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

local function propUpdate()
    local localPlayer = entities.GetLocalPlayer()
    local players = entities.FindByClass("CTFPlayer")

    for idx, player in pairs(players) do
        if idx == localPlayer:GetIndex() then goto continue end
        if player:IsDormant() or not player:IsAlive() then goto continue end
        
        if playerlist.GetPriority(player) then
            setupPlayerAngleData(player)
        end

        local steamID = getSteamID(player)
        local networkAngle = player:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]") 
        local customAngle = Vector3(networkAngle.x, networkAngle.y, networkAngle.z)
        
        if isUsingAntiAim(networkAngle.x) then
            if not usesAntiAim[steamID] then
                usesAntiAim[steamID] = true
            end 

            setupPlayerAngleData(player)
        end

        if customAngleData[steamID] then
            customAngle.y = getYaw(networkAngle.y, customAngleData[steamID])
            customAngle.x = resolvePitch(networkAngle.x)

            player:SetPropVector(customAngle, "tfnonlocaldata", "m_angEyeAngles[0]");
        end

        ::continue::
    end
end

callbacks.Register("CreateMove", function(cmd)
    local playerDidShoot = playerShot(cmd)
    local localPlayer = entities.GetLocalPlayer()

    if playerDidShoot then
        local victimInfo = getBestTarget()
    
        if victimInfo then
            local victim = victimInfo.entity

            awaitingConfirmation[getSteamID(victim)] = {enemy = victim, hitTime = globals.CurTime() + clientstate.GetLatencyIn() + clientstate.GetLatencyOut(), wasHit = false}
        end
    end

    for steamID, data in pairs(awaitingConfirmation) do
        local enemy, hitTime, wasHit = data.enemy, data.hitTime, data.wasHit

        if wasHit then
            awaitingConfirmation[steamID] = nil
            goto continue
        end

        if globals.CurTime() >= hitTime then
            if not wasHit then
                local usingAntiAim = usesAntiAim[steamID]

                if not usingAntiAim then
                    if not misses[steamID] then
                        misses[steamID] = 0
                    end

                    if misses[steamID] < config.maxMisses then
                        goto continue
                    end
                end

                if not customAngleData[steamID] then
                    setupPlayerAngleData(enemy)
                end

                cycleYaw(customAngleData[steamID])
            end

            awaitingConfirmation[steamID] = nil
            goto continue
        end

        ::continue::
    end
end)

callbacks.Register("FireGameEvent", function(event)
    if event:GetName() == 'player_hurt' then
        local localPlayer = entities.GetLocalPlayer()
        local victim = entities.GetByUserID(event:GetInt("userid"))
        local attacker = entities.GetByUserID(event:GetInt("attacker"))
        local headshot = getBool(event, "crit")

        if (attacker == nil or localPlayer:GetIndex() ~= attacker:GetIndex()) then
            local angles = getEyeAngles(attacker)

            if isUsingAntiAim(angles.pitch) then
                if not usesAntiAim[steamID] then
                    usesAntiAim[steamID] = true
                end 
    
                setupPlayerAngleData(player)
            end
            
            return
        end

        local steamID = getSteamID(victim)

        if awaitingConfirmation[steamID] then
            awaitingConfirmation[steamID].wasHit = headshot
        end
    end
end)

callbacks.Register("PostPropUpdate", propUpdate)
