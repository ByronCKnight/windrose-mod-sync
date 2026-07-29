-- Crafting Speed — multiply CraftingTime on R5BLRecipeData CDOs
local M = {}
local applied = false
local originals = {}

function M.apply(cfg)
    local mult = tonumber(cfg.time_multiplier) or 0.5

    local all = FindAllOf("R5BLRecipeData")
    if not all then return false end

    local count = 0
    for _, obj in ipairs(all) do
        local name = obj:GetFullName()
        if name:find("Default__") then goto continue end
        if name:find("Sell") or name:find("Trade") then goto continue end

        pcall(function()
            local addr = tostring(obj:GetAddress())
            if not originals[addr] then
                originals[addr] = obj.CraftingTime or 0
            end
            local base = originals[addr]
            if base > 0 then
                obj.CraftingTime = math.max(0.1, base * mult)
                count = count + 1
            end
        end)

        ::continue::
    end

    if count == 0 then
        print("[SuperMod:CraftSpeed] No recipes found to modify crafting time")
        return false
    end

    applied = true
    print("[SuperMod:CraftSpeed] Applied " .. mult .. "x time to " .. count .. " recipes")
end

function M.revert()
    if not applied then return end
    local all = FindAllOf("R5BLRecipeData")
    if all then
        for _, obj in ipairs(all) do
            local addr = tostring(obj:GetAddress())
            if originals[addr] then
                pcall(function() obj.CraftingTime = originals[addr] end)
            end
        end
    end
    originals = {}
    applied = false
    print("[SuperMod:CraftSpeed] Reverted crafting times")
end

return M
