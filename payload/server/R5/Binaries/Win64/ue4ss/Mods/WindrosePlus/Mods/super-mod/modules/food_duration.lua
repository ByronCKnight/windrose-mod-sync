-- Food/Consumable Duration — multiply buff durations from consumables
-- Requires GameplayEffect or R5BL consumable CDOs which may not exist on dedicated servers.
local M = {}
local applied = false
local originals = {}

function M.apply(cfg)
    local mult = tonumber(cfg.duration_multiplier) or 3

    local count = 0

    local ge_all = FindAllOf("GameplayEffect")
    if ge_all then
        for _, obj in ipairs(ge_all) do
            local name = obj:GetFullName()
            if name:find("Default__") then goto skip end
            if not (name:find("Food") or name:find("Drink") or name:find("Potion")
                or name:find("Consumable") or name:find("Buff") or name:find("Meal")) then
                goto skip
            end

            pcall(function()
                local addr = tostring(obj:GetAddress())
                if not originals[addr] then
                    originals[addr] = { Period = obj.Period }
                end
                if originals[addr].Period and originals[addr].Period > 0 then
                    obj.Period = originals[addr].Period / math.max(0.01, mult)
                    count = count + 1
                end
            end)

            ::skip::
        end
    end

    local r5_classes = {"R5BLConsumableParams", "R5BLFoodData", "R5BLConsumableDataAsset"}
    for _, cls in ipairs(r5_classes) do
        local items = FindAllOf(cls)
        if items then
            for _, obj in ipairs(items) do
                if obj:GetFullName():find("Default__") then goto skip2 end

                pcall(function()
                    local addr = "r5_" .. tostring(obj:GetAddress())
                    if not originals[addr] then
                        originals[addr] = {
                            Duration = obj.EffectDuration or obj.BuffDuration or 0,
                            Cooldown = obj.Cooldown or 0,
                        }
                    end
                    if originals[addr].Duration > 0 then
                        if obj.EffectDuration then obj.EffectDuration = originals[addr].Duration * mult end
                        if obj.BuffDuration then obj.BuffDuration = originals[addr].Duration * mult end
                        count = count + 1
                    end
                end)

                ::skip2::
            end
        end
    end

    if count == 0 then
        print("[SuperMod:FoodDuration] No GameplayEffect or consumable CDOs found — these classes may not load on dedicated servers")
        return false
    end

    applied = true
    print("[SuperMod:FoodDuration] Applied " .. mult .. "x duration to " .. count .. " effects")
end

function M.revert()
    if not applied then return end
    local ge_all = FindAllOf("GameplayEffect")
    if ge_all then
        for _, obj in ipairs(ge_all) do
            local addr = tostring(obj:GetAddress())
            if originals[addr] then
                pcall(function()
                    if originals[addr].Period then obj.Period = originals[addr].Period end
                end)
            end
        end
    end
    for _, cls in ipairs({"R5BLConsumableParams","R5BLFoodData","R5BLConsumableDataAsset"}) do
        local items = FindAllOf(cls)
        if items then
            for _, obj in ipairs(items) do
                local addr = "r5_" .. tostring(obj:GetAddress())
                if originals[addr] then
                    pcall(function()
                        if obj.EffectDuration then obj.EffectDuration = originals[addr].Duration end
                        if obj.BuffDuration then obj.BuffDuration = originals[addr].Duration end
                    end)
                end
            end
        end
    end
    originals = {}
    applied = false
    print("[SuperMod:FoodDuration] Reverted consumable durations")
end

return M
