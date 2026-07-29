-- Weapon Damage — multiply damage values on weapon CDOs
local M = {}
local applied = false
local originals = {}

local melee_patterns = { "Sword", "Axe", "Mace", "Dagger", "Spear", "Halberd", "Hammer", "Cutlass", "Rapier", "Sabre", "Pike" }
local ranged_patterns = { "Musket", "Pistol", "Rifle", "Bow", "Crossbow", "Blunder", "Cannon" }

local function get_weapon_type(name)
    for _, p in ipairs(melee_patterns) do
        if name:find(p) then return "melee" end
    end
    for _, p in ipairs(ranged_patterns) do
        if name:find(p) then return "ranged" end
    end
    return "other"
end

function M.apply(cfg)
    local global_mult = tonumber(cfg.damage_multiplier) or 2
    local melee_mult = tonumber(cfg.melee_mult) or 0
    local ranged_mult = tonumber(cfg.ranged_mult) or 0

    local all = FindAllOf("R5BLInventoryItem")
    if not all then
        all = FindAllOf("R5BLInventoryItemDataAsset")
    end
    if not all then return false end

    local count = 0
    for _, item in ipairs(all) do
        local name = item:GetFullName()
        if name:find("Default__") then goto continue end

        local wtype = get_weapon_type(name)
        if wtype == "other" then goto continue end

        local mult = global_mult
        if wtype == "melee" and melee_mult > 0 then mult = melee_mult end
        if wtype == "ranged" and ranged_mult > 0 then mult = ranged_mult end

        pcall(function()
            local gpd = item.InventoryItemGppData
            if gpd then
                local addr = tostring(item:GetAddress())
                if not originals[addr] then
                    originals[addr] = {
                        Damage = gpd.Damage,
                        BaseDamage = gpd.BaseDamage,
                        MinDamage = gpd.MinDamage,
                        MaxDamage = gpd.MaxDamage,
                    }
                end
                local orig = originals[addr]
                local modified = false
                if orig.Damage and orig.Damage > 0 then
                    gpd.Damage = math.floor(orig.Damage * mult)
                    modified = true
                end
                if orig.BaseDamage and orig.BaseDamage > 0 then
                    gpd.BaseDamage = math.floor(orig.BaseDamage * mult)
                    modified = true
                end
                if orig.MinDamage and orig.MinDamage > 0 then
                    gpd.MinDamage = math.floor(orig.MinDamage * mult)
                    modified = true
                end
                if orig.MaxDamage and orig.MaxDamage > 0 then
                    gpd.MaxDamage = math.floor(orig.MaxDamage * mult)
                    modified = true
                end
                if modified then count = count + 1 end
            end
        end)

        ::continue::
    end

    if count == 0 then
        print("[SuperMod:WeaponDmg] No weapon items found to modify damage")
        return false
    end

    applied = true
    print("[SuperMod:WeaponDmg] Applied damage mult to " .. count .. " weapons (global=" .. global_mult .. "x)")
end

function M.revert()
    if not applied then return end
    local all = FindAllOf("R5BLInventoryItem")
    if not all then all = FindAllOf("R5BLInventoryItemDataAsset") end
    if all then
        for _, item in ipairs(all) do
            local addr = tostring(item:GetAddress())
            if originals[addr] then
                pcall(function()
                    local gpd = item.InventoryItemGppData
                    if gpd and originals[addr] then
                        local o = originals[addr]
                        if o.Damage then gpd.Damage = o.Damage end
                        if o.BaseDamage then gpd.BaseDamage = o.BaseDamage end
                        if o.MinDamage then gpd.MinDamage = o.MinDamage end
                        if o.MaxDamage then gpd.MaxDamage = o.MaxDamage end
                    end
                end)
            end
        end
    end
    originals = {}
    applied = false
    print("[SuperMod:WeaponDmg] Reverted weapon damage")
end

return M
