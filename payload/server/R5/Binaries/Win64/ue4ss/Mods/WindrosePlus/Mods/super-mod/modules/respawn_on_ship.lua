-- Respawn on Ship — teleport players to their ship deck on death
local M = {}
local active = false
local player_alive = {}
local cfg_cache = {}

local function find_player_ship(pc, search_radius)
    local pawn = pc.Pawn
    if not pawn then return nil end
    local pawn_loc = pawn:K2_GetActorLocation()
    if not pawn_loc then return nil end

    local ships = FindAllOf("Pawn")
    if not ships then return nil end

    local best_ship = nil
    local best_dist = search_radius * search_radius

    for _, ship in ipairs(ships) do
        local name = ship:GetFullName()
        if name:find("BP_Ship_") and not name:find("Default__") and not name:find("BP_Ship_ShallowBoat") then
            local ship_loc = ship:K2_GetActorLocation()
            if ship_loc and ship_loc.Z > -1000 then
                local dx = ship_loc.X - pawn_loc.X
                local dy = ship_loc.Y - pawn_loc.Y
                local dist2 = dx*dx + dy*dy
                if dist2 < best_dist then
                    best_dist = dist2
                    best_ship = ship
                end
            end
        end
    end

    if not best_ship then
        for _, ship in ipairs(ships) do
            local name = ship:GetFullName()
            if name:find("BP_Ship_ShallowBoat") and not name:find("Default__") then
                local ship_loc = ship:K2_GetActorLocation()
                if ship_loc and ship_loc.Z > -1000 then
                    local dx = ship_loc.X - pawn_loc.X
                    local dy = ship_loc.Y - pawn_loc.Y
                    local dist2 = dx*dx + dy*dy
                    if dist2 < best_dist then
                        best_dist = dist2
                        best_ship = ship
                    end
                end
            end
        end
    end

    return best_ship
end

function M.apply(cfg)
    cfg_cache = cfg or {}
    if active then return end
    active = true

    local search_radius = tonumber(cfg.search_radius) or 3000
    local sunk_z = tonumber(cfg.sunk_threshold) or -1000

    LoopAsync(50, function()
        if not active then return true end

        local controllers = FindAllOf("PlayerController")
        if not controllers then return false end

        for _, pc in ipairs(controllers) do
            if not pc:GetFullName():find("Default__") then
                local pawn = pc.Pawn
                if pawn then
                    local hc = pawn.HealthComponent
                    local is_alive = hc and hc:IsAlive()
                    local addr = tostring(pawn:GetAddress())

                    if player_alive[addr] == true and is_alive == false then
                        local ship = find_player_ship(pc, search_radius)
                        if ship then
                            local ship_loc = ship:K2_GetActorLocation()
                            if ship_loc and ship_loc.Z > sunk_z then
                                LoopAsync(2000, function()
                                    if not active then return true end
                                    local new_pawn = pc.Pawn
                                    if new_pawn and new_pawn:GetAddress() ~= pawn:GetAddress() then
                                        local nhc = new_pawn.HealthComponent
                                        if nhc and nhc:IsAlive() then
                                            local tp_z = ship_loc.Z + 250
                                            new_pawn:K2_SetActorLocation(
                                                {X = ship_loc.X, Y = ship_loc.Y, Z = tp_z},
                                                false, {}, true
                                            )
                                            print("[SuperMod:Respawn] Teleported player to ship deck")
                                            return true
                                        end
                                    end
                                    return false
                                end)
                            end
                        end
                    end
                    player_alive[addr] = is_alive
                end
            end
        end
        return false
    end)

    print("[SuperMod:Respawn] Death watcher started (radius=" .. search_radius .. ")")
end

function M.revert()
    active = false
    player_alive = {}
    print("[SuperMod:Respawn] Disabled")
end

return M
