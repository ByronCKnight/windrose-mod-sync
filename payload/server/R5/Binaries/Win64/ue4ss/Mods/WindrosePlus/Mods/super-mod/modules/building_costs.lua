-- Building Costs — reduce ingredient counts on building/construction recipes
local M = {}
local applied = false
local originals = {}

local building_patterns = {
    "Build", "Construct", "Place", "Foundation", "Wall", "Floor",
    "Roof", "Fence", "Door", "Window", "Stair", "Pillar",
    "Craft_Station", "Workbench", "Forge", "Furnace", "Loom",
    "Tanning", "Alchemy", "Cooking", "Anvil", "Saw",
}

local function is_building_recipe(name)
    for _, p in ipairs(building_patterns) do
        if name:find(p) then return true end
    end
    return false
end

function M.apply(cfg)
    local mult = tonumber(cfg.cost_multiplier) or 0.5
    local station_mult = tonumber(cfg.station_cost_mult) or 0

    local all = FindAllOf("R5BLRecipeData")
    if not all then return false end

    local count = 0
    for _, obj in ipairs(all) do
        local name = obj:GetFullName()
        if name:find("Default__") then goto continue end
        if not is_building_recipe(name) then goto continue end

        local use_mult = mult
        if station_mult > 0 then
            for _, sp in ipairs({"Craft_Station","Workbench","Forge","Furnace","Loom","Tanning","Alchemy","Cooking","Anvil","Saw"}) do
                if name:find(sp) then use_mult = station_mult; break end
            end
        end

        pcall(function()
            local ingredients = obj.RecipeIngredients
            if ingredients then
                local addr = tostring(obj:GetAddress())
                if not originals[addr] then
                    originals[addr] = {}
                    for i = 0, ingredients:GetArrayNum() - 1 do
                        local e = ingredients:GetArrayElement(i)
                        if e then originals[addr][i] = e.Count or 1 end
                    end
                end
                for i = 0, ingredients:GetArrayNum() - 1 do
                    local e = ingredients:GetArrayElement(i)
                    if e and originals[addr][i] then
                        e.Count = math.max(1, math.floor(originals[addr][i] * use_mult))
                    end
                end
                count = count + 1
            end
        end)

        ::continue::
    end

    if count == 0 then
        print("[SuperMod:BuildCosts] No building recipes found to modify")
        return false
    end

    applied = true
    print("[SuperMod:BuildCosts] Applied " .. mult .. "x cost to " .. count .. " building recipes")
end

function M.revert()
    if not applied then return end
    local all = FindAllOf("R5BLRecipeData")
    if all then
        for _, obj in ipairs(all) do
            local addr = tostring(obj:GetAddress())
            if originals[addr] then
                pcall(function()
                    local ingredients = obj.RecipeIngredients
                    if ingredients then
                        for i, orig in pairs(originals[addr]) do
                            local e = ingredients:GetArrayElement(i)
                            if e then e.Count = orig end
                        end
                    end
                end)
            end
        end
    end
    originals = {}
    applied = false
    print("[SuperMod:BuildCosts] Reverted building costs")
end

return M
