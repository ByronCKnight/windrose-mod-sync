-- Drop Rate Multiplier — multiply Min/Max on all R5BLLootParams
local M = {}
local applied = false
local originals = {}

local category_patterns = {
    mob_drops = { "Mob", "NPC", "Enemy", "Boss", "Creature", "Animal" },
    chest_loot = { "Chest", "Container", "Treasure", "Personal", "Ship" },
    foliage = { "Foliage", "Gathering", "Pickup", "Crop", "Seed", "Resource" },
    fishing = { "Fish", "Butcher", "Alchemy" },
}

local function get_category(name)
    for cat, patterns in pairs(category_patterns) do
        for _, p in ipairs(patterns) do
            if name:find(p) then return cat end
        end
    end
    return "other"
end

local function should_apply(name, cfg)
    local cat = get_category(name)
    if cat == "mob_drops" and cfg.mob_drops == false then return false end
    if cat == "chest_loot" and cfg.chest_loot == false then return false end
    if cat == "foliage" and cfg.foliage == false then return false end
    if cat == "fishing" and cfg.fishing == false then return false end
    return true
end

function M.apply(cfg)
    local mult = tonumber(cfg.multiplier) or 2

    local all = FindAllOf("R5BLLootParams")
    if not all then return false end

    local count = 0
    for _, obj in ipairs(all) do
        local name = obj:GetFullName()
        if name:find("Default__") then goto continue end
        if not should_apply(name, cfg) then goto continue end

        -- Skip loot handled by barrel_loot and fishing modules
        if name:find("WaterPickup") or name:find("LostBoat") or name:find("Barrel")
           or name:find("Goods") or name:find("Fish") or name:find("Butcher") then
            goto continue
        end

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
        print("[SuperMod:DropRates] No loot tables found to modify")
        return false
    end

    applied = true
    print("[SuperMod:DropRates] Applied " .. mult .. "x to " .. count .. " loot tables")
end

function M.revert()
    if not applied then return end
    local all = FindAllOf("R5BLLootParams")
    if all then
        for _, obj in ipairs(all) do
            local addr = tostring(obj:GetAddress())
            if originals[addr] then
                pcall(function()
                    local ld = obj.LootData
                    if ld then
                        for i, orig in pairs(originals[addr]) do
                            local e = ld:GetArrayElement(i)
                            if e then e.Min = orig.Min; e.Max = orig.Max end
                        end
                    end
                end)
            end
        end
    end
    originals = {}
    applied = false
    print("[SuperMod:DropRates] Reverted drop rates")
end

return M
