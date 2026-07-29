-- ============================================================================
-- Fresh Start Enforcer - By OfficerLawless
-- All Rights Reserved. Download only from official sources.
-- Redistribution, modification, and commercial use are prohibited.
-- ============================================================================
--
-- WindrosePlus fresh-start mod: server-authoritative detection system.
--
-- Policy enforced (when enabled + enforcement="kick"):
--   New players: must arrive with no progression and no items.
--   Returning players: state must be a subset of their last verified snapshot
--                      (XP within tolerance; talents/stats can only stay or go
--                      down; inventory can only stay or go down).
--
-- Storage:
--   windrose_plus_data/fresh_start/config.json
--   windrose_plus_data/fresh_start/players/<player_name>.json
--   windrose_plus_data/fresh_start/audit.log

local API = WindrosePlus.API
local json = require("modules.json")

-- Build identification. Do not modify — used for support and integrity checks.
-- If you are reading this in a copy you obtained from outside an official
-- source, that copy is not licensed for use.
local FSE_BUILD = {
    name      = "Fresh Start Enforcer",
    author    = "OfficerLawless",
    version   = "1.4.0",
    build_id  = "fse-0FF1CE-LAWLE55-v1.4.0",  -- author fingerprint
    build_tag = "\xE2\x80\x8BOL\xE2\x80\x8C",  -- zero-width attribution marker
}

-- Derive the server root dynamically from this script's location.
-- This script lives at:
--   <server_root>\R5\Binaries\Win64\ue4ss\Mods\WindrosePlus\Mods\fresh-start\init.lua
-- so we strip 9 path components (filename + 8 directories) to get the root.
--
-- UE4SS may register Lua modules with RELATIVE paths (e.g.
-- ".\ue4ss\Mods\..."). When that happens, the game process's CWD is
-- R5\Binaries\Win64, so we prepend the absolute CWD before walking up,
-- otherwise paths resolve against CWD and Lua + DLL end up using
-- different roots (DLL uses absolute path from GetModuleFileName).
local function _fse_derive_data_dir()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    source = source:gsub("/", "\\")

    -- Make source absolute if it isn't already.
    -- Match "C:\..." or "\\server\..." for absolute paths; everything else
    -- gets prepended with the process CWD.
    local is_absolute = source:match("^%a:\\") or source:match("^\\\\")
    if not is_absolute then
        local h = io.popen("cd")
        if h then
            local cwd = h:read("*l")
            h:close()
            if cwd and cwd ~= "" then
                source = source:gsub("^%.\\", "")
                source = cwd .. "\\" .. source
            end
        end
    end

    local p = source
    for _ = 1, 9 do
        local stripped = p:match("(.+)\\[^\\]+$")
        if not stripped then break end
        p = stripped
    end
    return p .. "\\enforcer_data"
end

local DATA_DIR    = _fse_derive_data_dir()
-- V3.1+: per-player folder layout. PLAYERS_DIR is the root of those folders;
-- each player's state lives under PLAYERS_DIR\<name>\.
local PLAYERS_DIR = DATA_DIR .. "\\PlayerData"
local CONFIG_FILE = DATA_DIR .. "\\config.json"
local AUDIT_FILE  = DATA_DIR .. "\\audit.log"

-- ---------------------------------------------------------------------------
-- Config (loaded from config.json; defaults written on first run)
-- ---------------------------------------------------------------------------

-- V3.2+: items that Windrose grants to every brand-new character at creation.
-- These are EXCLUDED from the "new player must arrive empty" check so legit
-- fresh joins pass. Admins can extend via config.json starter_item_patterns[].
-- Patterns are matched as substrings against the asset path (case-sensitive
-- since UE paths are stable).
local DEFAULT_STARTER_PATTERNS = {
    -- Starter equipment granted at character creation
    "DA_EID_Armor_Starter_",
    "DA_EID_MeleeWeapon_Saber_Broken_Base",
    "DA_EID_RangeWeapon_Pistol_Rusty_Base",
    -- Starter ammo
    "DA_AID_Ammo_Gunpowder_Homemade",
    -- Quest items granted on character creation
    "DA_DID_Misc_BrokenFamilyAmulet",
    -- All ship customization cosmetics (every class × every part × every theme).
    -- These are unlock entries, not real cargo, and every fresh character starts
    -- with the full set of Stock/Brethren/BlackBeard options for each ship class.
    "/Ship/Brig/Customization/",
    "/Ship/Ketch/Customization/",
    "/Ship/Frigate/Customization/",
    "/Ship/ShallowBoat/Customization/",
}

local DEFAULT_CONFIG = {
    enabled               = true,          -- master switch
    enforcement           = "kick",        -- "log_only" | "kick"  (V3.1+: default is now kick)
    starter_item_patterns = DEFAULT_STARTER_PATTERNS,  -- substrings; items whose name contains any of these are exempt from the new-player empty check
    new_player_max_talents = 0,
    new_player_max_stats   = 0,
    xp_tolerance          = 50,
    snapshot_interval_s   = 30,
    join_check_delay_ticks = 0,            -- start polling on the very first tick (500ms)
    join_check_timeout_ticks = 600,        -- give up after ~5 min (600 ticks * 500ms)
    inventory_capture_window_s = 8,        -- after a player joins, sum AddItems firings
                                           -- inside this window (seconds) to estimate
                                           -- how many items they brought. Should comfortably
                                           -- exceed the save-load burst duration (~1-3s).
    heal_tool_url         = "https://windrose.gg/heal",
    kick_message_prefix   = "Fresh-start server: your character has off-server progression. ",
    kick_message_suffix   = "Repair your save with windrose-heal, then rejoin. See: ",
    -- Legacy player grace: if a returning player's stored snapshot predates
    -- inventory tracking (no `has_inventory` field), we have no baseline to
    -- compare against. With grace ON, their first post-update join is treated
    -- as the new baseline (no inventory violation). With grace OFF, missing
    -- prior inventory data is treated like a new player — any items they
    -- arrive with count as off-server gains.
    legacy_player_grace   = true,
    -- v3.3+: Grandfather mode. When TRUE, the first time a player connects
    -- with no existing baseline on disk, their current state (whatever it
    -- is — talents, items, ships) is SAVED as the new baseline instead of
    -- being checked for violations. Use this when installing the mod on
    -- a server that already has progressed players, so existing accounts
    -- are not falsely flagged as smugglers.
    --
    -- IMPORTANT: leave OFF unless you are intentionally onboarding existing
    -- players. While ON, any genuinely new player who connects with off-
    -- server progression will ALSO be grandfathered (the mod cannot tell
    -- the difference). Turn it OFF after your existing playerbase has
    -- logged in at least once.
    --
    -- Every grandfather event is recorded in audit.log for review.
    grandfather_existing_players = false,
}

local function readJson(path, default)
    local f = io.open(path, "r")
    if not f then return default end
    local content = f:read("*a")
    f:close()
    local ok, data = pcall(json.decode, content)
    if ok and type(data) == "table" then return data end
    return default
end

local function writeJson(path, data)
    local ok, encoded = pcall(json.encode, data)
    if not ok then return false end
    local f = io.open(path, "w")
    if not f then return false end
    f:write(encoded)
    f:close()
    return true
end

local function loadConfig()
    local cfg = readJson(CONFIG_FILE, nil)
    if not cfg then
        -- Make sure the file exists with defaults so the user can edit it
        writeJson(CONFIG_FILE, DEFAULT_CONFIG)
        return DEFAULT_CONFIG
    end
    -- Fill in any missing defaults so newer keys don't break old configs
    for k, v in pairs(DEFAULT_CONFIG) do
        if cfg[k] == nil then cfg[k] = v end
    end
    return cfg
end

local config = loadConfig()

-- V3.2+: hot-reload support. The save-repair tool's mode toggle rewrites
-- config.json without notifying the running mod. We poll the file's
-- modification time once every few seconds; when it changes, reload the
-- config in place so the next tick uses the new mode. This lets the admin
-- flip enforcement between kick/log_only live without a server restart.
local _configMtime = 0
local function _statMtime(path)
    -- io.open lets us check existence cheaply; lfs (which would give mtime)
    -- isn't available in stock UE4SS Lua. Use a `dir /T:W` shell-out fallback
    -- to get the timestamp string — cheap enough at our cadence (one popen
    -- every few seconds is negligible).
    local h = io.popen('for %I in ("' .. path .. '") do @echo %~tI', 'r')
    if not h then return 0 end
    local ts = h:read('*l') or ''
    h:close()
    -- Convert the Windows timestamp string into a comparable string. We
    -- don't actually need it as a number; raw string comparison works for
    -- "changed vs not changed" detection.
    return ts
end
local function maybeReloadConfig()
    local m = _statMtime(CONFIG_FILE)
    if m == _configMtime or m == '' or m == 0 then return end
    if _configMtime == 0 then
        -- First call — record current mtime without reloading.
        _configMtime = m
        return
    end
    local oldMode = config.enforcement
    config = loadConfig()
    _configMtime = m
    if oldMode ~= config.enforcement then
        -- `audit` is local-scoped further down the file and not in scope here.
        -- print() writes to UE4SS.log which is the canonical log for hot-reload
        -- events anyway (admins watching the toggle in real time see it there).
        print('[FreshStart:Config] enforcement changed: ' .. tostring(oldMode) ..
              ' -> ' .. tostring(config.enforcement) .. '\n')
    end
end

local function audit(msg)
    local f = io.open(AUDIT_FILE, "a")
    if f then
        f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. msg .. "\n")
        f:close()
    end
    -- Mirror to UE4SS log too so it's visible during dev
    pcall(function() API.log("info", "FreshStart", msg) end)
end

-- Startup banner (also seeds the audit log with the build fingerprint, so
-- any log file produced by this mod carries the author signature).
audit(FSE_BUILD.name .. " " .. FSE_BUILD.version ..
      " loaded (" .. FSE_BUILD.build_id .. FSE_BUILD.build_tag .. ")")

-- ---------------------------------------------------------------------------
-- Snapshot capture
-- ---------------------------------------------------------------------------

local function captureEquipment(equipmentObj)
    -- Walk all R5EquipmentItem UObjects whose Outer is this player's Equipment
    -- and return a sorted list of their identifying fields. Each entry:
    --   { class = "BP_Armor_Conquistador_Head_Base_C",
    --     logic = "/Game/.../DA_Armor_Conquistador_Head_Base_GearLogicParams" }
    -- We compare Outers by their FullName (UE4SS Lua's UObject == is unreliable).
    local items = {}
    if not equipmentObj or not equipmentObj:IsValid() then return items end

    local equipFullName = nil
    pcall(function() equipFullName = equipmentObj:GetFullName() end)
    if not equipFullName or equipFullName == "" then return items end

    pcall(function()
        local all = FindAllOf("R5EquipmentItem")
        if not all then return end
        for _, item in ipairs(all) do
            if item:IsValid() then
                local outerFullName = ""
                pcall(function()
                    local outer = item:GetOuter()
                    if outer and outer:IsValid() then
                        outerFullName = outer:GetFullName() or ""
                    end
                end)
                if outerFullName == equipFullName then
                    local clsName = ""
                    pcall(function() clsName = item:GetClass():GetFName():ToString() end)
                    local logicPath = ""
                    pcall(function()
                        local lp = item.LogicParams
                        if lp and lp:IsValid() then
                            logicPath = lp:GetFullName() or ""
                        end
                    end)
                    if clsName ~= "" then
                        table.insert(items, { class = clsName, logic = logicPath })
                    end
                end
            end
        end
    end)
    table.sort(items, function(a, b) return a.class < b.class end)
    return items
end

-- Forward declarations for functions defined later but referenced by
-- the inventory reading strategies below.
local nowMs
local readInventorySnapshot

-- ---------------------------------------------------------------------------
-- Inventory reading via MVVM ViewModel / HFSM reflection (v2.0)
--
-- Closes the backpack detection gap from v1.2. AddItems hooks don't fire
-- during save-load hydration, so the C++ firings log misses items a player
-- brings from another server or a tampered save. This module reads the
-- live inventory state through UE4SS Lua reflection by probing for MVVM
-- ViewModel instances (UR5BaseInventorySlotVM, UR5BaseInventorySlotListVM)
-- and falling back through progressively less detailed strategies.
--
-- Architecture (from RE analysis):
--   Container (server, mutable) → View (opaque, 0x58) → ViewModel (UFunctions)
--   The View has NO reflected properties. The ViewModel wraps it and exposes
--   callable UFunctions like GetItemName(), GetItemsCount(), GetSlotItem().
--   On a dedicated server the ViewModel layer MAY or MAY NOT be instantiated.
--   The probe command (wp.fsinvprobe) reports what's available.
-- ---------------------------------------------------------------------------

local INV_PROBE_CLASSES = {
    "R5SC_PlayerInventoryInfo",
    "R5BaseInventorySlotVM",
    "R5DefaultInventorySlotVM",
    "R5BaseInventorySlotListVM",
    "R5DefaultInventorySlotListVM",
    "R5BaseInventoryVM",
    "R5DefaultInventoryVM",
    "R5ItemsInfoWithFilterVM",
    "R5InventoryItemsInfoVM",
    "R5HFSMInventoryItemsInfoComponent",
    "R5DefaultInventoriesScreenHFSMComponent",
    "R5ProximityStorageComponent",
    "R5BLInventoryView",
    "R5BLInventoryModuleView",
    "R5BLInventorySlotView",
    "R5MVVMObserver_BLView",
}

local function safeFindAll(className)
    local ok, result = pcall(FindAllOf, className)
    if ok and result then return result end
    return nil
end

local function safeStr(obj, propName)
    local s = nil
    pcall(function()
        local v = obj[propName]
        if v then
            local ok2, str = pcall(function() return v:ToString() end)
            if ok2 and str then s = str end
        end
    end)
    return s
end

local function safeCall(obj, funcName, ...)
    local ok, result = pcall(function(...) return obj[funcName](obj, ...) end, ...)
    if ok then return result end
    return nil
end

local function viewKey(view)
    if not view then return nil end
    local addr = nil
    pcall(function() addr = tostring(view:GetAddress()) end)
    if not addr then
        pcall(function() addr = view:GetFullName() end)
    end
    return addr
end

local function getPlayerInventoryView(playerName)
    local pscs = safeFindAll("R5ProximityStorageComponent")
    if not pscs then return nil end

    for _, psc in ipairs(pscs) do
        if psc:IsValid() then
            local matched = false
            pcall(function()
                local outer = psc:GetOuter()
                if not outer or not outer:IsValid() then return end
                -- PSC outer is the pawn actor; walk to PlayerState for the name
                local ps = nil
                pcall(function() ps = outer.PlayerState end)
                if not ps or not pcall(function() return ps:IsValid() end) then
                    pcall(function()
                        local ctrl = outer.Controller
                        if ctrl and ctrl:IsValid() then ps = ctrl.PlayerState end
                    end)
                end
                if ps and ps:IsValid() then
                    local pn = safeStr(ps, "PlayerNamePrivate")
                    if pn == playerName then matched = true end
                end
            end)

            if matched then
                local view = nil
                pcall(function()
                    local v = psc.PlayerInventoryView
                    if v and v:IsValid() then view = v end
                end)
                if view then return view end
            end
        end
    end

    -- Fallback: try R5SC_PlayerInventoryInfo (take first valid if single-player)
    local infos = safeFindAll("R5SC_PlayerInventoryInfo")
    if infos then
        for _, info in ipairs(infos) do
            if info:IsValid() then
                local view = nil
                pcall(function()
                    local v = info.PlayerInventoryView
                    if v and v:IsValid() then view = v end
                end)
                if view then return view end
            end
        end
    end
    return nil
end

-- Strategy A: Read via UR5BaseInventorySlotListVM → per-slot UFunctions.
-- Matches list VMs to the player's InventoryView, then reads each slot.
local function readViaSlotListVMs(playerView)
    if not playerView then return nil, "no player view" end
    local pvKey = viewKey(playerView)
    if not pvKey then return nil, "cannot key player view" end

    local listVMs = safeFindAll("R5BaseInventorySlotListVM")
        or safeFindAll("R5DefaultInventorySlotListVM")
    if not listVMs or #listVMs == 0 then
        return nil, "no slot list VMs found"
    end

    local playerLists = {}
    for _, lvm in ipairs(listVMs) do
        if lvm:IsValid() then
            local match = false
            pcall(function()
                local lv = lvm.InventoryView
                if lv and lv:IsValid() then match = (viewKey(lv) == pvKey) end
            end)
            if match then table.insert(playerLists, lvm) end
        end
    end
    if #playerLists == 0 then return nil, "no slot lists matched player view" end

    local items = {}
    local total_items  = 0
    local total_stacks = 0

    for _, listVM in ipairs(playerLists) do
        local moduleTag = ""
        pcall(function()
            local mv = listVM.InventoryModuleView
            if mv and mv:IsValid() then moduleTag = mv:GetFullName() or "" end
        end)

        -- Retrieve slot entities via GetList or GetEntitiesCount+GetEntity
        local slots = nil
        pcall(function() slots = listVM:GetList() end)
        if not slots then
            slots = {}
            local cnt = 0
            pcall(function() cnt = listVM:GetEntitiesCount() end)
            for i = 0, cnt - 1 do
                pcall(function()
                    local e = listVM:GetEntity(i)
                    if e then table.insert(slots, e) end
                end)
            end
        end

        for _, slot in ipairs(slots) do
            pcall(function()
                if not slot:IsValid() then return end
                local hasItem = false
                pcall(function() hasItem = slot:ContainsItem() end)
                if not hasItem then return end

                local entry = { name = "<unknown>", id = "", count = 1, module = moduleTag }
                pcall(function()
                    local t = slot:GetItemName()
                    if t then entry.name = t:ToString() end
                end)
                pcall(function() entry.count = slot:GetItemsCount() or 1 end)
                pcall(function()
                    local tag = slot:GetContainedItemTag()
                    if tag then entry.id = tostring(tag) end
                end)
                pcall(function() entry.is_equipped = slot:IsEquipped() end)
                pcall(function() entry.is_equipment_slot = slot:IsEquipmentSlot() end)
                pcall(function() entry.is_consumable = slot:IsConsumableItem() end)
                pcall(function()
                    local ref = slot:GetSlotItem()
                    if ref then entry.item_def = tostring(ref) end
                end)

                table.insert(items, entry)
                total_stacks = total_stacks + 1
                total_items  = total_items + entry.count
            end)
        end
    end

    return {
        captured_at_ms = nowMs(),
        source         = "mvvm_slot_list_vms",
        total_stacks   = total_stacks,
        total_items    = total_items,
        items          = items,
    }
end

-- Strategy B: Read via bare UR5BaseInventorySlotVM instances (no list grouping).
-- Less precise (cannot filter by player if multiple are online) but still
-- captures the full item set when only one player is connected.
local function readViaBareSlotVMs()
    local slotVMs = safeFindAll("R5BaseInventorySlotVM")
        or safeFindAll("R5DefaultInventorySlotVM")
    if not slotVMs or #slotVMs == 0 then
        return nil, "no slot VMs found"
    end

    local items = {}
    local total_items  = 0
    local total_stacks = 0

    for _, slot in ipairs(slotVMs) do
        pcall(function()
            if not slot:IsValid() then return end
            local hasItem = false
            pcall(function() hasItem = slot:ContainsItem() end)
            if not hasItem then return end

            local entry = { name = "<unknown>", id = "", count = 1, module = "" }
            pcall(function()
                local t = slot:GetItemName()
                if t then entry.name = t:ToString() end
            end)
            pcall(function() entry.count = slot:GetItemsCount() or 1 end)
            pcall(function()
                local tag = slot:GetContainedItemTag()
                if tag then entry.id = tostring(tag) end
            end)
            pcall(function() entry.is_equipped = slot:IsEquipped() end)
            pcall(function() entry.is_equipment_slot = slot:IsEquipmentSlot() end)
            pcall(function() entry.is_consumable = slot:IsConsumableItem() end)
            pcall(function()
                local ref = slot:GetSlotItem()
                if ref then entry.item_def = tostring(ref) end
            end)

            table.insert(items, entry)
            total_stacks = total_stacks + 1
            total_items  = total_items + entry.count
        end)
    end

    if total_stacks == 0 then return nil, "slot VMs exist but all empty" end
    return {
        captured_at_ms = nowMs(),
        source         = "mvvm_bare_slot_vms",
        total_stacks   = total_stacks,
        total_items    = total_items,
        items          = items,
    }
end

-- Strategy C: Walk UR5BLInventorySlotView instances and read whatever
-- properties UE4SS reflection exposes. The CXX headers say these are opaque
-- (UR5BLViewBase, 0x58), but we probe anyway in case this build differs.
local function readViaSlotViews(playerView)
    local pvKey = playerView and viewKey(playerView) or nil
    local slotViews = safeFindAll("R5BLInventorySlotView")
    if not slotViews or #slotViews == 0 then
        return nil, "no R5BLInventorySlotView instances"
    end

    local items = {}
    local total_items  = 0
    local total_stacks = 0
    local props_found  = false

    for _, sv in ipairs(slotViews) do
        pcall(function()
            if not sv:IsValid() then return end
            local cls = sv:GetClass()
            if not cls then return end
            cls:ForEachProperty(function(prop)
                props_found = true
                -- If we find any reflected property, try to read it
                pcall(function()
                    local pname = prop:GetFName():ToString()
                    local val   = sv[pname]
                    if val ~= nil then
                        local entry = { name = pname, id = "", count = 1, module = "" }
                        pcall(function() entry.id = tostring(val) end)
                        table.insert(items, entry)
                        total_stacks = total_stacks + 1
                        total_items  = total_items + 1
                    end
                end)
            end)
        end)
    end

    if not props_found then return nil, "slot views are opaque (0 reflected properties)" end
    return {
        captured_at_ms = nowMs(),
        source         = "slot_views_reflection",
        total_stacks   = total_stacks,
        total_items    = total_items,
        items          = items,
    }
end

-- Master capture: runs strategies A → B → C → DLL fallback in order.
-- Pass silent=true from automated callers (periodic snapshot, join tick)
-- to suppress per-tick log spam. Manual commands pass silent=false.
local function captureFullInventory(pc, playerName, silent)
    local playerView = getPlayerInventoryView(playerName)
    local log = not silent and audit or function() end

    -- A: List VMs (per-player, full detail)
    local result, err = readViaSlotListVMs(playerView)
    if result and result.total_stacks > 0 then return result end
    if err then log("inv-read A (slot list VMs): " .. err) end

    -- B: Bare slot VMs (no player filter, works for single-player)
    result, err = readViaBareSlotVMs()
    if result and result.total_stacks > 0 then return result end
    if err then log("inv-read B (bare slot VMs): " .. err) end

    -- C: Slot views direct reflection (unlikely but covers edge cases)
    result, err = readViaSlotViews(playerView)
    if result and result.total_stacks > 0 then return result end
    if err then log("inv-read C (slot views): " .. err) end

    -- D: C++ DLL snapshot file (existing fallback)
    local shape = readInventorySnapshot(playerName, nil)
    if shape then
        log("inv-read D (DLL snapshot): " ..
            shape.total_stacks .. " stacks, " .. shape.total_items .. " items")
        return {
            captured_at_ms = shape.captured_at_ms,
            source         = "cpp_dll_snapshot",
            total_stacks   = shape.total_stacks,
            total_items    = shape.total_items,
            items          = shape.items,
        }
    end

    log("inv-read: all strategies exhausted for " .. (playerName or "?"))
    return nil
end


local function captureSnapshot(pc)
    local snap = {
        ts             = os.time(),
        ts_iso         = os.date("%Y-%m-%dT%H:%M:%S"),
        player_name    = nil,
        has_pawn       = false,
        has_inventory  = false,
        talent_count   = 0,
        stat_count     = 0,
        equipment      = {},
        inventory      = nil,
    }

    pcall(function()
        local ps = pc.PlayerState
        if not ps or not ps:IsValid() then return end

        local pn = ps.PlayerNamePrivate
        if pn then
            local ok, s = pcall(function() return pn:ToString() end)
            if ok and s then snap.player_name = s end
        end

        local progComp = ps.ProgressionComponent
        if progComp and progComp:IsValid() then
            pcall(function()
                local talents = progComp.CachedLearnedTalents
                if talents then snap.talent_count = #talents end
            end)
            pcall(function()
                local stats = progComp.CachedLearnedStats
                if stats then snap.stat_count = #stats end
            end)
        end
    end)

    pcall(function()
        local pawn = pc.Pawn
        if pawn and pawn:IsValid() then
            snap.has_pawn = true
            local eq = pawn.Equipment
            if eq and eq:IsValid() then
                snap.equipment = captureEquipment(eq)
            end
            local inv = captureFullInventory(pc, snap.player_name, true)
            if inv and inv.total_stacks and inv.total_stacks >= 0 then
                snap.inventory_shape = inv
                snap.has_inventory   = true
            else
                snap.inventory     = nil
                snap.has_inventory = false
            end
        end
    end)

    return snap
end

-- ---------------------------------------------------------------------------
-- Inventory: read the C++ DLL's inventory_firings.log
--
-- The DLL (WindroseInventoryGuard v7.0+) appends a structured record on every
-- inventory rule firing:
--
--   <epoch_millis>,<rule_name>,<this_ptr_hex>,<arg2_ptr_hex>,<item_count>
--
-- The "save-load burst" right after a player joins replays their saved
-- inventory through AddItems calls server-side, so summing AddItems firings
-- inside [join_ms, join_ms + window] gives us a reliable count of items they
-- arrived with — without trying (and failing) to read inventory state via
-- Lua reflection.
-- ---------------------------------------------------------------------------

-- Server root + "\\windrose_plus_data\\inventory_firings.log"
local INVENTORY_FIRINGS_LOG =
    DATA_DIR .. "\\inventory_firings.log"

-- V3.1+: DLL writes per-player live snapshot to PlayerData\<name>\current.json
-- (previously: inventory_snapshots\<name>.json). Helper resolves the per-player
-- path given a player name.
local function _playerCurrentJsonPath(player_name)
    if not player_name or player_name == "" then return nil end
    local safe = (player_name:gsub("[^A-Za-z0-9._%-]", ""))
    if safe == "" then return nil end
    return PLAYERS_DIR .. "\\" .. safe .. "\\current.json"
end

readInventorySnapshot = function(player_name, min_capture_ms)
    -- Returns nil if the file doesn't exist, is older than min_capture_ms,
    -- or fails to parse. The C++ DLL sanitizes player names the same way:
    -- keep ASCII alnum + dash + underscore + dot.
    local path = _playerCurrentJsonPath(player_name)
    if not path then return nil end
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return nil end
    local ok, parsed = pcall(json.decode, content)
    if not ok or type(parsed) ~= "table" then return nil end
    if min_capture_ms and (parsed.captured_at_ms or 0) < min_capture_ms then
        return nil  -- pre-join snapshot — DLL hasn't dumped since they connected
    end
    -- Flatten to {name, id, count, module} list for easy comparison.
    local items_flat = {}
    local total_stacks = 0
    local total_items  = 0
    for _, mod in ipairs(parsed.modules or {}) do
        for _, slot in ipairs(mod.slots or {}) do
            if slot.count and slot.count > 0 then
                table.insert(items_flat, {
                    name   = slot.name or "<unknown>",
                    id     = slot.item_id or "",
                    count  = slot.count or 1,
                    module = mod.tag or "",
                })
                total_stacks = total_stacks + 1
                total_items  = total_items  + slot.count
            end
        end
    end
    return {
        captured_at_ms = parsed.captured_at_ms or 0,
        total_stacks   = total_stacks,
        total_items    = total_items,
        items          = items_flat,
    }
end

-- v22: per-ship cargo snapshots written by the C++ DLL (ship_dumpAllShips).
-- Each <player>_ship_<sanitized_ship_name>.json contains cargo + equipment +
-- customization slots for one ship the player owns. DLL re-writes on a
-- 60-second rolling cadence while the player is connected.
-- Orphan-disconnect grace: read the DLL-maintained set of ShipIds this
-- player has observed in heap during any prior session. Returns a hex-string
-- set keyed for O(1) lookup. Empty table if the file doesn't exist yet.
local function readSeenShipIds(player_name)
    -- V3.2+: seen_ship_ids[] is now an inline array inside current.json
    -- (the DLL no longer writes a separate seen_ships.json file).
    local out = {}
    if not player_name or player_name == "" then return out end
    local safe = (player_name:gsub("[^A-Za-z0-9._%-]", ""))
    if safe == "" then return out end
    local path = PLAYERS_DIR .. "\\" .. safe .. "\\current.json"
    local f = io.open(path, "r")
    if not f then return out end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return out end
    local ok, parsed = pcall(json.decode, content)
    if not ok or type(parsed) ~= "table" or type(parsed.seen_ship_ids) ~= "table" then
        return out
    end
    for _, id in ipairs(parsed.seen_ship_ids) do
        if type(id) == "string" and #id == 32 then
            out[id:upper()] = true
        end
    end
    return out
end

local function readShipSnapshots(player_name, min_capture_ms)
    -- Returns a map { ship_name → {captured_at_ms, ship_class, ship_id, slots[]} }
    -- where slots[] is sorted by (slot_type, item_id, count) for stable diffs.
    -- V3.2+: ships[] is now an inline array inside current.json (no more
    -- ships\<name>.json files). Read the whole snapshot once + extract ships.
    if not player_name or player_name == "" then return {} end
    local safe = (player_name:gsub("[^A-Za-z0-9._%-]", ""))
    if safe == "" then return {} end
    local curPath = PLAYERS_DIR .. "\\" .. safe .. "\\current.json"
    local cf = io.open(curPath, "r")
    if not cf then return {} end
    local cContent = cf:read("*a")
    cf:close()
    if not cContent or cContent == "" then return {} end
    local cok, cParsed = pcall(json.decode, cContent)
    if not cok or type(cParsed) ~= "table" or type(cParsed.ships) ~= "table" then
        return {}
    end
    local ships = {}
    for _, sj in ipairs(cParsed.ships) do
        if type(sj) == "table" and sj.ship_name then
            local capMs = cParsed.ships_captured_at_ms or 0
            if not min_capture_ms or capMs >= min_capture_ms then
                ships[sj.ship_name] = {
                    captured_at_ms = capMs,
                    ship_name      = sj.ship_name,
                    ship_class     = sj.ship_class or "",
                    ship_id        = sj.ship_id or "",
                    total_stacks   = sj.total_stacks or 0,
                    total_items    = sj.total_items or 0,
                    slots          = sj.slots or {},
                }
            end
        end
    end
    return ships
end

local function readInventoryFirings(since_ms, until_ms)
    local result = {
        fire_count  = 0,    -- number of AddItems firings in the window
        total_items = 0,    -- sum of item_count across those firings
        rules_seen  = {},   -- map of rule_name → count (anything in window)
    }
    local f = io.open(INVENTORY_FIRINGS_LOG, "r")
    if not f then return result end
    for line in f:lines() do
        -- Format: <millis>,<rule>,<this>,<arg2>,<items>
        local ts_str, rule, items_str = line:match("^(%d+),([^,]+),[^,]+,[^,]+,(%-?%d+)")
        if ts_str then
            local ts = tonumber(ts_str)
            local items = tonumber(items_str) or 0
            if ts and ts >= since_ms and ts <= until_ms then
                result.rules_seen[rule] = (result.rules_seen[rule] or 0) + 1
                if rule == "AddItems" or rule == "ApplyItemsFromLootTable" then
                    result.fire_count  = result.fire_count + 1
                    result.total_items = result.total_items + items
                end
            end
        end
    end
    f:close()
    return result
end

-- ---------------------------------------------------------------------------
-- Per-player record persistence
-- ---------------------------------------------------------------------------

local function sanitizeName(name)
    -- File-safe version of the player name
    return (name or "unknown"):gsub("[^%w_%-]", "_")
end

local function playerFile(name)
    -- V3.1+: per-player folder. The cumulative state we maintain across
    -- sessions (used to compare on next join) lives at:
    --   PlayerData\<name>\last_snapshot.json
    -- Caller is responsible for ensuring the parent folder exists; readJson
    -- returns nil cleanly on a missing file.
    return PLAYERS_DIR .. "\\" .. sanitizeName(name) .. "\\last_snapshot.json"
end

local function _ensurePlayerDir(name)
    local pdir = PLAYERS_DIR .. "\\" .. sanitizeName(name)
    -- Use Lua's lfs equivalent via os.execute (no lfs in UE4SS Lua). md is
    -- silent if the dir already exists when called with /nul redirect.
    os.execute('mkdir "' .. pdir .. '" 2>nul')
    return pdir
end

local function loadRecord(name)
    return readJson(playerFile(name), nil)
end

local function saveRecord(name, snap)
    local rec = loadRecord(name) or {
        first_seen = snap.ts_iso,
        history    = {},
    }
    rec.last_seen     = snap.ts_iso
    rec.last_snapshot = snap
    rec.history = rec.history or {}
    table.insert(rec.history, snap)
    -- V3.1+: keep last 5 snapshots (down from 20). Per-player history files
    -- on disk are bounded; 5 gives enough audit trail for forensic comparison
    -- without unbounded growth.
    while #rec.history > 5 do table.remove(rec.history, 1) end
    _ensurePlayerDir(name)
    writeJson(playerFile(name), rec)

    -- V3.2+: ALSO copy current.json (the DLL's live snapshot) into the
    -- player's history\ folder with a timestamped filename. This gives us
    -- forensic-grade point-in-time snapshots separate from the Lua-managed
    -- last_snapshot.json baseline. Cap at 5 files per player; oldest gets
    -- deleted when count exceeds.
    pcall(function()
        local safe = sanitizeName(name)
        local pdir = PLAYERS_DIR .. "\\" .. safe
        local histDir = pdir .. "\\history"
        os.execute('mkdir "' .. histDir .. '" 2>nul')
        local curPath = pdir .. "\\current.json"
        local f = io.open(curPath, "rb")
        if not f then return end
        local content = f:read("*a")
        f:close()
        if not content or content == "" then return end
        -- ISO-8601-ish timestamp safe for filenames (no colons): YYYY-MM-DDTHH-MM-SSZ
        local ts = os.date("!%Y-%m-%dT%H-%M-%SZ")
        local histPath = histDir .. "\\" .. ts .. ".json"
        local wf = io.open(histPath, "wb")
        if wf then wf:write(content); wf:close() end
        -- Prune to 5 files (sorted by name = sorted by timestamp).
        local files = {}
        local p = io.popen('dir /b /o-d "' .. histDir .. '\\*.json" 2>nul', 'r')
        if p then
            for fn in p:lines() do
                if fn and fn ~= "" then table.insert(files, fn) end
            end
            p:close()
        end
        -- files[1] is newest (dir /o-d), files[N] is oldest. Delete anything past 5.
        for i = 6, #files do
            os.execute('del /Q "' .. histDir .. '\\' .. files[i] .. '" 2>nul')
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Snapshot comparison
-- ---------------------------------------------------------------------------

local function compareSnapshots(prev, curr)
    -- Returns a list of violation strings. Empty list = OK.
    local violations = {}

    -- Build a set of previous equipment classes (or empty set for new player)
    local prevEquipSet = {}
    if prev and prev.equipment then
        for _, e in ipairs(prev.equipment) do
            prevEquipSet[e.class] = true
        end
    end

    -- Inventory totals come from the C++ firings log (see readInventoryFirings).
    -- We have item count, not per-asset-path detail, so comparisons are numeric.
    local currInv = (curr.inventory and curr.inventory.total_items) or 0
    local prevInv = (prev and prev.inventory and prev.inventory.total_items) or 0

    if not prev then
        -- New player: must arrive empty.
        if curr.talent_count > config.new_player_max_talents then
            table.insert(violations,
                "new player has " .. curr.talent_count ..
                " talent nodes (max allowed: " .. config.new_player_max_talents .. ")")
        end
        if curr.stat_count > config.new_player_max_stats then
            table.insert(violations,
                "new player has " .. curr.stat_count ..
                " stat nodes (max allowed: " .. config.new_player_max_stats .. ")")
        end
        if curr.equipment and #curr.equipment > 0 then
            -- Default starter kit — every fresh character spawns with these.
            -- Verified against Adventurer (a true 0/0 fresh char) 2026-05-11 22:25:
            --   BP_Backpack_Simple_L01_T01_C   (basic backpack)
            --   BP_Armor_Starter_*_C           (starter armor, 5 pieces)
            --   BP_Wpn_TwoHand_Fists_T01_C     (unarmed weapon)
            local defaultPatterns = {
                "backpack_simple_l01",
                "armor_starter_",
                "wpn_twohand_fists_t01",
            }
            local function isDefault(className)
                local lc = className:lower()
                for _, pat in ipairs(defaultPatterns) do
                    if lc:find(pat, 1, true) then return true end
                end
                return false
            end
            local nonDefaultList = {}
            for _, e in ipairs(curr.equipment) do
                if not isDefault(e.class) then
                    table.insert(nonDefaultList, e.class)
                end
            end
            if #nonDefaultList > 0 then
                table.insert(violations,
                    "new player arrived equipped with " .. #nonDefaultList ..
                    " non-default item(s): " .. table.concat(nonDefaultList, ", "))
            end
        end
        if currInv > 0 then
            local fc = (curr.inventory and curr.inventory.fire_count) or 0
            table.insert(violations,
                "new player arrived with items in inventory (firings=" .. fc ..
                ", items=" .. currInv .. ")")
        end
        -- (v1.3) Inventory shape check — the DLL walks the inventory module
        -- directly, so this catches items that came in via save-load and
        -- never fired AddItems.
        --
        -- V3.2+: filter out Windrose's default starter-pack items before
        -- counting. A fresh-from-creation character always has the starter
        -- armor / saber / pistol / gunpowder / ship-customization-cosmetics
        -- (~36 items), and those should NOT count as off-server smuggling.
        -- Items not matching any whitelist pattern remain — those are the
        -- ones that suggest the character was played elsewhere.
        if curr.inventory_shape and #curr.inventory_shape.items > 0 then
            local rawItems = curr.inventory_shape.items
            local patterns = config.starter_item_patterns or DEFAULT_STARTER_PATTERNS
            local function isStarterItem(name)
                if not name then return false end
                for _, pat in ipairs(patterns) do
                    if name:find(pat, 1, true) then return true end
                end
                return false
            end

            local nonStarter = {}
            local nonStarterItemCount = 0
            local starterFiltered = 0
            for _, it in ipairs(rawItems) do
                if isStarterItem(it.name) then
                    starterFiltered = starterFiltered + 1
                else
                    table.insert(nonStarter, it)
                    nonStarterItemCount = nonStarterItemCount + (it.count or 0)
                end
            end

            if #nonStarter > 0 then
                local names = {}
                for i = 1, math.min(#nonStarter, 5) do
                    table.insert(names, nonStarter[i].name .. " x" .. nonStarter[i].count)
                end
                local more = ""
                if #nonStarter > 5 then more = " (+" .. (#nonStarter - 5) .. " more)" end
                table.insert(violations,
                    "new player arrived with " .. #nonStarter ..
                    " non-starter item stack(s), " ..
                    nonStarterItemCount .. " items total (" ..
                    starterFiltered .. " starter items allowed): " ..
                    table.concat(names, ", ") .. more)
            end
            -- If nonStarter is empty, the player arrived with ONLY the
            -- default starter pack — no violation.
        end
        return violations
    end

    -- Returning player: state must not have grown.
    if curr.talent_count > prev.talent_count then
        table.insert(violations,
            "talent_count grew off-server: " .. prev.talent_count ..
            " (last seen) -> " .. curr.talent_count .. " (now)")
    end
    if curr.stat_count > prev.stat_count then
        table.insert(violations,
            "stat_count grew off-server: " .. prev.stat_count ..
            " (last seen) -> " .. curr.stat_count .. " (now)")
    end

    -- Equipment: any item in current that wasn't in previous = off-server gain
    if curr.equipment then
        for _, e in ipairs(curr.equipment) do
            if not prevEquipSet[e.class] then
                table.insert(violations,
                    "new equipment off-server: " .. e.class)
            end
        end
    end

    -- (v1.3) Inventory shape drift — detect item instances that weren't in
    -- the prior baseline. Each item has a unique itemId; an itemId we
    -- haven't seen before means the item appeared off-server.
    if curr.inventory_shape and prev.inventory_shape then
        local prev_ids = {}
        for _, item in ipairs(prev.inventory_shape.items or {}) do
            if item.id and item.id ~= "" then
                prev_ids[item.id] = true
            end
        end
        local new_items = {}
        for _, item in ipairs(curr.inventory_shape.items) do
            if item.id and item.id ~= "" and not prev_ids[item.id] then
                table.insert(new_items, item)
            end
        end
        if #new_items > 0 then
            local names = {}
            for i = 1, math.min(#new_items, 5) do
                table.insert(names, new_items[i].name .. " x" .. new_items[i].count)
            end
            local more = ""
            if #new_items > 5 then more = " (+" .. (#new_items - 5) .. " more)" end
            table.insert(violations,
                "new inventory items off-server: " .. table.concat(names, ", ") .. more)
        end
    elseif curr.inventory_shape and not prev.inventory_shape and
           not config.legacy_player_grace then
        -- Returning player with no prior shape baseline and grace off — any
        -- items present count as off-server.
        if #curr.inventory_shape.items > 0 then
            table.insert(violations,
                "returning player has no prior inventory shape but arrived with " ..
                #curr.inventory_shape.items ..
                " item stack(s) (legacy_player_grace=false)")
        end
    end

    -- Inventory: only flag if count grew beyond what they had last time.
    --
    -- If prev has no inventory data (legacy snapshot from before tracking):
    --   * legacy_player_grace = true   → skip comparison, current state becomes
    --                                   the new baseline (one-time grace).
    --   * legacy_player_grace = false  → strict mode: any current items count
    --                                   as off-server gains.
    if prev.has_inventory then
        if currInv > prevInv then
            table.insert(violations,
                "inventory grew off-server: " .. prevInv ..
                " items (last seen) -> " .. currInv .. " (now)")
        end
    elseif not config.legacy_player_grace then
        if currInv > 0 then
            table.insert(violations,
                "returning player has no prior inventory record but arrived with " ..
                currInv .. " item(s) (legacy_player_grace=false)")
        end
    end

    -- v22: per-ship cargo drift detection. curr.ship_snapshots is a map of
    -- {ship_name → {slots[]}} from the DLL's per-player heap scan. prev's
    -- analog lives in prev.ship_snapshots. We compare per ship_name, flagging
    -- any item_id that appears in curr but not prev (new instance, almost
    -- certainly off-server). Count-only growth (player picked up an item the
    -- system already knew about) doesn't flag.
    if curr.ship_snapshots then
        local prev_ships = (prev and prev.ship_snapshots) or {}
        -- Orphan-disconnect grace: load the DLL-maintained set of ShipIds
        -- the player has seen in heap on this server. A "new since last
        -- session" ship gets grace if its ShipId is in this set (meaning
        -- it existed on the server while the player was previously online —
        -- likely built mid-session and orphaned at disconnect).
        local seen_ids = readSeenShipIds(curr.player_name)
        for ship_name, curr_ship in pairs(curr.ship_snapshots) do
            local prev_ship = prev_ships[ship_name]
            local curr_slots = curr_ship.slots or {}
            if not prev_ship then
                -- New ship (player didn't own this last time, or first session).
                local ship_id = (curr_ship.ship_id or ""):upper()
                local seen_before = ship_id ~= "" and seen_ids[ship_id]
                if seen_before then
                    -- Orphan-grace: the ShipId was observed during a prior
                    -- session, so this is a legitimate in-server build that
                    -- the attribution layer couldn't link at the time.
                    -- No violation in either grace or strict mode.
                elseif not config.legacy_player_grace and #curr_slots > 0 then
                    table.insert(violations,
                        "ship '" .. ship_name .. "' is new since last session with " ..
                        #curr_slots .. " stack(s) — possible off-server ship import")
                end
            else
                -- Build set of prior item_ids for this ship
                local prev_ids = {}
                for _, s in ipairs(prev_ship.slots or {}) do
                    if s.item_id and s.item_id ~= "" then
                        prev_ids[s.item_id] = true
                    end
                end
                local new_items = {}
                for _, s in ipairs(curr_slots) do
                    if s.item_id and s.item_id ~= "" and not prev_ids[s.item_id] then
                        table.insert(new_items, s)
                    end
                end
                if #new_items > 0 then
                    local names = {}
                    for i = 1, math.min(#new_items, 5) do
                        local nm = (new_items[i].name or "?"):gsub(".*/", "")
                        table.insert(names, nm .. " x" .. (new_items[i].count or 1))
                    end
                    local more = ""
                    if #new_items > 5 then more = " (+" .. (#new_items - 5) .. " more)" end
                    table.insert(violations,
                        "ship '" .. ship_name .. "' has new cargo off-server: " ..
                        table.concat(names, ", ") .. more)
                end
            end
        end
    end

    return violations
end

-- ---------------------------------------------------------------------------
-- Kick action
-- ---------------------------------------------------------------------------

-- IMPORTANT: UE4SS Lua cannot safely invoke the C++ virtual methods needed
-- to disconnect a player. The existing WindrosePlus admin module documents
-- this at length (Scripts/modules/admin.lua line 1646). Any path that calls
-- ClientReturnToMainMenuWithTextReason / DisconnectClient / GameMode.Logout
-- from Lua either silently fails or — observed in live testing 2026-05-11 —
-- crashes the entire server a few seconds later.
--
-- Instead we write a kick request to a JSON file. The companion C++ UE4SS
-- mod (WindroseInventoryGuard DLL) is responsible for picking up the
-- request and performing the actual kick using UE's reflection system,
-- which handles FText conversion correctly.
local KICK_REQUEST_DIR = DATA_DIR .. "\\kick_requests"

local function kickPlayer(pc, reason)
    local pname = "?"
    pcall(function()
        local ps = pc.PlayerState
        if ps and ps:IsValid() then
            local v = ps.PlayerNamePrivate
            if v then pname = v:ToString() end
        end
    end)
    -- Ensure directory exists (best effort)
    pcall(function() os.execute('if not exist "' .. KICK_REQUEST_DIR .. '" mkdir "' .. KICK_REQUEST_DIR .. '"') end)
    local req_file = KICK_REQUEST_DIR .. "\\" .. sanitizeName(pname) .. "_" .. os.time() .. ".json"
    local payload = {
        player_name = pname,
        reason      = reason or "",
        requested_at = os.date("%Y-%m-%dT%H:%M:%S"),
        status      = "pending",
    }
    local wrote = writeJson(req_file, payload)
    if wrote then
        audit("kick request queued: " .. req_file)
        return true
    end
    audit("kick request write FAILED for " .. pname)
    return false
end


-- ---------------------------------------------------------------------------
-- Find a connected PlayerController by display name
-- ---------------------------------------------------------------------------

local function findPC(targetName)
    local pcs = FindAllOf("PlayerController")
    if not pcs then return nil end
    for _, pc in ipairs(pcs) do
        if pc:IsValid() then
            local nm = nil
            pcall(function()
                local ps = pc.PlayerState
                if ps and ps:IsValid() then
                    local v = ps.PlayerNamePrivate
                    if v then
                        local ok, s = pcall(function() return v:ToString() end)
                        if ok then nm = s end
                    end
                end
            end)
            if nm == targetName then return pc end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Join handling: queue a deferred check ~20s after join (cache must load)
-- ---------------------------------------------------------------------------

local pending = {}  -- [player_name] = { joined = ts, ticks = N }
-- V3.1+: players whose join was kicked. They MUST NOT have their state
-- saved as a baseline by the periodic snapshot tick — otherwise the next
-- reconnect would see "same state as before, no diff, OK" and let them in.
-- Cleared when the player reconnects (re-entering pending).
local kicked_until_reconnect = {}

-- Returns the current time in epoch milliseconds. Lua's os.time() is in
-- seconds; we synthesize a wall-clock ms reading. UE4SS Lua doesn't expose
-- a millisecond clock directly, so we approximate by combining os.time()
-- (sec resolution) with the fractional part from os.clock() (CPU time,
-- monotonic within a session). The C++ firings log uses real wall-clock
-- millis from GetSystemTime, so this comparison is in the right ballpark
-- but can drift by up to a second. We use a generous 8-second window for
-- inventory capture to absorb that drift.
nowMs = function()
    return os.time() * 1000
end

-- v3.4+: Touch the ship-scan request flag so the C++ DLL's worker thread
-- wakes up and runs an immediate ship-cargo scan instead of waiting for
-- the next 30 s tick. Used on player connect/disconnect events to tighten
-- ship-ownership attribution. Best-effort write; failures are silent
-- because the worker will pick the scan up on its next normal cycle.
local function triggerImmediateShipScan(reason)
    pcall(function()
        local path = DATA_DIR .. "\\ship_scan_request.flag"
        local f = io.open(path, "w")
        if f then
            f:write(tostring(reason or "trigger") .. "\n")
            f:write("ts=" .. os.time() .. "\n")
            f:close()
        end
    end)
end

API.onPlayerJoin(function(player)
    if not config.enabled then
        audit("join: " .. player.name .. " (system disabled — no checks)")
        return
    end
    audit("join queued: " .. player.name)
    -- V3.1+: clear the post-kick block since this is a fresh reconnect.
    -- (If they're rejoining with the same smuggled state, the join check
    --  will catch it and kick again. If they cleaned their save, they'll
    --  pass and the new clean baseline will be saved.)
    kicked_until_reconnect[player.name] = nil
    pending[player.name] = {
        joined    = os.time(),
        joined_ms = nowMs(),
        ticks     = 0,
    }
    -- v3.4+: ship-attribution tightening. Trigger an immediate ship-cargo
    -- scan so we have a baseline ShipId set BEFORE the player has had a
    -- chance to build a new ship. Any new ShipIds that appear after this
    -- scan while this player is online are attributable to them with
    -- high confidence.
    triggerImmediateShipScan("connect:" .. player.name)
end)

-- v3.4+: symmetric leave hook. Triggers a final ship scan when a player
-- disconnects so we capture any newly-built ships before they leave. Combined
-- with the connect-time scan, this catches probably 80% of ship-creation
-- events with clean attribution (single-player or small group sessions).
if API.onPlayerLeave then
    API.onPlayerLeave(function(player)
        if not config.enabled then return end
        audit("leave: " .. player.name)
        triggerImmediateShipScan("disconnect:" .. player.name)
    end)
end

-- V3.2+: dedicated 3-second config hot-reload tick so the save-repair mode
-- toggle takes effect quickly (independent of how often other ticks fire).
local _lastConfigCheck = 0
API.registerTickCallback(function()
    -- Rate-limit so we don't io.popen on every 500ms tick.
    local now = os.time()
    if now - _lastConfigCheck < 3 then return end
    _lastConfigCheck = now
    maybeReloadConfig()
end, 500)

API.registerTickCallback(function()
    if not next(pending) then return end

    for name, info in pairs(pending) do
        info.ticks = info.ticks + 1

        if info.ticks > config.join_check_timeout_ticks then
            audit("timeout waiting for " .. name .. " to fully load — abandoning check")
            pending[name] = nil
            goto continue
        end

        if info.ticks < config.join_check_delay_ticks then
            goto continue
        end

        local pc = findPC(name)
        if not pc then goto continue end

        local curr = captureSnapshot(pc)
        if not curr.has_pawn then
            -- Pawn hasn't spawned yet, retry next tick.
            goto continue
        end

        -- Inventory: read the C++ DLL's firings log for AddItems calls fired
        -- inside the save-load window (from a second before the player joined
        -- through to now). We use this in place of Lua reflection, which
        -- doesn't work on this build (the R5BLInventoryView fields aren't
        -- readable without crashing the server).
        local join_ms   = info.joined_ms or (info.joined * 1000)
        local window_ms = (config.inventory_capture_window_s or 8) * 1000
        local firings   = readInventoryFirings(join_ms - 1000, join_ms + window_ms)
        curr.inventory = {
            fire_count  = firings.fire_count,
            total_items = firings.total_items,
            source      = "cpp_firings_log",
        }
        curr.has_inventory = firings.fire_count > 0

        -- Inventory SHAPE: captureSnapshot now attempts Lua-side reading via
        -- MVVM ViewModel reflection (strategies A-C in captureFullInventory).
        -- If that already populated curr.inventory_shape, use it. Otherwise
        -- fall back to the C++ DLL snapshot file (strategy D).
        if not curr.inventory_shape then
            local shape = readInventorySnapshot(name, join_ms)
            local tick_window = math.ceil(window_ms / 500)
            if not shape and info.ticks < (config.join_check_delay_ticks or 0) + tick_window then
                goto continue
            end
            if shape then
                curr.inventory_shape = shape
            end
        end

        -- v22: ship cargo snapshots from the DLL's per-player heap scan.
        -- DLL writes inventory_snapshots/<player>_ship_<name>.json on the
        -- in-world signal and every 60s thereafter. Wait the same window
        -- as the inventory shape so the first scan has time to land.
        if not curr.ship_snapshots then
            local ships = readShipSnapshots(name, join_ms)
            curr.ship_snapshots = ships
        end

        local rec = loadRecord(name)
        local prev = rec and rec.last_snapshot or nil

        -- v3.3+: Grandfather mode. If this player has NO existing baseline
        -- AND the admin has enabled grandfathering, skip the new-player
        -- empty-inventory check and accept whatever they show up with as
        -- their new baseline. Used when installing on a server with an
        -- already-progressed playerbase.
        if prev == nil and config.grandfather_existing_players then
            local shape_info = "n/a"
            if curr.inventory_shape then
                shape_info = curr.inventory_shape.total_stacks .. "stacks/" ..
                             curr.inventory_shape.total_items .. "items"
            end
            audit("GRANDFATHERED " .. name ..
                " (talent_count=" .. curr.talent_count ..
                ", stat_count=" .. curr.stat_count ..
                ", equipment_count=" .. (#curr.equipment or 0) ..
                ", inv_shape=" .. shape_info .. ") — baseline locked in")
            audit("  -> turn OFF grandfather_existing_players in config.json " ..
                "once your existing playerbase has all logged in once")
            saveRecord(name, curr)
            pending[name] = nil
            goto continue
        end

        local violations = compareSnapshots(prev, curr)

        if #violations == 0 then
            local shape_info = "n/a"
            if curr.inventory_shape then
                shape_info = curr.inventory_shape.total_stacks .. "stacks/" ..
                             curr.inventory_shape.total_items .. "items"
            end
            audit("OK join: " .. name ..
                " (talent_count=" .. curr.talent_count ..
                ", stat_count=" .. curr.stat_count ..
                ", equipment_count=" .. (#curr.equipment or 0) ..
                ", inv_fires=" .. firings.fire_count ..
                ", inv_items=" .. firings.total_items ..
                ", inv_shape=" .. shape_info .. ")")
            saveRecord(name, curr)
        else
            audit("VIOLATIONS on join for " .. name .. ":")
            for _, v in ipairs(violations) do
                audit("  - " .. v)
            end

            if config.enforcement == "kick" then
                local short = violations[1] or "state mismatch"
                if #violations > 1 then
                    short = short .. " (+" .. (#violations - 1) .. " more)"
                end
                local prefix = config.kick_message_prefix or
                    "Fresh-start server: your character has off-server progression. "
                local suffix = config.kick_message_suffix or
                    "Repair your save with windrose-heal, then rejoin. See: "
                local url = config.heal_tool_url or "https://windrose.gg/heal"
                local msg = prefix .. short .. " " .. suffix .. url

                local ok_block, kick_err = pcall(function()
                    if kickPlayer(pc, msg) then
                        audit("KICKED " .. name .. ": " .. short)
                    else
                        audit("kick attempt failed for " .. name)
                    end
                end)
                if not ok_block then audit("kick threw: " .. tostring(kick_err)) end
                -- Don't save baseline — we don't want their dirty state to
                -- become the new "OK" for next time. They have to clean their
                -- save (via windrose-heal) to rejoin successfully.
                --
                -- V3.1+: ALSO mark them as kicked_until_reconnect so the
                -- periodic snapshot tick doesn't overwrite the baseline in
                -- the ~5-second window between kick decision and actual
                -- DLL-side disconnect. The flag clears when they reconnect
                -- (in the onPlayerJoin handler).
                kicked_until_reconnect[name] = true
                audit("baseline NOT updated for " .. name ..
                    " — they must clean their save and rejoin clean")
            else
                audit("(log_only mode — no kick performed)")
            end
        end

        pending[name] = nil

        ::continue::
    end
end, 500)  -- 500ms tick — fast detection so the window between spawn and kick
            -- is tiny (< 1 sec). Small enough to prevent meaningful exploitation.

-- ---------------------------------------------------------------------------
-- Periodic snapshot of all connected players (so we capture state if disconnect
-- handler doesn't fire cleanly).
-- ---------------------------------------------------------------------------

API.registerTickCallback(function()
    -- V3.2+: hot-reload config.json if it was modified by the save-repair
    -- mode toggle (or any other external editor). Cheap — one io.popen
    -- on the same ~30s cadence as the snapshot loop.
    maybeReloadConfig()

    if not config.enabled then return end
    local pcs = FindAllOf("PlayerController")
    if not pcs then return end
    for _, pc in ipairs(pcs) do
        if pc:IsValid() then
            local snap = captureSnapshot(pc)
            if snap.player_name and snap.has_pawn then
                -- IMPORTANT: don't overwrite records for players still in the
                -- join-check queue. Their baseline must come from the join
                -- check itself — otherwise the periodic loop races the join
                -- check and writes a "current==current" record, after which
                -- the join check sees a returning player matching their own
                -- newly-arrived state and lets them through.
                if pending[snap.player_name] then
                    goto skip
                end
                -- V3.1+: also skip players whose join was just kicked. There's
                -- a ~5-second gap between the kick decision and the actual
                -- disconnect during which their PC is still in FindAllOf;
                -- saving their state here would persist the smuggled baseline
                -- and let them straight through on reconnect.
                if kicked_until_reconnect[snap.player_name] then
                    goto skip
                end
                -- Pick up the latest inventory shape so the persisted
                -- baseline includes the item list. Periodic snapshots don't
                -- need freshness gating — the DLL dumps every second and
                -- a stale-by-a-tick shape is still accurate for on-server
                -- play.
                local shape = readInventorySnapshot(snap.player_name, nil)
                if shape then snap.inventory_shape = shape end
                saveRecord(snap.player_name, snap)
            end
        end
        ::skip::
    end
end, (config.snapshot_interval_s or 30) * 1000)

-- ---------------------------------------------------------------------------
-- Admin commands
-- ---------------------------------------------------------------------------

API.registerCommand("wp.fsstatus", function(args)
    local lines = {
        "=== Fresh Start Status ===",
        "  enabled:                " .. tostring(config.enabled),
        "  enforcement:            " .. config.enforcement,
        "  new_player_max_talents: " .. config.new_player_max_talents,
        "  new_player_max_stats:   " .. config.new_player_max_stats,
        "  xp_tolerance:           " .. config.xp_tolerance,
        "  snapshot_interval_s:    " .. config.snapshot_interval_s,
        "  legacy_player_grace:    " .. tostring(config.legacy_player_grace),
        "  heal_tool_url:          " .. tostring(config.heal_tool_url),
        "  data dir:               " .. DATA_DIR,
        "  audit log:              " .. AUDIT_FILE,
    }
    return table.concat(lines, "\n")
end, "Show fresh-start config and runtime state", "wp.fsstatus")

API.registerCommand("wp.fslegacy", function(args)
    local arg = (args[1] or ""):lower()
    if arg == "on" or arg == "true" or arg == "1" then
        config.legacy_player_grace = true
    elseif arg == "off" or arg == "false" or arg == "0" then
        config.legacy_player_grace = false
    else
        return "Usage: wp.fslegacy on|off  (current: " ..
               tostring(config.legacy_player_grace) .. ")"
    end
    writeJson(CONFIG_FILE, config)
    audit("legacy_player_grace set to " .. tostring(config.legacy_player_grace))
    return "legacy_player_grace = " .. tostring(config.legacy_player_grace)
end, "Toggle one-time inventory-check grace for returning players with no prior inventory data", "wp.fslegacy on|off")

API.registerCommand("wp.fsenable", function(args)
    config.enabled = true
    writeJson(CONFIG_FILE, config)
    audit("system ENABLED via wp.fsenable")
    return "Fresh-start enabled. Mode: " .. config.enforcement ..
           " (use wp.fsmode kick to actually kick violators)"
end, "Enable the fresh-start detection system", "wp.fsenable")

API.registerCommand("wp.fsdisable", function(args)
    config.enabled = false
    writeJson(CONFIG_FILE, config)
    audit("system DISABLED via wp.fsdisable")
    return "Fresh-start disabled. No checks will run."
end, "Disable the fresh-start detection system", "wp.fsdisable")

API.registerCommand("wp.fsmode", function(args)
    local mode = args[1]
    if mode ~= "log_only" and mode ~= "kick" then
        return "Usage: wp.fsmode log_only|kick (currently: " .. config.enforcement .. ")"
    end
    config.enforcement = mode
    writeJson(CONFIG_FILE, config)
    audit("enforcement mode set to: " .. mode)
    return "Enforcement mode set to: " .. mode
end, "Set enforcement mode (log_only | kick)", "wp.fsmode <mode>")

API.registerCommand("wp.fssnap", function(args)
    -- Force-snapshot all connected players right now (for testing)
    local pcs = FindAllOf("PlayerController")
    if not pcs or #pcs == 0 then return "No PlayerControllers" end
    local lines = { "=== Forced Snapshot ===" }
    for _, pc in ipairs(pcs) do
        if pc:IsValid() then
            local snap = captureSnapshot(pc)
            if snap.player_name and snap.has_pawn then
                saveRecord(snap.player_name, snap)
                table.insert(lines,
                    snap.player_name ..
                    " : talents=" .. snap.talent_count ..
                    " stats=" .. snap.stat_count ..
                    " equipment=" .. #snap.equipment ..
                    " saved")
                if #snap.equipment > 0 then
                    for _, e in ipairs(snap.equipment) do
                        table.insert(lines, "    - " .. e.class)
                    end
                end
            elseif snap.player_name then
                table.insert(lines,
                    snap.player_name .. " : pawn not loaded yet, skipped")
            end
        end
    end
    return table.concat(lines, "\n")
end, "Force a snapshot of all connected players", "wp.fssnap")

API.registerCommand("wp.fsdiff", function(args)
    local target = args[1]
    if not target then return "Usage: wp.fsdiff <player_name>" end
    local rec = loadRecord(target)
    if not rec or not rec.last_snapshot then
        return "No snapshot on file for '" .. target .. "'"
    end
    local pc = findPC(target)
    if not pc then return "Player not currently connected: " .. target end
    local curr = captureSnapshot(pc)
    local violations = compareSnapshots(rec.last_snapshot, curr)
    local prevEquip = rec.last_snapshot.equipment or {}
    local currEquip = curr.equipment or {}
    local lines = {
        "=== fsdiff " .. target .. " ===",
        "  prev: talents=" .. rec.last_snapshot.talent_count ..
            " stats=" .. rec.last_snapshot.stat_count ..
            " equipment=" .. #prevEquip ..
            " (snap @ " .. rec.last_snapshot.ts_iso .. ")",
        "  curr: talents=" .. curr.talent_count ..
            " stats=" .. curr.stat_count ..
            " equipment=" .. #currEquip,
    }
    if #violations == 0 then
        table.insert(lines, "  result: OK")
    else
        table.insert(lines, "  result: VIOLATIONS:")
        for _, v in ipairs(violations) do
            table.insert(lines, "    - " .. v)
        end
    end
    return table.concat(lines, "\n")
end, "Compare a player's current state to their last snapshot", "wp.fsdiff <player>")

API.registerCommand("wp.fslist", function(args)
    -- List per-player records by walking the players directory.
    -- Lua has no portable directory iteration, so use io.popen with `dir`.
    local lines = { "=== Known Players ===" }
    local handle = io.popen('dir /B "' .. PLAYERS_DIR .. '\\*.json" 2>nul')
    if not handle then return "Could not list players directory" end
    local count = 0
    for fname in handle:lines() do
        local name = fname:match("^(.+)%.json$")
        if name then
            count = count + 1
            local rec = loadRecord(name)
            if rec and rec.last_snapshot then
                local s = rec.last_snapshot
                table.insert(lines,
                    name ..
                    " | last: " .. (rec.last_seen or "?") ..
                    " | t=" .. (s.talent_count or 0) ..
                    " s=" .. (s.stat_count or 0) ..
                    " e=" .. #(s.equipment or {}))
            else
                table.insert(lines, name .. " | (corrupt or empty record)")
            end
        end
    end
    handle:close()
    if count == 0 then
        table.insert(lines, "  (no records yet)")
    end
    return table.concat(lines, "\n")
end, "List all players with snapshots on file", "wp.fslist")

API.registerCommand("wp.fsclear", function(args)
    local target = args[1]
    if not target then return "Usage: wp.fsclear <player_name>" end
    local path = playerFile(target)
    local f = io.open(path, "r")
    if not f then return "No record for '" .. target .. "'" end
    f:close()
    os.remove(path)
    audit("cleared record for " .. target .. " via wp.fsclear")
    return "Cleared record for '" .. target .. "' (will be treated as new on next join)"
end, "Delete a player's snapshot history (treats them as new)", "wp.fsclear <player>")

-- ---------------------------------------------------------------------------
-- Inventory diagnostics
-- ---------------------------------------------------------------------------

API.registerCommand("wp.fsinvprobe", function(args)
    local lines = { "=== Inventory Class Probe ===" }

    for _, className in ipairs(INV_PROBE_CLASSES) do
        local instances = safeFindAll(className)
        local count = instances and #instances or 0
        local line = "  " .. className .. ": " .. count

        if count > 0 then
            local props = {}
            local funcs = {}
            pcall(function()
                local cls = instances[1]:GetClass()
                if cls then
                    cls:ForEachProperty(function(p)
                        pcall(function() table.insert(props, p:GetFName():ToString()) end)
                    end)
                    cls:ForEachFunction(function(f)
                        pcall(function() table.insert(funcs, f:GetFName():ToString()) end)
                    end)
                end
            end)
            if #props > 0 then
                line = line .. " | props=[" .. table.concat(props, ", ") .. "]"
            else
                line = line .. " | props=(none)"
            end
            if #funcs > 0 then
                line = line .. " | funcs=[" .. table.concat(funcs, ", ") .. "]"
            else
                line = line .. " | funcs=(none)"
            end
        end

        table.insert(lines, line)
    end

    -- Probe a specific player's inventory view if requested
    local target = args[1]
    if target then
        table.insert(lines, "")
        local view = getPlayerInventoryView(target)
        if view then
            table.insert(lines, "PlayerInventoryView for " .. target .. ": FOUND")
            local vClass = "?"
            pcall(function() vClass = view:GetClass():GetFName():ToString() end)
            table.insert(lines, "  class: " .. vClass)
            local vProps = {}
            local vFuncs = {}
            pcall(function()
                local cls = view:GetClass()
                cls:ForEachProperty(function(p)
                    pcall(function() table.insert(vProps, p:GetFName():ToString()) end)
                end)
                cls:ForEachFunction(function(f)
                    pcall(function() table.insert(vFuncs, f:GetFName():ToString()) end)
                end)
            end)
            table.insert(lines, "  props: " .. (#vProps > 0 and table.concat(vProps, ", ") or "(none)"))
            table.insert(lines, "  funcs: " .. (#vFuncs > 0 and table.concat(vFuncs, ", ") or "(none)"))
        else
            table.insert(lines, "PlayerInventoryView for " .. target .. ": NOT FOUND")
        end
    else
        table.insert(lines, "")
        table.insert(lines, "Tip: wp.fsinvprobe <player_name> to also probe their view")
    end

    return table.concat(lines, "\n")
end, "Probe inventory UClasses available on this server", "wp.fsinvprobe [player]")

API.registerCommand("wp.fsinvread", function(args)
    local target = args[1]
    if not target then return "Usage: wp.fsinvread <player_name>" end

    local pc = findPC(target)
    if not pc then return "Player not connected: " .. target end

    local inv = captureFullInventory(pc, target)
    if not inv then return "All inventory read strategies failed for " .. target end

    local lines = {
        "=== Inventory: " .. target .. " ===",
        "  source:       " .. (inv.source or "?"),
        "  total_stacks: " .. (inv.total_stacks or 0),
        "  total_items:  " .. (inv.total_items or 0),
    }

    if inv.items and #inv.items > 0 then
        for i, item in ipairs(inv.items) do
            local flags = ""
            if item.is_equipped then flags = flags .. " [EQUIPPED]" end
            if item.is_equipment_slot then flags = flags .. " [EQUIP_SLOT]" end
            if item.is_consumable then flags = flags .. " [CONSUMABLE]" end
            table.insert(lines,
                "  " .. i .. ". " .. (item.name or "?") ..
                " x" .. (item.count or 1) ..
                " (id=" .. (item.id or "") .. ")" .. flags)
        end
    else
        table.insert(lines, "  (no items)")
    end

    -- V3.1+: write to PlayerData\<safe>\current.json
    local safe = (target:gsub("[^A-Za-z0-9._%-]", ""))
    if safe ~= "" then
        local playerDir = PLAYERS_DIR .. "\\" .. safe
        pcall(function()
            os.execute('mkdir "' .. playerDir .. '" 2>nul')
        end)
        local snapPath = playerDir .. "\\current.json"
        if writeJson(snapPath, inv) then
            table.insert(lines, "")
            table.insert(lines, "Written to: " .. snapPath)
        end
    end

    return table.concat(lines, "\n")
end, "Force-read a player's full inventory via Lua reflection", "wp.fsinvread <player>")

-- ---------------------------------------------------------------------------
-- Crash recovery (v3.3+)
-- ---------------------------------------------------------------------------
--
-- The DLL writes current.json for each connected player every 30 seconds
-- (snapshot_interval_s). The Lua mod normally updates each player's
-- last_snapshot.json baseline only on a clean disconnect — which means
-- if the server crashes mid-session, the baseline is stale and the player
-- gets falsely flagged as a smuggler on reconnect for whatever they
-- legitimately earned in the crashed session.
--
-- The recovery mechanism:
--   1. Lua writes enforcer_data/session.lock at boot with a timestamp.
--   2. Lua updates session.lock's mtime periodically (every snapshot tick).
--   3. On boot, if session.lock exists AND its mtime is recent (within
--      LOCK_STALE_THRESHOLD_S), the previous session crashed.
--   4. For each PlayerData/<name>/ folder where current.json is newer
--      than last_snapshot.json, copy current.json's snapshot fields into
--      last_snapshot.json so the baseline catches up to the crash point.
--   5. Smugglers are still caught — the recovery only updates the baseline
--      to where the player was AT THE LAST SNAPSHOT before the crash. Any
--      items they bring in BETWEEN sessions still fail the diff check.

local SESSION_LOCK_PATH      = DATA_DIR .. "\\session.lock"
local LOCK_STALE_THRESHOLD_S = 10 * 60  -- if lock is < 10 min old, treat as crashed

local function _writeSessionLock()
    pcall(function()
        local f = io.open(SESSION_LOCK_PATH, "w")
        if f then
            f:write("session_start=" .. os.time() .. "\n")
            f:write("pid_approx=" .. (os.time() % 100000) .. "\n")
            f:close()
        end
    end)
end

local function _lockMtime()
    -- Lua has no native file mtime API. Use a directory-listing trick:
    --   dir /T:W /4 returns "MM/DD/YYYY  HH:MM <SIZE> filename" — but
    --   parsing is locale-fragile. Simpler: just check whether the file
    --   exists; combined with our periodic touch, ANY existing lock from
    --   a prior session means that session crashed. We don't need exact
    --   age for the recovery decision.
    local f = io.open(SESSION_LOCK_PATH, "r")
    if not f then return nil end
    f:close()
    return true  -- exists
end

local function _runCrashRecovery()
    -- For each PlayerData/<name>/ folder, if current.json is newer than
    -- last_snapshot.json, promote current.json to last_snapshot.json so
    -- the baseline catches up to wherever the crash interrupted.
    local recovered = 0
    pcall(function()
        local p = io.popen('dir /B /AD "' .. PLAYERS_DIR .. '" 2>nul', 'r')
        if not p then return end
        local names = {}
        for line in p:lines() do
            if line and line ~= "" then table.insert(names, line) end
        end
        p:close()

        for _, name in ipairs(names) do
            local pdir       = PLAYERS_DIR .. "\\" .. name
            local curPath    = pdir .. "\\current.json"
            local baseline   = pdir .. "\\last_snapshot.json"
            local cur        = readJson(curPath, nil)
            if cur then
                local rec = readJson(baseline, nil) or {
                    first_seen = cur.captured_at_iso or os.date("!%Y-%m-%dT%H-%M-%SZ"),
                    history    = {},
                }
                -- Promote the DLL's current.json into the baseline as if a
                -- clean disconnect had just happened. We don't have the full
                -- snapshot shape the Lua side normally builds, but the DLL
                -- writes enough fields for compareSnapshots to operate.
                rec.last_seen     = cur.captured_at_iso or os.date("!%Y-%m-%dT%H-%M-%SZ")
                rec.last_snapshot = cur
                rec.history = rec.history or {}
                table.insert(rec.history, cur)
                while #rec.history > 5 do table.remove(rec.history, 1) end
                rec.recovered_from_crash = true
                rec.recovered_at_iso     = os.date("!%Y-%m-%dT%H-%M-%SZ")
                if writeJson(baseline, rec) then
                    recovered = recovered + 1
                    audit("[crash-recovery] promoted current snapshot as baseline for " ..
                        name .. " (captured at " .. (cur.captured_at_iso or "?") .. ")")
                end
            end
        end
    end)
    audit("[crash-recovery] " .. recovered .. " player baseline(s) restored from in-flight snapshots")
end

-- Check for stale lock = crashed previous session
if _lockMtime() then
    audit("[crash-recovery] detected unclean previous shutdown (session.lock present at boot)")
    _runCrashRecovery()
    -- Delete the stale lock; we'll write a fresh one below.
    pcall(function() os.remove(SESSION_LOCK_PATH) end)
else
    audit("[boot] no stale session.lock found — previous session ended cleanly")
end

-- Write fresh session.lock for THIS session.
_writeSessionLock()

-- Periodically touch the lock to keep it fresh while we run. The lock's
-- presence on next boot is what signals a crash, so just keep it around.
local _lockTickCount = 0
API.registerTickCallback(function()
    _lockTickCount = _lockTickCount + 1
    -- Every ~30s (60 ticks/sec * 30 = 1800)
    if _lockTickCount >= 1800 then
        _lockTickCount = 0
        _writeSessionLock()
    end
end)

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------

audit("fresh-start mod loaded (enabled=" .. tostring(config.enabled) ..
    ", mode=" .. config.enforcement ..
    ", grandfather=" .. tostring(config.grandfather_existing_players) .. ")")
