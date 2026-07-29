-- Backpack Slots — modify R5BLSlotCountModifierParams CDOs
local M = {}
local applied = false
local originals = {}

local tier_patterns = {
    { pattern = "L00_T01", tier = 0 },
    { pattern = "L01_T01", tier = 1 },
    { pattern = "L02_T01", tier = 2 },
    { pattern = "L03_T01", tier = 3 },
    { pattern = "L04_T01", tier = 4 },
    { pattern = "L10_T01", tier = 10 },
}

function M.apply(cfg)
    local mult = tonumber(cfg.multiplier) or 2
    local tier0 = tonumber(cfg.tier0_slots) or 8
    local tier4 = tonumber(cfg.tier4_slots) or 40

    local all = FindAllOf("R5BLSlotCountModifierParams")
    if not all then return false end

    local count = 0
    for _, obj in ipairs(all) do
        local name = obj:GetFullName()
        if name:find("Default__") then goto continue end

        for _, tp in ipairs(tier_patterns) do
            if name:find(tp.pattern) then
                pcall(function()
                    local addr = tostring(obj:GetAddress())
                    if not originals[addr] then
                        originals[addr] = obj.CountSlots or 4
                    end

                    local new_val
                    if tp.tier == 0 then
                        new_val = tier0
                    elseif tp.tier >= 4 then
                        new_val = tier4
                    else
                        local frac = tp.tier / 4
                        new_val = math.floor(tier0 + (tier4 - tier0) * frac)
                    end

                    obj.CountSlots = new_val
                    count = count + 1
                end)
                break
            end
        end

        ::continue::
    end

    if count == 0 then
        print("[SuperMod:Backpacks] No slot modifier params found to modify")
        return false
    end

    applied = true
    print("[SuperMod:Backpacks] Set " .. count .. " tiers (T0=" .. tier0 .. " T4=" .. tier4 .. ")")
end

function M.revert()
    if not applied then return end
    local all = FindAllOf("R5BLSlotCountModifierParams")
    if all then
        for _, obj in ipairs(all) do
            local addr = tostring(obj:GetAddress())
            if originals[addr] then
                pcall(function() obj.CountSlots = originals[addr] end)
            end
        end
    end
    applied = false
    print("[SuperMod:Backpacks] Reverted slot counts")
end

return M
