-- Item Durability — multiply MaxDurability on R5BLInventoryItem GppData
local M = {}
local applied = false
local originals = {}

function M.apply(cfg)
    local mult = tonumber(cfg.durability_multiplier) or 5

    local all = FindAllOf("R5BLInventoryItem")
    if not all then
        all = FindAllOf("R5BLInventoryItemDataAsset")
    end
    if not all then return false end

    local count = 0
    for _, item in ipairs(all) do
        if item:GetFullName():find("Default__") then goto continue end

        pcall(function()
            local gpd = item.InventoryItemGppData
            if gpd then
                local addr = tostring(item:GetAddress())
                if not originals[addr] then
                    originals[addr] = gpd.MaxDurability or 0
                end
                local base = originals[addr]
                if base > 0 then
                    gpd.MaxDurability = math.floor(base * mult)
                    count = count + 1
                end
            end
        end)

        ::continue::
    end

    if count == 0 then
        print("[SuperMod:Durability] No inventory items found with MaxDurability property")
        return false
    end

    applied = true
    print("[SuperMod:Durability] Applied " .. mult .. "x durability to " .. count .. " items")
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
                    if gpd then gpd.MaxDurability = originals[addr] end
                end)
            end
        end
    end
    originals = {}
    applied = false
    print("[SuperMod:Durability] Reverted item durability")
end

return M
