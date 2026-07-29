-- Fishing — improve catch rates and fishing loot
local M = {}
local applied = false
local originals = {}

function M.apply(cfg)
    local loot_mult = tonumber(cfg.loot_multiplier) or 3
    local time_mult = tonumber(cfg.catch_time) or 0.5

    local count = 0

    -- Modify fishing loot tables (subset of R5BLLootParams)
    local all = FindAllOf("R5BLLootParams")
    if all then
        for _, obj in ipairs(all) do
            local name = obj:GetFullName()
            if name:find("Default__") then goto skip_loot end
            if not (name:find("Fish") or name:find("Fishing") or name:find("Butcher")) then goto skip_loot end

            pcall(function()
                local loot_data = obj.LootData
                if loot_data then
                    local addr = "loot_" .. tostring(obj:GetAddress())
                    if not originals[addr] then
                        originals[addr] = {}
                        for i = 0, loot_data:GetArrayNum() - 1 do
                            local entry = loot_data:GetArrayElement(i)
                            if entry then
                                originals[addr][i] = { Min = entry.Min or 0, Max = entry.Max or 0 }
                            end
                        end
                    end
                    for i = 0, loot_data:GetArrayNum() - 1 do
                        local entry = loot_data:GetArrayElement(i)
                        if entry and originals[addr][i] then
                            entry.Min = math.floor(originals[addr][i].Min * loot_mult)
                            entry.Max = math.floor(originals[addr][i].Max * loot_mult)
                        end
                    end
                    count = count + 1
                end
            end)

            ::skip_loot::
        end
    end

    -- Try fishing-specific CDOs for catch time
    local fish_classes = {"R5BLFishingParams", "R5FishingParams", "R5BLFishingData"}
    for _, cls in ipairs(fish_classes) do
        local items = FindAllOf(cls)
        if items then
            for _, obj in ipairs(items) do
                if obj:GetFullName():find("Default__") then goto skip_fish end

                pcall(function()
                    local addr = cls .. "_" .. tostring(obj:GetAddress())
                    if not originals[addr] then
                        originals[addr] = {
                            CatchTime = obj.CatchTime or obj.MinCatchTime,
                            MaxCatchTime = obj.MaxCatchTime,
                            BaitConsumption = obj.BaitConsumptionChance or obj.BaitConsumption,
                        }
                    end
                    local o = originals[addr]
                    if o.CatchTime and o.CatchTime > 0 then
                        if obj.CatchTime then obj.CatchTime = o.CatchTime * time_mult end
                        if obj.MinCatchTime then obj.MinCatchTime = o.CatchTime * time_mult end
                        count = count + 1
                    end
                    if o.MaxCatchTime and o.MaxCatchTime > 0 then
                        obj.MaxCatchTime = o.MaxCatchTime * time_mult
                    end
                    if o.BaitConsumption then
                        if obj.BaitConsumptionChance then obj.BaitConsumptionChance = math.min(1, o.BaitConsumption * time_mult) end
                        if obj.BaitConsumption then obj.BaitConsumption = math.min(1, o.BaitConsumption * time_mult) end
                    end
                end)

                ::skip_fish::
            end
        end
    end

    if count == 0 then
        print("[SuperMod:Fishing] No fishing objects found to modify")
        return false
    end

    applied = true
    print("[SuperMod:Fishing] Modified " .. count .. " fishing objects (loot=" .. loot_mult .. "x time=" .. time_mult .. "x)")
end

function M.revert()
    if not applied then return end
    local all = FindAllOf("R5BLLootParams")
    if all then
        for _, obj in ipairs(all) do
            local addr = "loot_" .. tostring(obj:GetAddress())
            if originals[addr] then
                pcall(function()
                    local ld = obj.LootData
                    if ld then
                        for i, orig in pairs(originals[addr]) do
                            local e = ld:GetArrayElement(i)
                            if e then e.Min = orig.Min; e.Max = orig.Max end
                        end
                    end
                end)
            end
        end
    end
    for _, cls in ipairs({"R5BLFishingParams","R5FishingParams","R5BLFishingData"}) do
        local items = FindAllOf(cls)
        if items then
            for _, obj in ipairs(items) do
                local addr = cls .. "_" .. tostring(obj:GetAddress())
                if originals[addr] then
                    pcall(function()
                        local o = originals[addr]
                        if o.CatchTime then
                            if obj.CatchTime then obj.CatchTime = o.CatchTime end
                            if obj.MinCatchTime then obj.MinCatchTime = o.CatchTime end
                        end
                        if o.MaxCatchTime then obj.MaxCatchTime = o.MaxCatchTime end
                        if o.BaitConsumption then
                            if obj.BaitConsumptionChance then obj.BaitConsumptionChance = o.BaitConsumption end
                            if obj.BaitConsumption then obj.BaitConsumption = o.BaitConsumption end
                        end
                    end)
                end
            end
        end
    end
    originals = {}
    applied = false
    print("[SuperMod:Fishing] Reverted fishing settings")
end

return M
