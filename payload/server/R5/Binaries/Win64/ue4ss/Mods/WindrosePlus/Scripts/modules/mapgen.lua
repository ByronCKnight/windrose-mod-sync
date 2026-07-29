-- WindrosePlus Map Generator Module
-- Reads terrain data from UE Landscape components to build a map
--
-- Architecture: Windrose uses UE5 Landscape system with 52 Landscape actors
-- composed of 1,256 LandscapeComponents. The in-game M-menu map is a real-time
-- SceneCapture2D rendering the terrain from above — we can't do that server-side
-- (Null RHI), so we read component positions and properties to reconstruct a map.
--
-- Run wp.mapgen on first boot (before any hot-reload) to capture terrain data.
-- After RestartMod, FindAllOf("Landscape") returns nil due to UE4SS cache issues.

local json = require("modules.json")
local Log = require("modules.log")

local MapGen = {}
MapGen._gameDir = nil
MapGen._config = nil
MapGen._isRunning = false

function MapGen.init(gameDir, config)
    MapGen._gameDir = gameDir
    MapGen._config = config
    Log.info("MapGen", "Map generator ready")
end

-- Probe all readable properties on a UObject
local function probeProps(obj, propNames)
    local results = {}
    for _, prop in ipairs(propNames) do
        local ok, val = pcall(function() return obj[prop] end)
        if ok and val ~= nil then
            local display = tostring(val)
            pcall(function()
                local s = val:ToString()
                if s and s ~= "" then display = s end
            end)
            local num = tonumber(display)
            if num then display = tostring(num) end
            if not display:match("^UObject:") and not display:match("^userdata:") then
                results[prop] = display
            else
                results[prop] = "[object]"
            end
        end
    end
    return results
end

-- Landscape-specific properties to probe
local LANDSCAPE_PROPS = {
    "SectionBaseX", "SectionBaseY", "ComponentSizeQuads", "SubsectionSizeQuads",
    "NumSubsections", "CollisionSizeQuads", "CollisionScale",
    "HeightfieldRowsCount", "HeightfieldColumnsCount",
    "SimpleCollisionSizeQuads", "ComponentSizeVerts",
    "RelativeLocation", "RelativeRotation", "RelativeScale3D",
    "HeightmapTexture", "XYOffsetmapTexture",
    "WeightmapTextures", "WeightmapLayerAllocations",
    "LODBias", "CollisionMipLevel", "ForcedLOD",
    "bUsedForNavigation", "bIncludeHoles",
    "MaterialInstance", "OverrideMaterial",
    "StaticLightingResolution",
}

function MapGen.generate()
    if MapGen._isRunning then
        return "error", "Map generation already in progress"
    end
    MapGen._isRunning = true
    Log.info("MapGen", "Starting terrain data capture...")

    local result = {}

    -- Step 1: Capture all Landscape actor positions (island chunks)
    local landscapes = FindAllOf("Landscape")
    if not landscapes then
        MapGen._isRunning = false
        return "ok", "No Landscape actors found — run wp.mapgen on a fresh server boot (before any mod hot-reload)"
    end

    result.landscape_count = 0
    result.landscapes = {}
    for i, land in ipairs(landscapes) do
        if land:IsValid() then
            result.landscape_count = result.landscape_count + 1
            local entry = { index = i, fullname = "" }
            pcall(function() entry.fullname = land:GetFullName() end)

            -- Position from RootComponent
            pcall(function()
                local root = land.RootComponent
                if root and root:IsValid() then
                    local rel = root.RelativeLocation
                    if rel then
                        entry.x = math.floor(rel.X)
                        entry.y = math.floor(rel.Y)
                        entry.z = math.floor(rel.Z)
                    end
                    local scale = root.RelativeScale3D
                    if scale then
                        entry.scale_x = tonumber(tostring(scale.X))
                        entry.scale_y = tonumber(tostring(scale.Y))
                        entry.scale_z = tonumber(tostring(scale.Z))
                    end
                end
            end)

            table.insert(result.landscapes, entry)
        end
    end
    Log.info("MapGen", "Captured " .. result.landscape_count .. " Landscape actors")

    -- Step 2: Capture LandscapeComponent data (terrain grid sections)
    local lcomps = FindAllOf("LandscapeComponent")
    result.component_count = 0
    result.components = {}
    result.component_props_sample = nil

    if lcomps then
        for ci, lc in ipairs(lcomps) do
            if lc:IsValid() then
                result.component_count = result.component_count + 1
                local entry = {}

                -- Position
                pcall(function()
                    local rel = lc.RelativeLocation
                    if rel then
                        entry.x = math.floor(rel.X)
                        entry.y = math.floor(rel.Y)
                        entry.z = math.floor(rel.Z)
                    end
                end)

                -- Section base (grid coordinates)
                pcall(function()
                    local sbx = lc.SectionBaseX
                    if sbx then entry.section_x = tonumber(tostring(sbx)) end
                end)
                pcall(function()
                    local sby = lc.SectionBaseY
                    if sby then entry.section_y = tonumber(tostring(sby)) end
                end)

                -- Component size
                pcall(function()
                    local csq = lc.ComponentSizeQuads
                    if csq then entry.size_quads = tonumber(tostring(csq)) end
                end)

                -- Full property probe on first component only
                if ci == 1 then
                    result.component_props_sample = probeProps(lc, LANDSCAPE_PROPS)
                end

                table.insert(result.components, entry)
            end
        end
    end
    Log.info("MapGen", "Captured " .. result.component_count .. " LandscapeComponents")

    -- Step 3: Capture LandscapeHeightfieldCollisionComponent data
    local hfcomps = FindAllOf("LandscapeHeightfieldCollisionComponent")
    result.heightfield_count = 0
    result.heightfield_props_sample = nil

    if hfcomps then
        for hi, hf in ipairs(hfcomps) do
            if hf:IsValid() then
                result.heightfield_count = result.heightfield_count + 1
                -- Full probe on first heightfield component only
                if hi == 1 then
                    result.heightfield_props_sample = probeProps(hf, LANDSCAPE_PROPS)
                    -- Also try heightfield-specific props
                    local hfProps = probeProps(hf, {
                        "CollisionHeightData", "DominantLayerData", "HeightData",
                        "CookedPhysicalMaterials", "bHeightFieldDataHasHole",
                        "RenderComponent", "HeightfieldRef", "MeshRef",
                        "SectionBaseX", "SectionBaseY", "CollisionSizeQuads",
                        "SimpleCollisionSizeQuads", "CollisionScale",
                    })
                    for k, v in pairs(hfProps) do
                        result.heightfield_props_sample[k] = v
                    end
                end
            end
        end
    end
    Log.info("MapGen", "Captured " .. result.heightfield_count .. " HeightfieldCollisionComponents")

    -- Step 4: Check for map-related UObjects
    local mapTypes = {
        "R5MapSubsystem", "R5MapSettings", "R5MapWidget", "R5FullscreenMapWidget",
        "R5MinimapWidget", "R5TerrainSubsystem", "R5IslandSubsystem",
        "R5ArchipelagoSettings", "R5TerrainSettings", "R5BiomeSettings",
        "SceneCaptureComponent2D", "R5MapCapture",
    }
    result.map_objects = {}
    for _, typeName in ipairs(mapTypes) do
        local objs = FindAllOf(typeName)
        if objs then
            local count = 0
            local firstName = ""
            for _, obj in ipairs(objs) do
                if obj:IsValid() then
                    count = count + 1
                    if count == 1 then pcall(function() firstName = obj:GetFullName() end) end
                end
            end
            if count > 0 then
                result.map_objects[typeName] = { count = count, first = firstName }
            end
        end
    end

    -- Write results
    result.timestamp = os.time()
    result.version = 2

    -- Guard against JSON serialization issues
    local dataDir = MapGen._gameDir .. "windrose_plus_data"
    local mapPath = dataDir .. "\\terrain_probe.json"
    local tmpPath = mapPath .. ".tmp"

    local file = io.open(tmpPath, "w")
    if file then
        file:write(json.encode(result))
        file:close()
        os.remove(mapPath)
        os.rename(tmpPath, mapPath)
        Log.info("MapGen", "Terrain data saved to terrain_probe.json")
    else
        Log.error("MapGen", "Failed to write terrain data")
    end

    MapGen._isRunning = false

    -- Build summary
    local summary = "Terrain capture complete:\n"
    summary = summary .. "  Landscapes: " .. result.landscape_count .. "\n"
    summary = summary .. "  Components: " .. result.component_count .. "\n"
    summary = summary .. "  Heightfields: " .. result.heightfield_count .. "\n"

    if result.component_props_sample then
        summary = summary .. "  Component sample props:\n"
        for k, v in pairs(result.component_props_sample) do
            summary = summary .. "    " .. k .. " = " .. tostring(v) .. "\n"
        end
    end

    if result.heightfield_props_sample then
        summary = summary .. "  Heightfield sample props:\n"
        for k, v in pairs(result.heightfield_props_sample) do
            summary = summary .. "    " .. k .. " = " .. tostring(v) .. "\n"
        end
    end

    for typeName, info in pairs(result.map_objects) do
        summary = summary .. "  " .. typeName .. ": " .. info.count .. " (" .. info.first:sub(1,60) .. ")\n"
    end

    return "ok", summary
end

return MapGen
