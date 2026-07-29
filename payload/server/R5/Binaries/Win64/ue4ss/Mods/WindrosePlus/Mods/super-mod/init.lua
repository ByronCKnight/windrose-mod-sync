-- SuperMod — server-side mod suite for Windrose dedicated server
-- WindrosePlus sub-mod. Reads mods_config.json from the admin panel,
-- applies runtime CDO changes, writes mods_status.json for indicators.
-- Supports hot-reload: admin panel can trigger Lua module reload without
-- restarting the game server.

local MOD_ID   = "super-mod"
local MOD_NAME = "SuperMod"
local VERSION  = "2.0.0"

local MOD_REQUIRE_PREFIX = "Mods.super-mod.modules."

-- Resolve paths
local script_dir = debug.getinfo(1, "S").source:match("@?(.*[/\\])")
local server_root = script_dir:match("(.+)[/\\]R5[/\\]") or ""
local data_dir = server_root .. "\\enforcer_data"
local config_path = data_dir .. "\\mods_config.json"
local status_path = data_dir .. "\\mods_status.json"
local reload_path = data_dir .. "\\mods_reload_trigger.json"

-- JSON parser (recursive descent — no load() which UE4SS sandboxes)
local json = {}
function json.decode(str)
    if not str or str == "" then return nil end
    local pos = 1
    local len = #str

    local function skip_ws()
        while pos <= len do
            local c = str:byte(pos)
            if c == 32 or c == 9 or c == 10 or c == 13 then pos = pos + 1
            else break end
        end
    end

    local parse_value

    local function parse_string()
        pos = pos + 1
        local parts = {}
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == '"' then pos = pos + 1; return table.concat(parts) end
            if c == '\\' then
                pos = pos + 1
                local e = str:sub(pos, pos)
                if e == '"' or e == '\\' or e == '/' then parts[#parts+1] = e
                elseif e == 'n' then parts[#parts+1] = '\n'
                elseif e == 'r' then parts[#parts+1] = '\r'
                elseif e == 't' then parts[#parts+1] = '\t'
                else parts[#parts+1] = e end
            else
                parts[#parts+1] = c
            end
            pos = pos + 1
        end
        return table.concat(parts)
    end

    local function parse_number()
        local start = pos
        if str:sub(pos, pos) == '-' then pos = pos + 1 end
        while pos <= len and str:sub(pos, pos):match("%d") do pos = pos + 1 end
        if pos <= len and str:sub(pos, pos) == '.' then
            pos = pos + 1
            while pos <= len and str:sub(pos, pos):match("%d") do pos = pos + 1 end
        end
        if pos <= len and str:sub(pos, pos):match("[eE]") then
            pos = pos + 1
            if pos <= len and str:sub(pos, pos):match("[%+%-]") then pos = pos + 1 end
            while pos <= len and str:sub(pos, pos):match("%d") do pos = pos + 1 end
        end
        return tonumber(str:sub(start, pos - 1))
    end

    local function parse_object()
        pos = pos + 1
        local obj = {}
        skip_ws()
        if pos <= len and str:sub(pos, pos) == '}' then pos = pos + 1; return obj end
        while pos <= len do
            skip_ws()
            if str:sub(pos, pos) ~= '"' then break end
            local key = parse_string()
            skip_ws()
            if str:sub(pos, pos) == ':' then pos = pos + 1 end
            local val = parse_value()
            obj[key] = val
            skip_ws()
            if str:sub(pos, pos) == ',' then pos = pos + 1
            elseif str:sub(pos, pos) == '}' then pos = pos + 1; return obj
            else break end
        end
        return obj
    end

    local function parse_array()
        pos = pos + 1
        local arr = {}
        skip_ws()
        if pos <= len and str:sub(pos, pos) == ']' then pos = pos + 1; return arr end
        while pos <= len do
            arr[#arr+1] = parse_value()
            skip_ws()
            if str:sub(pos, pos) == ',' then pos = pos + 1
            elseif str:sub(pos, pos) == ']' then pos = pos + 1; return arr
            else break end
        end
        return arr
    end

    parse_value = function()
        skip_ws()
        local c = str:sub(pos, pos)
        if c == '"' then return parse_string()
        elseif c == '{' then return parse_object()
        elseif c == '[' then return parse_array()
        elseif c == 't' then pos = pos + 4; return true
        elseif c == 'f' then pos = pos + 5; return false
        elseif c == 'n' then pos = pos + 4; return nil
        elseif c == '-' or c:match("%d") then return parse_number()
        end
        return nil
    end

    local ok, result = pcall(parse_value)
    if ok then return result end
    return nil
end
function json.encode(val)
    local t = type(val)
    if t == "nil" then return "null"
    elseif t == "boolean" then return val and "true" or "false"
    elseif t == "number" then return tostring(val)
    elseif t == "string" then return '"' .. val:gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
    elseif t == "table" then
        local is_arr = #val > 0
        local parts = {}
        if is_arr then
            for _, v in ipairs(val) do parts[#parts+1] = json.encode(v) end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, v in pairs(val) do
                parts[#parts+1] = '"' .. tostring(k) .. '":' .. json.encode(v)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

-- File I/O
local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function write_file(path, content)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content)
    f:close()
    return true
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

local function delete_file(path)
    os.remove(path)
end

local function read_json(path)
    local raw = read_file(path)
    if not raw or raw == "" then return nil end
    local ok, result = pcall(json.decode, raw)
    if ok then return result end
    return nil
end

local function write_json(path, data)
    local ok, encoded = pcall(json.encode, data)
    if ok then write_file(path, encoded) end
end

-- Module registry
local modules = {}
local module_names = {
    -- Original 11
    "weather", "respawn_on_ship", "swimming", "stacks",
    "backpacks", "stats", "ships", "barrel_loot",
    "drop_rates", "npc_spawn", "insignia_sell",
    -- Crafting & Recipes
    "crafting_speed", "recipe_output", "building_costs",
    -- Item Stats
    "item_weight", "item_durability", "weapon_damage", "armor_values",
    -- Character & GAS
    "stamina", "health_regen", "xp_multiplier", "food_duration",
    -- Ships & Naval
    "ship_health", "cannon_damage",
    -- Economy & World
    "merchant_prices", "farming_speed", "fishing", "skill_points",
}

local mod_id_map = {
    weather         = "weather_control",
    respawn_on_ship = "respawn_on_ship",
    swimming        = "unlimited_swimming",
    stacks          = "stack_multiplier",
    backpacks       = "backpacks",
    stats           = "extended_stats",
    ships           = "faster_ships",
    barrel_loot     = "floating_barrel_loot",
    drop_rates      = "drop_rates",
    npc_spawn       = "npc_respawn",
    insignia_sell   = "insignia_sell",
    crafting_speed  = "crafting_speed",
    recipe_output   = "recipe_output",
    building_costs  = "building_costs",
    item_weight     = "item_weight",
    item_durability = "item_durability",
    weapon_damage   = "weapon_damage",
    armor_values    = "armor_values",
    stamina         = "stamina_control",
    health_regen    = "health_regen",
    xp_multiplier   = "xp_multiplier",
    food_duration   = "food_duration",
    ship_health     = "ship_health",
    cannon_damage   = "cannon_damage",
    merchant_prices = "merchant_prices",
    farming_speed   = "farming_speed",
    fishing         = "fishing",
    skill_points    = "skill_points",
}

-- State tracking
local current_config = nil
local mod_statuses = {}
local reload_counter = 0

-- Load all modules
local function load_modules()
    local loaded = 0
    local failed = 0
    for _, name in ipairs(module_names) do
        local mod_path = MOD_REQUIRE_PREFIX .. name
        local ok, mod = pcall(require, mod_path)
        if ok and mod then
            modules[name] = mod
            loaded = loaded + 1
            print("[SuperMod] Loaded module: " .. name)
        else
            print("[SuperMod] FAILED to load module: " .. name .. " — " .. tostring(mod))
            failed = failed + 1
        end
    end
    return loaded, failed
end

-- Hot-reload: revert all active mods, clear package cache, re-require
local function hot_reload_modules()
    print("[SuperMod] ══════════════════════════════════════")
    print("[SuperMod] HOT RELOAD triggered")
    print("[SuperMod] ══════════════════════════════════════")

    for mod_name, m in pairs(modules) do
        if mod_statuses[mod_name] and mod_statuses[mod_name].active then
            pcall(function()
                if m.revert then m.revert() end
            end)
            print("[SuperMod] Reverted: " .. mod_name)
        end
    end

    for _, name in ipairs(module_names) do
        local mod_path = MOD_REQUIRE_PREFIX .. name
        package.loaded[mod_path] = nil
    end
    modules = {}

    local loaded, failed = load_modules()
    mod_statuses = {}

    print("[SuperMod] HOT RELOAD complete: " .. loaded .. " loaded, " .. failed .. " failed")
    print("[SuperMod] ══════════════════════════════════════")

    write_json(reload_path .. ".result", {
        success = true,
        loaded = loaded,
        failed = failed,
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    })

    return loaded, failed
end

-- Initial load
local loaded_count, failed_count = load_modules()

local function update_status()
    local status = {
        _meta = {
            version = VERSION,
            reload_count = reload_counter,
            module_count = 0,
            active_count = 0,
        }
    }
    local total = 0
    local active = 0
    for mod_name, mod_id in pairs(mod_id_map) do
        local s = mod_statuses[mod_name] or {}
        status[mod_id] = {
            status = s.active and "active" or (s.error and "error" or "inactive"),
            last_active_ms = s.last_active_ms or 0,
            error = s.error or nil,
        }
        total = total + 1
        if s.active then active = active + 1 end
    end
    status._meta.module_count = total
    status._meta.active_count = active
    write_json(status_path, status)
end

local function apply_config(config)
    if not config then return end

    for mod_name, mod_id in pairs(mod_id_map) do
        local mod_cfg = config[mod_id]
        local m = modules[mod_name]
        if not m then goto continue end

        local enabled = mod_cfg and mod_cfg.enabled
        local cfg_values = (mod_cfg and mod_cfg.config) or {}

        if enabled then
            local ok, result = pcall(function()
                return m.apply(cfg_values)
            end)
            if ok then
                if result == false then
                    mod_statuses[mod_name] = {
                        active = false,
                        error = "No matching game objects on this server",
                    }
                else
                    mod_statuses[mod_name] = {
                        active = true,
                        last_active_ms = math.floor(os.clock() * 1000),
                        error = nil,
                    }
                end
            else
                mod_statuses[mod_name] = {
                    active = false,
                    error = tostring(result),
                }
                print("[SuperMod] ERROR in " .. mod_name .. ": " .. tostring(result))
            end
        else
            if mod_statuses[mod_name] and mod_statuses[mod_name].active then
                pcall(function()
                    if m.revert then m.revert() end
                end)
            end
            mod_statuses[mod_name] = { active = false }
        end

        ::continue::
    end

    update_status()
end

-- One-time diagnostic probe
local function run_probe()
    local lines = {}
    local function log(s)
        lines[#lines+1] = s
        print("[SuperMod:PROBE] " .. s)
    end

    log("═══════════ CLASS SCAN START ═══════════")
    local probe_classes = {
        "R5ShipKinematicMovementParams", "R5ShipMovementReplicatorParams",
        "R5BLInventoryItem", "R5BLInventoryItemDataAsset",
        "R5BLRecipeData", "R5BLLootParams",
        "R5BLProgressionTreeParams", "R5BLSlotCountModifierParams",
        "R5N_WeatherComponent",
        "R5GameplaySpawnerVariantPreset", "R5GameplaySpawner", "R5AISpawner",
        "GameplayEffect", "GameplayModMagnitudeCalculation",
        "R5ShipHealthParams", "R5ShipHealthComponent",
        "R5BLConsumableParams", "R5BLFoodData",
        "R5BLFarmPlotParams", "R5BLCropData",
        "R5BLFishingParams",
        "R5ShipKinematicMovementComponent",
    }
    for _, cls in ipairs(probe_classes) do
        local ok, all = pcall(FindAllOf, cls)
        if ok and all then
            local total = #all
            local with_default = 0
            for _, obj in ipairs(all) do
                if obj:GetFullName():find("Default__") then with_default = with_default + 1 end
            end
            log(cls .. ": " .. total .. " found (" .. with_default .. " have Default__)")
            for i = 1, math.min(3, total) do
                log("  [" .. i .. "] " .. all[i]:GetFullName())
            end
            local first = all[1]
            if first then
                local props_to_try = {}
                if cls == "R5ShipKinematicMovementParams" then
                    props_to_try = {"SpeedKnotsMap", "MaxSpeed", "Speed", "SpeedMultiplier", "BaseSpeed"}
                elseif cls == "R5BLInventoryItem" or cls == "R5BLInventoryItemDataAsset" then
                    props_to_try = {"InventoryItemGppData", "MaxCountInSlot", "Weight", "ItemData"}
                elseif cls == "R5BLRecipeData" then
                    props_to_try = {"CraftingTime", "RecipeIngredients", "RecipeResult", "RecipeName"}
                elseif cls == "R5BLLootParams" then
                    props_to_try = {"LootData", "LootTable", "Drops"}
                elseif cls == "R5BLProgressionTreeParams" then
                    props_to_try = {"Branches", "Nodes", "PointsPerLevel", "SkillPointsPerLevel", "PointsPerLevelUp", "StatPointsPerLevel", "MaxLevel", "LevelCap"}
                elseif cls == "R5BLSlotCountModifierParams" then
                    props_to_try = {"CountSlots", "SlotCount", "Slots"}
                elseif cls == "GameplayEffect" then
                    props_to_try = {"Period", "DurationMagnitude", "DurationPolicy", "Modifiers"}
                elseif cls == "R5ShipKinematicMovementComponent" then
                    props_to_try = {"SpeedKnotsMap", "MaxSpeed", "CurrentSpeed"}
                end
                for _, prop in ipairs(props_to_try) do
                    local pok, pval = pcall(function() return first[prop] end)
                    if pok then
                        log("  ." .. prop .. " = " .. type(pval) .. " " .. tostring(pval))
                    else
                        log("  ." .. prop .. " = ERROR: " .. tostring(pval))
                    end
                end
            end
        else
            log(cls .. ": NOT FOUND")
        end
    end

    -- Deep dive: RecipeIngredients access patterns
    log("")
    log("═══ DEEP: RecipeIngredients access ═══")
    pcall(function()
        local recipes = FindAllOf("R5BLRecipeData")
        if not recipes then log("  No R5BLRecipeData found"); return end
        local tested = 0
        for _, obj in ipairs(recipes) do
            if tested >= 3 then break end
            local name = obj:GetFullName()
            if not name:find("Default__") and (name:find("Buy") or name:find("Build") or name:find("Craft")) then
                tested = tested + 1
                log("  Recipe: " .. name)
                local ing = obj.RecipeIngredients
                log("    type=" .. type(ing) .. " val=" .. tostring(ing))
                local ok1, r1 = pcall(function() return ing:GetArrayNum() end)
                log("    :GetArrayNum() ok=" .. tostring(ok1) .. " val=" .. tostring(r1))
                if ok1 and r1 and r1 > 0 then
                    local ok2, elem = pcall(function() return ing:GetArrayElement(0) end)
                    log("    :GetArrayElement(0) ok=" .. tostring(ok2) .. " type=" .. type(elem))
                    if ok2 and elem then
                        for _, ep in ipairs({"Count","Amount","Item","ItemId","ItemData","Quantity"}) do
                            local okE, rE = pcall(function() return elem[ep] end)
                            if okE and rE ~= nil then log("      ." .. ep .. " = " .. type(rE) .. " " .. tostring(rE)) end
                        end
                    end
                end
            end
        end
    end)

    -- Deep dive: Branches -> Nodes
    log("")
    log("═══ DEEP: ProgressionTree Branches->Nodes ═══")
    pcall(function()
        local trees = FindAllOf("R5BLProgressionTreeParams")
        if not trees then log("  No trees found"); return end
        for idx, obj in ipairs(trees) do
            local name = obj:GetFullName()
            if not name:find("Default__") then
                log("  Tree: " .. name)
                local branches = obj.Branches
                if branches then
                    local okN, numB = pcall(function() return branches:GetArrayNum() end)
                    log("    .Branches:GetArrayNum() ok=" .. tostring(okN) .. " val=" .. tostring(numB))
                    if okN and numB and numB > 0 then
                        local okE, branch = pcall(function() return branches:GetArrayElement(0) end)
                        log("    branch[0] type=" .. type(branch))
                        if okE and branch then
                            for _, bp in ipairs({"Nodes","Name","BranchName","NodeCount","MaxLevel","PointsPerLevel"}) do
                                local okP, rP = pcall(function() return branch[bp] end)
                                if okP and rP ~= nil then
                                    log("      ." .. bp .. " = " .. type(rP) .. " " .. tostring(rP))
                                    if bp == "Nodes" then
                                        local okN2, numN = pcall(function() return rP:GetArrayNum() end)
                                        log("        :GetArrayNum() ok=" .. tostring(okN2) .. " val=" .. tostring(numN))
                                        if okN2 and numN and numN > 0 then
                                            local okNE, node = pcall(function() return rP:GetArrayElement(0) end)
                                            log("        node[0] type=" .. type(node))
                                            if okNE and node then
                                                for _, np in ipairs({"PointsPerLevel","MaxNodeLevel","MaxLevel","NodeName","XPRequired","Cost","NodeType"}) do
                                                    local okNP, rNP = pcall(function() return node[np] end)
                                                    if okNP and rNP ~= nil then
                                                        log("          ." .. np .. " = " .. type(rNP) .. " " .. tostring(rNP))
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                else
                    log("    .Branches = nil")
                end
            end
            if idx >= 2 then break end
        end
    end)

    -- Deep dive: InventoryItemGppData sub-properties
    log("")
    log("═══ DEEP: InventoryItemGppData properties ═══")
    pcall(function()
        local items = FindAllOf("R5BLInventoryItem")
        if not items then log("  No items found"); return end
        local tested = 0
        for _, item in ipairs(items) do
            if tested >= 3 then break end
            local name = item:GetFullName()
            if not name:find("Default__") then
                local gpd = item.InventoryItemGppData
                if gpd then
                    tested = tested + 1
                    log("  Item: " .. name)
                    log("    GppData type=" .. type(gpd))
                    for _, gp in ipairs({"MaxCountInSlot","Weight","MaxDurability","Damage","BaseDamage",
                        "MinDamage","MaxDamage","Armor","BaseArmor","Defense","Protection","Value","Price"}) do
                        local okG, rG = pcall(function() return gpd[gp] end)
                        if okG and rG ~= nil then
                            log("    ." .. gp .. " = " .. type(rG) .. " " .. tostring(rG))
                        end
                    end
                end
            end
        end
    end)

    -- Deep dive: CraftingTime actual type
    log("")
    log("═══ DEEP: CraftingTime type check ═══")
    pcall(function()
        local recipes = FindAllOf("R5BLRecipeData")
        if not recipes then return end
        local tested = 0
        for _, obj in ipairs(recipes) do
            if tested >= 3 then break end
            local fname = obj:GetFullName()
            if not fname:find("Default__") and fname:find("Craft") then
                tested = tested + 1
                log("  " .. fname)
                local ct = obj.CraftingTime
                log("    .CraftingTime type=" .. type(ct) .. " val=" .. tostring(ct))
                if type(ct) == "number" then
                    log("    NUMERIC — direct arithmetic works")
                else
                    local ok1, r1 = pcall(function() return ct:get() end)
                    log("    :get() ok=" .. tostring(ok1) .. " val=" .. tostring(r1))
                    local ok2, r2 = pcall(function() return ct + 0 end)
                    log("    ct+0 ok=" .. tostring(ok2) .. " val=" .. tostring(r2))
                end
            end
        end
    end)

    -- Deep dive: Ship movement component speed values
    log("")
    log("═══ DEEP: Live ship SpeedKnotsMap values ═══")
    pcall(function()
        local comps = FindAllOf("R5ShipKinematicMovementComponent")
        if not comps then log("  No live components"); return end
        for i, comp in ipairs(comps) do
            local name = comp:GetFullName()
            if not name:find("Default__") then
                log("  " .. name)
                local skm = comp.SpeedKnotsMap
                if skm then
                    skm:ForEach(function(kp, vp)
                        log("    gear=" .. tostring(kp:get()) .. " knots=" .. tostring(vp:get()))
                    end)
                else
                    log("    SpeedKnotsMap = nil")
                end
            end
        end
    end)

    log("")
    log("═══════════ CLASS SCAN END ═══════════")

    pcall(function()
        local f = io.open(data_dir .. "\\deep_probe.txt", "w")
        if f then
            f:write(table.concat(lines, "\n"))
            f:close()
            print("[SuperMod:PROBE] Wrote deep_probe.txt (" .. #lines .. " lines)")
        end
    end)
end

-- Main tick loop
print("[SuperMod] v" .. VERSION .. " initializing...")
print("[SuperMod] Config path: " .. config_path)
print("[SuperMod] Status path: " .. status_path)
print("[SuperMod] Reload trigger: " .. reload_path)
print("[SuperMod] Loaded " .. loaded_count .. " modules (" .. failed_count .. " failed)")

local probe_done = false
LoopAsync(3000, function()
    if not probe_done then
        probe_done = true
        pcall(run_probe)
    end
    if file_exists(reload_path) then
        delete_file(reload_path)
        reload_counter = reload_counter + 1
        hot_reload_modules()
        if current_config then
            apply_config(current_config)
        end
        return false
    end

    local config = read_json(config_path)
    if config then
        current_config = config
        apply_config(current_config)
    end
    return false
end)

print("[SuperMod] v" .. VERSION .. " started — polling config every 3s, hot-reload enabled")
