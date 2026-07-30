-- DockMeBaby: saves a ship's position and rotation, then teleports every saved ship
-- back to its spot on demand.
--
-- Ships PATCHED - see docs/dockmebaby-patch.md. Pristine upstream is vendored at
-- vendor/DockMeBaby-2.0.0/main.lua.orig.
--
-- The two changes: the console commands are gone, replaced by keybinds (.) and (P),
-- and the save file moved to a name the launcher's stale-file sweep preserves.
local VERSION = "2.0.0 (windrose patch 1)"

local UEHelpers = require("UEHelpers")

local function Log(msg)
    print("[DockMeBaby] " .. tostring(msg) .. "\n")
end

-- [PATCH: windrose-mod-sync] begin - player-facing feedback
-- Upstream reported everything to the UE4SS console, which this repo disables by design
-- (ConsoleEnabled = 0), so a player pressing a key got no feedback whatsoever.
--
-- There is no guaranteed on-screen channel here. UKismetSystemLibrary:PrintString is
-- compiled out of UE5 Shipping builds, so it is attempted and must NOT be relied on;
-- if Windrose ships with screen messages live it works, otherwise it is a silent no-op.
-- Every message therefore also goes to UE4SS.log, which is the one channel known to work.
--
-- To put this in the game's own notification UI we need the toast widget's class name,
-- which means an object dump (Ctrl+J, bound by the Keybinds mod). See
-- docs/dockmebaby-patch.md.
local SCREEN_MESSAGE_SECONDS = 5.0

local function Notify(msg)
    Log(msg)
    pcall(function()
        local ksl = UEHelpers.GetKismetSystemLibrary()
        if ksl and ksl:IsValid() then
            ksl:PrintString(UEHelpers.GetWorldContextObject(), "[Dock] " .. msg,
                            true, false, { R = 0.25, G = 0.85, B = 1.0, A = 1.0 },
                            SCREEN_MESSAGE_SECONDS)
        end
    end)
end
-- [/PATCH]

-- ==========================================
-- HELPER FUNCTIONS
-- ==========================================
local function GetPlayerSafe()
    local ok1, r1 = pcall(function()
        local chars = FindAllOf("BP_R5Character_C")
        if chars then
            for _, c in ipairs(chars) do
                if c and c:IsValid() then return c end
            end
        end
        return nil
    end)
    if ok1 and r1 then return r1 end

    local ok2, r2 = pcall(function()
        local pc = FindFirstOf("PlayerController")
        if pc and pc:IsValid() then
            local pawn = pc:GetPawn()
            if pawn and pawn:IsValid() then return pawn end
        end
        return nil
    end)
    if ok2 and r2 then return r2 end

    local ok3, r3 = pcall(UEHelpers.GetPlayer)
    if ok3 and r3 and r3:IsValid() then return r3 end

    return nil
end

local function GetActorLoc(actor)
    if not actor then return nil end
    local ok, loc = pcall(function() return actor:K2_GetActorLocation() end)
    if ok and loc then
        local okX = pcall(function() return loc.X + 0 end)
        if okX then return loc end
    end
    local ok2, loc2 = pcall(function()
        local root = actor.RootComponent
        if root then return root.RelativeLocation end
        return nil
    end)
    if ok2 and loc2 then
        local okX = pcall(function() return loc2.X + 0 end)
        if okX then return loc2 end
    end
    return nil
end

local function GetPawnFromContextOwner(owner)
    if not owner or not owner:IsValid() then return nil end
    local name = owner:GetFullName()
    if string.find(name, "Character") or string.find(name, "Pawn") then
        return owner
    end
    local ok, p = pcall(function() return owner:GetPawn() end)
    if not (ok and p and p:IsValid()) then
        ok, p = pcall(function() return owner:K2_GetPawn() end)
    end
    if not (ok and p and p:IsValid()) then
        pcall(function() p = owner.Pawn end)
    end
    if ok and p and p:IsValid() then return p end
    return nil
end

local function GetPlayerNameFromContextOwner(owner)
    if not owner or not owner:IsValid() then return "UnknownPlayer" end

    local ps = nil
    local name = owner:GetFullName()

    if string.find(name, "PlayerState") then
        ps = owner
    else
        pcall(function() ps = owner.PlayerState end)
    end

    if ps and ps:IsValid() then
        local okName, pName = pcall(function() return ps:GetPlayerName() end)
        if okName and pName then
            local rawName = ""
            pcall(function()
                if type(pName) == "userdata" then
                    local okStr, str = pcall(function() return pName:ToString() end)
                    if okStr and str then rawName = str else rawName = tostring(pName) end
                else
                    rawName = tostring(pName)
                end
            end)

            if rawName ~= "" and not string.match(rawName, "^FString%s") then
                local safeName = string.gsub(rawName, '[^%w%s_]', '')
                if safeName ~= "" then return safeName end
            end
        end
    end
    return "UnknownPlayer"
end

local function GetWorldID(contextActor)
    -- Attempt 1: Blueprint Getter UR5UICommonLibrary::GetWorldRandomSeed
    local okLib, libClass = pcall(function() return StaticClass("/Script/R5.R5UICommonLibrary") end)
    if okLib and libClass and libClass:IsValid() then
        local okCDO, lib = pcall(function() return libClass:GetDefaultObject() end)
        if okCDO and lib and lib:IsValid() then
            local okSeed, seed = pcall(function() return lib:GetWorldRandomSeed(contextActor) end)
            if okSeed and seed then
                local numSeed = tonumber(seed)
                if not numSeed and type(seed) == "userdata" then
                    local okGet, unwr = pcall(function() return seed:get() end)
                    if okGet and unwr then numSeed = tonumber(unwr) end
                end
                if numSeed and numSeed ~= 0 then return "WorldSeed_" .. tostring(numSeed) end
            end
        end
    end

    -- Attempt 2: ArchipelagoSeed from ALL R5WorldGenerator instances
    local okWG, wgs = pcall(function() return FindAllOf("R5WorldGenerator") end)
    if okWG and wgs then
        for _, wg in ipairs(wgs) do
            if wg and wg:IsValid() then
                local okSeed, seed = pcall(function() return wg.ArchipelagoSeed end)
                if okSeed and seed then
                    local numSeed = tonumber(seed)
                    if not numSeed and type(seed) == "userdata" then
                        local okGet, unwr = pcall(function() return seed:get() end)
                        if okGet and unwr then numSeed = tonumber(unwr) end
                    end
                    if numSeed and numSeed ~= 0 then return "WorldSeed_" .. tostring(numSeed) end
                end
            end
        end
    end

    -- Attempt 3: ULocalPlayerSaveGame -> SaveSlotName (Safe fallback for SP if Seed is truly 0)
    local okSave, saveGames = pcall(function() return FindAllOf("LocalPlayerSaveGame") end)
    if okSave and saveGames then
        for _, saveGame in ipairs(saveGames) do
            if saveGame and saveGame:IsValid() then
                local okSlot, slot = pcall(function() return saveGame.SaveSlotName end)
                if okSlot and slot then
                    local strSlot = ""
                    pcall(function()
                        if type(slot) == "userdata" then
                            local okStr, str = pcall(function() return slot:ToString() end)
                            if okStr and str then
                                strSlot = str
                            else
                                local okGet, unwr = pcall(function() return slot:get() end)
                                if okGet and unwr then strSlot = tostring(unwr) else strSlot = tostring(slot) end
                            end
                        else
                            strSlot = tostring(slot)
                        end
                    end)

                    if strSlot ~= "" and not string.match(strSlot, "^FString%s") and strSlot ~= "nil" then
                        local lowerSlot = string.lower(strSlot)
                        if not string.find(lowerSlot, "settings") and not string.find(lowerSlot, "profile") then
                            local safeSlot = string.gsub(strSlot, '[^%w%s_-]', '')
                            if safeSlot ~= "" then return "SaveSlot_" .. safeSlot end
                        end
                    end
                end
            end
        end
    end

    -- Attempt 4: Safe fallback to base map name (e.g. GenlandiaMulty)
    local ok, world = pcall(function() return contextActor:GetWorld() end)
    if not ok or not world or not world:IsValid() then
        ok, world = pcall(UEHelpers.GetWorld)
    end
    if ok and world and world:IsValid() then
        local okName, name = pcall(function() return world:GetName() end)
        if okName and name then
            local safeName = string.gsub(name, '[^%w%s_]', '')
            if safeName ~= "" then return safeName end
        end
    end

    return "UnknownWorld"
end

local function GetShipID(ship)
    if not ship or not ship:IsValid() then return nil end
    local ok, val = pcall(function() return ship.ShipId end)
    if ok and val then
        -- Unwrap val if it's a RemoteUnrealParam Wrapper
        if type(val) == "userdata" then
            local okGet, unwrapped = pcall(function() return val:get() end)
            if okGet and unwrapped then val = unwrapped end
        end

        local okID, innerID = pcall(function() return val.ID end)
        if not okID or not innerID then
            okID, innerID = pcall(function() return val.Id end)
        end

        if okID and innerID then
            local s = ""
            pcall(function()
                if type(innerID) == "userdata" then
                    local okStr, str = pcall(function() return innerID:ToString() end)
                    if okStr and str then s = str
                    else
                        local okGet, unwr = pcall(function() return innerID:get() end)
                        if okGet and unwr then s = tostring(unwr) else s = tostring(innerID) end
                    end
                else
                    s = tostring(innerID)
                end
            end)

            -- Match consecutive hex characters (+ means 1 or more)
            local hex = string.match(s, "([A-Fa-f0-9]+)")
            if hex and string.len(hex) >= 16 then return hex end
        end
    end
    return nil
end

-- Checks if the player is within a specific distance of ANY BuildingCenter (Camp)
local function IsCharacterNearCamp(character, maxDistance)
    local pLoc = GetActorLoc(character)
    if not pLoc then
        Log("Could not verify character location for camp proximity check.")
        return false, 999999999
    end

    local bestDist = 999999999
    local campClasses = {
        "BP_BuildingBlock_BuildingCenterT01_C",
        "BP_BuildingBlock_BuildingCenterT02_C",
        "BP_BuildingBlock_BuildingCenterT03_C"
    }

    for _, className in ipairs(campClasses) do
        local ok, actors = pcall(function() return FindAllOf(className) end)
        if ok and actors then
            for _, actor in ipairs(actors) do
                if actor and actor:IsValid() then
                    local aLoc = GetActorLoc(actor)
                    if aLoc then
                        local dx = pLoc.X - aLoc.X
                        local dy = pLoc.Y - aLoc.Y
                        local dz = pLoc.Z - aLoc.Z
                        local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
                        if dist < bestDist then
                            bestDist = dist
                        end
                    end
                end
            end
        end
    end

    return (bestDist <= maxDistance), bestDist
end

-- Finds the ship physically closest to the player (so we save the right one if multiple exist)
local function GetClosestShipToCharacter(character)
    local pLoc = GetActorLoc(character)
    if not pLoc then
        Log("Could not find character location.")
        return nil
    end

    local bestShip = nil
    local bestDist = 999999999

    local ok, pawns = pcall(function() return FindAllOf("Pawn") end)
    if not ok or not pawns then return nil end

    for _, pawn in ipairs(pawns) do
        if pawn and pawn:IsValid() then
            local okName, name = pcall(function() return pawn:GetFullName() end)
            if okName and name then
                local lowerName = string.lower(name)
                local isShip = string.find(lowerName, "ship") and not string.find(lowerName, "character")
                if isShip then
                    local sLoc = GetActorLoc(pawn)
                    if sLoc then
                        local dx = pLoc.X - sLoc.X
                        local dy = pLoc.Y - sLoc.Y
                        local dz = pLoc.Z - sLoc.Z
                        local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
                        if dist < bestDist then
                            bestDist = dist
                            bestShip = pawn
                        end
                    end
                end
            end
        end
    end

    -- 15000 units is approx 150 meters. Prevents saving ships halfway across the map.
    if bestShip and bestDist < 15000 then
        return bestShip
    end

    Log("No ship found close enough to the player.")
    return nil
end

-- ==========================================
-- DATA MANAGEMENT
-- ==========================================
-- [PATCH: windrose-mod-sync] begin - save file renamed
-- Upstream wrote DockMeBaby_SaveData.lua next to enabled.txt. That path is inside the
-- launcher's managed tree, and anything in there the manifest doesn't list is stale and
-- gets deleted - so every launch would have wiped the player's docks. The .savedata.lua
-- suffix is on the launcher's preserve list. See docs/dockmebaby-patch.md.
--
-- The directory already exists (Scripts/ and enabled.txt ship into it), which matters
-- because Lua cannot create one.
local function GetSaveFilePath()
    return "ue4ss/Mods/DockMeBaby/DockMeBaby.savedata.lua"
end
-- [/PATCH]

local function LoadDockData()
    local fileName = GetSaveFilePath()
    local file = io.open(fileName, "r")
    if not file then return {} end

    local content = file:read("*a")
    file:close()

    local chunk = load(content)
    if chunk then
        local ok, data = pcall(chunk)
        if ok and type(data) == "table" then
            return data
        end
    end
    return {}
end

local function SaveDockData(data)
    local fileName = GetSaveFilePath()
    local file = io.open(fileName, "w")

    if not file then
        Log("Error: Could not open " .. fileName .. " for writing.")
        return
    end

    -- Write proper nested Lua dictionary structure
    file:write("return {\n")
    for worldId, players in pairs(data) do
        file:write(string.format('  ["%s"] = {\n', worldId))
        for playerName, ships in pairs(players) do
            file:write(string.format('    ["%s"] = {\n', playerName))
            for shipClass, spots in pairs(ships) do
                -- Support new direct GUID mapping or old array format
                if spots.X then
                    file:write(string.format('      ["%s"] = { X = %f, Y = %f, Z = %f, Yaw = %f },\n', shipClass, spots.X, spots.Y, spots.Z, spots.Yaw))
                elseif type(spots) == "table" and spots[1] then
                    file:write(string.format('      ["%s"] = {\n', shipClass))
                    for i, coords in ipairs(spots) do
                        file:write(string.format('        [%d] = { X = %f, Y = %f, Z = %f, Yaw = %f },\n', i, coords.X, coords.Y, coords.Z, coords.Yaw))
                    end
                    file:write("      },\n")
                end
            end
            file:write("    },\n")
        end
        file:write("  },\n")
    end
    file:write("}\n")
    file:close()
    Log("Success! Saved multi-ship data to " .. fileName)
end

-- ==========================================
-- COMMANDS
-- ==========================================

local function ExecuteSetDockLogic(playerName, ship, worldID)
    Log("Server executing 'setdock' for " .. playerName .. " in world: " .. worldID)

    local okName, name = pcall(function() return ship:GetFullName() end)
    local shipClass = string.match(name, "^([^%s]+)") or name
    local shipId = GetShipID(ship)
    local key = shipId and (shipClass .. "_" .. shipId) or shipClass

    Log("Targeting Ship: " .. tostring(key) .. " for Player: " .. playerName)

    local loc = GetActorLoc(ship)
    local okRot, rot = pcall(function() return ship:K2_GetActorRotation() end)

    if loc and okRot and rot then
        Log(string.format("Current Ship Transform -> X:%.2f, Y:%.2f, Z:%.2f, Yaw:%.2f", loc.X, loc.Y, loc.Z, rot.Yaw))

        local data = LoadDockData()
        if not data[worldID] then data[worldID] = {} end
        if not data[worldID][playerName] then data[worldID][playerName] = {} end

        data[worldID][playerName][key] = { X = loc.X, Y = loc.Y, Z = loc.Z, Yaw = rot.Yaw }
        Log(string.format("Saved dock for %s.", key))

        SaveDockData(data)
        -- [PATCH: windrose-mod-sync] report the outcome so the caller can tell the player
        return true, key
    else
        Log("Error: Failed to read ship location or rotation.")
        return false, "could not read the ship's position"
    end
end

local function ExecuteDockLogic(character, playerName, worldID)
    Log("Server executing 'dock' for " .. playerName .. " in world: " .. worldID)
    local data = LoadDockData()

    if not data[worldID] or not data[worldID][playerName] then
        Log("Error: No saved docks found for player: " .. playerName .. " in world: " .. worldID)
        -- [PATCH: windrose-mod-sync] every exit returns (count, reason) so the caller can report
        return 0, "no docks saved yet - press (.) next to a ship first"
    end

    -- Anti-Cheat: Check proximity to Camp (BuildingCenter)
    local maxAllowedDistance = 25000
    local isNear, currentDist = IsCharacterNearCamp(character, maxAllowedDistance)

    if not isNear then
        if currentDist == 999999999 then
            Log("Error: Could not find any Camp (BuildingCenter) in the world. You need a camp to dock.")
            return 0, "no Camp found - you need a camp to dock"
        end
        Log(string.format("Error: You are too far from your Camp to dock! (Distance: %.0f / %.0f)", currentDist, maxAllowedDistance))
        return 0, string.format("too far from your Camp (%.0fm away, need %.0fm)",
                                currentDist / 100, maxAllowedDistance / 100)
    end

    local ok, pawns = pcall(function() return FindAllOf("Pawn") end)
    if not ok or not pawns then return 0, "could not enumerate ships" end

    local dockedCount = 0
    local teleportedCharacters = {}
    for _, pawn in ipairs(pawns) do
        if pawn and pawn:IsValid() then
            local okName, name = pcall(function() return pawn:GetFullName() end)
            if okName and name then
                local lowerName = string.lower(name)
                local isShip = string.find(lowerName, "ship") and not string.find(lowerName, "character")
                if isShip then
                    local shipClass = string.match(name, "^([^%s]+)") or name
                    local shipId = GetShipID(pawn)
                    local key = shipId and (shipClass .. "_" .. shipId) or shipClass

                    local savedCoords = data[worldID][playerName][key]

                    -- Backwards compatibility with older array structures just in case
                    if not savedCoords and data[worldID][playerName][shipClass] then
                        local spots = data[worldID][playerName][shipClass]
                        if type(spots) == "table" and spots[1] then savedCoords = spots[1] end
                    end

                    if savedCoords and savedCoords.X then
                        local targetLoc = { X = savedCoords.X, Y = savedCoords.Y, Z = savedCoords.Z }
                        local targetRot = { Pitch = 0, Yaw = savedCoords.Yaw, Roll = 0 }

                        local sLoc = GetActorLoc(pawn)
                        local okRot, sRot = pcall(function() return pawn:K2_GetActorRotation() end)

                        pcall(function() pawn:K2_SetActorLocationAndRotation(targetLoc, targetRot, false, {}, true) end)

                        -- Dedicated Server Passenger Fix: Explicitly move players riding the ship
                        if sLoc and okRot and sRot then
                            local okChars, allChars = pcall(function() return FindAllOf("BP_R5Character_C") end)
                            if okChars and allChars then
                                for _, c in ipairs(allChars) do
                                    if c and c:IsValid() and not teleportedCharacters[c] then
                                        local cLoc = GetActorLoc(c)
                                        if cLoc then
                                            local dx = cLoc.X - sLoc.X
                                            local dy = cLoc.Y - sLoc.Y
                                            local dz = cLoc.Z - sLoc.Z
                                            local dist = math.sqrt(dx*dx + dy*dy + dz*dz)

                                            -- 5000 units (50 meters) covers even large galleons
                                            if dist < 5000 then
                                                local currentYawRad = math.rad(sRot.Yaw)
                                                local targetYawRad = math.rad(targetRot.Yaw)
                                                local deltaYawRad = targetYawRad - currentYawRad

                                                local cosD = math.cos(deltaYawRad)
                                                local sinD = math.sin(deltaYawRad)

                                                local charTargetLoc = {
                                                    X = targetLoc.X + (dx * cosD - dy * sinD),
                                                    Y = targetLoc.Y + (dx * sinD + dy * cosD),
                                                    Z = targetLoc.Z + dz + 150
                                                }

                                                pcall(function() c:K2_SetActorLocationAndRotation(charTargetLoc, targetRot, false, {}, true) end)
                                                teleportedCharacters[c] = true
                                                Log("Teleported a passenger with the ship (Dist: " .. tostring(math.floor(dist)) .. ").")
                                            end
                                        end
                                    end
                                end
                            end
                        end

                        Log(string.format("Success! %s docked.", key))
                        dockedCount = dockedCount + 1
                    end
                end
            end
        end
    end

    if dockedCount == 0 then
        Log("Error: Found saved data, but no matching active ships in the world.")
        return 0, "saved docks exist, but none of those ships are in this world"
    end
    return dockedCount
end

-- ==========================================
-- CLIENT RPC DISPATCHER
-- ==========================================
local function DispatchCommandSequence(pingCount)
    local pc = nil
    pcall(function() pc = UEHelpers.GetPlayerController() end)
    if not pc or not pc:IsValid() then
        pcall(function() pc = FindFirstOf("PlayerController") end)
    end

    if not pc or not pc:IsValid() then
        Log("Error: No PlayerController found to dispatch commands.")
        return false
    end

    Log(string.format("Dispatching sequence of %d pings...", pingCount))

    local function sendPings(remaining)
        if remaining > 0 and pc and pc:IsValid() then
            pcall(function() pc:ServerCheckClientPossession() end)
            ExecuteWithDelay(250, function() sendPings(remaining - 1) end)
        end
    end
    sendPings(pingCount)

    return true
end

-- ==========================================
-- KEYBINDS (Client Side)
-- ==========================================
-- [PATCH: windrose-mod-sync] begin - keybinds replace console commands
-- Upstream drove this mod from RegisterConsoleCommandHandler("setdock"/"dock"). Windrose
-- Mod Sync deliberately ships no ConsoleEnablerMod and sets ConsoleEnabled = 0 in
-- UE4SS-settings.ini, so those commands registered fine and no player could ever type
-- them. They are bound to keys instead. See docs/dockmebaby-patch.md.

-- Rebind here. Key names are the UE4SS list at the bottom of
-- ue4ss\Mods\Keybinds\Scripts\main.lua. The (.) key is OEM_PERIOD; numpad . is DECIMAL.
-- ModifierKeys takes e.g. { ModifierKey.CONTROL } if a bare key proves too easy to hit.
local DockKeybinds = {
    SetDock = { Key = Key.OEM_PERIOD, ModifierKeys = {} },
    Dock    = { Key = Key.P,          ModifierKeys = {} },
}

-- UE4SS keybinds are polled off the game thread, and they fire regardless of what the
-- game thinks the key means - including while a text field has focus. A bare (.) that
-- silently overwrites a saved dock is worth a moment's protection, so a repeat inside
-- this window is dropped. os.clock() to match the RPC tracker below.
local KEY_COOLDOWN_SECONDS = 1.0
local lastFired = {}

local function OnCooldown(name)
    local now = os.clock()
    local prev = lastFired[name]
    if prev and (now - prev) < KEY_COOLDOWN_SECONDS then return true end
    lastFired[name] = now
    return false
end

-- The same file ships to the client, the Host Game server process and the dedicated
-- server, matching how CampDepositReloaded is handled - the server half below has to
-- run where authority is, and the keybinds have to run where the keyboard is. Only a
-- client or a singleplayer session is the latter: a dedicated server's console window
-- must never be able to teleport somebody's ship.
--
-- The probe is the game viewport. UEHelpers documents it as the thing that "doesn't
-- exist on a server", and it is a plain property read off UEngine rather than a UFunction
-- call, so it answers reliably. Note that FindFirstOf("PlayerController") does NOT
-- discriminate - on a server it happily returns a connected player's controller.
--
-- Fails CLOSED: no viewport, no keypress. Better to ignore a key than to guess.
local function HasLocalPlayer()
    local ok, viewport = pcall(UEHelpers.GetGameViewportClient)
    return (ok and viewport and viewport:IsValid()) and true or false
end

-- Bodies of the two former console handlers, unchanged apart from being named.
local function TriggerSetDock()
    local player = GetPlayerSafe()

    local pc = nil
    pcall(function() pc = UEHelpers.GetPlayerController() end)
    if not pc or not pc:IsValid() then pcall(function() pc = FindFirstOf("PlayerController") end) end

    local hasAuth = false
    if pc and pc:IsValid() then pcall(function() hasAuth = pc:HasAuthority() end) end

    local ship = GetClosestShipToCharacter(player)
    if not ship then
        Notify("setdock failed - stand next to a ship first.")
        return
    end

    if hasAuth then
        Log("Local Authority detected (SP/Host). Executing 'setdock' directly...")
        local playerName = GetPlayerNameFromContextOwner(pc)
        local worldID = GetWorldID(pc)
        local ok, detail = ExecuteSetDockLogic(playerName, ship, worldID)
        if ok then
            Notify("Dock saved for this ship.")
        else
            Notify("setdock failed - " .. tostring(detail) .. ".")
        end
    else
        Log("Client detected. Sending 'setdock' sequence (5 pings) to server...")
        if DispatchCommandSequence(5) then
            Notify("setdock sent to the server...")
        else
            Notify("setdock failed - could not reach the server.")
        end
    end
end

local function TriggerDock()
    local pc = nil
    pcall(function() pc = UEHelpers.GetPlayerController() end)
    if not pc or not pc:IsValid() then pcall(function() pc = FindFirstOf("PlayerController") end) end

    local hasAuth = false
    if pc and pc:IsValid() then pcall(function() hasAuth = pc:HasAuthority() end) end

    if hasAuth then
        Log("Local Authority detected (SP/Host). Executing 'dock' directly...")
        local player = GetPlayerSafe()
        local playerName = GetPlayerNameFromContextOwner(pc)
        local worldID = GetWorldID(pc)
        if not (player and player:IsValid()) then
            Notify("dock failed - could not find your character.")
            return
        end
        local docked, reason = ExecuteDockLogic(player, playerName, worldID)
        if docked and docked > 0 then
            Notify(string.format("Docked %d ship%s.", docked, docked == 1 and "" or "s"))
        else
            Notify("dock failed - " .. tostring(reason) .. ".")
        end
    else
        Log("Client detected. Sending 'dock' sequence (3 pings) to server...")
        if DispatchCommandSequence(3) then
            Notify("dock sent to the server...")
        else
            Notify("dock failed - could not reach the server.")
        end
    end
end

-- Dispatch. The first version of this patch marshalled onto the game thread via
-- ExecuteInGameThread, on the reasoning that a console handler already ran there and a
-- keybind callback does not. That silently broke both keys: on Windrose,
-- ExecuteInGameThread is a black hole. UE4SS cannot install the UEngine::Tick detour in
-- a Shipping binary, so HookEngineTick is pinned to 0 (see the CRITICAL note in
-- UE4SS-settings.ini, and the log line "[EngineTick] ... hooking is disabled"). Queued
-- actions are never drained - the keys bound, the callbacks queued, nothing ever ran.
--
-- So we run directly, which is exactly what WindrosePlus's dispatcher falls back to on
-- this same stack ("ExecuteInGameThread unavailable ... writers will run directly").
-- Flip this to true only if HookEngineTick is ever safely enabled on Windrose.
local USE_GAME_THREAD_DISPATCH = false

local function OnKey(name, action)
    return function()
        -- Logged before anything else can fail, so a keypress ALWAYS leaves a trace in
        -- UE4SS.log. Silence here means the key never reached the mod at all.
        Log(name .. ": key pressed")

        if OnCooldown(name) then
            Log(name .. ": ignored - within the " .. KEY_COOLDOWN_SECONDS .. "s cooldown")
            return
        end

        local function run()
            if not HasLocalPlayer() then
                Log(name .. ": ignored - no local player in this process (server-side copy)")
                return
            end
            action()
        end

        if USE_GAME_THREAD_DISPATCH then
            ExecuteInGameThread(run)
        else
            -- Off the game thread, so an error here would otherwise vanish silently.
            local ok, err = pcall(run)
            if not ok then Log(name .. ": FAILED - " .. tostring(err)) end
        end
    end
end

local function RegisterKey(name, binding, callback)
    local mods = binding.ModifierKeys
    local hasMods = mods and #mods > 0

    local taken = false
    if hasMods then
        pcall(function() taken = IsKeyBindRegistered(binding.Key, mods) end)
    else
        pcall(function() taken = IsKeyBindRegistered(binding.Key) end)
    end
    if taken then
        Log(name .. ": that key is already registered by another mod - not binding.")
        return
    end

    local ok, err
    if hasMods then
        ok, err = pcall(RegisterKeyBindAsync, binding.Key, mods, callback)
    else
        ok, err = pcall(RegisterKeyBindAsync, binding.Key, callback)
    end
    if ok then
        Log(name .. " bound.")
    else
        Log(name .. ": failed to bind - " .. tostring(err))
    end
end

RegisterKey("setdock", DockKeybinds.SetDock, OnKey("setdock", TriggerSetDock))
RegisterKey("dock",    DockKeybinds.Dock,    OnKey("dock",    TriggerDock))
-- [/PATCH]

-- ==========================================
-- SERVER SIDE RPC HOOK
-- ==========================================
local rpcTracker = {}
RegisterHook("/Script/Engine.PlayerController:ServerCheckClientPossession", function(Context)
    local contextObj = Context
    if type(Context) == "userdata" then
        local okCtx, ctxGet = pcall(function() return Context:get() end)
        if okCtx and ctxGet then contextObj = ctxGet end
    end

    -- The PlayerController itself is the root network object; it has no higher "owner"
    local owner = contextObj
    if not owner or not owner:IsValid() then return end

    local playerName = GetPlayerNameFromContextOwner(owner)

    if not rpcTracker[playerName] then
        rpcTracker[playerName] = { count = 0, lastTime = 0 }
    end
    local t = rpcTracker[playerName]

    local currentTime = os.clock()
    if (currentTime - t.lastTime) > 2.0 then
        t.count = 0
    end
    t.lastTime = currentTime
    t.count = t.count + 1

    local snapCount = t.count

    local pawn = GetPawnFromContextOwner(owner) or owner
    local worldID = GetWorldID(owner)

    ExecuteWithDelay(800, function()
        if rpcTracker[playerName] and rpcTracker[playerName].count == snapCount then
            if snapCount == 3 then
                Log("Server intercepted Dock sequence (3 pings) for " .. playerName .. "!")
                if pawn and pawn:IsValid() then
                    ExecuteDockLogic(pawn, playerName, worldID)
                end
            elseif snapCount == 5 then
                Log("Server intercepted SetDock sequence (5 pings) for " .. playerName .. "!")
                if pawn and pawn:IsValid() then
                    local ship = GetClosestShipToCharacter(pawn)
                    if ship then
                        ExecuteSetDockLogic(playerName, ship, worldID)
                    else
                        Log("Server Error: Player not near a ship.")
                    end
                end
            end
            if snapCount >= 3 then
                rpcTracker[playerName].count = 0
            end
        end
    end)
end)

-- Entry point execution
Log("Mod initialized successfully. v" .. VERSION)
-- [PATCH: windrose-mod-sync] the console commands are gone; report the keys instead
Log("Keys: (.) setdock - save the nearest ship's spot | (P) dock - recall saved ships")
-- [/PATCH]
