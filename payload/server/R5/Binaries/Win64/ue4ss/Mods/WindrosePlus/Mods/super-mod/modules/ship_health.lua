-- Ship Health — multiply ship durability/health via ship params CDOs
-- Requires R5ShipHealthParams or R5ShipHealthComponent which may not exist on dedicated servers.
local M = {}
local applied = false
local originals = {}

function M.apply(cfg)
    local mult = tonumber(cfg.health_multiplier) or 3

    local count = 0

    local param_classes = {
        "R5ShipHealthParams", "R5ShipDurabilityParams",
        "R5BLShipHealthParams",
    }
    for _, cls in ipairs(param_classes) do
        local all = FindAllOf(cls)
        if all then
            for _, obj in ipairs(all) do
                local name = obj:GetFullName()
                if name:find("Default__") or name:find("Empty") then goto skip end

                pcall(function()
                    local addr = cls .. "_" .. tostring(obj:GetAddress())
                    if not originals[addr] then
                        originals[addr] = {
                            MaxHealth = obj.MaxHealth,
                            MaxHullHealth = obj.MaxHullHealth,
                            Health = obj.Health,
                            MaxHitPoints = obj.MaxHitPoints,
                        }
                    end
                    local o = originals[addr]
                    if o.MaxHealth and o.MaxHealth > 0 then obj.MaxHealth = math.floor(o.MaxHealth * mult); count = count + 1 end
                    if o.MaxHullHealth and o.MaxHullHealth > 0 then obj.MaxHullHealth = math.floor(o.MaxHullHealth * mult) end
                    if o.Health and o.Health > 0 then obj.Health = math.floor(o.Health * mult) end
                    if o.MaxHitPoints and o.MaxHitPoints > 0 then obj.MaxHitPoints = math.floor(o.MaxHitPoints * mult) end
                end)

                ::skip::
            end
        end
    end

    local ships = FindAllOf("R5ShipHealthComponent")
    if ships then
        for _, comp in ipairs(ships) do
            if comp:GetFullName():find("Default__") then goto skip2 end
            pcall(function()
                local addr = "comp_" .. tostring(comp:GetAddress())
                if not originals[addr] then
                    originals[addr] = {
                        MaxHealth = comp.MaxHealth or comp.DefaultMaxHealth,
                    }
                end
                if originals[addr].MaxHealth and originals[addr].MaxHealth > 0 then
                    if comp.MaxHealth then comp.MaxHealth = math.floor(originals[addr].MaxHealth * mult) end
                    if comp.DefaultMaxHealth then comp.DefaultMaxHealth = math.floor(originals[addr].MaxHealth * mult) end
                    count = count + 1
                end
            end)
            ::skip2::
        end
    end

    if count == 0 then
        print("[SuperMod:ShipHP] No ship health CDOs found — R5ShipHealthParams/R5ShipHealthComponent may not load on dedicated servers")
        return false
    end

    applied = true
    print("[SuperMod:ShipHP] Applied " .. mult .. "x health to " .. count .. " ship objects")
end

function M.revert()
    if not applied then return end
    for _, cls in ipairs({"R5ShipHealthParams","R5ShipDurabilityParams","R5BLShipHealthParams"}) do
        local all = FindAllOf(cls)
        if all then
            for _, obj in ipairs(all) do
                local addr = cls .. "_" .. tostring(obj:GetAddress())
                if originals[addr] then
                    pcall(function()
                        local o = originals[addr]
                        if o.MaxHealth then obj.MaxHealth = o.MaxHealth end
                        if o.MaxHullHealth then obj.MaxHullHealth = o.MaxHullHealth end
                        if o.Health then obj.Health = o.Health end
                        if o.MaxHitPoints then obj.MaxHitPoints = o.MaxHitPoints end
                    end)
                end
            end
        end
    end
    local ships = FindAllOf("R5ShipHealthComponent")
    if ships then
        for _, comp in ipairs(ships) do
            local addr = "comp_" .. tostring(comp:GetAddress())
            if originals[addr] then
                pcall(function()
                    if comp.MaxHealth then comp.MaxHealth = originals[addr].MaxHealth end
                    if comp.DefaultMaxHealth then comp.DefaultMaxHealth = originals[addr].MaxHealth end
                end)
            end
        end
    end
    originals = {}
    applied = false
    print("[SuperMod:ShipHP] Reverted ship health")
end

return M
