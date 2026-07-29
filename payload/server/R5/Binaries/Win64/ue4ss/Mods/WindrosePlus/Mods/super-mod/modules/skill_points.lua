-- Skill Points — modify points gained per level via progression params
local M = {}
local applied = false
local originals = {}

function M.apply(cfg)
    local points_mult = tonumber(cfg.points_multiplier) or 3

    local count = 0

    -- Modify skill point allocation in progression trees
    local trees = FindAllOf("R5BLProgressionTreeParams")
    if trees then
        for _, obj in ipairs(trees) do
            local name = obj:GetFullName()
            if name:find("Default__") then goto skip end

            pcall(function()
                local addr = tostring(obj:GetAddress())
                -- SkillPointsPerLevel or similar
                if not originals[addr] then
                    originals[addr] = {
                        SkillPointsPerLevel = obj.SkillPointsPerLevel,
                        PointsPerLevelUp = obj.PointsPerLevelUp,
                        StatPointsPerLevel = obj.StatPointsPerLevel,
                    }
                end
                local o = originals[addr]
                if o.SkillPointsPerLevel and o.SkillPointsPerLevel > 0 then
                    obj.SkillPointsPerLevel = math.floor(o.SkillPointsPerLevel * points_mult)
                    count = count + 1
                end
                if o.PointsPerLevelUp and o.PointsPerLevelUp > 0 then
                    obj.PointsPerLevelUp = math.floor(o.PointsPerLevelUp * points_mult)
                    count = count + 1
                end
                if o.StatPointsPerLevel and o.StatPointsPerLevel > 0 then
                    obj.StatPointsPerLevel = math.floor(o.StatPointsPerLevel * points_mult)
                    count = count + 1
                end
            end)

            ::skip::
        end
    end

    -- Try level-up reward CDOs
    local reward_classes = {"R5BLLevelUpReward", "R5BLLevelRewardParams", "R5BLCharacterLevelParams"}
    for _, cls in ipairs(reward_classes) do
        local all = FindAllOf(cls)
        if all then
            for _, obj in ipairs(all) do
                if obj:GetFullName():find("Default__") then goto skip2 end
                pcall(function()
                    local addr = cls .. "_" .. tostring(obj:GetAddress())
                    if not originals[addr] then
                        originals[addr] = {
                            SkillPoints = obj.SkillPoints or obj.PointsReward,
                            StatPoints = obj.StatPoints,
                        }
                    end
                    local o = originals[addr]
                    if o.SkillPoints and o.SkillPoints > 0 then
                        if obj.SkillPoints then obj.SkillPoints = math.floor(o.SkillPoints * points_mult) end
                        if obj.PointsReward then obj.PointsReward = math.floor(o.SkillPoints * points_mult) end
                        count = count + 1
                    end
                    if o.StatPoints and o.StatPoints > 0 then
                        obj.StatPoints = math.floor(o.StatPoints * points_mult)
                    end
                end)
                ::skip2::
            end
        end
    end

    if count == 0 then
        print("[SuperMod:SkillPts] No skill point objects could be modified — progression tree nodes or reward CDOs may not be accessible")
        return false
    end

    applied = true
    print("[SuperMod:SkillPts] Applied " .. points_mult .. "x to " .. count .. " progression objects")
end

function M.revert()
    if not applied then return end
    local trees = FindAllOf("R5BLProgressionTreeParams")
    if trees then
        for _, obj in ipairs(trees) do
            local addr = tostring(obj:GetAddress())
            if originals[addr] then
                pcall(function()
                    local o = originals[addr]
                    if o.SkillPointsPerLevel then obj.SkillPointsPerLevel = o.SkillPointsPerLevel end
                    if o.PointsPerLevelUp then obj.PointsPerLevelUp = o.PointsPerLevelUp end
                    if o.StatPointsPerLevel then obj.StatPointsPerLevel = o.StatPointsPerLevel end
                end)
            end
        end
    end
    for _, cls in ipairs({"R5BLLevelUpReward","R5BLLevelRewardParams","R5BLCharacterLevelParams"}) do
        local all = FindAllOf(cls)
        if all then
            for _, obj in ipairs(all) do
                local addr = cls .. "_" .. tostring(obj:GetAddress())
                if originals[addr] then
                    pcall(function()
                        local o = originals[addr]
                        if o.SkillPoints then
                            if obj.SkillPoints then obj.SkillPoints = o.SkillPoints end
                            if obj.PointsReward then obj.PointsReward = o.SkillPoints end
                        end
                        if o.StatPoints then obj.StatPoints = o.StatPoints end
                    end)
                end
            end
        end
    end
    originals = {}
    applied = false
    print("[SuperMod:SkillPts] Reverted skill points")
end

return M
