-- Farming Speed — reduce crop growth times and gathering cooldowns
-- Requires R5BL farming CDOs which may not exist on dedicated servers.
local M = {}
local applied = false
local originals = {}

function M.apply(cfg)
    local growth_mult = tonumber(cfg.growth_multiplier) or 0.25
    local gather_mult = tonumber(cfg.gather_cooldown) or 0.5

    local count = 0

    local farm_classes = {
        "R5BLFarmPlotParams", "R5BLCropData", "R5BLFarmingParams",
        "R5BLGardenParams", "R5BLPlantGrowthParams",
    }
    for _, cls in ipairs(farm_classes) do
        local all = FindAllOf(cls)
        if all then
            for _, obj in ipairs(all) do
                if obj:GetFullName():find("Default__") then goto skip end
                pcall(function()
                    local addr = cls .. "_" .. tostring(obj:GetAddress())
                    if not originals[addr] then
                        originals[addr] = {
                            GrowthTime = obj.GrowthTime or obj.GrowTime or obj.TimeToGrow,
                            GrowthDuration = obj.GrowthDuration,
                            HarvestCooldown = obj.HarvestCooldown,
                        }
                    end
                    local o = originals[addr]
                    if o.GrowthTime and o.GrowthTime > 0 then
                        if obj.GrowthTime then obj.GrowthTime = o.GrowthTime * growth_mult end
                        if obj.GrowTime then obj.GrowTime = o.GrowthTime * growth_mult end
                        if obj.TimeToGrow then obj.TimeToGrow = o.GrowthTime * growth_mult end
                        count = count + 1
                    end
                    if o.GrowthDuration and o.GrowthDuration > 0 then
                        obj.GrowthDuration = o.GrowthDuration * growth_mult
                    end
                    if o.HarvestCooldown and o.HarvestCooldown > 0 then
                        obj.HarvestCooldown = o.HarvestCooldown * gather_mult
                    end
                end)
                ::skip::
            end
        end
    end

    local gather_classes = {"R5GatherableParams", "R5BLGatherableResource"}
    for _, cls in ipairs(gather_classes) do
        local all = FindAllOf(cls)
        if all then
            for _, obj in ipairs(all) do
                if obj:GetFullName():find("Default__") then goto skip2 end
                pcall(function()
                    local addr = "g_" .. tostring(obj:GetAddress())
                    if not originals[addr] then
                        originals[addr] = {
                            RespawnTime = obj.RespawnTime or obj.RespawnDelay,
                            GatherTime = obj.GatherTime or obj.HarvestTime,
                        }
                    end
                    local o = originals[addr]
                    if o.RespawnTime and o.RespawnTime > 0 then
                        if obj.RespawnTime then obj.RespawnTime = o.RespawnTime * gather_mult end
                        if obj.RespawnDelay then obj.RespawnDelay = o.RespawnTime * gather_mult end
                        count = count + 1
                    end
                    if o.GatherTime and o.GatherTime > 0 then
                        if obj.GatherTime then obj.GatherTime = o.GatherTime * gather_mult end
                        if obj.HarvestTime then obj.HarvestTime = o.GatherTime * gather_mult end
                    end
                end)
                ::skip2::
            end
        end
    end

    if count == 0 then
        print("[SuperMod:Farming] No farming/crop/gathering CDOs found — these classes may not load on dedicated servers")
        return false
    end

    applied = true
    print("[SuperMod:Farming] Applied growth=" .. growth_mult .. "x gather=" .. gather_mult .. "x to " .. count .. " objects")
end

function M.revert()
    if not applied then return end
    for _, cls in ipairs({"R5BLFarmPlotParams","R5BLCropData","R5BLFarmingParams","R5BLGardenParams","R5BLPlantGrowthParams"}) do
        local all = FindAllOf(cls)
        if all then
            for _, obj in ipairs(all) do
                local addr = cls .. "_" .. tostring(obj:GetAddress())
                if originals[addr] then
                    pcall(function()
                        local o = originals[addr]
                        if o.GrowthTime then
                            if obj.GrowthTime then obj.GrowthTime = o.GrowthTime end
                            if obj.GrowTime then obj.GrowTime = o.GrowthTime end
                            if obj.TimeToGrow then obj.TimeToGrow = o.GrowthTime end
                        end
                        if o.GrowthDuration then obj.GrowthDuration = o.GrowthDuration end
                        if o.HarvestCooldown then obj.HarvestCooldown = o.HarvestCooldown end
                    end)
                end
            end
        end
    end
    for _, cls in ipairs({"R5GatherableParams","R5BLGatherableResource"}) do
        local all = FindAllOf(cls)
        if all then
            for _, obj in ipairs(all) do
                local addr = "g_" .. tostring(obj:GetAddress())
                if originals[addr] then
                    pcall(function()
                        local o = originals[addr]
                        if o.RespawnTime then
                            if obj.RespawnTime then obj.RespawnTime = o.RespawnTime end
                            if obj.RespawnDelay then obj.RespawnDelay = o.RespawnTime end
                        end
                        if o.GatherTime then
                            if obj.GatherTime then obj.GatherTime = o.GatherTime end
                            if obj.HarvestTime then obj.HarvestTime = o.GatherTime end
                        end
                    end)
                end
            end
        end
    end
    originals = {}
    applied = false
    print("[SuperMod:Farming] Reverted farming/gathering speeds")
end

return M
