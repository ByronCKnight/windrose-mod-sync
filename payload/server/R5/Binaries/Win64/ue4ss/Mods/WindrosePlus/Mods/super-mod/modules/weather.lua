-- Weather Control — set server weather via R5N_WeatherComponent.CheatWeatherID
local M = {}
local last_weather_id = nil

function M.apply(cfg)
    local id = tonumber(cfg.weather_id) or 13
    if id == last_weather_id then return end

    local all = FindAllOf("R5N_WeatherComponent")
    if not all then
        print("[SuperMod:Weather] FindAllOf('R5N_WeatherComponent') returned nil — no instances found")
        return false
    end
    print("[SuperMod:Weather] Found " .. #all .. " weather component(s)")
    for _, comp in ipairs(all) do
        local name = comp:GetFullName()
        print("[SuperMod:Weather]   " .. name)
        if not name:find("Default__") then
            comp.CheatWeatherID = id
        end
    end
    last_weather_id = id
    print("[SuperMod:Weather] Set weather to ID " .. id)
end

function M.revert()
    last_weather_id = nil
    local all = FindAllOf("R5N_WeatherComponent")
    if not all then return end
    for _, comp in ipairs(all) do
        if not comp:GetFullName():find("Default__") then
            comp.CheatWeatherID = 13
        end
    end
    print("[SuperMod:Weather] Reverted to default weather cycle")
end

return M
