-- Lionfell server updates. Before an engine update the server counts down (extended opcode 125,
-- {"type":"restart","seconds":N}: data/globalevents/scripts/lionfell_hotreload.lua) and restarts.
-- This shows the countdown and, when the connection drops, logs the same character back in by
-- itself (retrying while the server starts up) instead of leaving the player at the login screen.

local OPCODE = 125
local RETRY_MS = 4000
local GIVE_UP_MS = 180000 -- after the countdown: how long the server may take to come back

local banner = nil
local pending = false     -- an update was announced and we're not back in yet
local restartAt = 0       -- g_clock.millis() when the server goes down
local giveUpAt = 0
local tickEvent, retryEvent = nil, nil
local attempts = 0

local function now()
    return g_clock.millis()
end

local function showBanner(title, detail)
    if not banner then
        return
    end
    banner.title:setText(title)
    banner.detail:setText(detail or '')
    banner.detail:setVisible((detail or '') ~= '')
    banner:show()
    banner:raise()
    -- top centre of the screen
    local width = math.max(banner.title:getTextSize().width, banner.detail:getTextSize().width) + 40
    banner:setWidth(width)
    banner:setPosition({ x = math.floor((rootWidget:getWidth() - width) / 2), y = 70 })
end

local function hideBanner()
    if banner then
        banner:hide()
    end
end

local function stop()
    pending = false
    removeEvent(tickEvent)
    removeEvent(retryEvent)
    tickEvent, retryEvent = nil, nil
end

-- the countdown while still online
local function tick()
    tickEvent = nil
    if not pending or not g_game.isOnline() then
        return
    end
    local left = math.max(0, math.ceil((restartAt - now()) / 1000))
    showBanner(tr('Lionfell is updating in %d seconds', left), tr('You will be reconnected automatically.'))
    tickEvent = scheduleEvent(tick, 500)
end

-- message boxes the character list leaves after a failed attempt (connection refused while the
-- server starts): they would stack up, one per try
local function clearMessageBoxes()
    for _, child in ipairs(rootWidget:getChildren()) do
        if child:getClassName() == 'UIMessageBox' then
            child:destroy()
        end
    end
end

local function attempt()
    retryEvent = nil
    if not pending or g_game.isOnline() then
        return
    end
    if now() > giveUpAt then
        stop()
        clearMessageBoxes()
        showBanner(tr('Lionfell is taking longer than usual'), tr('Please log in again in a moment.'))
        scheduleEvent(hideBanner, 8000)
        if CharacterList and CharacterList.show then
            CharacterList.show()
        end
        return
    end
    attempts = attempts + 1
    clearMessageBoxes()
    showBanner(tr('Lionfell is updating'), tr('Reconnecting... (attempt %d)', attempts))
    if CharacterList and CharacterList.doLogin then
        CharacterList.doLogin()
    end
    retryEvent = scheduleEvent(attempt, RETRY_MS)
end

local function onMessage(protocol, opcode, buffer)
    local ok, message = pcall(json.decode, buffer)
    if not ok or type(message) ~= 'table' or message.type ~= 'restart' then
        return
    end
    local seconds = tonumber(message.seconds) or 30
    pending = true
    attempts = 0
    restartAt = now() + seconds * 1000
    giveUpAt = restartAt + GIVE_UP_MS
    removeEvent(tickEvent)
    tick()
end

local function onGameEnd()
    removeEvent(tickEvent)
    tickEvent = nil
    if not pending then
        hideBanner()
        return
    end
    -- give the server a moment to go down and start again before the first try
    showBanner(tr('Lionfell is updating'), tr('Reconnecting in a moment...'))
    removeEvent(retryEvent)
    retryEvent = scheduleEvent(attempt, 6000)
end

local function onGameStart()
    if pending or (banner and banner:isVisible()) then
        stop()
        clearMessageBoxes()
        showBanner(tr('Welcome back'), tr('Lionfell has been updated.'))
        scheduleEvent(hideBanner, 3000)
    end
end

function init()
    g_ui.importStyle('restart')
    banner = g_ui.createWidget('LfRestartBanner', rootWidget)
    banner:hide()
    ProtocolGame.registerExtendedOpcode(OPCODE, onMessage)
    connect(g_game, { onGameEnd = onGameEnd, onGameStart = onGameStart })
end

function terminate()
    stop()
    disconnect(g_game, { onGameEnd = onGameEnd, onGameStart = onGameStart })
    ProtocolGame.unregisterExtendedOpcode(OPCODE)
    if banner then
        banner:destroy()
        banner = nil
    end
end
