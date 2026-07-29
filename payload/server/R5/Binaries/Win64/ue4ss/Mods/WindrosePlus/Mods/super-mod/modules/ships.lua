-- Ship Speed — modify DataAsset CDOs + live R5ShipKinematicMovementComponent instances
local M = {}
local applied = false
local originals = {}

local ship_type_patterns = {
    { pattern = "Cutter",  cfg_key = "cutter_mult" },
    { pattern = "Brig",    cfg_key = "brig_mult" },
    { pattern = "Frigate", cfg_key = "frigate_mult" },
    { pattern = "Ketch",   cfg_key = "ketch_mult" },
}

local function get_ship_mult(name, cfg, global_mult)
    for _, sp in ipairs(ship_type_patterns) do
        if name:find(sp.pattern) then
            local override = tonumber(cfg[sp.cfg_key]) or 0
            if override > 0 then return override end
            return global_mult
        end
    end
    return global_mult
end

function M.apply(cfg)
    local global_mult = tonumber(cfg.speed_multiplier) or 2
    local count = 0

    -- Phase 1: Modify DataAsset CDOs (affects newly-spawned and AI ships)
    local all = FindAllOf("R5ShipKinematicMovementParams")
    if all then
        for _, obj in ipairs(all) do
            local name = obj:GetFullName()
            if name:find("Empty") then goto skip_cdo end

            local mult = get_ship_mult(name, cfg, global_mult)
            local ok, err = pcall(function()
                local skm = obj.SpeedKnotsMap
                if not skm then return end
                local addr = "cdo_" .. tostring(obj:GetAddress())
                if not originals[addr] then
                    originals[addr] = {}
                    skm:ForEach(function(kp, vp)
                        originals[addr][kp:get()] = vp:get()
                    end)
                end
                skm:ForEach(function(kp, vp)
                    local g = kp:get()
                    if originals[addr][g] then
                        vp:set(originals[addr][g] * mult)
                    end
                end)
                count = count + 1
            end)
            if not ok then
                print("[SuperMod:Ships] CDO error: " .. tostring(err))
            end
            ::skip_cdo::
        end
    end

    -- Phase 2: Modify live ship movement components (affects already-spawned player ships)
    local comps = FindAllOf("R5ShipKinematicMovementComponent")
    if comps then
        for _, comp in ipairs(comps) do
            local name = comp:GetFullName()
            if name:find("Default__") then goto skip_comp end

            local mult = get_ship_mult(name, cfg, global_mult)
            local ok, err = pcall(function()
                local skm = comp.SpeedKnotsMap
                if not skm then return end
                local addr = "live_" .. tostring(comp:GetAddress())
                if not originals[addr] then
                    originals[addr] = {}
                    skm:ForEach(function(kp, vp)
                        originals[addr][kp:get()] = vp:get()
                    end)
                end
                skm:ForEach(function(kp, vp)
                    local g = kp:get()
                    if originals[addr][g] then
                        vp:set(originals[addr][g] * mult)
                    end
                end)
                count = count + 1
            end)
            if not ok then
                print("[SuperMod:Ships] Component error: " .. tostring(err))
            end
            ::skip_comp::
        end
    end

    -- Phase 3: Replicator speed caps
    local replicators = FindAllOf("R5ShipMovementReplicatorParams")
    if replicators then
        for _, rep in ipairs(replicators) do
            pcall(function()
                local addr = "rep_" .. tostring(rep:GetAddress())
                if not originals[addr] then
                    originals[addr] = {
                        squared = rep.TooBigSpeedSquared or 10000,
                        speed = rep.TooBigSpeed or 100,
                    }
                end
                rep.TooBigSpeedSquared = 9000000
                rep.TooBigSpeed = 3000
            end)
        end
    end

    applied = true
    if count > 0 then
        print("[SuperMod:Ships] Modified " .. count .. " objects (global=" .. global_mult .. "x)")
    end
end

function M.revert()
    if not applied then return end
    local all = FindAllOf("R5ShipKinematicMovementParams")
    if all then
        for _, obj in ipairs(all) do
            pcall(function()
                local addr = "cdo_" .. tostring(obj:GetAddress())
                if originals[addr] and obj.SpeedKnotsMap then
                    obj.SpeedKnotsMap:ForEach(function(kp, vp)
                        local g = kp:get()
                        if originals[addr][g] then vp:set(originals[addr][g]) end
                    end)
                end
            end)
        end
    end
    local comps = FindAllOf("R5ShipKinematicMovementComponent")
    if comps then
        for _, comp in ipairs(comps) do
            pcall(function()
                local addr = "live_" .. tostring(comp:GetAddress())
                if originals[addr] and comp.SpeedKnotsMap then
                    comp.SpeedKnotsMap:ForEach(function(kp, vp)
                        local g = kp:get()
                        if originals[addr][g] then vp:set(originals[addr][g]) end
                    end)
                end
            end)
        end
    end
    local replicators = FindAllOf("R5ShipMovementReplicatorParams")
    if replicators then
        for _, rep in ipairs(replicators) do
            local addr = "rep_" .. tostring(rep:GetAddress())
            if originals[addr] then
                pcall(function()
                    rep.TooBigSpeedSquared = originals[addr].squared
                    rep.TooBigSpeed = originals[addr].speed
                end)
            end
        end
    end
    originals = {}
    applied = false
    print("[SuperMod:Ships] Reverted ship speeds")
end

return M
