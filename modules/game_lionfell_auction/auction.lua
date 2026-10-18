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
local modifiers = nil -- the server's modifier catalogue: { name, effect, legendary }, for suggestions
local MAX_SUGGESTIONS = 7
local suggestFor = nil -- the field the suggestions belong to
local suggestPick = 0 -- the highlighted suggestion (arrow keys), 0 = none
local applying = false
local quietCombos = false -- set while the code itself changes the dropdowns (no search per change)
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

-- a long message comes in parts: "S..." starts it, "P..." continues, "E..." ends (the server's
-- LionfellSendOpcode); anything else is a whole message
local pending = nil

local function onMessage(protocol, opcode, buffer)
    local mark = buffer:sub(1, 1)
    if mark == 'S' then
        pending = { buffer:sub(2) }
        return
    elseif mark == 'P' or mark == 'E' then
        if not pending then
            return
        end
        pending[#pending + 1] = buffer:sub(2)
        if mark == 'P' then
            return
        end
        buffer = table.concat(pending)
        pending = nil
    end
    local ok, message = pcall(json.decode, buffer)
    if not ok or type(message) ~= 'table' or not window then
        return
    end
    if message.type == 'show' then
        show()
    elseif message.type == 'state' then
        state.feePercent, state.minFee = message.feePercent or 2, message.minFee or 10
        if message.lines and not modifiers then
            modifiers = {}
            local names = {}
            for _, line in ipairs(message.lines) do
                modifiers[#modifiers + 1] = { name = line.name, effect = line.text or '', legendary = line.kind == 'legendary',
                    id = line.id or '' }
                names[#names + 1] = string.format('%s%s: %s', line.name, line.kind == 'legendary' and ' (legendary)' or '',
                    line.text or '')
            end
            window:recursiveGetChildById('statLabel'):setTooltip('Type part of a name or effect, e.g. "attack", "fire", ' ..
                '"Sharp", and pick from the list. Min is the lowest value.\n\n' .. table.concat(names, '\n'))
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

local function trim(text)
    return (text:gsub('^%s+', ''):gsub('%s+$', ''))
end

-- "words:min,words:min" from the three modifier fields (words as typed: "attack", "fire", ...)
local function statFilter()
    local row = window:recursiveGetChildById('statRow')
    local parts = {}
    for i = 1, 3 do
        local words = trim(row:getChildById('stat' .. i):getText():gsub('[|:,]', ' '))
        if words ~= '' then
            local min = tonumber(row:getChildById('min' .. i):getText()) or 0
            parts[#parts + 1] = words .. ':' .. math.floor(min)
        end
    end
    return table.concat(parts, ',')
end

-- ---------------------------------------------------------------------------------------------
-- Typing suggestions: the modifiers matching what's typed so far, under the field

local function hideSuggestions()
    suggestFor, suggestPick = nil, 0
    if window then
        local box = window:getChildById('suggestions')
        box:destroyChildren()
        box:hide()
    end
end

local function highlight(index)
    local box = window:getChildById('suggestions')
    suggestPick = index
    for i, row in ipairs(box:getChildren()) do
        row:setChecked(i == index)
    end
end

-- the modifier's name goes in the field; a modifier field moves on to its "min" box
local function applySuggestion(entry)
    local field = suggestFor
    hideSuggestions()
    if not field or not entry then
        return
    end
    applying = true
    field:setText(entry.name)
    field:setCursorPos(#entry.name)
    applying = false
    local index = field:getId():match('^stat(%d)$')
    if index then
        window:recursiveGetChildById('min' .. index):focus()
    else
        browse(0)
    end
end

-- filler words in effect texts that shouldn't match ("fro" isn't looking for "from")
local FILLER = { from = true, of = true, the = true, on = true, as = true, to = true, a = true, an = true, ['and'] = true,
    when = true, with = true, you = true, your = true, by = true, ['in'] = true, is = true, ['for'] = true, at = true,
    x = true, chance = true, taken = true, drawn = true }

local function effectMatches(effect, words)
    effect = effect:lower()
    if words:find(' ', 1, true) then
        return effect:find(words, 1, true) ~= nil -- several words: as a phrase
    end
    for word in effect:gmatch('%a+') do
        if not FILLER[word] and word:sub(1, #words) == words then
            return true
        end
    end
    return false
end

-- names starting with the words first, then names containing them or effects with a word that
-- starts with them
local function matches(words)
    local first, rest = {}, {}
    for _, entry in ipairs(modifiers or {}) do
        local name = entry.name:lower()
        if name:sub(1, #words) == words or name:find(' ' .. words, 1, true) then
            first[#first + 1] = entry
        elseif name:find(words, 1, true) or effectMatches(entry.effect, words) then
            rest[#rest + 1] = entry
        end
    end
    local list = {}
    for _, group in ipairs({ first, rest }) do
        for _, entry in ipairs(group) do
            if #list < MAX_SUGGESTIONS then
                list[#list + 1] = entry
            end
        end
    end
    return list, #first + #rest
end

function suggest(field)
    if applying or not window or not field:isFocused() then
        return
    end
    local words = trim(field:getText()):lower()
    if words == '' or not modifiers then
        hideSuggestions()
        return
    end
    local list, total = matches(words)
    if #list == 0 then
        hideSuggestions()
        return
    end
    local box = window:getChildById('suggestions')
    box:destroyChildren()
    for _, entry in ipairs(list) do
        local row = g_ui.createWidget('AuctionSuggestion', box)
        row.name:setText(entry.name .. (entry.legendary and '  (legendary)' or ''))
        row.name:setColor(entry.legendary and QUALITY_COLORS[4] or '#e7e5e2')
        local effect = entry.effect
        row.effect:setText(#effect > 34 and (effect:sub(1, 33) .. '...') or effect)
        row.onMousePress = function()
            applySuggestion(entry)
            return true
        end
    end
    if total > #list then
        local more = g_ui.createWidget('LfMuted', box)
        more:setText(string.format('  %d more - keep typing', total - #list))
        more:setHeight(22)
    end
    suggestFor, suggestPick = field, 0
    local pos = field:getPosition()
    box:setWidth(math.max(380, field:getWidth()))
    box:setPosition({ x = pos.x, y = pos.y + field:getHeight() + 2 })
    box:show()
    box:raise()
end

-- Enter searches (or takes the highlighted suggestion), arrow keys walk the suggestions, Escape
-- closes them. (Text fields have no Enter event of their own.)
local function onFieldKey(field, keyCode)
    if keyCode == KeyEnter then
        onFieldEnter(field)
        return true
    end
    if suggestFor ~= field then
        return false
    end
    local box = window:getChildById('suggestions')
    local count = 0
    for _, row in ipairs(box:getChildren()) do
        if row.name then
            count = count + 1
        end
    end
    if keyCode == KeyDown then
        highlight(suggestPick % count + 1)
        return true
    elseif keyCode == KeyUp then
        highlight(suggestPick <= 1 and count or suggestPick - 1)
        return true
    elseif keyCode == KeyEscape then
        hideSuggestions()
        return true
    end
    return false
end

-- Enter: takes the highlighted suggestion, otherwise searches with what's typed
function onFieldEnter(field)
    if not field then
        return
    end
    if suggestFor == field and suggestPick > 0 then
        local row = window:getChildById('suggestions'):getChildByIndex(suggestPick)
        if row and row.onMousePress then
            row.onMousePress()
            return
        end
    end
    hideSuggestions()
    browse(0)
end

function browse(page)
    local panel = window:recursiveGetChildById('browsePanel')
    hideSuggestions()
    local search = trim(panel:getChildById('search'):getText():gsub('|', ''))
    send('browse', comboValue(panel:getChildById('category'), CATEGORIES), comboValue(panel:getChildById('quality'), QUALITIES),
        search, comboValue(panel:getChildById('sort'), SORTS), page or 0, statFilter())
end

-- back to every listing: clears the search, filters and modifiers
function reset()
    hideSuggestions()
    quietCombos = true
    local panel = window:recursiveGetChildById('browsePanel')
    panel:getChildById('search'):setText('')
    panel:getChildById('category'):setCurrentOption(CATEGORIES[1][1])
    panel:getChildById('quality'):setCurrentOption(QUALITIES[1][1])
    panel:getChildById('sort'):setCurrentOption(SORTS[1][1])
    local row = panel:getChildById('statRow')
    for i = 1, 3 do
        row:getChildById('stat' .. i):setText('')
        row:getChildById('min' .. i):setText('')
    end
    quietCombos = false
    setStatus('')
    browse(0)
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

-- the sell form's price box (listing rows have "price" labels too, so not a recursive lookup)
local function sellPriceField()
    return window:recursiveGetChildById('sellPanel'):getChildById('price')
end

function updateFee()
    local price = tonumber(sellPriceField():getText()) or 0
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
    sellPriceField():setText('')
    updateFee()
end

-- Reset button on the sell tab
function resetSell()
    clearSell()
    setStatus('')
end

function sell()
    if not sellPosition then
        setStatus('Drag an item from your backpack into the slot first.', false)
        return
    end
    local price = tonumber(sellPriceField():getText())
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
    hideSuggestions()
    if window then
        clearSell() -- closing gives the item back: nothing stays in the sell slot
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
    -- picking a category, quality or order searches right away
    for _, id in ipairs({ 'category', 'quality', 'sort' }) do
        browsePanel:getChildById(id).onOptionChange = function()
            if not quietCombos and window:isVisible() then
                browse(0)
            end
        end
    end
    window:recursiveGetChildById('sellItem').onDrop = onSellDrop
    -- arrow keys / Escape for the suggestions; leaving a field closes them
    local fields = { browsePanel:getChildById('search') }
    for i = 1, 3 do
        fields[#fields + 1] = browsePanel:recursiveGetChildById('stat' .. i)
    end
    for i = 1, 3 do
        browsePanel:recursiveGetChildById('min' .. i).onKeyDown = function(self, keyCode)
            if keyCode == KeyEnter then
                browse(0)
                return true
            end
            return false
        end
    end
    for _, field in ipairs(fields) do
        field.onKeyDown = onFieldKey
        field.onFocusChange = function(self, focused)
            if not focused and suggestFor == self then
                hideSuggestions()
            end
        end
    end
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
