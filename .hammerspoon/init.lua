-- ============================================
-- HAMMERSPOON FFM: Focus Follows Mouse
-- Optimized for performance, memory efficiency, and battery life
-- ============================================

-- ============================================
-- CONFIGURATION
-- ============================================
local CONFIG = {
    debounceSeconds = 0.06,
    pollInterval = 2.0,              -- Reduced to 2s for battery savings (was 1.0)
    debugConsole = true,
    showAlerts = false,
    maxScreenMemory = 5,             -- Limit focus memory to prevent unbounded growth
    excludeApps = {
        "System Preferences",
        -- "System Settings",
        "Alfred",
        "Raycast",
        "Spotlight",
    }
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
    mouseWatcher = nil,
    pollTimer = nil,
    screenWatcher = nil,
    windowFilter = nil,              -- Single filter instance (reused)
    lastFocusedWindow = {},          -- {[screenId] = window}
}

-- ============================================
-- UTILITY FUNCTIONS
-- ============================================

-- Safe screen identifier (handles nil)
local function screenId(s)
    return s and (s:id() or tostring(s)) or "nil"
end

-- Compare two screens for equality
local function screensEqual(s1, s2)
    if not (s1 and s2) then return false end
    return s1:id() == s2:id()
end

-- Check if app is in exclusion list
local function isExcludedApp(appName)
    if not appName then return false end
    for _, excluded in ipairs(CONFIG.excludeApps) do
        if appName == excluded then return true end
    end
    return false
end

-- Check if window is a valid focus candidate
local function isCandidate(w)
    if not w then return false end
    if not w:isVisible() then return false end
    if w:isMinimized() then return false end
    if not w:isStandard() then return false end
    
    -- Check application blacklist
    local app = w:application()
    if app and isExcludedApp(app:name()) then return false end
    
    return true
end

-- Validate that window still exists and is usable (prevents crashes)
local function isValidWindow(w)
    if not w then return false end
    
    -- pcall prevents crash if window was destroyed
    local success, _ = pcall(function() return w:id() end)
    if not success then return false end
    
    return isCandidate(w)
end

-- Point-in-rectangle collision detection
local function pointInRect(pt, rect)
    if not (pt and rect) then return false end
    local x, y = pt.x or pt[1], pt.y or pt[2]
    local rx, ry, rw, rh = rect.x, rect.y, rect.w, rect.h
    if not (x and y and rx and ry and rw and rh) then return false end
    return x >= rx and x <= (rx + rw) and y >= ry and y <= (ry + rh)
end

-- Remember window with memory cap to prevent unbounded growth
local function rememberWindow(scId, win)
    state.lastFocusedWindow[scId] = win
    
    -- Count entries
    local count = 0
    for _ in pairs(state.lastFocusedWindow) do count = count + 1 end
    
    -- Clean up old screens if limit exceeded
    if count > CONFIG.maxScreenMemory then
        -- Remove one old entry (simple cleanup)
        for k in pairs(state.lastFocusedWindow) do
            if k ~= scId then  -- Don't remove what we just added
                state.lastFocusedWindow[k] = nil
                if CONFIG.debugConsole then
                    log("Cleaned up focus memory for old screen: " .. k)
                end
                break
            end
        end
    end
end

-- ============================================
-- WINDOW MANAGEMENT
-- ============================================

-- Get valid windows on screen (using cached window filter)
local function getValidWindowsOnScreen(sc)
    if not sc then return {} end
    local validWindows = {}
    
    -- Use window filter if available, fallback to orderedWindows
    local windows = state.windowFilter and state.windowFilter:getWindows() or window.orderedWindows()
    
    for _, w in ipairs(windows) do
        if isCandidate(w) and w:screen() == sc then
            table.insert(validWindows, w)
        end
    end
    
    return validWindows
end

-- Find topmost window under cursor on given screen
local function windowUnderPointOnScreen(pt, sc)
    if not (pt and sc) then return nil end
    
    local validWindows = getValidWindowsOnScreen(sc)
    
    for _, w in ipairs(validWindows) do
        local f = w:frame()
        if pointInRect(pt, f) then
            return w
        end
    end
    
    return nil
end

-- Focus window on screen (with per-screen focus memory and fullscreen protection)
local function focusWindowOnScreen(sc)
    if not sc then
        if CONFIG.debugConsole then 
            log("focusWindowOnScreen: no screen") 
        end
        return false
    end

    -- Don't steal focus from fullscreen windows
    local currentWin = window.focusedWindow()
    if currentWin and currentWin:isFullScreen() and currentWin:screen() == sc then
        if CONFIG.debugConsole then 
            log("Skipping focus - fullscreen window is active on this screen") 
        end
        return false
    end

    local scId = screenId(sc)
    local pt = mouse.absolutePosition()
    
    -- PRIORITY 1: Try to restore last focused window on this screen
    local lastWin = state.lastFocusedWindow[scId]
    if lastWin and isValidWindow(lastWin) and lastWin:screen() == sc then
        if CONFIG.debugConsole then 
            log(string.format("Restoring last focused window: %s (%s)", 
                tostring(lastWin:title()), tostring(lastWin:application():name()))) 
        end
        if CONFIG.showAlerts then
            alert.show("↻ " .. lastWin:application():name(), 0.5)
        end
        lastWin:focus()
        return true
    elseif lastWin then
        -- Clean up stale reference
        state.lastFocusedWindow[scId] = nil
        if CONFIG.debugConsole then
            log("Cleared stale window reference for screen " .. scId)
        end
    end
    
    -- PRIORITY 2: Find window under cursor
    local w = windowUnderPointOnScreen(pt, sc)
    if w then
        if CONFIG.debugConsole then 
            log(string.format("Focusing window under cursor: %s (%s)", 
                tostring(w:title()), tostring(w:application():name()))) 
        end
        if CONFIG.showAlerts then
            alert.show(w:application():name(), 0.5)
        end
        w:focus()
        rememberWindow(scId, w)
        return true
    end

    -- PRIORITY 3: Fallback to first visible window
    local validWindows = getValidWindowsOnScreen(sc)
    if #validWindows > 0 then
        local w2 = validWindows[1]
        if CONFIG.debugConsole then 
            log(string.format("Fallback focus: %s (%s)", 
                tostring(w2:title()), tostring(w2:application():name()))) 
        end
        if CONFIG.showAlerts then
            alert.show(w2:application():name(), 0.5)
        end
        w2:focus()
        rememberWindow(scId, w2)
        return true
    end

    if CONFIG.debugConsole then 
        log("No candidate window found on screen " .. scId) 
    end
    return false
end

-- Debounced focus with timer
local function scheduleFocus(sc)
    if state.focusTimer then
        state.focusTimer:stop()
    end
    
    state.focusTimer = timer.doAfter(CONFIG.debounceSeconds, function()
        if state.enabled then
            focusWindowOnScreen(sc)
        end
        state.focusTimer = nil
    end)
end

-- Handle screen change
local function handleScreenChange(cur, source)
    if cur and not screensEqual(cur, state.lastScreen) then
        if CONFIG.debugConsole then 
            log(string.format("Screen change detected (%s): %s -> %s", 
                source, screenId(state.lastScreen), screenId(cur))) 
        end
        state.lastScreen = cur
        scheduleFocus(cur)
    end
end

-- ============================================
-- EVENT WATCHERS
-- ============================================

-- Create mouse movement watcher
local function createMouseWatcher()
    return eventtap.new({ 
        eventtap.event.types.mouseMoved,
        eventtap.event.types.leftMouseDragged,
        eventtap.event.types.rightMouseDragged
    }, function(e)
        if not state.enabled then return false end
        local cur = mouse.getCurrentScreen()
        handleScreenChange(cur, "event")
        return false
    end)
end

-- Create polling fallback timer
local function createPollTimer()
    return timer.new(CONFIG.pollInterval, function()
        if not state.enabled then return end
        local cur = mouse.getCurrentScreen()
        handleScreenChange(cur, "poll")
    end)
end

-- Create screen configuration watcher
local function createScreenWatcher()
    return screen.watcher.new(function()
        if CONFIG.debugConsole then 
            log("Screen configuration changed (wake/sleep/connect/disconnect)") 
        end
        state.lastScreen = mouse.getCurrentScreen()
        if state.lastScreen then
            scheduleFocus(state.lastScreen)
        end
    end)
end

-- Subscribe to window focus events (reuses windowFilter)
local function subscribeToWindowFocus()
    if state.windowFilter then
        state.windowFilter:subscribe(window.filter.windowFocused, function(win)
            if not win then return end
            local sc = win:screen()
            if sc then
                local scId = screenId(sc)
                rememberWindow(scId, win)
                if CONFIG.debugConsole then
                    log(string.format("Tracked focus: %s on screen %s", 
                        tostring(win:application():name()), scId))
                end
            end
        end)
    end
end

-- ============================================
-- LIFECYCLE MANAGEMENT
-- ============================================

-- Cleanup all watchers and timers
local function cleanup()
    if state.mouseWatcher then 
        state.mouseWatcher:stop() 
        state.mouseWatcher = nil
    end
    if state.pollTimer then 
        state.pollTimer:stop() 
        state.pollTimer = nil
    end
    if state.screenWatcher then 
        state.screenWatcher:stop() 
        state.screenWatcher = nil
    end
    if state.windowFilter then
        state.windowFilter:unsubscribeAll()
        state.windowFilter = nil
    end
    if state.focusTimer then 
        state.focusTimer:stop() 
        state.focusTimer = nil
    end
    
    -- Clear focus memory to free memory
    state.lastFocusedWindow = {}
    
    if CONFIG.debugConsole then 
        log("FFM cleanup complete") 
    end
end

-- Initialize all watchers
local function initialize()
    -- Create single window filter instance (memory efficient)
    state.windowFilter = window.filter.new()
    
    -- Subscribe to window focus events
    subscribeToWindowFocus()
    
    -- Create and start watchers
    state.mouseWatcher = createMouseWatcher()
    state.pollTimer = createPollTimer()
    state.screenWatcher = createScreenWatcher()
    
    state.mouseWatcher:start()
    state.pollTimer:start()
    state.screenWatcher:start()
    
    alert.show("FFM (monitor→focus) loaded", 1)
    if CONFIG.debugConsole then 
        log("FFM initialized; lastScreen = " .. screenId(state.lastScreen)) 
    end
end

-- ============================================
-- CONTROL
-- ============================================

-- Enable/disable FFM system
local function setEnabled(v)
    state.enabled = v
    if state.enabled then
        if state.mouseWatcher then state.mouseWatcher:start() end
        if state.pollTimer then state.pollTimer:start() end
        if state.screenWatcher then state.screenWatcher:start() end
        alert.show("FFM → ON", 1)
        if CONFIG.debugConsole then log("FFM enabled") end
    else
        if state.mouseWatcher then state.mouseWatcher:stop() end
        if state.pollTimer then state.pollTimer:stop() end
        if state.screenWatcher then state.screenWatcher:stop() end
        if state.focusTimer then 
            state.focusTimer:stop()
            state.focusTimer = nil 
        end
        alert.show("FFM → OFF", 1)
        if CONFIG.debugConsole then log("FFM disabled") end
    end
end

-- ============================================
-- INITIALIZATION
-- ============================================

initialize()

-- ============================================
-- HOTKEYS
-- ============================================

-- Reload config (with cleanup)
hotkey.bind({"ctrl", "alt", "cmd"}, "R", function() 
    cleanup()
    hs.reload() 
end)

-- Toggle FFM
hotkey.bind({"ctrl", "alt", "cmd"}, "T", function() 
    setEnabled(not state.enabled) 
end)

-- Debug: Show current state
hotkey.bind({"ctrl", "alt", "cmd"}, "D", function()
    local cur = mouse.getCurrentScreen()
    local memCount = 0
    for _ in pairs(state.lastFocusedWindow) do memCount = memCount + 1 end
    
    local msg = string.format(
        "FFM State:\nEnabled: %s\nCurrent Screen: %s\nLast Screen: %s\nMemory: %d screens",
        tostring(state.enabled),
        screenId(cur),
        screenId(state.lastScreen),
        memCount
    )
    alert.show(msg, 3)
    log(msg)
end)

-- Clear focus memory (useful for debugging)
hotkey.bind({"ctrl", "alt", "cmd"}, "C", function()
    state.lastFocusedWindow = {}
    alert.show("Focus memory cleared", 1)
    if CONFIG.debugConsole then
        log("Focus memory cleared")
    end
end)