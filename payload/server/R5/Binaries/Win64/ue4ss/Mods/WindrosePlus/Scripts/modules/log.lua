-- WindrosePlus Logging Module
-- Leveled logging with configurable output

local Log = {}
Log._level = 2 -- default: info

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }
local LABELS = { [1] = "DEBUG", [2] = "INFO", [3] = "WARN", [4] = "ERROR" }

function Log.setLevel(level)
    if type(level) == "string" then
        Log._level = LEVELS[level:lower()] or 2
    elseif type(level) == "number" then
        Log._level = level
    end
end

function Log.getLevel()
    return Log._level
end

local function write(level, module, msg)
    if level < Log._level then return end
    local label = LABELS[level] or "?"
    print("[WindrosePlus:" .. module .. "] " .. label .. ": " .. tostring(msg) .. "\n")
end

function Log.debug(module, msg) write(1, module, msg) end
function Log.info(module, msg) write(2, module, msg) end
function Log.warn(module, msg) write(3, module, msg) end
function Log.error(module, msg) write(4, module, msg) end

return Log
