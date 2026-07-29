-- Insignia Sell Values — modify R5BLRecipeData for reputation/coin gains
local M = {}
local applied = false
local originals = {}

local insignia_patterns = {
    "Reputation", "BBSign", "FSign", "Insignia", "FactionSign"
}

local function is_insignia_recipe(name)
    if not name:find("Sell") and not name:find("Trade") then return false end
    for _, p in ipairs(insignia_patterns) do
        if name:find(p) then return true end
    end
    return false
end

function M.apply(cfg)
    local rep_mult = tonumber(cfg.reputation_multiplier) or 2
    local coin_mult = tonumber(cfg.coin_multiplier) or 2

    local all = FindAllOf("R5BLRecipeData")
    if not all then return false end

    local count = 0
    for _, obj in ipairs(all) do
        local name = obj:GetFullName()
        if name:find("Default__") then goto continue end
        if not is_insignia_recipe(name) then goto continue end

        pcall(function()
            local addr = tostring(obj:GetAddress())

            -- Modify recipe results (coin payouts)
            local results = obj.RecipeResult
            if results then
                if not originals[addr .. "_res"] then
                    originals[addr .. "_res"] = {}
                    for i = 0, results:GetArrayNum() - 1 do
                        local e = results:GetArrayElement(i)
                        if e then originals[addr .. "_res"][i] = e.Count or 1 end
                    end
                end
                for i = 0, results:GetArrayNum() - 1 do
                    local e = results:GetArrayElement(i)
                    if e and originals[addr .. "_res"][i] then
                        e.Count = math.floor(originals[addr .. "_res"][i] * coin_mult)
                    end
                end
            end

            -- Modify blackboard values (reputation gains)
            local bbv = obj.ResultBlackboardValuesToAdd
            if bbv then
                local vals = bbv.BlackboardValuesToAdd
                if vals then
                    if not originals[addr .. "_rep"] then
                        originals[addr .. "_rep"] = {}
                        for i = 0, vals:GetArrayNum() - 1 do
                            local e = vals:GetArrayElement(i)
                            if e then originals[addr .. "_rep"][i] = e.Amount or 1 end
                        end
                    end
                    for i = 0, vals:GetArrayNum() - 1 do
                        local e = vals:GetArrayElement(i)
                        if e and originals[addr .. "_rep"][i] then
                            e.Amount = math.floor(originals[addr .. "_rep"][i] * rep_mult)
                        end
                    end
                end
            end

            count = count + 1
        end)

        ::continue::
    end

    if count == 0 then
        print("[SuperMod:Insignia] No insignia sell recipes found to modify")
        return false
    end

    applied = true
    print("[SuperMod:Insignia] Modified " .. count .. " recipes (rep=" .. rep_mult .. "x coin=" .. coin_mult .. "x)")
end

function M.revert()
    if not applied then return end
    local all = FindAllOf("R5BLRecipeData")
    if all then
        for _, obj in ipairs(all) do
            local addr = tostring(obj:GetAddress())
            pcall(function()
                if originals[addr .. "_res"] then
                    local results = obj.RecipeResult
                    if results then
                        for i, orig in pairs(originals[addr .. "_res"]) do
                            local e = results:GetArrayElement(i)
                            if e then e.Count = orig end
                        end
                    end
                end
                if originals[addr .. "_rep"] then
                    local bbv = obj.ResultBlackboardValuesToAdd
                    if bbv and bbv.BlackboardValuesToAdd then
                        for i, orig in pairs(originals[addr .. "_rep"]) do
                            local e = bbv.BlackboardValuesToAdd:GetArrayElement(i)
                            if e then e.Amount = orig end
                        end
                    end
                end
            end)
        end
    end
    originals = {}
    applied = false
    print("[SuperMod:Insignia] Reverted insignia sell values")
end

return M
