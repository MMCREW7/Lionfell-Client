-- Lionfell quality item tooltips. Hover a quality item (outlined in its colour) in any slot or on
-- the map: we ask the server (extended opcode 121) for its lines and show them next to the mouse.

local OPCODE = 121
local QUALITY_NAMES = { 'UNCOMMON', 'RARE', 'EPIC', 'LEGENDARY' }
local QUALITY_COLORS = { '#4cc94c', '#4a90ff', '#b65cff', '#ff8c1a' }
local LINE_COLORS = { prefix = '#e7e5e2', suffix = '#cfccc7', legendary = '#ff8c1a' }
local CACHE_MS = 4000

local tip = nil
local card = nil      -- the detailed view (hold Alt)
local cardShown = false
local pollEvent = nil
local cache = {}      -- key -> { at, data }
local requested = {}  -- key -> ms of the last request
local showing = nil   -- key on screen

local function now()
    return g_clock.millis()
end

local function hide()
    if tipDebug and tip and tip:isVisible() then
        local w = g_ui.getHoveredWidget()
        print('LFTIPDBG hide (hovered: ' .. (w and (w:getClassName() .. ' ' .. w:getId()) or 'none') .. ')')
    end
    if tip and tip:isVisible() then
        tip:hide()
    end
    if card and card:isVisible() then
        card:hide()
    end
    showing = nil
end

local function place()
    local mouse = g_window.getMousePosition()
    local tip = cardShown and card or tip
    local size = tip:getSize()
    local screen = rootWidget:getSize()
    local x, y = mouse.x + 18, mouse.y + 18
    if x + size.width > screen.width - 4 then
        x = mouse.x - size.width - 12
    end
    if y + size.height > screen.height - 4 then
        y = screen.height - size.height - 4
    end
    tip:setPosition({ x = math.max(4, x), y = math.max(4, y) })
end

local function hexAlpha(color, alpha)
    return color .. string.format('%02x', math.floor(alpha * 255))
end

-- the detailed card: name and base item in a header band, centred properties, the modifiers,
-- the quality; border, band and dividers in the quality's colour
local function showCard(key, data)
    local quality = data.quality or 1
    local color = QUALITY_COLORS[quality] or '#cfccc7'
    card:setBorderColor(color)
    card.header:setBorderColor(hexAlpha(color, 0.55))
    card.header:setBackgroundColor(hexAlpha(color, 0.14))
    card.header.name:setText(data.name or '')
    card.header.name:setColor(color)
    local base = data.base or ''
    base = base:gsub('(%a)([%w]*)', function(first, rest) return first:upper() .. rest end)
    card.header.base:setText(base)
    card.header.base:setColor(hexAlpha(color, 0.8))

    local body = card.body
    body:destroyChildren()
    local widest = math.max(card.header.name:getTextSize().width, card.header.base:getTextSize().width)
    local function text(content, colored)
        local label = g_ui.createWidget('LfItemCardText', body)
        if colored then
            label:setColoredText(content)
        else
            label:setText(content)
        end
        widest = math.max(widest, label:getTextSize().width)
        return label
    end
    local function divider()
        local line = g_ui.createWidget('LfItemCardDivider', body)
        line:setBackgroundColor(hexAlpha(color, 0.45))
    end
    local function property(name, value)
        text(string.format('{%s: , #8d8a86}{%s, #a9b8ff}', name, value), true)
    end

    -- properties
    local any = false
    if (data.attack or 0) > 0 then property('Attack', data.attack) any = true end
    if (data.defense or 0) > 0 then property('Defense', data.defense) any = true end
    if (data.armor or 0) > 0 then property('Armour', data.armor) any = true end
    if (data.speed or 0) > 0 then property('Attack speed', string.format('%.2fs', data.speed / 1000)) any = true end
    if (data.durability or 0) > 0 then property('Durability', data.durability) any = true end
    if (data.level or 0) > 0 then
        text(string.format('{Requires Level , #8d8a86}{%d, #e7e5e2}', data.level), true)
        any = true
    end
    if any then
        divider()
    end

    -- modifiers
    if data.identified then
        for _, line in ipairs(data.lines or {}) do
            local label = text(line.text)
            label:setColor(line.kind == 'legendary' and QUALITY_COLORS[4] or '#8fa0ff')
            if line.tier and line.tier > 0 then
                label:setColoredText(string.format('{%s, %s}{  T%d, #6f6c68}', line.text,
                    line.kind == 'legendary' and QUALITY_COLORS[4] or '#8fa0ff', line.tier))
                widest = math.max(widest, label:getTextSize().width)
            end
        end
    else
        text('Unidentified'):setColor('#c7453c')
        text('Use an identification rune to reveal its properties.'):setColor('#8d8a86')
    end
    divider()
    text(QUALITY_NAMES[quality] or ''):setColor(color)

    card:setWidth(math.max(260, widest + 48))
    hide()
    card:show()
    card:raise()
    cardShown = true
    showing = key
    place()
end

local function show(key, data)
    if g_keyboard.isAltPressed() then
        return showCard(key, data)
    end
    cardShown = false
    local quality = data.quality or 1
    -- the frame takes the quality's colour too
    tip:setBorderWidth(1)
    tip:setBorderColor(QUALITY_COLORS[quality] or '#cfccc7')
    tip.name:setText(data.name or '')
    tip.name:setColor(QUALITY_COLORS[quality] or '#cfccc7')
    tip.quality:setText((QUALITY_NAMES[quality] or '') .. (data.identified and '' or '  -  UNIDENTIFIED'))
    tip.stats:setText(data.stats or '')
    tip.stats:setVisible((data.stats or '') ~= '')
    tip.lines:destroyChildren()
    if data.identified then
        for _, line in ipairs(data.lines or {}) do
            local label = g_ui.createWidget('LfItemTipLine', tip.lines)
            local tier = line.tier and line.tier > 0 and ('  T' .. line.tier) or ''
            label:setText(line.text .. tier)
            label:setColor(LINE_COLORS[line.kind] or '#cfccc7')
        end
    else
        local label = g_ui.createWidget('LfItemTipLine', tip.lines)
        label:setText('Use an identification rune to reveal its properties.')
        label:setColor('#8d8a86')
    end
    -- the layout fits the height; the width follows the widest line
    local width = 180
    for _, label in ipairs({ tip.name, tip.quality, tip.stats }) do
        width = math.max(width, label:getTextSize().width)
    end
    for _, label in ipairs(tip.lines:getChildren()) do
        width = math.max(width, label:getTextSize().width)
    end
    tip:setWidth(width + tip:getPaddingLeft() + tip:getPaddingRight())
    if card:isVisible() then
        card:hide()
    end
    tip:show()
    tip:raise()
    showing = key
    place()
    if tipDebug then
        local r = tip:getRect()
        print(string.format('LFTIPDBG show "%s" at %d,%d size %dx%d visible %s', data.name or '', r.x, r.y, r.width, r.height,
            tostring(tip:isVisible())))
    end
end

-- the quality item under the mouse: { key, request } or nil
local function hoveredItem()
    local widget = g_ui.getHoveredWidget()
    if not widget then
        return nil
    end
    local item
    if widget:getClassName() == 'UIItem' then
        item = widget:getItem()
    elseif widget:getClassName() == 'UIGameMap' or widget:getClassName() == 'UIMap' then
        local tile = widget:getTile(g_window.getMousePosition())
        local thing = tile and tile:getTopLookThing()
        if thing and thing:isItem() then
            item = thing
        end
    end
    if not item or not item.getTier or item:getTier() <= 0 then
        return nil
    end
    local pos = item:getPosition()
    if not pos or (pos.x == 0 and pos.y == 0) then
        return nil -- a display copy (e.g. auction rows have their own tooltip)
    end
    local stackpos = math.max(0, item:getStackPos())
    local key = string.format('%d,%d,%d,%d,%d', pos.x, pos.y, pos.z, stackpos, item:getId())
    return key, string.format('%d|%d|%d|%d|%d', pos.x, pos.y, pos.z, stackpos, item:getId())
end

local function poll()
    if not g_game.isOnline() then
        hide()
        return
    end
    local key, request = hoveredItem()
    if not key then
        hide()
        return
    end
    local cached = cache[key]
    if cached and now() - cached.at < CACHE_MS then
        if showing ~= key or cardShown ~= g_keyboard.isAltPressed() then
            show(key, cached.data)
        else
            place()
        end
        return
    end
    if now() - (requested[key] or 0) > 800 then
        requested[key] = now()
        local protocol = g_game.getProtocolGame()
        if protocol then
            protocol:sendExtendedOpcode(OPCODE, request)
        end
    end
    if showing == key then
        place()
    end
end

local function onTip(protocol, opcode, buffer)
    local ok, data = pcall(json.decode, buffer)
    if not ok or type(data) ~= 'table' or not data.key then
        return
    end
    cache[data.key] = { at = now(), data = data }
    local key = hoveredItem()
    if key == data.key then
        show(key, data)
    end
end

function init()
    g_ui.importStyle('items')
    tip = g_ui.createWidget('LfItemTip', rootWidget)
    tip:hide()
    card = g_ui.createWidget('LfItemCard', rootWidget)
    card:hide()
    ProtocolGame.registerExtendedOpcode(OPCODE, onTip)
    pollEvent = cycleEvent(poll, 120)
    connect(g_game, { onGameEnd = function() cache = {} hide() end })
end

function terminate()
    if pollEvent then
        removeEvent(pollEvent)
        pollEvent = nil
    end
    ProtocolGame.unregisterExtendedOpcode(OPCODE)
    if tip then
        tip:destroy()
        tip = nil
    end
    if card then
        card:destroy()
        card = nil
    end
end

-- for tests: is the tooltip showing, and what does it say
function tipState()
    return tip and tip:isVisible() or false, tip and tip.name:getText() or '', tip and tip.lines:getChildCount() or 0
end
