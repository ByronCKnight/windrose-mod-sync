-- QuickDiscard: dragging an item out of the inventory throws it away instead of
-- leaving a loot bag on the ground. Two halves - relabel the button, then destroy the
-- bag the game spawns for the drop.
--
-- Ships PATCHED - see docs/quickdiscard-patch.md. Pristine upstream is vendored at
-- vendor/QuickDiscard-1.0/main.lua.orig.
local VERSION = "1.0 (windrose patch 1)"

local LOGGING = true

-- Turn on to log every text widget whose text contains "drop". This is how you find
-- the real label if the button ever stops being relabelled after a game update.
local DEBUG = false

local function log(fmt, ...)
    if LOGGING then print(("[QuickDiscard] " .. fmt .. "\n"):format(...)) end
end

-- [PATCH: windrose-mod-sync] begin - relabel rewritten
-- Upstream compared a TextBlock's text to exactly "DROP" from one hook, and the button
-- still read "Drop" in game. Three brittle spots: the comparison was exact, so a
-- trailing space or a longer label missed; only UMG TextBlock was scanned; and the scan
-- ran once, not necessarily after the widget existed.

local LABEL_TO = "Delete"

-- Matched against the widget text trimmed and lowercased.
local LABEL_FROM = {
    ["drop"]       = true,
    ["drop item"]  = true,
    ["drop items"] = true,
}

-- Only these two text widget classes exist in this build - the shipping exe has no
-- CommonTextBlock, so there is no CommonUI variant to chase. FindAllOf returns nil for
-- a class the build lacks, hence the pcall.
local TEXT_CLASSES = { "TextBlock", "RichTextBlock" }

-- The label can be built a frame or two after the hook says the inventory changed, so a
-- trigger rescans on a short tail instead of once.
local RESCAN_MS = { 100, 250, 500, 1000, 2000 }

-- Safety net for the case where no inventory hook fires while the button is on screen.
-- One pass costs a couple of milliseconds. Set to 0 to rely on the hook alone.
local SAFETY_NET_MS = 3000

local function trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function textOf(widget)
    local ok, text = pcall(function() return widget:GetText():ToString() end)
    if ok and type(text) == "string" then return text end
    return nil
end

local relabelled = 0

local function relabelDropButtons()
    for _, class in ipairs(TEXT_CLASSES) do
        local ok, widgets = pcall(function() return FindAllOf(class) end)
        for _, widget in ipairs((ok and widgets) or {}) do
            if widget:IsValid() then
                local text = textOf(widget)
                local key = text and trim(text):lower()
                if key then
                    if DEBUG and key:find("drop", 1, true) then
                        log('[debug] a %s reads "%s"', class, text)
                    end
                    if LABEL_FROM[key] and pcall(function() widget:SetText(FText(LABEL_TO)) end) then
                        relabelled = relabelled + 1
                        -- The inventory refreshes constantly; logging every pass would
                        -- bury everything else in the log.
                        if relabelled <= 3 then
                            log('relabelled a %s from "%s" to "%s"', class, trim(text), LABEL_TO)
                        end
                    end
                end
            end
        end
    end
end

-- OnVirtualSlotUpdated fires once per slot, so one refresh arrives as a burst of hooks.
-- Collapse it into a single pass plus its tail, ignoring triggers until that finishes.
local scanPending = false

local function scheduleRelabel()
    if scanPending then return end
    scanPending = true
    ExecuteInGameThread(relabelDropButtons)
    for _, ms in ipairs(RESCAN_MS) do
        ExecuteWithDelay(ms, function() ExecuteInGameThread(relabelDropButtons) end)
    end
    ExecuteWithDelay(RESCAN_MS[#RESCAN_MS] + 100, function() scanPending = false end)
end

RegisterHook("/Script/R5.R5DefaultInventoryVM:OnVirtualSlotUpdated", scheduleRelabel)

if SAFETY_NET_MS > 0 then
    LoopAsync(SAFETY_NET_MS, function()
        ExecuteInGameThread(relabelDropButtons)
        return false
    end)
end
-- [PATCH: windrose-mod-sync] end

-- Unchanged upstream: the drag-out spawns a loot bag, and destroying that bag as it
-- spawns is what turns the drop into a delete.
local IsArmed = false

RegisterHook("/Script/R5.R5DefaultInventoryVM:DropItemsFromDrag", function()
    IsArmed = true
end)

NotifyOnNewObject("/Script/R5.R5LootActor", function(L)
    if IsArmed and L:IsValid() then L:K2_DestroyActor() IsArmed = false end
end)

log("loaded v%s", VERSION)
