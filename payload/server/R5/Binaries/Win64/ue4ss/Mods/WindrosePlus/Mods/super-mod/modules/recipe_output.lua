-- Recipe Output — multiply RecipeResult Count on R5BLRecipeData CDOs
local M = {}
local applied = false
local originals = {}

function M.apply(cfg)
    local mult = tonumber(cfg.output_multiplier) or 2

    local all = FindAllOf("R5BLRecipeData")
    if not all then return false end

    local count = 0
    for _, obj in ipairs(all) do
        local name = obj:GetFullName()
        if name:find("Default__") then goto continue end
        -- Skip sell/trade recipes (handled by insignia_sell)
        if name:find("Sell") or name:find("Trade") then goto continue end

        pcall(function()
            local results = obj.RecipeResult
            if results then
                local addr = tostring(obj:GetAddress())
                if not originals[addr] then
                    originals[addr] = {}
                    for i = 0, results:GetArrayNum() - 1 do
                        local e = results:GetArrayElement(i)
                        if e then originals[addr][i] = e.Count or 1 end
                    end
                end
                for i = 0, results:GetArrayNum() - 1 do
                    local e = results:GetArrayElement(i)
                    if e and originals[addr][i] then
                        e.Count = math.floor(originals[addr][i] * mult)
                    end
                end
                count = count + 1
            end
        end)

        ::continue::
    end

    if count == 0 then
        print("[SuperMod:RecipeOutput] No recipes found to modify output")
        return false
    end

    applied = true
    print("[SuperMod:RecipeOutput] Applied " .. mult .. "x output to " .. count .. " recipes")
end

function M.revert()
    if not applied then return end
    local all = FindAllOf("R5BLRecipeData")
    if all then
        for _, obj in ipairs(all) do
            local addr = tostring(obj:GetAddress())
            if originals[addr] then
                pcall(function()
                    local results = obj.RecipeResult
                    if results then
                        for i, orig in pairs(originals[addr]) do
                            local e = results:GetArrayElement(i)
                            if e then e.Count = orig end
                        end
                    end
                end)
            end
        end
    end
    originals = {}
    applied = false
    print("[SuperMod:RecipeOutput] Reverted recipe outputs")
end

return M
