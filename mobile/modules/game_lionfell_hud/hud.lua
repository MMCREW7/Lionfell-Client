-- Lionfell phone HUD (mobile/modules: on phones it replaces the PC game_lionfell_hud, so PC
-- interface changes never reach it). Landscape layout for thumbs:
--   top left      name, level, health and mana
--   top right     the menu button (three bars): a sheet with every window as a large tile;
--                 a window opened from it slides in on the right (the stock right column)
--   under it      tap modes for the map: LOOK, USE, FOLLOW (stock game_shortcuts), CHAT
--   bottom left   the stock joystick (game_joystick)
--   bottom right  ATTACK (next monster, nearest first) and six skill buttons: action bar 1,
--                 slots 1-6 (tap = use it, long press = a phone picker: spells, or items from the
--                 open bags on target / self / aim; saved in action bar 1, so PC sees it too)

local hud, status, sheet, tiles, drawerClose, actions, modes
local refreshEvent
local skillButtons = {}
local active = false

local DRAWER_WIDTH = 270
-- map zoom in tiles across the short side (PC HUD: 11-19); phones start a little further out
local MIN_ZOOM, MAX_ZOOM, DEFAULT_ZOOM = 11, 19, 15
local ZOOM_SETTING = 'lionfellMobileZoom'
local LONG_PRESS_MS = 450
local SKILL_SLOTS = 6

local function callModule(name, fn, ...)
    local module = modules[name]
    if module and type(module[fn]) == 'function' then
        return module[fn](...)
    end
end

-- ---------------------------------------------------------------------------------------------
-- Drawer: the stock right column, shown on the right edge when a window is opened

local function showDrawer(show)
    local rightPanel = modules.game_interface.getRightPanel()
    rightPanel:setVisible(show)
    drawerClose:setVisible(show)
    modes:setVisible(not show) -- the tap-mode buttons sit where the drawer opens
    if show then
        rightPanel:raise()
        drawerClose:raise()
    end
end

-- ---------------------------------------------------------------------------------------------
-- Sheet

-- windows that open in the drawer: one at a time (the others in the column are hidden, not
-- closed, so nothing about their saved PC state changes)
local function drawerWindow(get)
    return function()
        local ok, widget = pcall(get)
        if not ok or not widget or widget:isDestroyed() then
            return
        end
        local rightPanel = modules.game_interface.getRightPanel()
        if widget:getParent() ~= rightPanel then
            widget:setParent(rightPanel)
        end
        for _, child in ipairs(rightPanel:getChildren()) do
            child:setVisible(child == widget)
        end
        widget:show()
        if widget.open then
            widget:open(true)
        end
        showDrawer(true)
        -- the whole drawer height (mini windows open at their short default height)
        if widget.setContentMaximumHeight then
            widget:setContentMaximumHeight(rightPanel:getHeight())
        end
        widget:setHeight(rightPanel:getHeight() - 8)
    end
end

local MENU = {
    { key = 'INV', label = 'Inventory', run = drawerWindow(function() return modules.game_inventory.inventoryController.ui end) },
    { key = 'BAG', label = 'Bags', run = function() callModule('game_lionfell_bags', 'toggle') end },
    { key = 'MAP', label = 'Map', run = drawerWindow(function() return modules.game_minimap.mapController.ui end) },
    { key = 'SKL', label = 'Skills', run = drawerWindow(function() return modules.game_skills.skillsWindow end) },
    { key = 'BTL', label = 'Battle', run = drawerWindow(function() return rootWidget:recursiveGetChildById('battleWindow') end) },
    { key = 'LT', label = 'Auto loot', run = function() callModule('game_lionfell_loot', 'toggle') end },
    { key = 'TAL', label = 'Talents', run = function() callModule('game_lionfell_talents', 'toggle') end },
    { key = 'AH', label = 'Auction', run = function() callModule('game_lionfell_auction', 'toggle') end },
    { key = 'SPL', label = 'Spells', run = function() callModule('game_spelllist', 'toggle') end },
    { key = 'QST', label = 'Quests', run = function() callModule('game_questlog', 'show') end },
    { key = 'VIP', label = 'Friends', run = drawerWindow(function() return modules.game_viplist.vipWindow end) },
    { key = 'CHT', label = 'Chat', run = function() toggleChat() end },
    { key = 'OPT', label = 'Options', run = function() callModule('client_options', 'toggle') end },
    { key = 'SIZ', label = 'Interface size', run = function() cycleSize() end, keepOpen = true },
    { key = 'OUT', label = 'Log out', run = function() callModule('game_interface', 'tryLogout') end },
}

local SIZE_ORDER = { 'small', 'medium', 'large' }

function cycleSize()
    local mobile = modules.client_lionfell_mobile
    if not mobile then
        return
    end
    local current = mobile.getSize()
    for i, size in ipairs(SIZE_ORDER) do
        if size == current then
            mobile.setSize(SIZE_ORDER[i % #SIZE_ORDER + 1])
            break
        end
    end
    refreshSizeTile()
end

function refreshSizeTile()
    local tile = tiles and tiles:getChildById('tile_SIZ')
    local mobile = modules.client_lionfell_mobile
    if tile and mobile then
        tile:getChildById('label'):setText('Size: ' .. mobile.getSize())
    end
end

local function showSheet(show)
    sheet:setVisible(show)
    -- the joystick is its own overlay above the game: out of the way while the sheet is open
    callModule('game_joystick', show and 'hide' or 'show')
    if show then
        refreshSizeTile()
        sheet:raise()
        sheet:focus()
    end
end

local function buildSheet()
    tiles:destroyChildren()
    for _, entry in ipairs(MENU) do
        local tile = g_ui.createWidget('LfMenuTile', tiles)
        tile:setId('tile_' .. entry.key)
        tile:getChildById('key'):setText(entry.key)
        tile:getChildById('label'):setText(entry.label)
        tile.onClick = function()
            if not entry.keepOpen then
                showSheet(false)
            end
            entry.run()
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Chat: the stock console, as a panel over the bottom left (hidden until asked for)

function toggleChat()
    local chat = modules.game_interface.getBottomPanel()
    local show = not chat:isVisible()
    chat:setVisible(show)
    if show then
        chat:raise()
    end
    local button = modes and modes:getChildById('mode_chat')
    if button then
        button:setChecked(show)
    end
end

-- ---------------------------------------------------------------------------------------------
-- Status

local function setBar(bar, percent, color)
    local fill = bar:getChildById('fill')
    fill:setBackgroundColor(color)
    fill:setWidth(math.floor(bar:getWidth() * math.max(0, math.min(1, percent))))
end

local function refreshStatus()
    local player = g_game.getLocalPlayer()
    if not player or not status then
        return
    end
    status:getChildById('name'):setText(player:getName())
    status:getChildById('level'):setText('Lv ' .. player:getLevel())
    local maxHealth, maxMana = player:getMaxHealth(), player:getMaxMana()
    setBar(status:getChildById('hp'), maxHealth > 0 and player:getHealth() / maxHealth or 0, '#c95d4f')
    setBar(status:getChildById('mp'), maxMana > 0 and player:getMana() / maxMana or 0, '#5b7fbf')
end

-- ---------------------------------------------------------------------------------------------
-- Attack: the next monster on screen, nearest first (tap again for the one after)

local function distance(a, b)
    return math.max(math.abs(a.x - b.x), math.abs(a.y - b.y))
end

local function attackNext()
    local player = g_game.getLocalPlayer()
    if not player then
        return
    end
    local here = player:getPosition()
    local list = {}
    for _, creature in ipairs(g_map.getSpectators(here, false)) do
        local pos = creature:getPosition()
        if creature:isMonster() and creature:getHealthPercent() > 0 and pos.z == here.z then
            list[#list + 1] = creature
        end
    end
    if #list == 0 then
        return
    end
    table.sort(list, function(a, b) return distance(here, a:getPosition()) < distance(here, b:getPosition()) end)
    local index = 1
    local current = g_game.getAttackingCreature()
    if current then
        for i, creature in ipairs(list) do
            if creature:getId() == current:getId() then
                index = i % #list + 1
                break
            end
        end
    end
    g_game.attack(list[index])
end

-- ---------------------------------------------------------------------------------------------
-- Skill buttons: mirrors of action bar 1, slots 1-6

local function barButton(slot)
    local bars = modules.game_actionbar and modules.game_actionbar.actionBars
    local bar = bars and bars[1]
    return bar and bar.tabBar and bar.tabBar:getChildById('1.' .. slot)
end

local function refreshSkills()
    for slot, button in ipairs(skillButtons) do
        local real = barButton(slot)
        local item, icon, shade = button:getChildById('item'), button:getChildById('icon'), button:getChildById('shade')
        local realItem = real and real:getChildById('item')
        if realItem then
            item:setItemId(realItem:getItemId())
            -- spells draw their icon on the slot item's "text" child (game_actionbar updateButton)
            local text = realItem:getChildById('text')
            local source = text and text:getImageSource() or ''
            if source ~= '' and realItem:getItemId() == 0 then
                icon:setImageSource(source)
                icon:setImageClip(text:getImageClip())
            else
                icon:setImageSource('')
            end
            local cooldown = real:getChildById('cooldown')
            shade:setVisible(cooldown and cooldown:isVisible() or false)
        else
            item:setItemId(0)
            icon:setImageSource('')
            shade:setVisible(false)
        end
    end
end

local function buildSkills()
    for _, button in ipairs(skillButtons) do
        button:destroy()
    end
    skillButtons = {}
    -- an arc around ATTACK (its centre: 46 px in from the panel's bottom-right corner)
    local cx, cy = actions:getWidth() - 46, actions:getHeight() - 46
    -- { distance from the centre, angle }: an inner ring of four (30 degrees apart: 62 px between
    -- 56 px buttons), two more further out between them
    local places = { { 118, 180 }, { 118, 210 }, { 118, 240 }, { 118, 270 }, { 190, 202 }, { 190, 248 } }
    for slot = 1, SKILL_SLOTS do
        local button = g_ui.createWidget('LfSkillSlot', actions)
        button:setId('skill' .. slot)
        local radius, angle = places[slot][1], math.rad(places[slot][2])
        button:addAnchor(AnchorLeft, 'parent', AnchorLeft)
        button:addAnchor(AnchorTop, 'parent', AnchorTop)
        button:setMarginLeft(math.floor(cx + radius * math.cos(angle) - 28))
        button:setMarginTop(math.floor(cy + radius * math.sin(angle) - 28))
        button.onMousePress = function(self, pos, mouseButton)
            self.pressedAt = g_clock.millis()
            return true
        end
        button.onMouseRelease = function(self, pos, mouseButton)
            local real = barButton(slot)
            local held = g_clock.millis() - (self.pressedAt or g_clock.millis())
            self.pressedAt = nil
            if held >= LONG_PRESS_MS or mouseButton == MouseRightButton then
                showAssign(true, slot) -- the phone picker (saves into action bar 1)
            elseif real and modules.game_actionbar.onExecuteAction then
                modules.game_actionbar.onExecuteAction(real, false)
            end
            return true
        end
        skillButtons[slot] = button
    end
    refreshSkills()
end

-- ---------------------------------------------------------------------------------------------
-- Assign (long press on a skill button): a phone-sized picker that saves into action bar 1
-- through the action bar's own storage (game_actionbar ApiJson), exactly as its PC menus do

local assignSheet, assignList, assignModes
local assignSlot, assignTab = nil, 'spells'

local function actionbar()
    return modules.game_actionbar
end

local function saveAndRefresh(slot)
    local ab = actionbar()
    local real = barButton(slot)
    if ab and real and ab.updateButton then
        ab.updateButton(real)
    end
    showAssign(false)
    scheduleEvent(refreshSkills, 100)
end

local function assignSpellWords(slot, words)
    local ab = actionbar()
    if ab and ab.ApiJson then
        ab.ApiJson.createOrUpdateText(1, slot, words, true)
        saveAndRefresh(slot)
    end
end

local function assignItem(slot, itemId, useType)
    local ab = actionbar()
    if ab and ab.ApiJson then
        ab.ApiJson.createOrUpdateAction(1, slot, useType, itemId, 0)
        saveAndRefresh(slot)
    end
end

local function clearSlot(slot)
    local ab = actionbar()
    if ab and ab.ApiJson then
        ab.ApiJson.removeAction(1, slot)
        saveAndRefresh(slot)
    end
end

local function playerSpells()
    local player = g_game.getLocalPlayer()
    local spells = modules.gamelib and modules.gamelib.SpellInfo and modules.gamelib.SpellInfo['Default'] or SpellInfo['Default']
    local vocation = translateVocation and translateVocation(player:getVocation()) or player:getVocation()
    local list = {}
    for name, spell in pairs(spells or {}) do
        if vocation == 0 or table.contains(spell.vocations or {}, vocation) then
            list[#list + 1] = { name = name, spell = spell }
        end
    end
    table.sort(list, function(a, b)
        if (a.spell.level or 0) ~= (b.spell.level or 0) then
            return (a.spell.level or 0) < (b.spell.level or 0)
        end
        return a.name < b.name
    end)
    return list
end

-- items in the open bags (one tile per kind)
local function bagItems()
    local seen, list = {}, {}
    for _, container in pairs(g_game.getContainers()) do
        for _, item in ipairs(container:getItems()) do
            local id = item:getId()
            if not seen[id] and not item:isContainer() then
                seen[id] = true
                list[#list + 1] = item
            end
        end
    end
    return list
end

local function showModes(item)
    assignModes:destroyChildren()
    assignModes:setVisible(true)
    local ab = actionbar()
    local types = ab and ab.UseTypes or UseTypes
    local choices
    if item:isMultiUse() then
        choices = { { 'On target', types.UseOnTarget }, { 'On self', types.UseOnYourself }, { 'Aim', types.SelectUseTarget } }
    else
        choices = { { 'Use', types.Use } }
    end
    for _, choice in ipairs(choices) do
        local button = g_ui.createWidget('LfPrimaryButton', assignModes)
        button:setText(choice[1])
        button:setWidth(150)
        button.onClick = function() assignItem(assignSlot, item:getId(), choice[2]) end
    end
end

local function fillAssign()
    assignList:destroyChildren()
    assignModes:setVisible(false)
    assignSheet:getChildById('tabSpells'):setOn(assignTab == 'spells')
    assignSheet:getChildById('tabItems'):setOn(assignTab == 'items')
    local player = g_game.getLocalPlayer()
    if assignTab == 'spells' then
        local settings = SpelllistSettings and SpelllistSettings['Default']
        for _, entry in ipairs(playerSpells()) do
            local tile = g_ui.createWidget('LfAssignTile', assignList)
            local spell = entry.spell
            tile:getChildById('name'):setText(entry.name)
            tile:getChildById('sub'):setText(spell.words .. '   lvl ' .. (spell.level or 0))
            if settings and Spells and spell.clientId and spell.clientId > 0 then
                local icon = tile:getChildById('icon')
                icon:setImageSource(settings.iconFile)
                icon:setImageClip(Spells.getImageClip(spell.clientId, 'Default'))
            end
            tile:setEnabled((spell.level or 0) <= player:getLevel())
            tile.onClick = function() assignSpellWords(assignSlot, spell.words) end
        end
    else
        local items = bagItems()
        for _, item in ipairs(items) do
            local tile = g_ui.createWidget('LfAssignTile', assignList)
            tile:getChildById('item'):setItemId(item:getId())
            local name = item.getName and item:getName() or nil
            if not name or name == '' then
                local thing = g_things.getThingType(item:getId(), ThingCategoryItem)
                name = thing and thing:getName() or ''
                if name == '' then
                    local market = thing and thing:getMarketData()
                    name = market and market.name ~= '' and market.name or ('item ' .. item:getId())
                end
            end
            tile:getChildById('name'):setText(name)
            tile:getChildById('sub'):setText(item:isMultiUse() and 'on target / self / aim' or 'use')
            tile.onClick = function()
                for _, other in ipairs(assignList:getChildren()) do
                    other:setChecked(other == tile)
                end
                showModes(item)
            end
        end
        if #items == 0 then
            -- nothing open yet: open the backpack and list it once it arrives
            local player = g_game.getLocalPlayer()
            local backpack = player and player:getInventoryItem(InventorySlotBack)
            assignSheet.waits = (assignSheet.waits or 0) + 1
            if backpack and assignSheet.waits == 1 then
                g_game.open(backpack)
            end
            if assignSheet.waits == 1 then
                assignSheet.openedBags = not callModule('game_lionfell_bags', 'isVisible')
            end
            if backpack and assignSheet.waits <= 6 then
                scheduleEvent(function()
                    if assignSheet:isVisible() and assignTab == 'items' then
                        fillAssign()
                    end
                end, 500)
            end
            local note = g_ui.createWidget('LfMuted', assignList)
            note:setText(backpack and 'Opening the backpack ...' or 'No backpack.')
        end
    end
end

function showAssign(show, slot)
    if show then
        assignSlot = slot
        assignSheet.waits = 0
        -- on the top layer: windows that open meanwhile (the bags, for the item list) stay under it
        if assignSheet:getParent() ~= rootWidget then
            assignSheet:setParent(rootWidget)
        end
        assignSheet:getChildById('assignTitle'):setText('Skill button ' .. slot)
        fillAssign()
        assignSheet:show()
        assignSheet:raise()
        assignSheet:focus()
        callModule('game_joystick', 'hide')
    else
        assignSheet:hide()
        if assignSheet.openedBags then
            assignSheet.openedBags = nil
            callModule('game_lionfell_bags', 'hide') -- opened only for the item list
        end
        callModule('game_joystick', 'show')
    end
end

local function setupAssign()
    assignSheet = hud:getChildById('assign')
    assignList = assignSheet:getChildById('assignList')
    assignModes = assignSheet:getChildById('assignModes')
    assignSheet:getChildById('assignClose').onClick = function() showAssign(false) end
    assignSheet:getChildById('tabSpells').onClick = function() assignTab = 'spells'; fillAssign() end
    assignSheet:getChildById('tabItems').onClick = function() assignTab = 'items'; fillAssign() end
    assignSheet:getChildById('assignClear').onClick = function() clearSlot(assignSlot) end
end

-- ---------------------------------------------------------------------------------------------
-- Tap modes: LOOK / USE / FOLLOW change what a tap on the map does (stock game_shortcuts)

local MODES = { { 'look', 'LOOK' }, { 'use', 'USE' }, { 'follow', 'FOLLOW' } }

local function stockShortcut(id)
    local panel = callModule('game_shortcuts', 'getPanel')
    return panel and panel.shortcutIcons and panel.shortcutIcons:getChildById(id)
end

local function refreshModes()
    local current = callModule('game_shortcuts', 'getShortcut') or ''
    for _, mode in ipairs(MODES) do
        local button = modes:getChildById('mode_' .. mode[1])
        if button then
            button:setChecked(current == mode[1])
        end
    end
end

local function buildModes()
    modes:destroyChildren()
    for _, mode in ipairs(MODES) do
        local button = g_ui.createWidget('LfModeButton', modes)
        button:setId('mode_' .. mode[1])
        button:setText(mode[2])
        button.onClick = function()
            local stock = stockShortcut(mode[1])
            if stock and stock.onClick then
                stock.onClick()
            end
            refreshModes()
        end
    end
    local chat = g_ui.createWidget('LfModeButton', modes)
    chat:setId('mode_chat')
    chat:setText('CHAT')
    chat.onClick = toggleChat
end

-- ---------------------------------------------------------------------------------------------
-- Layout

local function hideWidget(widget)
    if widget then
        widget:setVisible(false)
    end
end

local function applyLayout()
    local gi = modules.game_interface
    local root = gi.getRootPanel()
    hud:show()
    hud:raise()
    callModule('client_topmenu', 'hide')

    -- the map fills the screen: the stock extended view (mode 2), as the PC HUD uses; this runs
    -- again from onViewModeChange once it is set
    if gi.currentViewMode ~= 2 then
        gi.setupViewMode(2)
        return
    end
    local map = gi.getMapPanel()
    map:setLimitVisibleRange(false)
    map:setKeepAspectRatio(false)
    map:setMaxZoomIn(MIN_ZOOM)
    map:setMaxZoomOut(MAX_ZOOM)
    map:setZoom(math.max(MIN_ZOOM, math.min(MAX_ZOOM, g_settings.getNumber(ZOOM_SETTING, DEFAULT_ZOOM))))
    for _, id in ipairs({ 'bottomSplitter', 'lockPanel', 'gameTopPanel', 'gameBottomStatsBarPanel' }) do
        hideWidget(root:getChildById(id))
    end
    hideWidget(gi.getLeftPanel())
    hideWidget(gi.getBottomActionPanel())
    local healthInfo = modules.game_healthinfo and modules.game_healthinfo.healthManaController
    hideWidget(healthInfo and healthInfo.ui)
    hideWidget(modules.game_cooldown and modules.game_cooldown.cooldownWindow)
    callModule('game_shortcuts', 'hide') -- its tap modes stay: the MODES buttons drive them
    hideWidget(root:recursiveGetChildById('showTopMenuButton')) -- the phone menu replaces it

    -- the right column becomes the drawer; the small top-right panel's windows join it
    local rightPanel = gi.getRightPanel()
    local mainRightPanel = gi.getMainRightPanel()
    for _, child in ipairs(mainRightPanel:getChildren()) do
        child:setParent(rightPanel)
    end
    mainRightPanel:setHeight(0)
    rightPanel:breakAnchors()
    rightPanel:addAnchor(AnchorTop, 'parent', AnchorTop)
    rightPanel:addAnchor(AnchorBottom, 'parent', AnchorBottom)
    rightPanel:addAnchor(AnchorRight, 'parent', AnchorRight)
    rightPanel:setWidth(DRAWER_WIDTH)
    rightPanel:setMarginTop(0)
    rightPanel:setMarginRight(0)
    rightPanel:setImageSource('/images/lionfell/panel')
    rightPanel:setImageBorder(6)
    showDrawer(false)

    -- chat: over the bottom left, above the joystick, hidden until CHAT
    local chat = gi.getBottomPanel()
    chat:breakAnchors()
    chat:addAnchor(AnchorLeft, 'parent', AnchorLeft)
    chat:addAnchor(AnchorTop, 'parent', AnchorTop)
    chat:setMarginLeft(10)
    chat:setMarginTop(94)
    chat:setSize({ width = 520, height = 220 })
    chat:setImageSource('/images/lionfell/panel')
    chat:setImageBorder(6)
    chat:setVisible(false)

    -- the stock health/mana circles around the character: the status card shows both; off once
    -- (the player can turn them back on in the options)
    if not g_settings.getBoolean('lionfellMobileCirclesOff') then
        callModule('game_healthcircle', 'setHealthCircle', false)
        callModule('game_healthcircle', 'setManaCircle', false)
        g_settings.set('lionfellMobileCirclesOff', true)
    end

    buildSkills()
    refreshStatus()
    refreshModes()
end

local function onGameStart()
    active = true
    -- after the stock interface has set itself up for the game
    scheduleEvent(applyLayout, 100)
    removeEvent(refreshEvent)
    refreshEvent = cycleEvent(function()
        refreshSkills()
        refreshModes()
    end, 300)
end

local function onGameEnd()
    active = false
    removeEvent(refreshEvent)
    refreshEvent = nil
    showSheet(false)
    hud:hide()
end

function openMenu()
    showSheet(true)
end

function closeMenu()
    showSheet(false)
end

-- the console and game_interface call these on the PC HUD
function isActive()
    return false -- the phone keeps the stock chat styling
end

function styleChatNow()
end

function onViewModeChange(mode)
    if active and g_game.isOnline() then
        scheduleEvent(applyLayout, 100) -- back to mode 2 if something switched away
    end
end

function init()
    hud = g_ui.loadUI('hud', modules.game_interface.getRootPanel())
    hud:hide()
    status = hud:getChildById('status')
    sheet = hud:getChildById('sheet')
    tiles = sheet:getChildById('tiles')
    actions = hud:getChildById('actions')
    modes = hud:getChildById('modes')

    hud:getChildById('menuButton').onClick = function() showSheet(true) end
    sheet:getChildById('sheetClose').onClick = function() showSheet(false) end
    actions:getChildById('attack').onClick = attackNext

    drawerClose = g_ui.createWidget('LfRoundButton', hud)
    drawerClose:setText('X')
    drawerClose:addAnchor(AnchorTop, 'parent', AnchorTop)
    drawerClose:addAnchor(AnchorRight, 'parent', AnchorRight)
    drawerClose:setMarginTop(10)
    drawerClose:setMarginRight(DRAWER_WIDTH + 8)
    drawerClose:setVisible(false)
    drawerClose.onClick = function() showDrawer(false) end

    buildSheet()
    buildModes()
    setupAssign()

    connect(g_game, { onGameStart = onGameStart, onGameEnd = onGameEnd })
    connect(LocalPlayer, {
        onHealthChange = refreshStatus,
        onManaChange = refreshStatus,
        onLevelChange = refreshStatus
    })
    if g_game.isOnline() then
        onGameStart()
    end
end

function terminate()
    removeEvent(refreshEvent)
    disconnect(g_game, { onGameStart = onGameStart, onGameEnd = onGameEnd })
    disconnect(LocalPlayer, {
        onHealthChange = refreshStatus,
        onManaChange = refreshStatus,
        onLevelChange = refreshStatus
    })
    if assignSheet and assignSheet:getParent() == rootWidget then
        assignSheet:destroy() -- moved out of the HUD (top layer)
    end
    if hud then
        hud:destroy()
        hud = nil
    end
end
