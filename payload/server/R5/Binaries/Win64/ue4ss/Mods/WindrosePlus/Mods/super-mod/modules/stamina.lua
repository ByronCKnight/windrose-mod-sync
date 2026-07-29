-- Stamina — reduce stamina drain for sprint, combat, etc.
-- Requires GAS (GameplayAbilitySystem) CDOs which may not exist on dedicated servers.
local M = {}
local applied = false
local originals = {}

local stamina_cdo_paths = {
    sprint = "/Game/Gameplay/Character/Common/GameplayAbilities/Stamina/BP_ModMag_SprintStaminaConsumption.Default__BP_ModMag_SprintStaminaConsumption_C",
    combat = "/Game/Gameplay/Character/Common/GameplayAbilities/Stamina/BP_ModMag_CombatStaminaConsumption.Default__BP_ModMag_CombatStaminaConsumption_C",
    dodge  = "/Game/Gameplay/Character/Common/GameplayAbilities/Stamina/BP_ModMag_DodgeStaminaConsumption.Default__BP_ModMag_DodgeStaminaConsumption_C",
    jump   = "/Game/Gameplay/Character/Common/GameplayAbilities/Stamina/BP_ModMag_JumpStaminaConsumption.Default__BP_ModMag_JumpStaminaConsumption_C",
    climb  = "/Game/Gameplay/Character/Common/GameplayAbilities/Stamina/BP_ModMag_ClimbStaminaConsumption.Default__BP_ModMag_ClimbStaminaConsumption_C",
}

function M.apply(cfg)
    local sprint_mult = tonumber(cfg.sprint_drain) or 0.3
    local combat_mult = tonumber(cfg.combat_drain) or 0.5
    local general_mult = tonumber(cfg.general_drain) or 0.5

    local mult_map = {
        sprint = sprint_mult,
        combat = combat_mult,
        dodge = combat_mult,
        jump = general_mult,
        climb = general_mult,
    }

    local count = 0
    for key, path in pairs(stamina_cdo_paths) do
        local cdo = StaticFindObject(path)
        if cdo then
            pcall(function()
                if not originals[key] then
                    originals[key] = cdo.BaseMagnitude or 1
                end
                cdo.BaseMagnitude = originals[key] * (mult_map[key] or general_mult)
                count = count + 1
            end)
        end
    end

    if count == 0 then
        print("[SuperMod:Stamina] No GAS stamina CDOs found — this mod requires GameplayAbilitySystem objects that may not load on dedicated servers")
        return false
    end

    applied = true
    print("[SuperMod:Stamina] Modified " .. count .. " stamina drain sources")
end

function M.revert()
    if not applied then return end
    for key, path in pairs(stamina_cdo_paths) do
        if originals[key] then
            local cdo = StaticFindObject(path)
            if cdo then pcall(function() cdo.BaseMagnitude = originals[key] end) end
        end
    end
    originals = {}
    applied = false
    print("[SuperMod:Stamina] Reverted stamina drain")
end

return M
