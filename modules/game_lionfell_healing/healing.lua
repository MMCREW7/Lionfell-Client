-- Party healing frames. The server supplies every party member's health and spell reach.
-- It also shares tank markers with everyone who opens this panel.

local OPCODE = 129
local UPDATE_MS = 350
local FRAME_WIDTH, FRAME_HEIGHT, FRAME_GAP = 60, 24, 3
local MAX_COLUMNS = 5

local window, roster, hint, menuButton, topButton, refreshEvent
local rows = {}
local selfGuid, memberCount, markMode, pendingBuffer = nil, 0, nil, nil

local function send(message)
    local protocol = g_game.getProtocolGame()
    if protocol then protocol:sendExtendedOpcode(OPCODE, message) end
end

local function compactName(name, limit)
    if #name <= limit then return name end
    return name:sub(1, limit - 2) .. '..'
end

local function setHealth(row)
    local member = row.member
    if not member then return end
    local percent = math.max(0, math.min(100, 100 * (member.health or 0) / math.max(1, member.maxHealth or 1)))
    local available = member.status == 'ok'
    local urgent, warning = percent <= 30, percent <= 65
    local bar = row:getChildById('health')
    local fill = bar:getChildById('fill')
    fill:setBackgroundColor(not available and '#686b6d'
        or urgent and '#b9625a' or warning and '#c2a46a' or '#8fb08a')
    fill:setWidth(math.floor(bar:getWidth() * percent / 100))
    row:setImageColor(not available and '#2b2d30'
        or urgent and '#4b2b2a' or warning and '#4d402b' or '#263d32')
end

local STATUS_TEXT = {
    range = 'Out of healing range',
    los = 'Line of sight blocked',
    floor = 'On another floor',
    dead = 'Dead',
}

local function updateHint()
    if not hint then return end
    if markMode then
        hint:setText(markMode == 'tank' and tr('Click a box to mark the tank; click the tank again to clear.')
            or tr('Click a box to mark the off-tank; click again to clear.'))
    elseif memberCount == 0 then
        hint:setText(tr('Loading party...'))
    elseif memberCount == 1 then
        hint:setText(tr('Just you. T = tank, 2 = off-tank.'))
    else
        hint:setText(tr('Gray = out of reach. T = tank, 2 = off-tank.'))
    end
end

local function setMarkMode(mode)
    markMode = mode
    if window then
        window:getChildById('markTank'):setText(mode == 'tank' and tr('PICK T') or tr('TANK'))
        window:getChildById('markOfftank'):setText(mode == 'offtank' and tr('PICK 2') or tr('2ND'))
    end
    updateHint()
end

function selectMarker(mode)
    if mode ~= 'tank' and mode ~= 'offtank' then return end
    setMarkMode(markMode == mode and nil or mode)
end

local function castOn(name, words)
    if not g_game.isOnline() or name:find('"', 1, true) then return end
    g_game.talk(words .. ' "' .. name)
end

local function addRow(guid)
    local row = g_ui.createWidget('LfHealingRow', roster)
    row.onMouseRelease = function(widget, mousePos, button)
        local member = row.member
        if not member then return true end
        if markMode then
            if button == MouseLeftButton then
                send('mark|' .. markMode .. '|' .. member.guid)
            end
            setMarkMode(nil)
            return true
        end
        if member.status ~= 'ok' then return true end
        if member.guid == selfGuid then
            if button == MouseLeftButton then
                g_game.talk('exura')
            elseif button == MouseRightButton then
                g_game.talk('exura gran')
            end
        elseif button == MouseLeftButton then
            castOn(member.name, 'exura sio')
        elseif button == MouseRightButton then
            castOn(member.name, 'exura gran sio')
        end
        return true
    end
    row:getChildById('health').onGeometryChange = function()
        setHealth(row)
    end
    rows[guid] = row
    return row
end

local function updateRow(row, member)
    row.member = member
    local role = member.role or ''
    local prefix = role == 'tank' and 'T ' or (role == 'offtank' and '2 ' or '')
    local name = member.guid == selfGuid and tr('You') or member.name
    local label = row:getChildById('name')
    label:setText(prefix .. compactName(name, role == '' and 8 or 6))
    label:setColor(member.status ~= 'ok' and '#85888b'
        or role == 'tank' and '#e0bd80' or role == 'offtank' and '#d6c7aa' or '#e7e5e2')
    local roleText = role == 'tank' and tr('Tank') or (role == 'offtank' and tr('Off-tank') or nil)
    local statusText = STATUS_TEXT[member.status]
    local actionText = member.guid == selfGuid
        and tr('Left: Light Healing. Right: Intense Healing.')
        or tr("Left: Heal Friend. Right: Nature's Embrace.")
    local parts = { member.name }
    if roleText then parts[#parts + 1] = roleText end
    parts[#parts + 1] = statusText or actionText
    row:setTooltip(table.concat(parts, '\n'))
    setHealth(row)
end

local function render(message)
    if not window or not window:isVisible() or message.type ~= 'party' or type(message.members) ~= 'table' then
        return
    end
    selfGuid = message.self
    local members = message.members
    memberCount = #members
    local present = {}
    for index, member in ipairs(members) do
        if type(member.guid) == 'number' and type(member.name) == 'string' then
            present[member.guid] = true
            local row = rows[member.guid] or addRow(member.guid)
            updateRow(row, member)
            if roster:getChildByIndex(index) ~= row then
                roster:moveChildToIndex(row, index)
            end
        end
    end
    for guid, row in pairs(rows) do
        if not present[guid] then
            row:destroy()
            rows[guid] = nil
        end
    end
    local count = math.max(1, memberCount)
    local columns = math.min(MAX_COLUMNS, count)
    local lines = math.ceil(count / columns)
    window:setWidth(math.max(288, 24 + columns * FRAME_WIDTH + (columns - 1) * FRAME_GAP))
    roster:setHeight(lines * FRAME_HEIGHT + (lines - 1) * FRAME_GAP)
    window:setHeight(94 + roster:getHeight())
    updateHint()
end

local function onMessage(protocol, opcode, buffer)
    local mark = buffer:sub(1, 1)
    if mark == 'S' then
        pendingBuffer = buffer:sub(2)
        return
    elseif mark == 'P' and pendingBuffer then
        pendingBuffer = pendingBuffer .. buffer:sub(2)
        return
    elseif mark == 'E' and pendingBuffer then
        buffer = pendingBuffer .. buffer:sub(2)
        pendingBuffer = nil
    end
    local ok, message = pcall(json.decode, buffer)
    if ok and type(message) == 'table' then render(message) end
end

local function refresh()
    refreshEvent = nil
    if not window or not window:isVisible() or not g_game.isOnline() then return end
    send('get')
    refreshEvent = scheduleEvent(refresh, UPDATE_MS)
end

local function setButtons(on)
    if menuButton then menuButton:setOn(on) end
    if topButton then topButton:setOn(on) end
end

function show()
    if not window or not g_game.isOnline() then return end
    window:show()
    window:raise()
    setButtons(true)
    if not refreshEvent then refresh() end
end

function hide()
    if not window then return end
    window:hide()
    setButtons(false)
    if refreshEvent then removeEvent(refreshEvent) refreshEvent = nil end
    for guid, row in pairs(rows) do
        row:destroy()
        rows[guid] = nil
    end
    selfGuid, memberCount, pendingBuffer = nil, 0, nil
    setMarkMode(nil)
end

function toggle()
    if window and window:isVisible() then hide() else show() end
end

function isVisible()
    return window and window:isVisible() or false
end

local function onGameEnd()
    hide()
end

function init()
    window = g_ui.loadUI('healing', modules.game_interface.getRootPanel())
    modules.game_lionfell_hud.registerPanel('healing', 'PARTY HEALING', window,
        { anchor = 'topCenter', top = 96, show = show, hide = hide })
    modules.game_lionfell_hud.registerMenuAction({
        key = 'HEAL', order = 6, label = 'Party healing', run = toggle, isOn = isVisible,
    })
    roster = window:getChildById('roster')
    hint = window:getChildById('hint')
    window.onEscape = hide
    ProtocolGame.registerExtendedOpcode(OPCODE, onMessage)
    connect(g_game, { onGameEnd = onGameEnd })
    if modules.game_mainpanel and modules.game_mainpanel.addToggleButton then
        menuButton = modules.game_mainpanel.addToggleButton('healingButton', tr('Party healing'),
            '/images/icons/icon_health', toggle, false, 10)
        menuButton:setOn(false)
    end
    if modules.client_topmenu and modules.client_topmenu.addRightToggleButton then
        topButton = modules.client_topmenu.addRightToggleButton('healingTopButton', tr('Party healing'),
            '/images/icons/icon_health', toggle)
        topButton:setOn(false)
    end
end

function terminate()
    modules.game_lionfell_hud.unregisterMenuAction('HEAL')
    modules.game_lionfell_hud.unregisterPanel('healing')
    disconnect(g_game, { onGameEnd = onGameEnd })
    ProtocolGame.unregisterExtendedOpcode(OPCODE)
    onGameEnd()
    for _, button in ipairs({ menuButton, topButton }) do
        if button and not button:isDestroyed() then button:destroy() end
    end
    if window then window:destroy() end
end
