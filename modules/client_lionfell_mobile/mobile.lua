-- Lionfell on phones (g_platform.isMobile(); on PC start the client with -mobile to try it):
-- the interface is scaled to fit the screen. Android scales the UI by a fixed factor (the stock
-- option: 1.5x), which on most phones left too little room: the login window was huge and the
-- character list ran off the bottom. Here the scale is picked so the screen is SIZES[size]
-- interface pixels tall, whatever the phone. The in-game phone layout is game_lionfell_mobile.

local SETTING = 'lionfellMobileSize'
-- interface height in UI pixels: more = everything smaller
SIZES = { small = 680, medium = 600, large = 520 }
local DEFAULT = 'medium'
local MIN_SCALE, MAX_SCALE = 1, 4

function getSize()
    local size = g_settings.getString(SETTING)
    return SIZES[size] and size or DEFAULT
end

-- the UI scale (display density) that makes the screen SIZES[size] UI pixels tall
function scale()
    local physical = g_graphics.getViewportSize()
    local height = math.min(physical.width, physical.height) -- landscape: the short side
    if height <= 0 then
        return 1.5
    end
    return math.max(MIN_SCALE, math.min(MAX_SCALE, height / SIZES[getSize()]))
end

function apply()
    if not g_platform.isMobile() then
        return
    end
    local wanted = scale()
    -- setting the scale resizes the UI (and fires onGeometryChange again): only on a real change
    if math.abs(wanted - g_window.getDisplayDensity()) > 0.01 then
        g_app.setHUDScale(wanted)
    end
end

function setSize(size)
    if not SIZES[size] then
        return
    end
    g_settings.set(SETTING, size)
    apply()
end

local function onResize()
    -- the window gets its real size a moment after start (and after rotating)
    scheduleEvent(apply, 100)
end

function init()
    if not g_platform.isMobile() then
        return
    end
    connect(rootWidget, { onGeometryChange = onResize })
    apply()
end

function terminate()
    if g_platform.isMobile() then
        disconnect(rootWidget, { onGeometryChange = onResize })
    end
end
