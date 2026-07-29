-- ============================================================================
-- Enforcer (Standalone) â€” V3.0
-- ============================================================================
--
-- This file replaces the WindrosePlus host framework dependency with a thin
-- compatibility shim. The actual fresh-start enforcement logic is unchanged
-- and lives in Scripts/fresh-start/init.lua (vendored from V2.x verbatim).
--
-- What this shim provides:
--   * A global `WindrosePlus.API` table with the four surfaces the
--     fresh-start logic calls:
--       - API.log(level, module, msg)        â€” leveled console logging
--       - API.onPlayerJoin(fn)                â€” fired when a new PlayerController
--                                              appears in the world
--       - API.registerTickCallback(fn, ms)    â€” periodic timer via LoopAsync
--       - API.registerCommand(name, ...)      â€” stub (no admin chat commands in
--                                              the standalone build; use audit.log
--                                              and config.json files instead)
--   * Player-join detection by polling `FindAllOf("PlayerController")` every 2s.
--   * No dependency on WindrosePlus, livemap, poiscan, rcon, or any other
--     sub-mods. Single-purpose UE4SS Lua mod focused on Fresh Start.
--
-- The data directory path resolution in fresh-start/init.lua walks 9 dirs up
-- from the script's source path. Because we placed init.lua at
--    Mods/FreshStartEnforcer/Scripts/fresh-start/init.lua
-- the walk lands at the server root, same as the legacy
--    Mods/WindrosePlus/Mods/fresh-start/init.lua
-- layout. The on-disk data dir (`windrose_plus_data\fresh_start\`) is
-- therefore unchanged â€” admins upgrading from V2.x keep all their captured
-- snapshots and config.
-- ============================================================================

-- ---- log helper (mirrors WindrosePlus's modules/log.lua) -------------------

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }
local LABELS = { [1] = "DEBUG", [2] = "INFO", [3] = "WARN", [4] = "ERROR" }

local function log_write(level_name, module, msg)
    local level = LEVELS[tostring(level_name):lower()] or 2
    local label = LABELS[level] or "?"
    print("[Enforcer:" .. tostring(module) .. "] " .. label .. ": " ..
          tostring(msg) .. "\n")
end


-- ---- player-join polling --------------------------------------------------
--
-- WindrosePlus's API.onPlayerJoin was driven by its periodic query module
-- doing FindAllOf("PlayerController") + diff against the last-known set.
-- We do the same thing here, scoped to just what fresh-start needs.

local _player_join_callbacks = {}
local _player_leave_callbacks = {}    -- v3.4+
local _last_known_players = {}   -- set: name -> player table

-- Mirror WindrosePlus._isConnected so we don't fire joins for half-loaded
-- PlayerControllers (pre-spawn, mid-disconnect). A PC is "connected enough
-- to enforce against" if it either has a live Pawn or a non-zero ping.
local function _is_connected(pc)
    local hasPawn = false
    pcall(function()
        local pawn = pc.Pawn
        if pawn and pawn:IsValid() then hasPawn = true end
    end)
    if hasPawn then return true end

    local hasPing = false
    pcall(function()
        local ps = pc.PlayerState
        if ps and ps:IsValid() then
            local ping = ps.CompressedPing
            local n = ping and tonumber(tostring(ping))
            if n and n > 0 then hasPing = true end
        end
    end)
    return hasPing
end

local function _enumerate_players()
    local results = {}
    local pcs = FindAllOf("PlayerController")
    if not pcs then return results end
    for _, pc in ipairs(pcs) do
        if pc and pc:IsValid() and _is_connected(pc) then
            local ps = pc.PlayerState
            if ps and ps:IsValid() then
                -- Extract the raw FString property and call :ToString() to get
                -- the Lua string. tostring(ps:GetPlayerName()) returns the
                -- FString wrapper's pointer address ("FString: 0x..."), which
                -- changes every tick and breaks dedup. PlayerNamePrivate is
                -- the actual replicated property and stringifies cleanly.
                local name = nil
                pcall(function()
                    local fs = ps.PlayerNamePrivate
                    if fs then
                        local ok, str = pcall(function() return fs:ToString() end)
                        if ok and str and str ~= "" then name = str end
                    end
                end)
                if name then
                    table.insert(results, {
                        name = name,
                        playerController = pc,
                        playerState = ps,
                    })
                end
            end
        end
    end
    return results
end

local function _fire_join_events_if_new(current_players)
    local current_by_name = {}
    for _, p in ipairs(current_players) do
        if p.name then current_by_name[p.name] = p end
    end

    -- Join: in current set, not in previous set
    for name, player in pairs(current_by_name) do
        if not _last_known_players[name] then
            for _, cb in ipairs(_player_join_callbacks) do
                local ok, err = pcall(cb, player)
                if not ok then
                    log_write("warn", "Shim",
                        "onPlayerJoin callback errored for " .. name .. ": " ..
                        tostring(err))
                end
            end
        end
    end

    -- v3.4+: Leave: in previous set, not in current set
    for name, prev_player in pairs(_last_known_players) do
        if not current_by_name[name] then
            for _, cb in ipairs(_player_leave_callbacks) do
                local ok, err = pcall(cb, { name = name })
                if not ok then
                    log_write("warn", "Shim",
                        "onPlayerLeave callback errored for " .. name .. ": " ..
                        tostring(err))
                end
            end
        end
    end

    _last_known_players = current_by_name
end


-- ---- tick callbacks (LoopAsync wrappers) -----------------------------------

local function _register_tick(fn, interval_ms)
    interval_ms = tonumber(interval_ms) or 5000
    if interval_ms < 250 then interval_ms = 250 end
    if type(LoopAsync) ~= "function" then
        log_write("error", "Shim",
            "LoopAsync not available; cannot register tick callback")
        return
    end
    LoopAsync(interval_ms, function()
        local ok, err = pcall(fn)
        if not ok then
            log_write("warn", "Shim",
                "Tick callback errored: " .. tostring(err))
        end
        return false  -- continue looping
    end)
end


-- ---- the API surface that fresh-start/init.lua expects ---------------------

WindrosePlus = WindrosePlus or {}
WindrosePlus.API = WindrosePlus.API or {}

WindrosePlus.API.log = function(level, module, msg)
    log_write(level, module, msg)
end

WindrosePlus.API.onPlayerJoin = function(fn)
    if type(fn) == "function" then
        table.insert(_player_join_callbacks, fn)
    end
end

-- v3.4+: symmetric leave hook. Fires after a player who was previously in
-- _last_known_players is no longer present in the current poll. Callback
-- receives a table with just { name = "<player>" } (the PlayerController
-- is gone by the time we detect the leave, so no live UObject to pass).
WindrosePlus.API.onPlayerLeave = function(fn)
    if type(fn) == "function" then
        table.insert(_player_leave_callbacks, fn)
    end
end

WindrosePlus.API.registerTickCallback = function(fn, interval_ms)
    if type(fn) == "function" then
        _register_tick(fn, interval_ms)
    end
end

-- Admin chat commands are not supported in the standalone build. Calls
-- are accepted (so init.lua doesn't error) but no-op. Admin operations
-- happen via the on-disk config.json and audit.log instead.
WindrosePlus.API.registerCommand = function(name, handler, description, usage)
    log_write("info", "Shim",
        "registerCommand('" .. tostring(name) .. "') â€” standalone build, no-op")
end

-- A couple of incidental helpers init.lua may consult. Safe defaults.
WindrosePlus.API.isIdle = function() return false end
WindrosePlus.isIdle    = function() return false end


-- ---- bootstrap: start the player-join poller, then load fresh-start logic --

log_write("info", "Shim",
    "Enforcer (Standalone) shim initialised â€” loading fresh-start logic")

-- Start polling for player joins every 2 seconds. This MUST run before
-- fresh-start/init.lua registers its onPlayerJoin callback so the poller
-- is ready when the first player connects.
if type(LoopAsync) == "function" then
    LoopAsync(2000, function()
        local players = _enumerate_players()
        _fire_join_events_if_new(players)
        return false
    end)
else
    log_write("error", "Shim",
        "LoopAsync not available; player-join detection disabled â€” " ..
        "join-time enforcement will not run. The mod will still write " ..
        "snapshots via the C++ DLL.")
end

-- Now load the actual fresh-start enforcement logic. Any error here is
-- caught and logged so the mod doesn't crash the UE4SS Lua VM on a bad
-- update; the DLL continues to capture snapshots regardless.
local ok, err = pcall(require, "fresh-start.init")
if not ok then
    log_write("error", "Shim",
        "fresh-start.init failed to load: " .. tostring(err))
    log_write("error", "Shim",
        "Join-time enforcement is DISABLED. DLL snapshot capture still runs.")
end

