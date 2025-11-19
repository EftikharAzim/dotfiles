-- ============================================
-- HAMMERSPOON FFM: Focus Follows Mouse
-- Conservative optimization - preserves original behavior
-- ============================================

-- ============================================
-- CONFIGURATION
-- ============================================
local CONFIG = {
    debounceSeconds = 0.06,
    pollInterval = 0.25,
    debugConsole = true,
}

-- ============================================
-- IMPORTS (aliased for readability)
-- ============================================
local mouse    = hs.mouse
local window   = hs.window
local screen   = hs.screen
local timer    = hs.timer
local eventtap = hs.eventtap
local alert    = hs.alert
local hotkey   = hs.hotkey
local log      = hs.printf

-- ============================================
-- STATE
-- ============================================
local state = {
    enabled = true,
    lastScreen = mouse.absolutePosition() and mouse.getCurrentScreen() or nil,
    focusTimer = nil,
}

-- ============================================
-- UTILITY FUNCTIONS
-- ============================================

-- Safe screen identifier (handles nil)
local function screenId(s)
    return s and (s:id() or tostring(s)) or "nil"
end

-- Check if window is a valid focus candidate
local function isCandidate(w)
    if not w then return false end
    if not w:isVisible() then return false end
    if w:isMinimized() then return false end
    if not w:isStandard() then return false end
    return true
end

-- Point-in-rectangle collision detection
local function pointInRect(pt, rect)
    if not (pt and rect) then return false end
    local x, y = pt.x or pt[1], pt.y or pt[2]
    local rx, ry, rw, rh = rect.x, rect.y, rect.w, rect.h
    if not (x and y and rx and ry and rw and rh) then return false end
    return x >= rx and x <= (rx + rw) and y >= ry and y <= (ry + rh)
end

-- ============================================
-- WINDOW MANAGEMENT
-- ============================================

-- Find topmost window under cursor on given screen
local function windowUnderPointOnScreen(pt, sc)
    if not (pt and sc) then return nil end
    for _, w in ipairs(window.orderedWindows()) do
        if isCandidate(w) and w:screen() == sc then
            local f = w:frame()
            if pointInRect(pt, f) then
                return w
            end
        end
    end
    return nil
end

-- Focus window on screen (try under cursor, else first visible)
local function focusWindowOnScreen(sc)
    if not sc then
        if CONFIG.debugConsole then 
            log("focusWindowOnScreen: no screen") 
        end
        return false
    end

    local pt = mouse.absolutePosition()
    local w = windowUnderPointOnScreen(pt, sc)
    
    if w then
        if CONFIG.debugConsole then 
            log(string.format("Focusing window under cursor: %s (%s)", 
                tostring(w:title()), tostring(w:application():name()))) 
        end
        w:focus()
        return true
    end

    -- Fallback: focus first visible standard window
    for _, w2 in ipairs(window.orderedWindows()) do
        if isCandidate(w2) and w2:screen() == sc then
            if CONFIG.debugConsole then 
                log(string.format("Fallback focus: %s (%s)", 
                    tostring(w2:title()), tostring(w2:application():name()))) 
            end
            w2:focus()
            return true
        end
    end

    if CONFIG.debugConsole then 
        log("No candidate window found on screen " .. screenId(sc)) 
    end
    return false
end

-- Debounced focus with timer
local function scheduleFocus(sc)
    if state.focusTimer then
        state.focusTimer:stop()
        state.focusTimer = nil
    end
    state.focusTimer = timer.doAfter(CONFIG.debounceSeconds, function()
        focusWindowOnScreen(sc)
        state.focusTimer = nil
    end)
end

-- ============================================
-- EVENT WATCHERS
-- ============================================

-- Mouse movement watcher
local mouseWatcher = eventtap.new({ eventtap.event.types.mouseMoved }, function(e)
    if not state.enabled then return false end
    local cur = mouse.getCurrentScreen()
    if cur and state.lastScreen and cur:id() ~= state.lastScreen:id() then
        if CONFIG.debugConsole then 
            log(string.format("Screen change detected (event): %s -> %s", 
                screenId(state.lastScreen), screenId(cur))) 
        end
        state.lastScreen = cur
        scheduleFocus(cur)
    end
    return false
end)

-- Polling fallback (catches edge cases)
local pollTimer = timer.new(CONFIG.pollInterval, function()
    if not state.enabled then return end
    local cur = mouse.getCurrentScreen()
    if cur and state.lastScreen and cur:id() ~= state.lastScreen:id() then
        if CONFIG.debugConsole then 
            log(string.format("Screen change detected (poll): %s -> %s", 
                screenId(state.lastScreen), screenId(cur))) 
        end
        state.lastScreen = cur
        scheduleFocus(cur)
    end
end)

-- ============================================
-- CONTROL
-- ============================================

-- Enable/disable FFM system
local function setEnabled(v)
    state.enabled = v
    if state.enabled then
        mouseWatcher:start()
        pollTimer:start()
        alert.show("FFM → ON")
        if CONFIG.debugConsole then log("FFM enabled") end
    else
        mouseWatcher:stop()
        pollTimer:stop()
        if state.focusTimer then 
            state.focusTimer:stop()
            state.focusTimer = nil 
        end
        alert.show("FFM → OFF")
        if CONFIG.debugConsole then log("FFM disabled") end
    end
end

-- ============================================
-- INITIALIZATION
-- ============================================

-- Start watchers
mouseWatcher:start()
pollTimer:start()
alert.show("FFM (monitor→focus) loaded")
if CONFIG.debugConsole then 
    log("FFM loaded; lastScreen = " .. screenId(state.lastScreen)) 
end

-- ============================================
-- HOTKEYS
-- ============================================

-- Reload config
hotkey.bind({"ctrl", "alt", "cmd"}, "R", function() 
    hs.reload() 
end)

-- Toggle FFM
hotkey.bind({"ctrl", "alt", "cmd"}, "T", function() 
    setEnabled(not state.enabled) 
end)