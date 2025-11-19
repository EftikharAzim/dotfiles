-- Put this in ~/.hammerspoon/init.lua and Reload Config (menu or Ctrl+Alt+Cmd+R)

local mouse    = hs.mouse
local window   = hs.window
local screen   = hs.screen
local timer    = hs.timer
local eventtap = hs.eventtap
local alert    = hs.alert
local hotkey   = hs.hotkey
local log      = hs.printf

-- Config
local DEBOUNCE_SECONDS = 0.06   -- how long to wait before focusing after crossing (tweakable)
local POLL_INTERVAL     = 0.25   -- fallback poll interval (keeps it robust)
local DEBUG_CONSOLE_MSG = true   -- set false to silence console logs

-- internal state
local enabled = true
local lastScreen = mouse.absolutePosition() and mouse.getCurrentScreen() or nil
local focusTimer = nil

-- helper: safe screen id string (nil-safe)
local function screenId(s)
    return s and (s:id() or tostring(s)) or "nil"
end

-- helper: is a window a candidate to focus?
local function isCandidate(w)
    if not w then return false end
    if not w:isVisible() then return false end
    if w:isMinimized() then return false end
    if not w:isStandard() then return false end
    return true
end

-- helper: point-in-rect using numeric fields (robust)
local function pointInRect(pt, rect)
    if not (pt and rect) then return false end
    local x, y = pt.x or pt[1], pt.y or pt[2]
    local rx, ry, rw, rh = rect.x, rect.y, rect.w, rect.h
    if not (x and y and rx and ry and rw and rh) then return false end
    return x >= rx and x <= (rx + rw) and y >= ry and y <= (ry + rh)
end

-- find the topmost window on 'sc' that contains the point (pt)
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

-- focus logic: try under-cursor window, else focus first visible standard window on screen
local function focusWindowOnScreen(sc)
    if not sc then
        if DEBUG_CONSOLE_MSG then log("focusWindowOnScreen: no screen") end
        return false
    end

    local pt = mouse.absolutePosition()
    local w = windowUnderPointOnScreen(pt, sc)
    if w then
        if DEBUG_CONSOLE_MSG then log(string.format("Focusing window under cursor: %s (%s)", tostring(w:title()), tostring(w:application():name()))) end
        w:focus()
        return true
    end

    for _, w2 in ipairs(window.orderedWindows()) do
        if isCandidate(w2) and w2:screen() == sc then
            if DEBUG_CONSOLE_MSG then log(string.format("Fallback focus: %s (%s)", tostring(w2:title()), tostring(w2:application():name()))) end
            w2:focus()
            return true
        end
    end

    if DEBUG_CONSOLE_MSG then log("No candidate window found on screen " .. screenId(sc)) end
    return false
end

-- debounce wrapper
local function scheduleFocus(sc)
    if focusTimer then
        focusTimer:stop()
        focusTimer = nil
    end
    focusTimer = timer.doAfter(DEBOUNCE_SECONDS, function()
        focusWindowOnScreen(sc)
        focusTimer = nil
    end)
end

-- eventtap mouse-move watcher
local mouseWatcher = eventtap.new({ eventtap.event.types.mouseMoved }, function(e)
    if not enabled then return false end
    local cur = mouse.getCurrentScreen()
    if cur and lastScreen and cur:id() ~= lastScreen:id() then
        if DEBUG_CONSOLE_MSG then log(string.format("Screen change detected (event): %s -> %s", screenId(lastScreen), screenId(cur))) end
        lastScreen = cur
        scheduleFocus(cur)
    end
    return false
end)

-- poll fallback: ensures we catch cases where mouseMoved events might not trigger
local pollTimer = timer.new(POLL_INTERVAL, function()
    if not enabled then return end
    local cur = mouse.getCurrentScreen()
    if cur and lastScreen and cur:id() ~= lastScreen:id() then
        if DEBUG_CONSOLE_MSG then log(string.format("Screen change detected (poll): %s -> %s", screenId(lastScreen), screenId(cur))) end
        lastScreen = cur
        scheduleFocus(cur)
    end
end)

-- toggle function & hotkey
local function setEnabled(v)
    enabled = v
    if enabled then
        mouseWatcher:start()
        pollTimer:start()
        alert.show("FFM → ON")
        if DEBUG_CONSOLE_MSG then log("FFM enabled") end
    else
        mouseWatcher:stop()
        pollTimer:stop()
        if focusTimer then focusTimer:stop(); focusTimer = nil end
        alert.show("FFM → OFF")
        if DEBUG_CONSOLE_MSG then log("FFM disabled") end
    end
end

-- start up
mouseWatcher:start()
pollTimer:start()
alert.show("FFM (monitor→focus) loaded")
if DEBUG_CONSOLE_MSG then log("FFM loaded; lastScreen = " .. screenId(lastScreen)) end

-- hotkeys
hotkey.bind({"ctrl", "alt", "cmd"}, "R", function() hs.reload() end)       -- reload config
hotkey.bind({"ctrl", "alt", "cmd"}, "T", function() setEnabled(not enabled) end) -- toggle with Ctrl+Alt+Cmd+T
