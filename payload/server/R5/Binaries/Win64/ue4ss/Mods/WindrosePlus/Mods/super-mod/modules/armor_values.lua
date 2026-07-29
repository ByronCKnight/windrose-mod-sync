-- Armor Values — multiply armor/protection on armor CDOs
local M = {}
local applied = false
local originals = {}

local armor_patterns = {
    "Armor", "Chest", "Legs", "Helm", "Boots", "Gloves", "Gauntlet",
    "Shield", "Hat", "Coat", "Vest", "Pants", "Shirt",
}

local function is_armor(name)
    for _, p in ipairs(armor_patterns) do
        if name:find(p) then return true end
    end
    return false
end

function M.apply(cfg)
    local mult = tonumber(cfg.armor_multiplier) or 2

    local all = FindAllOf("R5BLInventoryItem")
    if not all then
        all = FindAllOf("R5BLInventoryItemDataAsset")
    end
    if not all then return false end

    local count = 0
    for _, item in ipairs(all) do
        local name = item:GetFullName()
        if name:find("Default__") then goto continue end
        if not is_armor(name) then goto continue end

        pcall(function()
            local gpd = item.InventoryItemGppData
            if gpd then
                local addr = tostring(item:GetAddress())
                if not originals[addr] then
                    originals[addr] = {
                        Armor = gpd.Armor,
                        BaseArmor = gpd.BaseArmor,
                        Defense = gpd.Defense,
                        Protection = gpd.Protection,
                    }
                end
                local o = originals[addr]
                local modified = false
                if o.Armor and o.Armor > 0 then gpd.Armor = math.floor(o.Armor * mult); modified = true end
                if o.BaseArmor and o.BaseArmor > 0 then gpd.BaseArmor = math.floor(o.BaseArmor * mult); modified = true end
                if o.Defense and o.Defense > 0 then gpd.Defense = math.floor(o.Defense * mult); modified = true end
                if o.Protection and o.Protection > 0 then gpd.Protection = math.floor(o.Protection * mult); modified = true end
                if modified then count = count + 1 end
            end
        end)

        ::continue::
    end

    if count == 0 then
        print("[SuperMod:Armor] No armor items found to modify")
        return false
    end

    applied = true
    print("[SuperMod:Armor] Applied " .. mult .. "x armor to " .. count .. " items")
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
                    if gpd then
                        local o = originals[addr]
                        if o.Armor then gpd.Armor = o.Armor end
                        if o.BaseArmor then gpd.BaseArmor = o.BaseArmor end
                        if o.Defense then gpd.Defense = o.Defense end
                        if o.Protection then gpd.Protection = o.Protection end
                    end
                end)
            end
        end
    end
    originals = {}
    applied = false
    print("[SuperMod:Armor] Reverted armor values")
end

return M
