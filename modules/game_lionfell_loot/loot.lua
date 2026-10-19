-- Lionfell auto loot settings. The server picks up what the player wants from their kills
-- (data/scripts/lionfell/lf_autoloot.lua) and keeps the settings; this window edits them.
-- Items go on the "always" / "never" lists from the right-click menu of any item.
--
-- Opcode 123: send "get" or "set|enabled|gold|quality|supplies|stackables|other|always|never"
-- (lists: client ids joined with ","); the server answers with the current "set|..." line.

local OPCODE = 123
local QUALITIES = { { -1, 'Off' }, { 0, 'Common' }, { 1, 'Uncommon' }, { 2, 'Rare' }, { 3, 'Epic' }, { 4, 'Legendary' } }
-- valuables: anything that isn't gear and an NPC pays at least this much for (gems, scales, ...)
local VALUES = { { 0, 'Off' }, { 25, '25' }, { 50, '50' }, { 100, '100' }, { 250, '250' }, { 1000, '1000' } }

window = nil
local state = { enabled = true, gold = true, quality = 0, supplies = true, stackables = false, other = false,
    always = {}, never = {}, valuables = 50 }
local sendEvent
local MENU_CATEGORY = 'lionfellLoot'

local function send(text)
    local protocol = g_game.getProtocolGame()
    if protocol then
        protocol:sendExtendedOpcode(OPCODE, text)
    end
end

local function listText(list)
    local ids = {}
    for id in pairs(list) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    return table.concat(ids, ',')
end

local function encode()
    return table.concat({ 'set', state.enabled and 1 or 0, state.gold and 1 or 0, state.quality,
        state.supplies and 1 or 0, state.stackables and 1 or 0, state.other and 1 or 0,
        listText(state.always), listText(state.never), state.valuables }, '|')
end

local function parseList(text)
    local list = {}
    for id in (text or ''):gmatch('%d+') do
        list[tonumber(id)] = true
    end
    return list
end

-- changes go to the server a moment after the last click (it rate-limits requests)
local function save()
    if sendEvent then
        removeEvent(sendEvent)
    end
    sendEvent = scheduleEvent(function()
        sendEvent = nil
        send(encode())
    end, 300)
end

local function itemName(clientId)
    local item = Item.create(clientId)
    local data = item and item:getMarketData()
    if data and data.name and data.name ~= '' then
        return data.name
    end
    return tr('item %d', clientId)
end

-- ---------------------------------------------------------------------------------------------
-- Window

local function refreshList(listId, hintId, list)
    local panel = window:recursiveGetChildById(listId)
    local hint = window:recursiveGetChildById(hintId)
    panel:destroyChildren()
    local ids = {}
    for id in pairs(list) do
        ids[#ids + 1] = id
    end
    table.sort(ids, function(a, b) return itemName(a) < itemName(b) end)
    hint:setVisible(#ids == 0)
    for _, id in ipairs(ids) do
        local cell = g_ui.createWidget('LfLootItem', panel)
        cell:setItemId(id)
        cell:setTooltip(tr('%s (right-click to remove)', itemName(id)))
        cell.onMouseRelease = function(widget, mousePos, mouseButton)
            if mouseButton == MouseRightButton then
                list[id] = nil
                save()
                refreshList(listId, hintId, list)
                return true
            end
        end
    end
end

local function refresh()
    if not window then
        return
    end
    for _, id in ipairs({ 'enabled', 'gold', 'supplies', 'stackables', 'other' }) do
        local box = window:recursiveGetChildById(id)
        box.lfUpdating = true
        box:setChecked(state[id])
        box.lfUpdating = nil
    end
    for _, segment in ipairs(window:recursiveGetChildById('quality'):getChildren()) do
        segment:setOn(segment.quality == state.quality)
    end
    for _, segment in ipairs(window:recursiveGetChildById('valuables'):getChildren()) do
        segment:setOn(segment.value == state.valuables)
    end
    refreshList('always', 'alwaysHint', state.always)
    refreshList('never', 'neverHint', state.never)
end

function show()
    if not window or not g_game.isOnline() then
        return
    end
    refresh()
    window:show()
    window:raise()
    window:focus()
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

-- ---------------------------------------------------------------------------------------------
-- Lists from the right-click menu

local function menuItem(lookThing, useThing)
    local thing = useThing or lookThing
    if thing and thing:isItem() and thing:isPickupable() then
        return thing
    end
end

local function addTo(listName, item)
    local id = item:getId()
    state.always[id], state.never[id] = nil, nil
    state[listName][id] = true
    save()
    refresh()
    modules.game_textmessage.displayStatusMessage(listName == 'always'
        and tr('Auto loot: always picking up %s.', itemName(id))
        or tr('Auto loot: never picking up %s.', itemName(id)))
end

local function addMenuHooks()
    local hook = modules.game_interface.addMenuHook
    hook(MENU_CATEGORY, tr('Always pick up'), function(_, lookThing, useThing)
        addTo('always', menuItem(lookThing, useThing))
    end, function(_, lookThing, useThing)
        local item = menuItem(lookThing, useThing)
        return item ~= nil and not state.always[item:getId()]
    end)
    hook(MENU_CATEGORY, tr('Never pick up'), function(_, lookThing, useThing)
        addTo('never', menuItem(lookThing, useThing))
    end, function(_, lookThing, useThing)
        local item = menuItem(lookThing, useThing)
        return item ~= nil and not state.never[item:getId()]
    end)
    hook(MENU_CATEGORY, tr('Remove from auto loot lists'), function(_, lookThing, useThing)
        local id = menuItem(lookThing, useThing):getId()
        state.always[id], state.never[id] = nil, nil
        save()
        refresh()
    end, function(_, lookThing, useThing)
        local item = menuItem(lookThing, useThing)
        return item ~= nil and (state.always[item:getId()] or state.never[item:getId()]) ~= nil
    end)
end

-- ---------------------------------------------------------------------------------------------
-- Server

local function onMessage(protocol, opcode, buffer)
    local fields = {}
    for part in (buffer .. '|'):gmatch('([^|]*)|') do
        fields[#fields + 1] = part
    end
    if fields[1] ~= 'set' or #fields < 7 then
        return
    end
    state.enabled = fields[2] == '1'
    state.gold = fields[3] == '1'
    state.quality = tonumber(fields[4]) or 0
    state.supplies = fields[5] == '1'
    state.stackables = fields[6] == '1'
    state.other = fields[7] == '1'
    state.always = parseList(fields[8])
    state.never = parseList(fields[9])
    state.valuables = tonumber(fields[10]) or 50
    refresh()
end

local function onGameStart()
    send('get')
end

local function onGameEnd()
    hide()
end

function init()
    window = g_ui.loadUI('loot', modules.game_interface.getRootPanel())
    window:hide()
    window.onEscape = hide

    for _, id in ipairs({ 'enabled', 'gold', 'supplies', 'stackables', 'other' }) do
        window:recursiveGetChildById(id).onCheckChange = function(widget, checked)
            if widget.lfUpdating then
                return
            end
            state[id] = checked
            save()
        end
    end
    local qualityBar = window:recursiveGetChildById('quality')
    for _, entry in ipairs(QUALITIES) do
        local segment = g_ui.createWidget('LfSegment', qualityBar)
        segment:setText(tr(entry[2]))
        segment.quality = entry[1]
        segment.onClick = function()
            state.quality = entry[1]
            save()
            refresh()
        end
    end

    local valueBar = window:recursiveGetChildById('valuables')
    for _, entry in ipairs(VALUES) do
        local segment = g_ui.createWidget('LfSegment', valueBar)
        segment:setText(entry[1] == 0 and tr(entry[2]) or entry[2]) -- (tr() puts separators in numbers)
        segment.value = entry[1]
        segment.onClick = function()
            state.valuables = entry[1]
            save()
            refresh()
        end
    end

    addMenuHooks()
    ProtocolGame.registerExtendedOpcode(OPCODE, onMessage)
    connect(g_game, { onGameStart = onGameStart, onGameEnd = onGameEnd })
    if g_game.isOnline() then
        onGameStart()
    end
end

function terminate()
    disconnect(g_game, { onGameStart = onGameStart, onGameEnd = onGameEnd })
    ProtocolGame.unregisterExtendedOpcode(OPCODE)
    modules.game_interface.removeMenuHook(MENU_CATEGORY)
    if sendEvent then
        removeEvent(sendEvent)
    end
    if window then
        window:destroy()
        window = nil
    end
end
