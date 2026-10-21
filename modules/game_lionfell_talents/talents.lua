-- Lionfell talent tree window. The server (data/scripts/lionfell/talents/lf_talents.lua) sends
-- the tree in parts and the player's state over extended opcode 122; this draws it as a
-- pannable, zoomable map and sends "alloc|id", "refund|id" and "reset".

local OPCODE = 122

local window, canvas, tip, messageLabel, resetButton, menuButton, topButton
local pointsChip, keystoneChip, ascendancyChip
local tree = { version = -1, nodes = {}, received = 0, parts = 0, ready = false }
local state = { allocated = {}, start = 0, points = 0, spent = 0, refundCost = 0, resetCost = 0, keystones = 0,
    maxKeystones = 2, maxPoints = 80, ascendancies = 0, maxAscendancies = 2 }
local nodeWidgets, links = {}, {}
local zoom, pan = 0.4, { x = 0, y = 0 }
local drag
local layoutEvent, messageEvent

local REGION_COLOR = { knight = '#b0644f', caster = '#3f9fa8', sorcerer = '#5a78d0', paladin = '#5fae6c', battle = '#8f6cc0' }
local LEARNED = '#d9b36a'
local SIZE = { small = 18, path = 18, notable = 30, start = 32, keystone = 44, ascendancy = 54 }
local OCTAGON = { keystone = true, ascendancy = true }
local MIN_ZOOM, MAX_ZOOM = 0.25, 1.4

local function send(text)
    local protocol = g_game.getProtocolGame()
    if protocol then
        protocol:sendExtendedOpcode(OPCODE, text)
    end
end

local function isLearned(id)
    return state.allocated[id] or id == state.start
end

local function canLearn(id)
    local node = tree.nodes[id]
    if not node or isLearned(id) then
        return false
    end
    for _, other in ipairs(node.c) do
        if isLearned(other) then
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------------------------
-- Layout

local function center()
    local rect = canvas:getRect()
    return rect.x + rect.width / 2 + pan.x, rect.y + rect.height / 2 + pan.y
end

local function screenOf(node)
    local cx, cy = center()
    return cx + node.x * zoom, cy + node.y * zoom
end

local function sizeOf(node)
    local scale = math.max(0.6, math.min(2, zoom / 0.4))
    return math.floor((SIZE[node.k] or 18) * scale)
end

local function layout()
    layoutEvent = nil
    if not window:isVisible() then
        return
    end
    local thickness = math.max(2, math.floor(3 * math.max(0.6, math.min(2, zoom / 0.4))))
    for _, link in ipairs(links) do
        local ax, ay = screenOf(tree.nodes[link.a])
        local bx, by = screenOf(tree.nodes[link.b])
        local dx, dy = bx - ax, by - ay
        local length = math.sqrt(dx * dx + dy * dy)
        link.widget:setRect({ x = math.floor((ax + bx) / 2 - length / 2), y = math.floor((ay + by) / 2 - thickness / 2),
            width = math.floor(length), height = thickness })
        link.widget:setRotation(math.deg(math.atan2(dy, dx)))
    end
    for id, widget in pairs(nodeWidgets) do
        local node = tree.nodes[id]
        local x, y = screenOf(node)
        local size = sizeOf(node)
        widget:setRect({ x = math.floor(x - size / 2), y = math.floor(y - size / 2), width = size, height = size })
        local ring = widget:getChildById('ring')
        ring:setRect({ x = math.floor(x - size / 2) - 3, y = math.floor(y - size / 2) - 3, width = size + 6, height = size + 6 })
    end
end

local function scheduleLayout()
    if not layoutEvent then
        layoutEvent = addEvent(layout)
    end
end

local function fit()
    local rect = canvas:getRect()
    zoom = math.max(MIN_ZOOM, math.min(MAX_ZOOM, math.min(rect.width, rect.height) / 2400))
    pan = { x = 0, y = 0 }
end

-- ---------------------------------------------------------------------------------------------
-- Look

local function paint()
    for id, widget in pairs(nodeWidgets) do
        local node = tree.nodes[id]
        local ring = widget:getChildById('ring')
        if isLearned(id) then
            widget:setImageColor(LEARNED)
            widget:setOpacity(1)
            ring:setVisible(true)
            ring:setImageColor(LEARNED)
        elseif canLearn(id) then
            widget:setImageColor(REGION_COLOR[node.r] or '#8d8a86')
            widget:setOpacity(1)
            ring:setVisible(true)
            ring:setImageColor('#f1efec')
        else
            widget:setImageColor(REGION_COLOR[node.r] or '#8d8a86')
            widget:setOpacity(0.4)
            ring:setVisible(false)
        end
    end
    for _, link in ipairs(links) do
        local a, b = isLearned(link.a), isLearned(link.b)
        if a and b then
            link.widget:setBackgroundColor(LEARNED)
        elseif a or b then
            link.widget:setBackgroundColor('#6f6c68')
        else
            link.widget:setBackgroundColor('#2a2c30')
        end
    end
    local left = math.max(0, state.points - state.spent)
    pointsChip:setText(tr('POINTS  %d / %d', left, state.points))
    pointsChip:setTooltip(state.points >= state.maxPoints and tr('Talent points left to spend (you have the most there is)')
        or tr('Talent points left to spend. You get one more each level, up to %d.', state.maxPoints))
    pointsChip:setColor(left > 0 and '#e2c14a' or '#cfccc7')
    keystoneChip:setText(tr('KEYSTONES  %d / %d', state.keystones, state.maxKeystones))
    ascendancyChip:setText(tr('ASCENDANCIES  %d / %d', state.ascendancies, state.maxAscendancies))
    resetButton:setTooltip(tr('Unlearn every talent for %d gold', state.resetCost))
end

local function showMessage(text)
    if messageEvent then
        removeEvent(messageEvent)
    end
    messageLabel:setText(text)
    messageLabel:setVisible(true)
    messageEvent = scheduleEvent(function()
        messageEvent = nil
        messageLabel:setVisible(false)
    end, 4000)
end

-- ---------------------------------------------------------------------------------------------
-- Hover card

local function addTipLine(text, style, color)
    local label = g_ui.createWidget(style, tip)
    label:setText(text)
    label:setTextWrap(true)
    label:setTextAutoResize(true)
    label:setWidth(276)
    if color then
        label:setColor(color)
    end
end

local function showTip(id)
    local node = tree.nodes[id]
    tip:destroyChildren()
    local kind = node.k == 'keystone' and tr('Keystone') or node.k == 'notable' and tr('Notable')
        or node.k == 'ascendancy' and tr('Ascendancy') or nil
    if node.n ~= '' then
        addTipLine(node.n, 'LfTitle', OCTAGON[node.k] and '#e2c14a' or nil)
    end
    if kind then
        addTipLine(kind, 'LfMono', '#7d7a76')
    end
    if node.k == 'keystone' then
        addTipLine(tr('You can hold %d keystones (%d now). Beyond it lies an ascendancy.', state.maxKeystones, state.keystones), 'LfMuted')
    elseif node.k == 'ascendancy' then
        addTipLine(tr('You can hold %d ascendancies (%d now). Needs its keystone.', state.maxAscendancies, state.ascendancies), 'LfMuted')
    end
    for _, line in ipairs(node.l) do
        addTipLine(line, 'LfLabel', '#cfccc7')
    end
    if id == state.start then
        addTipLine(tr('Your starting point'), 'LfMuted')
    elseif isLearned(id) then
        addTipLine(tr('Learned. Right-click to unlearn (%d gold).', state.refundCost), 'LfMuted')
    elseif canLearn(id) then
        addTipLine(tr('Click to learn (1 point).'), 'LfMuted', '#8fb08a')
    else
        addTipLine(tr('Not connected to your tree yet.'), 'LfMuted')
    end
    tip:setVisible(true)
    tip:raise()
    local mouse = g_window.getMousePosition()
    local root = rootWidget:getRect()
    addEvent(function()
        local x = math.min(mouse.x + 18, root.width - tip:getWidth() - 8)
        local y = math.min(mouse.y + 18, root.height - tip:getHeight() - 8)
        tip:setPosition({ x = x, y = y })
    end)
end

-- ---------------------------------------------------------------------------------------------
-- Building the map

local function build()
    canvas:destroyChildren()
    nodeWidgets, links = {}, {}
    for id, node in pairs(tree.nodes) do
        for _, other in ipairs(node.c) do
            if id < other and tree.nodes[other] then
                local widget = g_ui.createWidget('LfTalentLink', canvas)
                links[#links + 1] = { a = id, b = other, widget = widget }
            end
        end
    end
    for id, node in pairs(tree.nodes) do
        local widget = g_ui.createWidget('LfTalentNode', canvas)
        if OCTAGON[node.k] then
            widget:setImageSource('/images/lionfell/talent_keystone')
        end
        local ring = g_ui.createWidget('UIWidget', widget)
        ring:setId('ring')
        ring:setImageSource(OCTAGON[node.k] and '/images/lionfell/talent_keystone' or '/images/lionfell/talent_ring')
        ring:setImageSmooth(true)
        ring:setPhantom(true)
        if OCTAGON[node.k] then
            ring:setOpacity(0.5)
        end
        widget.onHoverChange = function(self, hovered)
            if hovered then
                showTip(id)
            else
                tip:setVisible(false)
            end
        end
        nodeWidgets[id] = widget
    end
    tree.ready = true
    fit()
    paint()
    scheduleLayout()
end

-- the node under a screen point (canvas clicks: nodes don't take the mouse press, the canvas pans)
local function nodeAt(pos)
    local best, bestDistance
    for id, node in pairs(tree.nodes) do
        local x, y = screenOf(node)
        local radius = sizeOf(node) / 2 + 3
        local dx, dy = pos.x - x, pos.y - y
        local distance = dx * dx + dy * dy
        if distance <= radius * radius and (not bestDistance or distance < bestDistance) then
            best, bestDistance = id, distance
        end
    end
    return best
end

-- ---------------------------------------------------------------------------------------------
-- Server messages

local function onMessage(protocol, opcode, buffer)
    local ok, message = pcall(json.decode, buffer)
    if not ok or type(message) ~= 'table' then
        return
    end
    if message.type == 'tree' then
        if message.version ~= tree.version or message.part == 1 then
            tree = { version = message.version, nodes = {}, received = 0, parts = message.parts, ready = false }
        end
        for _, node in ipairs(message.nodes or {}) do
            tree.nodes[node.id] = node
        end
        tree.received = tree.received + 1
        if tree.received >= tree.parts then
            build()
        end
    elseif message.type == 'state' then
        state.allocated = {}
        for _, id in ipairs(message.allocated or {}) do
            state.allocated[tonumber(id)] = true
        end
        state.start = message.start or 0
        state.points, state.spent = message.points or 0, message.spent or 0
        state.refundCost, state.resetCost = message.refundCost or 0, message.resetCost or 0
        state.keystones, state.maxKeystones = message.keystones or 0, message.maxKeystones or 2
        state.maxPoints = message.maxPoints or 80
        state.ascendancies, state.maxAscendancies = message.ascendancies or 0, message.maxAscendancies or 2
        if message.version ~= tree.version and window:isVisible() then
            send('tree') -- the tree changed on the server
            return
        end
        if tree.ready then
            paint()
        end
        if message.message and message.message ~= '' then
            showMessage(message.message)
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Mouse

local function onCanvasPress(self, mousePos, button)
    if button == MouseLeftButton or button == MouseRightButton then
        drag = { start = mousePos, pan = { x = pan.x, y = pan.y }, moved = false, button = button }
        return true
    end
    return false
end

local function onCanvasMove(self, mousePos, mouseMoved)
    if drag and drag.button == MouseLeftButton and g_mouse.isPressed(MouseLeftButton) then
        local dx, dy = mousePos.x - drag.start.x, mousePos.y - drag.start.y
        if drag.moved or math.abs(dx) + math.abs(dy) > 5 then
            drag.moved = true
            tip:setVisible(false)
            pan = { x = drag.pan.x + dx, y = drag.pan.y + dy }
            scheduleLayout()
        end
        return true
    end
    return false
end

local function onCanvasRelease(self, mousePos, button)
    local current = drag
    drag = nil
    if not current or current.moved or not tree.ready then
        return true
    end
    local id = nodeAt(mousePos)
    if not id then
        return true
    end
    if button == MouseLeftButton and canLearn(id) then
        if state.spent >= state.points then
            showMessage(tr('You have no talent points left.'))
        else
            send('alloc|' .. id)
        end
    elseif button == MouseRightButton and state.allocated[id] then
        send('refund|' .. id)
    end
    return true
end

local function onCanvasWheel(self, mousePos, direction)
    local factor = direction == MouseWheelUp and 1.15 or 1 / 1.15
    local newZoom = math.max(MIN_ZOOM, math.min(MAX_ZOOM, zoom * factor))
    if newZoom == zoom then
        return true
    end
    -- keep the point under the mouse in place
    local rect = canvas:getRect()
    local cx, cy = rect.x + rect.width / 2, rect.y + rect.height / 2
    local wx, wy = (mousePos.x - cx - pan.x) / zoom, (mousePos.y - cy - pan.y) / zoom
    zoom = newZoom
    pan = { x = mousePos.x - cx - wx * zoom, y = mousePos.y - cy - wy * zoom }
    scheduleLayout()
    return true
end

-- ---------------------------------------------------------------------------------------------
-- Window

local function setMenuButton(on)
    for _, button in ipairs({ menuButton, topButton }) do
        if button and not button:isDestroyed() then
            button:setOn(on)
        end
    end
end

-- map controls
function zoomBy(factor)
    if not tree.ready then
        return
    end
    local newZoom = math.max(MIN_ZOOM, math.min(MAX_ZOOM, zoom * factor))
    -- around the middle of the map
    pan = { x = pan.x * newZoom / zoom, y = pan.y * newZoom / zoom }
    zoom = newZoom
    scheduleLayout()
end

function fitTree()
    if tree.ready then
        fit()
        scheduleLayout()
    end
end

function centerOnStart()
    local node = tree.ready and tree.nodes[state.start]
    if not node then
        return
    end
    zoom = math.max(zoom, 0.6)
    pan = { x = -node.x * zoom, y = -node.y * zoom }
    scheduleLayout()
end

function show()
    if not g_game.isOnline() then
        return
    end
    setMenuButton(true)
    window:show()
    window:raise()
    window:focus()
    if tree.ready then
        send('state')
        scheduleLayout()
    else
        send('tree')
    end
end

function hide()
    window:hide()
    tip:setVisible(false)
    setMenuButton(false)
end

function toggle()
    if window:isVisible() then
        hide()
    else
        show()
    end
end

function isVisible()
    return window and window:isVisible() or false
end

function confirmReset()
    local box
    local function close()
        if box then
            box:destroy()
            box = nil
        end
    end
    box = displayGeneralBox(tr('Reset talents'),
        tr('Unlearn every talent for %d gold? You get all your points back.', state.resetCost),
        { { text = tr('Reset'), callback = function() close() send('reset') end },
          { text = tr('Cancel'), callback = close }, anchor = AnchorHorizontalCenter }, close, close)
end

local function onGameEnd()
    hide()
end

function init()
    window = g_ui.loadUI('talents', modules.game_interface.getRootPanel())
    modules.game_lionfell_hud.registerPanel('talents', 'TALENTS', window,
        { anchor = 'center', show = show, hide = hide })
    modules.game_lionfell_hud.registerMenuAction({
        key = 'TAL', order = 12, label = 'Talent tree', run = toggle, isOn = isVisible,
    })
    canvas = window:getChildById('canvas')
    pointsChip = window:getChildById('pointsChip')
    keystoneChip = window:getChildById('keystoneChip')
    ascendancyChip = window:getChildById('ascendancyChip')
    messageLabel = window:getChildById('message')
    resetButton = window:getChildById('reset')
    tip = g_ui.createWidget('LfTalentTip', rootWidget)
    tip:setVisible(false)
    window.onEscape = hide
    canvas.onMousePress = onCanvasPress
    canvas.onMouseMove = onCanvasMove
    canvas.onMouseRelease = onCanvasRelease
    canvas.onMouseWheel = onCanvasWheel
    canvas.onGeometryChange = scheduleLayout
    ProtocolGame.registerExtendedOpcode(OPCODE, onMessage)
    connect(g_game, { onGameEnd = onGameEnd })
    -- game menu button (the menu's skill-wheel icon: the talent tree takes the wheel's place)
    if modules.game_mainpanel and modules.game_mainpanel.addToggleButton then
        menuButton = modules.game_mainpanel.addToggleButton('talentsButton', tr('Talent tree'),
            '/images/options/button_skillwheeldialog', toggle, false, 9)
        menuButton:setOn(false)
    end
    -- and the top menu bar (MNU in the HUD dock)
    if modules.client_topmenu and modules.client_topmenu.addRightToggleButton then
        topButton = modules.client_topmenu.addRightToggleButton('talentsTopButton', tr('Talent tree'),
            '/images/lionfell/icon_talents', toggle)
        topButton:setOn(false)
    end
end

function terminate()
    modules.game_lionfell_hud.unregisterMenuAction('TAL')
    modules.game_lionfell_hud.unregisterPanel('talents')
    disconnect(g_game, { onGameEnd = onGameEnd })
    ProtocolGame.unregisterExtendedOpcode(OPCODE)
    if layoutEvent then
        removeEvent(layoutEvent)
    end
    if messageEvent then
        removeEvent(messageEvent)
    end
    for _, button in ipairs({ menuButton, topButton }) do
        if button and not button:isDestroyed() then
            button:destroy()
        end
    end
    tip:destroy()
    window:destroy()
end

-- a node's data as the server sent it (tests, other modules)
function getNode(id)
    return tree.nodes[id]
end
