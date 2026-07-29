-- Merchant Prices — adjust buy/sell prices via R5BLRecipeData
local M = {}
local applied = false
local originals = {}

local buy_patterns = { "Buy", "Purchase", "Shop", "Vendor", "Merchant", "Store" }
local sell_patterns = { "Sell", "Trade" }

local function get_recipe_type(name)
    for _, p in ipairs(sell_patterns) do
        if name:find(p) then return "sell" end
    end
    for _, p in ipairs(buy_patterns) do
        if name:find(p) then return "buy" end
    end
    return nil
end

function M.apply(cfg)
    local buy_mult = tonumber(cfg.buy_price_mult) or 0.5
    local sell_mult = tonumber(cfg.sell_price_mult) or 2

    local all = FindAllOf("R5BLRecipeData")
    if not all then return false end

    local count = 0
    for _, obj in ipairs(all) do
        local name = obj:GetFullName()
        if name:find("Default__") then goto continue end
        -- Skip insignia recipes (handled by insignia_sell module)
        if name:find("Insignia") or name:find("FSign") or name:find("BBSign") then goto continue end

        local rtype = get_recipe_type(name)
        if not rtype then goto continue end

        pcall(function()
            local addr = tostring(obj:GetAddress())

            if rtype == "buy" then
                local ingredients = obj.RecipeIngredients
                if ingredients then
                    if not originals[addr .. "_buy"] then
                        originals[addr .. "_buy"] = {}
                        for i = 0, ingredients:GetArrayNum() - 1 do
                            local e = ingredients:GetArrayElement(i)
                            if e then originals[addr .. "_buy"][i] = e.Count or 1 end
                        end
                    end
                    for i = 0, ingredients:GetArrayNum() - 1 do
                        local e = ingredients:GetArrayElement(i)
                        if e and originals[addr .. "_buy"][i] then
                            e.Count = math.max(1, math.floor(originals[addr .. "_buy"][i] * buy_mult))
                        end
                    end
                    count = count + 1
                end
            elseif rtype == "sell" then
                local results = obj.RecipeResult
                if results then
                    if not originals[addr .. "_sell"] then
                        originals[addr .. "_sell"] = {}
                        for i = 0, results:GetArrayNum() - 1 do
                            local e = results:GetArrayElement(i)
                            if e then originals[addr .. "_sell"][i] = e.Count or 1 end
                        end
                    end
                    for i = 0, results:GetArrayNum() - 1 do
                        local e = results:GetArrayElement(i)
                        if e and originals[addr .. "_sell"][i] then
                            e.Count = math.max(1, math.floor(originals[addr .. "_sell"][i] * sell_mult))
                        end
                    end
                    count = count + 1
                end
            end
        end)

        ::continue::
    end

    if count == 0 then
        print("[SuperMod:Merchant] No merchant recipes found to modify")
        return false
    end

    applied = true
    print("[SuperMod:Merchant] Modified " .. count .. " recipes (buy=" .. buy_mult .. "x sell=" .. sell_mult .. "x)")
end

function M.revert()
    if not applied then return end
    local all = FindAllOf("R5BLRecipeData")
    if all then
        for _, obj in ipairs(all) do
            local addr = tostring(obj:GetAddress())
            pcall(function()
                if originals[addr .. "_buy"] then
                    local ingredients = obj.RecipeIngredients
                    if ingredients then
                        for i, orig in pairs(originals[addr .. "_buy"]) do
                            local e = ingredients:GetArrayElement(i)
                            if e then e.Count = orig end
                        end
                    end
                end
                if originals[addr .. "_sell"] then
                    local results = obj.RecipeResult
                    if results then
                        for i, orig in pairs(originals[addr .. "_sell"]) do
                            local e = results:GetArrayElement(i)
                            if e then e.Count = orig end
                        end
                    end
                end
            end)
        end
    end
    originals = {}
    applied = false
    print("[SuperMod:Merchant] Reverted merchant prices")
end

return M
