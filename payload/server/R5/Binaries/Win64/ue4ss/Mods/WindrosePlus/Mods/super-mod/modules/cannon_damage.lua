-- Cannon Damage — modify cannon/naval weapon damage and reload speed
local M = {}
local applied = false
local originals = {}

local cannon_patterns = {
    "Cannon", "Mortar", "Swivel", "Ballista", "Naval", "Turret", "Bombard",
}

local function is_cannon(name)
    for _, p in ipairs(cannon_patterns) do
        if name:find(p) then return true end
    end
    return false
end

function M.apply(cfg)
    local dmg_mult = tonumber(cfg.damage_multiplier) or 2
    local reload_mult = tonumber(cfg.reload_speed) or 0.5

    local count = 0

    -- Scan inventory items for cannon weapons
    local items = FindAllOf("R5BLInventoryItem")
    if not items then items = FindAllOf("R5BLInventoryItemDataAsset") end
    if items then
        for _, item in ipairs(items) do
            local name = item:GetFullName()
            if name:find("Default__") then goto skip_item end
            if not is_cannon(name) then goto skip_item end

            pcall(function()
                local gpd = item.InventoryItemGppData
                if gpd then
                    local addr = "itm_" .. tostring(item:GetAddress())
                    if not originals[addr] then
                        originals[addr] = {
                            Damage = gpd.Damage,
                            BaseDamage = gpd.BaseDamage,
                        }
                    end
                    local modified = false
                    if originals[addr].Damage and originals[addr].Damage > 0 then
                        gpd.Damage = math.floor(originals[addr].Damage * dmg_mult)
                        modified = true
                    end
                    if originals[addr].BaseDamage and originals[addr].BaseDamage > 0 then
                        gpd.BaseDamage = math.floor(originals[addr].BaseDamage * dmg_mult)
                        modified = true
                    end
                    if modified then count = count + 1 end
                end
            end)

            ::skip_item::
        end
    end

    -- Scan for cannon-specific param CDOs
    local param_classes = {"R5CannonParams", "R5BLCannonData", "R5ShipCannonParams", "R5WeaponParams"}
    for _, cls in ipairs(param_classes) do
        local all = FindAllOf(cls)
        if all then
            for _, obj in ipairs(all) do
                local name = obj:GetFullName()
                if name:find("Default__") then goto skip_param end
                if cls == "R5WeaponParams" and not is_cannon(name) then goto skip_param end

                pcall(function()
                    local addr = cls .. "_" .. tostring(obj:GetAddress())
                    if not originals[addr] then
                        originals[addr] = {
                            Damage = obj.Damage or obj.BaseDamage,
                            ReloadTime = obj.ReloadTime or obj.ReloadDuration,
                            FireRate = obj.FireRate,
                        }
                    end
                    local o = originals[addr]
                    local modified = false
                    if o.Damage and o.Damage > 0 then
                        if obj.Damage then obj.Damage = math.floor(o.Damage * dmg_mult) end
                        if obj.BaseDamage then obj.BaseDamage = math.floor(o.Damage * dmg_mult) end
                        modified = true
                    end
                    if o.ReloadTime and o.ReloadTime > 0 then
                        if obj.ReloadTime then obj.ReloadTime = o.ReloadTime * reload_mult end
                        if obj.ReloadDuration then obj.ReloadDuration = o.ReloadTime * reload_mult end
                        modified = true
                    end
                    if o.FireRate and o.FireRate > 0 and reload_mult > 0 then
                        obj.FireRate = o.FireRate / reload_mult
                        modified = true
                    end
                    if modified then count = count + 1 end
                end)

                ::skip_param::
            end
        end
    end

    if count == 0 then
        print("[SuperMod:Cannons] No cannon objects found to modify")
        return false
    end

    applied = true
    print("[SuperMod:Cannons] Modified " .. count .. " cannon objects (dmg=" .. dmg_mult .. "x reload=" .. reload_mult .. "x)")
end

function M.revert()
    if not applied then return end
    local items = FindAllOf("R5BLInventoryItem")
    if not items then items = FindAllOf("R5BLInventoryItemDataAsset") end
    if items then
        for _, item in ipairs(items) do
            local addr = "itm_" .. tostring(item:GetAddress())
            if originals[addr] then
                pcall(function()
                    local gpd = item.InventoryItemGppData
                    if gpd then
                        if originals[addr].Damage then gpd.Damage = originals[addr].Damage end
                        if originals[addr].BaseDamage then gpd.BaseDamage = originals[addr].BaseDamage end
                    end
                end)
            end
        end
    end
    for _, cls in ipairs({"R5CannonParams","R5BLCannonData","R5ShipCannonParams","R5WeaponParams"}) do
        local all = FindAllOf(cls)
        if all then
            for _, obj in ipairs(all) do
                local addr = cls .. "_" .. tostring(obj:GetAddress())
                if originals[addr] then
                    pcall(function()
                        local o = originals[addr]
                        if o.Damage then
                            if obj.Damage then obj.Damage = o.Damage end
                            if obj.BaseDamage then obj.BaseDamage = o.Damage end
                        end
                        if o.ReloadTime then
                            if obj.ReloadTime then obj.ReloadTime = o.ReloadTime end
                            if obj.ReloadDuration then obj.ReloadDuration = o.ReloadTime end
                        end
                        if o.FireRate then obj.FireRate = o.FireRate end
                    end)
                end
            end
        end
    end
    originals = {}
    applied = false
    print("[SuperMod:Cannons] Reverted cannon stats")
end

return M
