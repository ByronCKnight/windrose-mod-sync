-- Floating Barrel Loot — multiply loot from water pickup loot tables
local M = {}
local applied = false
local originals = {}

local barrel_patterns = {
    "WaterPickup", "LostBoat", "Barrel", "Goods"
}

local function is_barrel_loot(name)
    for _, p in ipairs(barrel_patterns) do
        if name:find(p) then return true end
    end
    return false
end

function M.apply(cfg)
    local mult = tonumber(cfg.multiplier) or 10

    local all = FindAllOf("R5BLLootParams")
    if not all then return false end

    local count = 0
    for _, obj in ipairs(all) do
        local name = obj:GetFullName()
        if name:find("Default__") then goto continue end
        if not is_barrel_loot(name) then goto continue end

        pcall(function()
            local loot_data = obj.LootData
            if loot_data then
                local addr = tostring(obj:GetAddress())
                if not originals[addr] then
                    originals[addr] = {}
                    for i = 0, loot_data:GetArrayNum() - 1 do
                        local entry = loot_data:GetArrayElement(i)
                        if entry then
                            originals[addr][i] = { Min = entry.Min or 0, Max = entry.Max or 0 }
                        end
                    end
                end
                for i = 0, loot_data:GetArrayNum() - 1 do
                    local entry = loot_data:GetArrayElement(i)
                    if entry and originals[addr][i] then
                        entry.Min = math.floor(originals[addr][i].Min * mult)
                        entry.Max = math.floor(originals[addr][i].Max * mult)
                    end
                end
                count = count + 1
            end
        end)

        ::continue::
    end

    if count == 0 then
        print("[SuperMod:BarrelLoot] No barrel loot tables found to modify")
        return false
    end

    applied = true
    print("[SuperMod:BarrelLoot] Applied " .. mult .. "x to " .. count .. " loot tables")
end

function M.revert()
    if not applied then return end
    local all = FindAllOf("R5BLLootParams")
    if all then
        for _, obj in ipairs(all) do
            local addr = tostring(obj:GetAddress())
            if originals[addr] then
                pcall(function()
                    local loot_data = obj.LootData
                    if loot_data then
                        for i, orig in pairs(originals[addr]) do
                            local entry = loot_data:GetArrayElement(i)
                            if entry then
                                entry.Min = orig.Min
                                entry.Max = orig.Max
                            end
                        end
                    end
                end)
            end
        end
    end
    originals = {}
    applied = false
    print("[SuperMod:BarrelLoot] Reverted barrel loot")
end

return M
