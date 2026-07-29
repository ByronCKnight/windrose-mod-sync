-- Stack Multiplier — multiply MaxCountInSlot on all inventory item CDOs
local M = {}
local applied = false
local original_stacks = {}
local last_multiplier = nil

function M.apply(cfg)
    local mult = tonumber(cfg.multiplier) or 5
    if mult == last_multiplier and applied then return end

    local items = FindAllOf("R5BLInventoryItem")
    if not items then
        items = FindAllOf("R5BLInventoryItemDataAsset")
    end
    if not items then return false end

    local count = 0
    for _, item in ipairs(items) do
        if not item:GetFullName():find("Default__") then
            pcall(function()
                local gpd = item.InventoryItemGppData
                if gpd then
                    local addr = tostring(item:GetAddress())
                    if not original_stacks[addr] then
                        original_stacks[addr] = gpd.MaxCountInSlot or 1
                    end
                    local base = original_stacks[addr]
                    if base > 0 then
                        gpd.MaxCountInSlot = math.floor(base * mult)
                        count = count + 1
                    end
                end
            end)
        end
    end

    if count == 0 then
        print("[SuperMod:Stacks] No inventory items found to modify stack sizes")
        return false
    end

    last_multiplier = mult
    applied = true
    print("[SuperMod:Stacks] Applied " .. mult .. "x to " .. count .. " items")
end

function M.revert()
    if not applied then return end
    local items = FindAllOf("R5BLInventoryItem")
    if not items then items = FindAllOf("R5BLInventoryItemDataAsset") end
    if items then
        for _, item in ipairs(items) do
            pcall(function()
                local addr = tostring(item:GetAddress())
                if original_stacks[addr] then
                    local gpd = item.InventoryItemGppData
                    if gpd then gpd.MaxCountInSlot = original_stacks[addr] end
                end
            end)
        end
    end
    applied = false
    last_multiplier = nil
    print("[SuperMod:Stacks] Reverted stack sizes")
end

return M
