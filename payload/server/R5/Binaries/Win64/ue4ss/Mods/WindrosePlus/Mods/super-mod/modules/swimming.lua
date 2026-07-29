-- Unlimited Swimming — modify swim stamina consumption magnitude
-- Requires GAS CDOs which may not exist on dedicated servers.
local M = {}
local applied = false
local original_values = {}

function M.apply(cfg)
    local mult = tonumber(cfg.stamina_drain_mult) or 0

    local cdo = StaticFindObject("/Game/Gameplay/Character/Common/GameplayAbilities/Stamina/BP_ModMag_SwimStaminaConsumption.Default__BP_ModMag_SwimStaminaConsumption_C")
    if cdo then
        if not applied then
            pcall(function()
                original_values.base = cdo.BaseMagnitude or 1
            end)
        end
        pcall(function()
            cdo.BaseMagnitude = mult
        end)
        applied = true
        print("[SuperMod:Swimming] Set swim stamina drain to " .. mult)
        return
    end

    print("[SuperMod:Swimming] No GAS swim stamina CDO found — this mod requires GameplayAbilitySystem objects that may not load on dedicated servers")
    return false
end

function M.revert()
    if not applied then return end
    local cdo = StaticFindObject("/Game/Gameplay/Character/Common/GameplayAbilities/Stamina/BP_ModMag_SwimStaminaConsumption.Default__BP_ModMag_SwimStaminaConsumption_C")
    if cdo then
        pcall(function()
            cdo.BaseMagnitude = original_values.base or 1
        end)
    end
    original_values = {}
    applied = false
    print("[SuperMod:Swimming] Reverted to vanilla stamina drain")
end

return M
