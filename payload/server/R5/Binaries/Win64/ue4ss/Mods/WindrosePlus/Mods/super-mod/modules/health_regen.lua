-- Health Regen — modify health regeneration rate via GAS attributes
-- Requires GAS CDOs which may not exist on dedicated servers.
local M = {}
local applied = false
local originals = {}

local regen_cdo_paths = {
    base = "/Game/Gameplay/Character/Common/GameplayAbilities/Health/BP_ModMag_HealthRegeneration.Default__BP_ModMag_HealthRegeneration_C",
    rate = "/Game/Gameplay/Character/Common/GameplayAbilities/Health/BP_ModMag_HealthRegenerationRate.Default__BP_ModMag_HealthRegenerationRate_C",
}

function M.apply(cfg)
    local mult = tonumber(cfg.regen_multiplier) or 3

    local count = 0

    for key, path in pairs(regen_cdo_paths) do
        local cdo = StaticFindObject(path)
        if cdo then
            pcall(function()
                if not originals[key] then
                    originals[key] = cdo.BaseMagnitude or 1
                end
                cdo.BaseMagnitude = originals[key] * mult
                count = count + 1
            end)
        end
    end

    if count == 0 then
        print("[SuperMod:HealthRegen] No GAS health regen CDOs found — this mod requires GameplayAbilitySystem objects that may not load on dedicated servers")
        return false
    end

    applied = true
    print("[SuperMod:HealthRegen] Applied " .. mult .. "x regen to " .. count .. " objects")
end

function M.revert()
    if not applied then return end
    for key, path in pairs(regen_cdo_paths) do
        if originals[key] then
            local cdo = StaticFindObject(path)
            if cdo then pcall(function() cdo.BaseMagnitude = originals[key] end) end
        end
    end
    originals = {}
    applied = false
    print("[SuperMod:HealthRegen] Reverted health regen")
end

return M
