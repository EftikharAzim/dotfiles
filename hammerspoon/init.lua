-- ============================================
-- HAMMERSPOON FFM: Focus Follows Mouse
-- Optimized for performance, memory efficiency, and battery life
--
-- Hotkeys (see CONFIG.hotkeys):
--   ⌃⌥⌘ R  reload config      ⌃⌥⌘ T  toggle FFM on/off
--   ⌃⌥⌘ D  show debug state   ⌃⌥⌘ C  clear focus memory
-- Set CONFIG.debugConsole = true for verbose logging in the Hammerspoon console.
-- Requires Hammerspoon to have Accessibility permission
-- (System Settings → Privacy & Security → Accessibility).
--
-- Known limitations:
--   * Apps that disable their Accessibility API expose no AX window and
--     therefore cannot be focused by any window manager (e.g. Claude for
--     Desktop, bundle com.anthropic.claudefordesktop). This is an app-side
--     limitation, not a config bug. CLIs run inside a terminal focus fine.
--   * With "Displays have separate Spaces" enabled, windows on a non-active
--     Space may not be enumerated by hs.window.filter and so won't be picked.
-- ============================================

-- ============================================
-- CONFIGURATION
-- ============================================
local CONFIG = {
    debounceSeconds = 0.06,
    pollInterval = 2.0,              -- Reduced to 2s for battery savings (was 1.0)
    debugConsole = false,            -- Set to true for troubleshooting
    showAlerts = false,
    maxScreenMemory = 5,             -- Limit focus memory to prevent unbounded growth
    dragDebounceSeconds = 0.3,       -- Wait after drag before focusing
    dragEndDetectSeconds = 0.1,      -- Settle time after mouse-up before treating drag as ended
    clickCooldownSeconds = 0.4,      -- Ignore FFM briefly after mouse click
    mouseMoveThreshold = 8,          -- Min pixels of motion before a move is processed (throttle)
    persistEnabled = true,           -- Remember on/off state across reloads (hs.settings)

    -- Alert durations (seconds)
    alertShort = 0.5,
    alertNormal = 1.0,
    alertLong = 3.0,

    -- Hotkeys
    hotkeys = {
        mods        = {"ctrl", "alt", "cmd"},
        reload      = "R",
        toggle      = "T",
        debug       = "D",
        clearMemory = "C",
    },

    excludeApps = {
        "System Preferences",        -- pre-Ventura name
        "Alfred",
        "Raycast",
        "Spotlight",
        "Notification Center",
        "Control Center",
    }
}

local SETTINGS_KEY = "ffm.enabled"

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

-- Load IPC so the `hs` command-line tool can introspect this instance,
-- e.g. `hs -c "hs.accessibilityState()"`. Wrapped in pcall so a missing
-- module never breaks config loading.
pcall(require, "hs.ipc")

-- Safe logger: hs.printf treats arg #1 as a format string, so a value
-- containing a literal '%' would error/garble. Always format as a plain string.
local function log(s)
    hs.printf("%s", tostring(s))
end

-- ============================================
-- STATE
-- ============================================
local state = {
    -- Restore persisted on/off state; default ON when nothing stored.
    enabled = (not CONFIG.persistEnabled) or (hs.settings.get(SETTINGS_KEY) ~= false),
    lastScreen = mouse.absolutePosition() and mouse.getCurrentScreen() or nil,
    lastMousePos = nil,              -- For move throttling
    focusTimer = nil,
    mouseWatcher = nil,
    pollTimer = nil,
    screenWatcher = nil,
    windowFilter = nil,              -- Single filter instance (reused)
    lastFocusedWindow = {},          -- {[screenId] = window}
    isDragging = false,              -- Track if currently dragging
    dragEndTimer = nil,              -- Timer for drag end detection
    lastClickTime = 0,               -- Track last click for cooldown
}

-- ============================================
-- UTILITY FUNCTIONS
-- ============================================

-- Safe screen identifier (handles nil)
local function screenId(s)
    return s and (s:id() or tostring(s)) or "nil"
end

-- Compare two screens for equality (do NOT rely on `==` for hs.screen)
local function screensEqual(s1, s2)
    if not (s1 and s2) then return false end
    return s1:id() == s2:id()
end

-- Safe application name for a window (application() can be nil)
local function appName(w)
    if not w then return "?" end
    local app = w:application()
    return (app and app:name()) or "?"
end

-- Check if app is in exclusion list
local function isExcludedApp(name)
    if not name then return false end
    for _, excluded in ipairs(CONFIG.excludeApps) do
        if name == excluded then return true end
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
        if isCandidate(w) and screensEqual(w:screen(), sc) then
            table.insert(validWindows, w)
        end
    end

    return validWindows
end

-- Find topmost window under cursor on given screen
local function windowUnderPointOnScreen(pt, sc, candidates)
    if not (pt and sc) then return nil end

    local validWindows = candidates or getValidWindowsOnScreen(sc)

    for _, w in ipairs(validWindows) do
        local f = w:frame()
        if pointInRect(pt, f) then
            return w
        end
    end

    return nil
end

-- Focus window on screen (with per-screen focus memory and fullscreen protection)
local function focusWindowOnScreen(sc, prioritizeCursor)
    if not sc then
        if CONFIG.debugConsole then
            log("focusWindowOnScreen: no screen")
        end
        return false
    end

    -- Don't steal focus from fullscreen windows
    local currentWin = window.focusedWindow()
    if currentWin and currentWin:isFullScreen() and screensEqual(currentWin:screen(), sc) then
        if CONFIG.debugConsole then
            log("Skipping focus - fullscreen window is active on this screen")
        end
        return false
    end

    local scId = screenId(sc)
    local pt = mouse.absolutePosition()

    -- Compute candidate list once and reuse across the priority checks below.
    local validWindows = getValidWindowsOnScreen(sc)

    -- PRIORITY 1: If prioritizing cursor (e.g., after drag), focus window under cursor first
    if prioritizeCursor then
        local w = windowUnderPointOnScreen(pt, sc, validWindows)
        if w then
            if CONFIG.debugConsole then
                log(string.format("Focusing dragged window under cursor: %s (%s)",
                    tostring(w:title()), appName(w)))
            end
            if CONFIG.showAlerts then
                alert.show("🎯 " .. appName(w), CONFIG.alertShort)
            end
            -- Raise window first to preserve z-order, then focus
            w:raise()
            w:focus()
            rememberWindow(scId, w)
            return true
        end
    end

    -- PRIORITY 2: Try to restore last focused window on this screen
    local lastWin = state.lastFocusedWindow[scId]
    if lastWin and isValidWindow(lastWin) and screensEqual(lastWin:screen(), sc) then
        if CONFIG.debugConsole then
            log(string.format("Restoring last focused window: %s (%s)",
                tostring(lastWin:title()), appName(lastWin)))
        end
        if CONFIG.showAlerts then
            alert.show("↻ " .. appName(lastWin), CONFIG.alertShort)
        end
        -- Raise window first to preserve z-order, then focus
        lastWin:raise()
        lastWin:focus()
        return true
    elseif lastWin then
        -- Clean up stale reference
        state.lastFocusedWindow[scId] = nil
        if CONFIG.debugConsole then
            log("Cleared stale window reference for screen " .. scId)
        end
    end

    -- PRIORITY 3: Find window under cursor
    local w = windowUnderPointOnScreen(pt, sc, validWindows)
    if w then
        if CONFIG.debugConsole then
            log(string.format("Focusing window under cursor: %s (%s)",
                tostring(w:title()), appName(w)))
        end
        if CONFIG.showAlerts then
            alert.show(appName(w), CONFIG.alertShort)
        end
        -- Raise window first to preserve z-order, then focus
        w:raise()
        w:focus()
        rememberWindow(scId, w)
        return true
    end

    -- PRIORITY 4: Fallback to first visible window
    if #validWindows > 0 then
        local w2 = validWindows[1]
        if CONFIG.debugConsole then
            log(string.format("Fallback focus: %s (%s)",
                tostring(w2:title()), appName(w2)))
        end
        if CONFIG.showAlerts then
            alert.show(appName(w2), CONFIG.alertShort)
        end
        -- Raise window first to preserve z-order, then focus
        w2:raise()
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
local function scheduleFocus(sc, prioritizeCursor)
    if state.focusTimer then
        state.focusTimer:stop()
    end

    state.focusTimer = timer.doAfter(CONFIG.debounceSeconds, function()
        if state.enabled then
            focusWindowOnScreen(sc, prioritizeCursor)
        end
        state.focusTimer = nil
    end)
end

-- Handle plain mouse-move screen change (respects click cooldown)
local function handleScreenChange(cur, source)
    -- Skip if recent click (user is intentionally clicking)
    local now = timer.secondsSinceEpoch()
    if (now - state.lastClickTime) < CONFIG.clickCooldownSeconds then
        if CONFIG.debugConsole then
            log("Skipping FFM - click cooldown active")
        end
        return
    end

    if cur and not screensEqual(cur, state.lastScreen) then
        if CONFIG.debugConsole then
            log(string.format("Screen change detected (%s): %s -> %s",
                source, screenId(state.lastScreen), screenId(cur)))
        end
        state.lastScreen = cur
        scheduleFocus(cur, false)
    end
end

-- Handle drag movement: always flag dragging, defer focus to drag end.
-- Not subject to the click cooldown, because a drag legitimately starts
-- with a mouse-down (so its lastClickTime would otherwise swallow it).
local function handleDrag(cur)
    state.isDragging = true
    if cur and not screensEqual(cur, state.lastScreen) then
        if CONFIG.debugConsole then
            log(string.format("Drag screen change: %s -> %s",
                screenId(state.lastScreen), screenId(cur)))
        end
        state.lastScreen = cur
    end
end

-- Handle drag end
local function onDragEnd()
    if state.isDragging then
        if CONFIG.debugConsole then
            log("Drag ended, focusing window under cursor")
        end

        state.isDragging = false
        local cur = mouse.getCurrentScreen()

        -- Use longer debounce for drag to let window settle
        if state.focusTimer then
            state.focusTimer:stop()
        end

        state.focusTimer = timer.doAfter(CONFIG.dragDebounceSeconds, function()
            if state.enabled then
                -- Prioritize cursor (the dragged window)
                focusWindowOnScreen(cur, true)
            end
            state.focusTimer = nil
        end)
    end
end

-- ============================================
-- EVENT WATCHERS
-- ============================================

-- Create mouse movement watcher
local function createMouseWatcher()
    local types = eventtap.event.types
    local moveThresholdSq = CONFIG.mouseMoveThreshold * CONFIG.mouseMoveThreshold

    return eventtap.new({
        types.mouseMoved,
        types.leftMouseDown,  -- Track clicks for cooldown
        types.leftMouseDragged,
        types.rightMouseDragged,
        types.leftMouseUp,
        types.rightMouseUp
    }, function(e)
        if not state.enabled then return false end

        local eventType = e:getType()

        -- Track click time for cooldown
        if eventType == types.leftMouseDown then
            state.lastClickTime = timer.secondsSinceEpoch()
            return false  -- Don't block the click

        -- Detect drag events
        elseif eventType == types.leftMouseDragged or
               eventType == types.rightMouseDragged then
            handleDrag(mouse.getCurrentScreen())

        -- Detect drag end
        elseif eventType == types.leftMouseUp or
               eventType == types.rightMouseUp then
            if state.dragEndTimer then
                state.dragEndTimer:stop()
            end
            state.dragEndTimer = timer.doAfter(CONFIG.dragEndDetectSeconds, function()
                onDragEnd()
                state.dragEndTimer = nil
            end)

        -- Normal mouse movement (throttled to reduce CPU/battery)
        else
            local pos = mouse.absolutePosition()
            if state.lastMousePos then
                local dx = pos.x - state.lastMousePos.x
                local dy = pos.y - state.lastMousePos.y
                if (dx * dx + dy * dy) < moveThresholdSq then
                    return false  -- Movement too small; skip the expensive work
                end
            end
            state.lastMousePos = pos
            handleScreenChange(mouse.getCurrentScreen(), "event")
        end

        return false
    end)
end

-- Create polling fallback timer
local function createPollTimer()
    return timer.new(CONFIG.pollInterval, function()
        if not state.enabled then return end
        if state.isDragging then return end  -- Skip during drag
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
            scheduleFocus(state.lastScreen, false)
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
                        appName(win), scId))
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
    if state.dragEndTimer then
        state.dragEndTimer:stop()
        state.dragEndTimer = nil
    end

    -- Clear focus memory to free memory
    state.lastFocusedWindow = {}
    state.isDragging = false

    if CONFIG.debugConsole then
        log("FFM cleanup complete")
    end
end

-- Initialize all watchers
local function initialize()
    -- Accessibility is REQUIRED for eventtaps and for window:focus()/raise().
    -- Without it, FFM can still detect screen changes but silently fails to
    -- focus anything — so check up front and guide the user to fix it.
    if not hs.accessibilityState() then
        alert.show("⚠️ FFM needs Accessibility permission.\n" ..
                   "System Settings → Privacy & Security → Accessibility →\n" ..
                   "enable Hammerspoon, then reload (⌃⌥⌘R).", CONFIG.alertLong)
        hs.accessibilityState(true)  -- prompt + open the System Settings pane
        log("FFM init aborted: Accessibility permission not granted")
        return
    end

    -- Create single window filter instance (memory efficient)
    state.windowFilter = window.filter.new()

    -- Subscribe to window focus events
    subscribeToWindowFocus()

    -- Create and start watchers
    state.mouseWatcher = createMouseWatcher()
    state.pollTimer = createPollTimer()
    state.screenWatcher = createScreenWatcher()

    -- Secondary guard: eventtap.new can return nil in rare cases
    if not state.mouseWatcher then
        alert.show("⚠️ FFM: failed to create mouse watcher.", CONFIG.alertLong)
        log("FFM init failed: eventtap.new returned nil")
        return
    end

    state.mouseWatcher:start()
    if state.pollTimer then state.pollTimer:start() end
    if state.screenWatcher then state.screenWatcher:start() end

    alert.show("FFM (monitor→focus) loaded", CONFIG.alertNormal)
    if CONFIG.debugConsole then
        log("FFM initialized; lastScreen = " .. screenId(state.lastScreen)
            .. ", enabled = " .. tostring(state.enabled))
    end
end

-- ============================================
-- CONTROL
-- ============================================

-- Enable/disable FFM system
local function setEnabled(v)
    state.enabled = v
    if CONFIG.persistEnabled then
        hs.settings.set(SETTINGS_KEY, v)
    end

    if state.enabled then
        if state.mouseWatcher then state.mouseWatcher:start() end
        if state.pollTimer then state.pollTimer:start() end
        if state.screenWatcher then state.screenWatcher:start() end
        alert.show("FFM → ON", CONFIG.alertNormal)
        if CONFIG.debugConsole then log("FFM enabled") end
    else
        if state.mouseWatcher then state.mouseWatcher:stop() end
        if state.pollTimer then state.pollTimer:stop() end
        if state.screenWatcher then state.screenWatcher:stop() end
        if state.focusTimer then
            state.focusTimer:stop()
            state.focusTimer = nil
        end
        if state.dragEndTimer then
            state.dragEndTimer:stop()
            state.dragEndTimer = nil
        end
        state.isDragging = false
        alert.show("FFM → OFF", CONFIG.alertNormal)
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
local HK = CONFIG.hotkeys

-- Reload config (with cleanup)
hotkey.bind(HK.mods, HK.reload, function()
    cleanup()
    hs.reload()
end)

-- Toggle FFM
hotkey.bind(HK.mods, HK.toggle, function()
    setEnabled(not state.enabled)
end)

-- Debug: Show current state
hotkey.bind(HK.mods, HK.debug, function()
    local cur = mouse.getCurrentScreen()
    local memCount = 0
    for _ in pairs(state.lastFocusedWindow) do memCount = memCount + 1 end

    local msg = string.format(
        "FFM State:\nEnabled: %s\nAccessibility: %s\nCurrent Screen: %s\nLast Screen: %s\nMemory: %d screens\nDragging: %s",
        tostring(state.enabled),
        tostring(hs.accessibilityState()),
        screenId(cur),
        screenId(state.lastScreen),
        memCount,
        tostring(state.isDragging)
    )
    alert.show(msg, CONFIG.alertLong)
    log(msg)
end)

-- Clear focus memory (useful for debugging)
hotkey.bind(HK.mods, HK.clearMemory, function()
    state.lastFocusedWindow = {}
    alert.show("Focus memory cleared", CONFIG.alertNormal)
    if CONFIG.debugConsole then
        log("Focus memory cleared")
    end
end)
