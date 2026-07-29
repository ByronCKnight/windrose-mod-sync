-- NPC Respawn Tuner — modify spawner RespawnInterval and spawn counts
local M = {}
local applied = false
local originals = {}

function M.apply(cfg)
    local respawn_sec = (tonumber(cfg.respawn_minutes) or 45) * 60
    local spawn_mult = tonumber(cfg.spawn_multiplier) or 2
    local total_modified = 0

    local presets = FindAllOf("R5GameplaySpawnerVariantPreset")
    if presets then
        local count = 0
        for _, obj in ipairs(presets) do
            if obj:GetFullName():find("Default__") then goto skip_preset end

            pcall(function()
                local addr = tostring(obj:GetAddress())
                local spawn_data = obj.SpawnData
                if spawn_data then
                    if not originals[addr] then
                        originals[addr] = {}
                        for i = 0, spawn_data:GetArrayNum() - 1 do
                            local entry = spawn_data:GetArrayElement(i)
                            if entry then
                                originals[addr][i] = { Min = entry.Min or 1, Max = entry.Max or 1 }
                            end
                        end
                    end
                    for i = 0, spawn_data:GetArrayNum() - 1 do
                        local entry = spawn_data:GetArrayElement(i)
                        if entry and originals[addr][i] then
                            entry.Min = math.floor(originals[addr][i].Min * spawn_mult)
                            entry.Max = math.floor(originals[addr][i].Max * spawn_mult)
                        end
                    end
                    count = count + 1
                end
            end)

            ::skip_preset::
        end
        total_modified = total_modified + count
        if count > 0 then
            print("[SuperMod:NPCSpawn] Modified " .. count .. " spawn presets (" .. spawn_mult .. "x)")
        end
    end

    local spawner_classes = {
        "R5GameplaySpawner", "R5AISpawner", "R5GameplaySpawnerActor"
    }
    for _, cls in ipairs(spawner_classes) do
        local spawners = FindAllOf(cls)
        if spawners then
            local scount = 0
            for _, obj in ipairs(spawners) do
                if obj:GetFullName():find("Default__") then goto skip_spawner end
                pcall(function()
                    local addr = "ri_" .. tostring(obj:GetAddress())
                    if not originals[addr] then
                        originals[addr] = {
                            Min = obj.RespawnInterval and obj.RespawnInterval.Min or 3600,
                            Max = obj.RespawnInterval and obj.RespawnInterval.Max or 3600,
                        }
                    end
                    if obj.RespawnInterval then
                        obj.RespawnInterval.Min = respawn_sec
                        obj.RespawnInterval.Max = respawn_sec
                    end
                    scount = scount + 1
                end)
                ::skip_spawner::
            end
            total_modified = total_modified + scount
            if scount > 0 then
                print("[SuperMod:NPCSpawn] Set respawn to " .. (respawn_sec/60) .. "min on " .. scount .. " " .. cls .. " spawners")
            end
        end
    end

    if total_modified == 0 then
        print("[SuperMod:NPCSpawn] No spawn objects could be modified — spawner classes may not be accessible")
        return false
    end
    applied = true
end

function M.revert()
    if not applied then return end
    local presets = FindAllOf("R5GameplaySpawnerVariantPreset")
    if presets then
        for _, obj in ipairs(presets) do
            local addr = tostring(obj:GetAddress())
            if originals[addr] then
                pcall(function()
                    local sd = obj.SpawnData
                    if sd then
                        for i, orig in pairs(originals[addr]) do
                            local e = sd:GetArrayElement(i)
                            if e then e.Min = orig.Min; e.Max = orig.Max end
                        end
                    end
                end)
            end
        end
    end
    for _, cls in ipairs({"R5GameplaySpawner","R5AISpawner","R5GameplaySpawnerActor"}) do
        local spawners = FindAllOf(cls)
        if spawners then
            for _, obj in ipairs(spawners) do
                local addr = "ri_" .. tostring(obj:GetAddress())
                if originals[addr] and obj.RespawnInterval then
                    pcall(function()
                        obj.RespawnInterval.Min = originals[addr].Min
                        obj.RespawnInterval.Max = originals[addr].Max
                    end)
                end
            end
        end
    end
    originals = {}
    applied = false
    print("[SuperMod:NPCSpawn] Reverted spawn settings")
end

return M
