-- Lionfell auction house window. Server side: data/scripts/lionfell/items/lf_auction.lua
-- (extended opcode 120; we send "cmd|arg|..." and receive JSON).

local OPCODE = 120
local QUALITY_NAMES = { [0] = 'Common', 'Uncommon', 'Rare', 'Epic', 'Legendary' }
local QUALITY_COLORS = { [0] = '#cfccc7', '#4cc94c', '#4a90ff', '#b65cff', '#ff8c1a' }
local CATEGORIES = {
    { 'All items', 'all' }, { 'Weapons', 'weapon' }, { 'Wands & rods', 'wand' }, { 'Shields', 'shield' },
    { 'Helmets', 'helmet' }, { 'Armor', 'armor' }, { 'Legs', 'legs' }, { 'Boots', 'boots' },
    { 'Rings', 'ring' }, { 'Amulets', 'amulet' },
}
local QUALITIES = { { 'Any quality', 0 }, { 'Uncommon+', 1 }, { 'Rare+', 2 }, { 'Epic+', 3 }, { 'Legendary', 4 } }
local SORTS = { { 'Cheapest first', 'price_asc' }, { 'Priciest first', 'price_desc' }, { 'Newest', 'newest' },
    { 'Best quality', 'quality' } }

window = nil
local state = { page = 0, pages = 1, feePercent = 2, minFee = 10, tab = 'browse' }
local statOptions = { { 'Any modifier', '' } } -- filled from the server's line catalogue
local sellPosition = nil -- { pos, stackpos, clientId } of the item in the sell slot

local function send(...)
    local protocol = g_game.getProtocolGame()
    if not protocol then
        return
    end
    protocol:sendExtendedOpcode(OPCODE, table.concat({ ... }, '|'))
end

local function formatGold(value)
    local text = tostring(math.floor(value or 0))
    local formatted = text:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    return (formatted:gsub('^,', '')) .. ' gp'
end

local function comboValue(combo, list)
    local text = combo:getText()
    for _, entry in ipairs(list) do
        if entry[1] == text then
            return entry[2]
        end
    end
    return list[1][2]
end

local function fillCombo(combo, list)
    combo:clearOptions()
    for _, entry in ipairs(list) do
        combo:addOption(entry[1])
    end
    combo:setCurrentOption(list[1][1])
end

local function setStatus(text, ok)
    local status = window:recursiveGetChildById('status')
    status:setText(text or '')
    status:setColor(ok == false and '#b9625a' or '#8d8a86')
end

-- ---------------------------------------------------------------------------------------------
-- Rows

local function fillRow(row, entry, actionText, onAction)
    local item = Item.create(entry.clientId)
    if item then
        item:setTier(entry.quality) -- draws the quality outline
        row.item:setItem(item)
    end
    row.name:setText(entry.name)
    row.name:setColor(QUALITY_COLORS[entry.quality] or '#cfccc7')
    local daysLeft = math.max(0, math.ceil(((entry.expires or 0) - os.time()) / 86400))
    row.seller:setText(string.format('%s  -  %s  -  %d day%s left', QUALITY_NAMES[entry.quality] or '', entry.seller or '',
        daysLeft, daysLeft == 1 and '' or 's'))
    row.price:setText(formatGold(entry.price))
    row.action:setText(actionText)
    row.action.onClick = onAction
    row:setTooltip(entry.name .. '\n' .. (entry.description or ''))
end

local function fillList(list, entries, actionText, makeAction)
    list:destroyChildren()
    if #entries == 0 then
        local empty = g_ui.createWidget('LfMuted', list)
        empty:setText('Nothing here yet.')
        return
    end
    for _, entry in ipairs(entries) do
        local row = g_ui.createWidget('AuctionRow', list)
        fillRow(row, entry, actionText, makeAction(entry))
    end
end

-- ---------------------------------------------------------------------------------------------
-- Server messages

local function onMessage(protocol, opcode, buffer)
    local ok, message = pcall(json.decode, buffer)
    if not ok or type(message) ~= 'table' or not window then
        return
    end
    if message.type == 'show' then
        show()
    elseif message.type == 'state' then
        state.feePercent, state.minFee = message.feePercent or 2, message.minFee or 10
        if message.lines and #statOptions == 1 then
            for _, line in ipairs(message.lines) do
                local label = line.kind == 'legendary' and (line.name .. ' (legendary)') or line.name
                statOptions[#statOptions + 1] = { label, line.id, line.text }
            end
            local row = window:recursiveGetChildById('statRow')
            for i = 1, 3 do
                fillCombo(row:getChildById('stat' .. i), statOptions)
            end
        end
        window:recursiveGetChildById('balance'):setText(string.format('%s  -  %d/%d listed', formatGold(message.balance),
            message.listings or 0, message.maxListings or 20))
        if message.inZone == false then
            setStatus('Buying and selling needs a protection zone (town).', false)
        end
    elseif message.type == 'browse' then
        state.page, state.pages = message.page or 0, message.pages or 1
        local panel = window:recursiveGetChildById('browsePanel')
        fillList(panel:getChildById('list'), message.items or {}, 'Buy', function(entry)
            return function()
                send('buy', entry.id)
            end
        end)
        panel:recursiveGetChildById('pageLabel'):setText(string.format('page %d / %d  -  %d items', state.page + 1, state.pages,
            message.total or 0))
        panel:recursiveGetChildById('prev'):setEnabled(state.page > 0)
        panel:recursiveGetChildById('next'):setEnabled(state.page + 1 < state.pages)
    elseif message.type == 'mine' then
        fillList(window:recursiveGetChildById('minePanel'):getChildById('list'), message.items or {}, 'Cancel',
            function(entry)
                return function()
                    send('cancel', entry.id)
                end
            end)
    elseif message.type == 'result' then
        setStatus(message.message, message.ok)
        if message.ok then
            if state.tab == 'browse' then
                browse(state.page)
            elseif state.tab == 'sell' then
                clearSell()
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Actions (called from the .otui)

-- "line:min,line:min" from the three modifier pickers
local function statFilter()
    local row = window:recursiveGetChildById('statRow')
    local parts = {}
    for i = 1, 3 do
        local line = comboValue(row:getChildById('stat' .. i), statOptions)
        if line ~= '' then
            local min = tonumber(row:getChildById('min' .. i):getText()) or 0
            parts[#parts + 1] = line .. ':' .. math.floor(min)
        end
    end
    return table.concat(parts, ',')
end

function browse(page)
    local panel = window:recursiveGetChildById('browsePanel')
    local search = panel:getChildById('search'):getText():gsub('|', '')
    send('browse', comboValue(panel:getChildById('category'), CATEGORIES), comboValue(panel:getChildById('quality'), QUALITIES),
        search, comboValue(panel:getChildById('sort'), SORTS), page or 0, statFilter())
end

function page(delta)
    browse(math.max(0, math.min(state.pages - 1, state.page + delta)))
end

function showTab(tab)
    state.tab = tab
    for _, name in ipairs({ 'browse', 'mine', 'sell' }) do
        window:recursiveGetChildById(name .. 'Panel'):setVisible(name == tab)
        window:recursiveGetChildById(name .. 'Tab'):setChecked(name == tab)
    end
    setStatus('')
    if tab == 'browse' then
        browse(state.page)
    elseif tab == 'mine' then
        send('mine')
    end
end

function updateFee()
    local price = tonumber(window:recursiveGetChildById('price'):getText()) or 0
    local fee = math.max(state.minFee, math.floor(price * state.feePercent / 100))
    window:recursiveGetChildById('fee'):setText(price > 0 and string.format('Listing fee: %s (%d%%)', formatGold(fee),
        state.feePercent) or '')
end

function clearSell()
    sellPosition = nil
    local slot = window:recursiveGetChildById('sellItem')
    slot:setItem(nil)
    window:recursiveGetChildById('sellName'):setText('')
    window:recursiveGetChildById('sellDescription'):setText('')
    window:recursiveGetChildById('price'):setText('')
    updateFee()
end

function sell()
    if not sellPosition then
        setStatus('Drag an item from your backpack into the slot first.', false)
        return
    end
    local price = tonumber(window:recursiveGetChildById('price'):getText())
    if not price or price < 1 then
        setStatus('Enter a price.', false)
        return
    end
    local pos = sellPosition.pos
    send('sell', math.floor(price), pos.x, pos.y, pos.z, sellPosition.stackpos, sellPosition.clientId)
end

-- the sell slot accepts items dragged from containers or the inventory
local function onSellDrop(self, widget, mousePos)
    if not widget or not widget.getItem then
        return false
    end
    local item = widget:getItem()
    if not item or item:isStackable() then
        return false
    end
    local pos = item:getPosition()
    if not pos or pos.x ~= 65535 then
        setStatus('Drag it from your backpack or equipment.', false)
        return false
    end
    sellPosition = { pos = pos, stackpos = item:getStackPos(), clientId = item:getId() }
    local copy = Item.create(item:getId())
    copy:setTier(item:getTier())
    self:setItem(copy)
    local quality = item:getTier()
    window:recursiveGetChildById('sellName'):setText(quality > 0 and QUALITY_NAMES[quality] .. ' item' or 'Common item')
    window:recursiveGetChildById('sellName'):setColor(QUALITY_COLORS[quality] or '#cfccc7')
    window:recursiveGetChildById('sellDescription'):setText(quality > 0 and 'Set a price and list it.'
        or 'Common items trade on the market, not here.')
    setStatus('')
    return true
end

-- ---------------------------------------------------------------------------------------------
-- Show / hide

function show()
    if not window then
        return
    end
    window:show()
    window:raise()
    window:focus()
    send('open')
    showTab(state.tab)
end

function hide()
    if window then
        window:hide()
    end
end

function toggle()
    if window and window:isVisible() then
        hide()
    else
        show()
    end
end

function isVisible()
    return window and window:isVisible() or false
end

function init()
    window = g_ui.loadUI('auction', modules.game_interface.getRootPanel())
    window:hide()
    local browsePanel = window:recursiveGetChildById('browsePanel')
    fillCombo(browsePanel:getChildById('category'), CATEGORIES)
    fillCombo(browsePanel:getChildById('quality'), QUALITIES)
    fillCombo(browsePanel:getChildById('sort'), SORTS)
    window:recursiveGetChildById('sellItem').onDrop = onSellDrop
    ProtocolGame.registerExtendedOpcode(OPCODE, onMessage)
    connect(g_game, { onGameEnd = hide })
end

function terminate()
    disconnect(g_game, { onGameEnd = hide })
    ProtocolGame.unregisterExtendedOpcode(OPCODE)
    if window then
        window:destroy()
        window = nil
    end
end
