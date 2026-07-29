-- XP Multiplier — boost experience gains via progression CDOs
local M = {}
local applied = false
local originals = {}

function M.apply(cfg)
    local mult = tonumber(cfg.xp_multiplier) or 3

    local count = 0

    -- Try R5BLProgressionTreeParams — modify XP requirements (lower = faster leveling)
    local trees = FindAllOf("R5BLProgressionTreeParams")
    if trees then
        for _, obj in ipairs(trees) do
            local name = obj:GetFullName()
            if name:find("Default__") then goto skip_tree end

            pcall(function()
                local branches = obj.Branches
                if branches then
                    for i = 0, branches:GetArrayNum() - 1 do
                        local branch = branches:GetArrayElement(i)
                        if branch then
                            local nodes = branch.Nodes
                            if nodes then
                                for j = 0, nodes:GetArrayNum() - 1 do
                                    local node = nodes:GetArrayElement(j)
                                    if node then
                                        local addr = "xp_" .. tostring(obj:GetAddress()) .. "_" .. i .. "_" .. j
                                        if not originals[addr] then
                                            originals[addr] = node.PointsPerLevel or 0
                                        end
                                        local base = originals[addr]
                                        if base > 0 and mult > 0 then
                                            node.PointsPerLevel = math.max(1, math.floor(base / mult))
                                            count = count + 1
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end)

            ::skip_tree::
        end
    end

    -- Also try GAS XP modifiers (may not exist on dedicated servers)
    local xp_paths = {
        "/Game/Gameplay/Character/Common/GameplayAbilities/Experience/BP_ModMag_ExperienceGain.Default__BP_ModMag_ExperienceGain_C",
        "/Game/Gameplay/Progression/BP_ModMag_XPGain.Default__BP_ModMag_XPGain_C",
    }
    for _, path in ipairs(xp_paths) do
        local cdo = StaticFindObject(path)
        if cdo then
            pcall(function()
                if not originals[path] then
                    originals[path] = cdo.BaseMagnitude or 1
                end
                cdo.BaseMagnitude = originals[path] * mult
                count = count + 1
            end)
        end
    end

    if count == 0 then
        print("[SuperMod:XP] No XP-related objects could be modified — progression tree nodes or GAS CDOs may not be accessible")
        return false
    end

    applied = true
    print("[SuperMod:XP] Applied " .. mult .. "x XP boost (" .. count .. " objects)")
end

function M.revert()
    if not applied then return end
    local trees = FindAllOf("R5BLProgressionTreeParams")
    if trees then
        for _, obj in ipairs(trees) do
            pcall(function()
                local branches = obj.Branches
                if branches then
                    for i = 0, branches:GetArrayNum() - 1 do
                        local branch = branches:GetArrayElement(i)
                        if branch and branch.Nodes then
                            for j = 0, branch.Nodes:GetArrayNum() - 1 do
                                local node = branch.Nodes:GetArrayElement(j)
                                if node then
                                    local addr = "xp_" .. tostring(obj:GetAddress()) .. "_" .. i .. "_" .. j
                                    if originals[addr] then
                                        node.PointsPerLevel = originals[addr]
                                    end
                                end
                            end
                        end
                    end
                end
            end)
        end
    end
    local xp_paths = {
        "/Game/Gameplay/Character/Common/GameplayAbilities/Experience/BP_ModMag_ExperienceGain.Default__BP_ModMag_ExperienceGain_C",
        "/Game/Gameplay/Progression/BP_ModMag_XPGain.Default__BP_ModMag_XPGain_C",
    }
    for _, path in ipairs(xp_paths) do
        if originals[path] then
            local cdo = StaticFindObject(path)
            if cdo then pcall(function() cdo.BaseMagnitude = originals[path] end) end
        end
    end
    originals = {}
    applied = false
    print("[SuperMod:XP] Reverted XP rates")
end

return M
