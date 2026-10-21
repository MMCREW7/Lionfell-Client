-- Lionfell map-first HUD.
--
-- Builds on OTClient's extended view (view mode 2: map fills the window, side panels float on
-- top of it). This module adds the vitals card, the dock and the low-health vignette, re-places
-- the stock panels (minimap/battle/equipment/containers column, chat, action bar) where the
-- design puts them, and sizes the map for widescreen. Other view modes are left untouched.

local hud
local vitals
local dock
local menuBackdrop
local menuWindow
local menuOptions
local layoutSlots
local vignette
local active = false
local layoutEvent
local movedToColumn = {}
local layoutEditing = false
local toggleLayoutEditing
local openLayoutSlots

-- Zoom is the number of visible rows. The game starts fully zoomed out at 19 rows, the most the
-- server streams (Map::maxClientViewportX/Y = 18/10, data/setup.otml `viewport`: at most
-- 35 x 19 tiles); players can zoom in to the classic 11-row Tibia view and back out.
local BASE_ZOOM = 11  -- closest zoom (classic Tibia)
local MAX_ZOOM = 19   -- farthest zoom, also the default
local DEFAULT_ZOOM = MAX_ZOOM
local MAX_VISIBLE_WIDTH = 35
local ZOOM_SETTING = 'lionfell_map_zoom'
local STOCK_MAX_ZOOM_IN = 3  -- UIMap default (src/client/uimap.cpp), restored outside the HUD
local LOW_HEALTH = 0.25

local MARGIN = 24
local COLUMN_WIDTH = 260
local CHAT_SIZE = { width = 560, height = 280 }
local ACTIONBAR_WIDTH = 688  -- 12 slots at 56px pitch + 6px padding each side + 4px tab margin
local ACTIONBAR_GAP = 34      -- from the chat's right edge, as in the design
local STATUS_LINE_BOTTOM = 128  -- status text sits above the action bar

local CONDITIONS = {
    { state = PlayerStates.Haste, label = 'HASTE', color = '#a8c3a3' },
    { state = PlayerStates.Swords, label = 'BATTLE', color = '#cfccc7' },
    { state = PlayerStates.PzBlock, label = 'PZ LOCK', color = '#d9a29b' },
    { state = PlayerStates.Pz, label = 'PZ', color = '#8fb08a' },
    { state = PlayerStates.ManaShield, label = 'MANA SHIELD', color = '#a8b8cf' },
    { state = PlayerStates.Poison, label = 'POISONED', color = '#a8c3a3' },
    { state = PlayerStates.Burn, label = 'BURNING', color = '#d9a29b' },
    { state = PlayerStates.Energy, label = 'ELECTRIFIED', color = '#a8b8cf' },
    { state = PlayerStates.Bleeding, label = 'BLEEDING', color = '#d9a29b' },
    { state = PlayerStates.Paralyze, label = 'PARALYSED', color = '#d9a29b' },
    { state = PlayerStates.Drowning, label = 'DROWNING', color = '#a8b8cf' },
    { state = PlayerStates.Freezing, label = 'FREEZING', color = '#a8b8cf' },
    { state = PlayerStates.Dazzled, label = 'DAZZLED', color = '#c2a46a' },
    { state = PlayerStates.Cursed, label = 'CURSED', color = '#c2a46a' },
    { state = PlayerStates.Drunk, label = 'DRUNK', color = '#c2a46a' },
}

local function callModule(moduleName, functionName, ...)
    local module = modules[moduleName]
    if module and type(module[functionName]) == 'function' then
        return module[functionName](...)
    end
end

local function controllerVisible(moduleName, controllerName)
    local module = modules[moduleName]
    local controller = module and module[controllerName]
    return controller and controller.ui and controller.ui:isVisible() or false
end

local function windowVisible(moduleName, windowName)
    local module = modules[moduleName]
    local window = module and module[windowName]
    return window and not window:isDestroyed() and window:isVisible() or false
end

-- The menu holds the stock window toggles. The top-menu action exposes the remaining game buttons.
local DOCK = {
    { key = 'INV', order = 1, label = 'Inventory', run = function() callModule('game_inventory', 'toggle') end,
      isOn = function() return controllerVisible('game_inventory', 'inventoryController') end },
    { key = 'SKL', order = 4, label = 'Skills', run = function() callModule('game_skills', 'toggle') end,
      isOn = function() return windowVisible('game_skills', 'skillsWindow') end },
    { key = 'BTL', order = 5, label = 'Battle list', run = function() callModule('game_battle', 'toggle') end },
    { key = 'MAP', order = 7, label = 'Minimap', run = function() callModule('game_minimap', 'toggle') end,
      isOn = function() return controllerVisible('game_minimap', 'mapController') end },
    { key = 'VIP', order = 8, label = 'VIP list', run = function() callModule('game_viplist', 'toggle') end,
      isOn = function() return windowVisible('game_viplist', 'vipWindow') end },
    { key = 'QST', order = 9, label = 'Quest log', run = function() callModule('game_questlog', 'show') end },
    { key = 'SPL', order = 10, label = 'Spell list', run = function() callModule('game_spelllist', 'toggle') end },
    { key = 'LAY', order = 13, label = 'Edit layout: move the HUD panels', menuLabel = 'Edit layout', run = function() toggleLayoutEditing() end,
      isOn = function() return layoutEditing end },
    { key = 'LAYOUTS', order = 14, label = 'Save or load a layout', menuLabel = 'Saved layouts', run = function() openLayoutSlots() end },
    { key = 'OPT', order = 15, label = 'Options', run = function() callModule('client_options', 'toggle') end },
    { key = 'MNU', order = 16, label = 'Show / hide the top menu', menuLabel = 'Top menu', run = function() callModule('client_topmenu', 'toggle') end,
      isOn = function()
          local topMenu = callModule('client_topmenu', 'getTopMenu')
          return topMenu and topMenu:isVisible() or false
      end },
    { key = 'LOG', order = 17, label = 'Logout', run = function() callModule('game_interface', 'tryLogout') end },
}
local registeredMenuActions = {}

local function formatNumber(value)
    local text = tostring(math.floor(value or 0))
    local formatted = text:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    return (formatted:gsub('^,', ''))
end

local function formatRate(perHour)
    if perHour >= 1000000 then
        return string.format('%.1fM xp/h', perHour / 1000000)
    elseif perHour >= 1000 then
        return string.format('%.0fk xp/h', perHour / 1000)
    end
    return string.format('%d xp/h', perHour)
end

local function setBar(bar, percent)
    bar.percent = math.max(0, math.min(1, percent or 0))
    local fill = bar:getChildById('fill')
    fill:setBackgroundColor(bar.fillColor or '#e7e5e2')
    fill:setWidth(math.floor(bar:getWidth() * bar.percent))
end

-- ---------------------------------------------------------------------------------------------
-- Vitals

local xpTracker = { startTime = 0, startExperience = 0 }

local function resetXpTracker(player)
    xpTracker.startTime = g_clock.seconds()
    xpTracker.startExperience = player and player:getExperience() or 0
end

local function updateHealth(player)
    local health, maxHealth = player:getHealth(), math.max(1, player:getMaxHealth())
    local block = vitals:getChildById('hpBlock')
    block:getChildById('row'):getChildById('caption'):setText('HP')
    block:getChildById('row'):getChildById('value'):setText(formatNumber(health) .. ' / ' .. formatNumber(maxHealth))
    setBar(block:getChildById('bar'), health / maxHealth)
    vignette:setVisible(active and health > 0 and health / maxHealth <= LOW_HEALTH)
end

local function updateMana(player)
    local mana, maxMana = player:getMana(), player:getMaxMana()
    local block = vitals:getChildById('mpBlock')
    block:getChildById('row'):getChildById('caption'):setText('MP')
    block:getChildById('row'):getChildById('value'):setText(formatNumber(mana) .. ' / ' .. formatNumber(maxMana))
    setBar(block:getChildById('bar'), maxMana > 0 and mana / maxMana or 0)
end

local function updateExperience(player)
    local block = vitals:getChildById('xpBlock')
    local percent = player:getLevelPercent()
    setBar(block:getChildById('bar'), percent / 100)
    block:getChildById('progress'):setText(string.format('%d%% to %d', percent, player:getLevel() + 1))

    local elapsed = g_clock.seconds() - xpTracker.startTime
    local gained = player:getExperience() - xpTracker.startExperience
    if elapsed >= 60 and gained > 0 then
        block:getChildById('rate'):setText(formatRate(gained * 3600 / elapsed))
    else
        block:getChildById('rate'):setText('')
    end
end

local function updateIdentity(player)
    local header = vitals:getChildById('header')
    header:getChildById('name'):setText(player:getName())

    local vocation = player.getVocationNameByClientId and player:getVocationNameByClientId() or ''
    if vocation == 'Unknown Vocation' or vocation == 'None' or vocation == 'No Vocation' then
        vocation = ''
    end
    local level = tr('Level %d', player:getLevel())
    header:getChildById('subtitle'):setText(vocation ~= '' and (vocation .. '  \183  ' .. level) or level)
    header:getChildById('world'):setText(g_game.getWorldName() or '')
end

local function updateConditions(player)
    local panel = vitals:getChildById('conditions')
    panel:destroyChildren()
    local states = player:getStates()
    local shown = 0
    for _, condition in ipairs(CONDITIONS) do
        if condition.state and condition.state > 0 and Player.isStateActive(states, condition.state) then
            local chip = g_ui.createWidget('LfChip', panel)
            chip:setText(condition.label)
            chip:setColor(condition.color)
            shown = shown + 1
            if shown >= 4 then
                break
            end
        end
    end
    panel:setHeight(shown > 0 and 18 or 0)
    panel:setVisible(shown > 0)
end

local function refreshVitals()
    local player = g_game.getLocalPlayer()
    if not player or not vitals then
        return
    end
    updateIdentity(player)
    updateHealth(player)
    updateMana(player)
    updateExperience(player)
    updateConditions(player)
end

local function onHealthChange(player) updateHealth(player) end
local function onManaChange(player) updateMana(player) end
local function onStatesChange(player) updateConditions(player) end
local function onLevelChange(player)
    updateIdentity(player)
    updateExperience(player)
end
local function onExperienceChange(player) updateExperience(player) end

-- ---------------------------------------------------------------------------------------------
-- Dock

local function refreshDock()
    if not menuOptions then
        return
    end
    for _, button in ipairs(menuOptions:getChildren()) do
        if button.entry and button.entry.isOn then
            button:setOn(button.entry.isOn())
        end
    end
end

local function closeMenu()
    if menuWindow then
        menuWindow:hide()
        menuBackdrop:hide()
        dock:getChildById('dockMenu'):setOn(false)
    end
end

local function toggleMenu()
    if not active then
        return
    end
    if menuWindow:isVisible() then
        closeMenu()
    else
        refreshDock()
        local hudRect, dockRect = hud:getRect(), dock:getRect()
        local available = hudRect.y + hudRect.height - dockRect.y - 12
        local optionsHeight = math.max(60, math.min(302, available - 64))
        menuOptions:setHeight(optionsHeight)
        menuWindow:setHeight(optionsHeight + 64)
        menuBackdrop:show()
        menuWindow:show()
        menuWindow:raise()
        dock:getChildById('dockMenu'):setOn(true)
    end
end

local function rebuildMenuOptions()
    if not menuOptions then return end
    menuOptions:destroyChildren()
    local entries = {}
    for _, entry in ipairs(DOCK) do entries[#entries + 1] = entry end
    for _, entry in pairs(registeredMenuActions) do entries[#entries + 1] = entry end
    table.sort(entries, function(a, b)
        if (a.order or 100) ~= (b.order or 100) then return (a.order or 100) < (b.order or 100) end
        return a.key < b.key
    end)
    for _, entry in ipairs(entries) do
        local button = g_ui.createWidget('LfDockMenuButton', menuOptions)
        button:setId('menu' .. entry.key)
        button:setText(tr(entry.menuLabel or entry.label))
        button:setTooltip(tr(entry.label))
        button.entry = entry
        button.onClick = function()
            closeMenu()
            entry.run()
            addEvent(refreshDock)
        end
    end
    refreshDock()
end

function registerMenuAction(entry)
    if type(entry) ~= 'table' or type(entry.key) ~= 'string' or type(entry.run) ~= 'function' then return end
    registeredMenuActions[entry.key] = entry
    rebuildMenuOptions()
end

function unregisterMenuAction(key)
    registeredMenuActions[key] = nil
    rebuildMenuOptions()
end

local function buildDock()
    local trigger = g_ui.createWidget('LfDockButton', dock)
    trigger:setId('dockMenu')
    trigger:setWidth(44)
    trigger:setText('MENU')
    trigger:setTooltip(tr('Open game menu'))
    trigger.onClick = toggleMenu

    rebuildMenuOptions()

    menuBackdrop.onMousePress = function()
        closeMenu()
        return true
    end
    menuWindow:getChildById('close').onClick = closeMenu
end

-- ---------------------------------------------------------------------------------------------
-- Widescreen map

local function updateMapView()
    if not active then
        return
    end
    local map = modules.game_interface.getMapPanel()
    local width, height = map:getWidth(), map:getHeight()
    if width <= 0 or height <= 0 then
        return
    end

    map:setLimitVisibleRange(false)
    map:setMaxZoomIn(BASE_ZOOM)
    map:setMaxZoomOut(MAX_ZOOM)

    -- Fill the window at the current zoom; only letterbox when the window is wider than the
    -- server streams (e.g. 32:9 zoomed all the way out).
    local zoom = math.max(BASE_ZOOM, math.min(map:getZoom(), MAX_ZOOM))
    if zoom * width / height > MAX_VISIBLE_WIDTH then
        map:setKeepAspectRatio(true)
        map:setVisibleDimension({ width = MAX_VISIBLE_WIDTH, height = zoom })
    else
        map:setKeepAspectRatio(false)
        map:setZoom(zoom)
    end
    g_settings.set(ZOOM_SETTING, zoom)
end

-- Ctrl + mouse wheel zooms (Ctrl+= / Ctrl+- are bound by game_interface)
local function onMapMouseWheel(map, mousePos, direction)
    if not active or not g_keyboard.isCtrlPressed() then
        return false
    end
    if direction == MouseWheelUp then
        map:zoomIn()
    else
        map:zoomOut()
    end
    return true
end

local function restoreZoom()
    local map = modules.game_interface.getMapPanel()
    local zoom = g_settings.getNumber(ZOOM_SETTING, DEFAULT_ZOOM)
    if zoom < BASE_ZOOM or zoom > MAX_ZOOM or zoom % 2 == 0 then
        zoom = DEFAULT_ZOOM
    end
    map:setMaxZoomIn(BASE_ZOOM)
    map:setMaxZoomOut(MAX_ZOOM)
    map:setZoom(zoom)
end

-- ---------------------------------------------------------------------------------------------
-- Right column

-- design order: minimap, battle, equipment, then containers, then everything else
local COLUMN_ORDER = { 'mainmappanel', 'battleWindow', 'maininventorypanel' }
local PINNED = { 'mainmappanel', 'maininventorypanel' }

local function pinnedClose()
end

-- Saved layout, per character (g_settings node 'lionfell_layout'): HUD panels, feature windows,
-- and the order of the right column.
local LAYOUT_NODE = 'lionfell_layout'
local PRESET_NODE = 'lionfell_layout_presets'
local CONTAINERS = '*containers*'  -- stands for the open containers in a saved column order

local function loadLayout()
    local node = g_settings.getNode(LAYOUT_NODE)
    return node and node[g_game.getCharacterName()] or {}
end

local function saveLayout(layout)
    local node = g_settings.getNode(LAYOUT_NODE) or {}
    node[g_game.getCharacterName()] = layout
    g_settings.setNode(LAYOUT_NODE, node)
    g_settings.save()
end

local function orderColumn(panel)
    local saved = loadLayout().column
    local order = type(saved) == 'string' and saved:split(',') or COLUMN_ORDER
    local index = 1
    local function place(widget)
        panel:moveChildToIndex(widget, index)
        index = index + 1
    end
    local containersPlaced = false
    local function placeContainers()
        containersPlaced = true
        for _, widget in ipairs(panel:getChildren()) do
            if widget:getId():find('^container') then
                place(widget)
            end
        end
    end
    for _, id in ipairs(order) do
        if id == CONTAINERS then
            placeContainers()
        else
            local widget = panel:getChildById(id)
            if widget then
                place(widget)
            end
        end
    end
    if not containersPlaced then
        placeContainers()
    end
end

-- The saved order is the player's: it is saved when a window is dropped into the column, and any
-- other reshuffle (the stock windows re-sort themselves by their own saved slots) is undone on
-- the style cycle.
local lastColumnKey

local function columnKey()
    local ids = {}
    local sawContainer = false
    for _, widget in ipairs(modules.game_interface.getRightPanel():getChildren()) do
        local id = widget:getId()
        if id:find('^container') then
            if not sawContainer then
                ids[#ids + 1] = CONTAINERS
                sawContainer = true
            end
        else
            ids[#ids + 1] = id
        end
    end
    return table.concat(ids, ',')
end

local function rememberColumnOrder()
    lastColumnKey = columnKey()
    local layout = loadLayout()
    layout.column = lastColumnKey  -- a plain string: settings files bring lists back with string keys
    saveLayout(layout)
end

local function keepColumnOrder(panel)
    if columnKey() ~= lastColumnKey then
        orderColumn(panel)
        lastColumnKey = columnKey()
    end
end

local function onColumnDrop(self, widget, mousePos)
    local accepted = UIMiniWindowContainer.onDrop(self, widget, mousePos)
    scheduleEvent(rememberColumnOrder, 100)
    return accepted
end

-- Panel titles in the design are small grey caps (BATTLE, EQUIPMENT, ...). Titles are plain
-- labels inside each module's window, and some change at runtime (container names), so this
-- runs on a light cycle while the HUD is active.
local styleEvent

local DOCK_PANELS = { 'getRightPanel', 'getLeftPanel', 'getRightExtraPanel', 'getLeftExtraPanel' }
-- stock decorations some modules add on top of the MiniWindow skin
local STOCK_DECOR = { 'miniwindowIcon', 'containerItemWidget', 'miniborder', 'resizeIndicator' }

local function styleWindow(window)
    local title = window:getChildById('miniwindowTitle')
    if not title then
        return
    end
    if not window.lfStyled then
        title:setTTFFont('GeistMono-Medium', 10, 0, '#00000000')
        title:setColor('#7d7a76')
        title:setMarginLeft(12)
        title:setMarginTop(5)
        for _, id in ipairs(STOCK_DECOR) do
            local decor = window:recursiveGetChildById(id)
            if decor then
                decor:setVisible(false)
            end
        end
        window:setIcon('')
        window.lfStyled = true
    end
    -- some modules title the window itself as well as the label: keep one, on the label
    local windowText = window:getText()
    if windowText ~= '' then
        if title:getText() == '' then
            title:setText(windowText)
        end
        window:setText('')
    end
    local text = title:getText()
    if text ~= text:upper() then
        title:setText(text:upper())
    end
    window:setBorderWidth(0)  -- extended view adds a black frame to docked panels
end

local function styleWindowTitles()
    local gi = modules.game_interface
    for _, getter in ipairs(DOCK_PANELS) do
        local panel = gi[getter] and gi[getter]()
        if panel then
            for _, window in ipairs(panel:getChildren()) do
                styleWindow(window)
            end
        end
    end
    -- windows the player pulled out of the columns float on the map
    for _, window in ipairs(gi.getRootPanel():getChildren()) do
        if window:getClassName() == 'UIMiniWindow' then
            styleWindow(window)
        end
    end
end

-- Stock on-map chrome the design replaces: the "Menu" button (dock MNU), the ping/FPS readout,
-- the health/mana circles (vitals card) and the empty side action-bar strips. Some of it is re-shown by its
-- module on events, so this also runs on the maintenance cycle.
local HEALTH_CIRCLE_WIDGETS = { 'healthCircle', 'healthCircleFront', 'manaCircle', 'manaCircleFront',
    'manaShieldCircle', 'manaShieldCircleFront', 'expCircle', 'expCircleFront', 'skillCircle', 'skillCircleFront' }
local SIDE_ACTION_WIDGETS = { 'gameLeftActionPanel', 'gameRightActionPanel', 'lockLeftPanel', 'lockRightPanel' }
local hiddenStock = {}

local function hideStockChrome()
    local gi = modules.game_interface
    local function hide(widget)
        if widget and not widget:isDestroyed() and widget:isVisible() then
            hiddenStock[widget] = true
            widget:setVisible(false)
        end
    end
    hide(gi.getShowTopMenuButton())
    -- client_topmenu's ping/FPS readout (pingFps.otui) on the map's top-left corner
    local ping = gi.getMapPanel():recursiveGetChildById('ping')
    if ping and ping:getParent() then
        hide(ping:getParent():getParent())
    end
    local circles = modules.game_healthcircle
    if circles then
        for _, name in ipairs(HEALTH_CIRCLE_WIDGETS) do
            hide(circles[name])
        end
    end
    local root = gi.getRootPanel()
    for _, id in ipairs(SIDE_ACTION_WIDGETS) do
        local widget = root:getChildById(id)
        -- only the empty strips; side action bars the player enabled stay
        if widget and widget:getWidth() <= 2 then
            hide(widget)
        end
    end
end

-- The stock "Hide chat" (chat menu) and its way back (returnChat in game_console) restore the
-- classic look: stone textures on the panel and message area, and the spell-cooldown strip over
-- the tabs. Put the Lionfell chat back whenever that happens.
local function styleChat()
    local chat = modules.game_interface.getBottomPanel()
    local cooldown = modules.game_cooldown and modules.game_cooldown.cooldownWindow
    if cooldown and cooldown:isVisible() then
        cooldown:setVisible(false)
    end
    if not chat:isVisible() or chat:isPhantom() then
        return  -- hidden, or the see-through "peek" mode
    end
    if chat:getImageSource() ~= '/images/lionfell/panel' then
        chat:setImageSource('/images/lionfell/panel')
        chat:setImageBorder(6)
        chat:setImageRepeated(false)
        chat:setImageColor('white')
    end
    local tabBar = chat:recursiveGetChildById('consoleTabBar')
    for _, tab in ipairs(tabBar and tabBar.tabs or {}) do
        local buffer = tab.tabPanel and tab.tabPanel:getChildById('consoleBuffer')
        if buffer and buffer:getImageSource() ~= '' then
            buffer:setImageSource('')
        end
    end
end

function isActive()
    return active
end

function styleChatNow()
    styleChat()
end

-- the top menu's layout sets its own stone-texture background; flatten it while the HUD is up
local topMenuLook

local function flattenTopMenu()
    local topMenu = modules.client_topmenu and modules.client_topmenu.getTopMenu()
    if not topMenu or topMenuLook then
        return
    end
    topMenuLook = { source = topMenu:getImageSource(), color = topMenu:getImageColor() }
    topMenu:setImageSource('/images/lionfell/fill_r4')
    topMenu:setImageRepeated(false)
    topMenu:setImageBorder(4)
    topMenu:setImageColor('#101112e6')
end

local function restoreTopMenu()
    local topMenu = modules.client_topmenu and modules.client_topmenu.getTopMenu()
    if topMenu and topMenuLook then
        topMenu:setImageSource(topMenuLook.source)
        topMenu:setImageRepeated(true)
        topMenu:setImageBorder(0)
        topMenu:setImageColor(topMenuLook.color)
    end
    topMenuLook = nil
end

local function restoreStockChrome()
    for widget in pairs(hiddenStock) do
        if not widget:isDestroyed() then
            widget:setVisible(true)
        end
    end
    hiddenStock = {}
    local circles = modules.game_healthcircle
    if circles and circles.setHealthCircle then
        -- re-apply the player's own circle settings
        circles.setHealthCircle(circles.isHealthCircle)
        circles.setManaCircle(circles.isManaCircle)
    end
end

local function updateMinimapFooter()
    local minimapModule = modules.game_minimap
    local ui = minimapModule and minimapModule.mapController and minimapModule.mapController.ui
    if not ui or not ui.footer then
        return
    end
    local position = ui.minimapBorder.minimap:getCameraPosition()
    if not position then
        return
    end
    ui.footer.coords:setText(string.format('%d, %d', position.x, position.y))
    ui.footer.floor:setText(tr('Floor %d', position.z))
end

-- ---------------------------------------------------------------------------------------------
-- Layout

-- the design's action bar is a fixed row of 12 slots, without the stock scroll arrows
local function setActionBarArrows(panel, visible)
    for _, bar in ipairs(panel:getChildren()) do
        for _, id in ipairs({ 'prevPanel', 'nextPanel' }) do
            local arrows = bar:getChildById(id)
            if arrows then
                arrows:setVisible(visible)
                arrows:setWidth(visible and 17 or 0)
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Movable panels. Edit layout gives each visible part a handle. Standalone feature windows also
-- save when dragged normally. Spots use the nearest screen edges so they survive resizing.

local layoutBar
local layoutHandles = {}
local registeredPanels = {}

local function restorePanelDefault(part)
    local widget, default = part.widget, part.default
    if not widget or widget:isDestroyed() or not default then return end
    widget:breakAnchors()
    widget:setMarginLeft(0)
    widget:setMarginRight(0)
    widget:setMarginTop(0)
    widget:setMarginBottom(0)
    if default.anchor == 'center' then
        widget:addAnchor(AnchorHorizontalCenter, 'parent', AnchorHorizontalCenter)
        widget:addAnchor(AnchorVerticalCenter, 'parent', AnchorVerticalCenter)
    else
        widget:addAnchor(AnchorTop, 'parent', AnchorTop)
        widget:setMarginTop(default.top or 0)
        if default.anchor == 'topRight' then
            widget:addAnchor(AnchorRight, 'parent', AnchorRight)
            widget:setMarginRight(default.right or 0)
        else
            widget:addAnchor(AnchorHorizontalCenter, 'parent', AnchorHorizontalCenter)
        end
    end
end

local function movableParts()
    local gi = modules.game_interface
    local parts = {
        { id = 'vitals', label = tr('VITALS'), widget = vitals },
        { id = 'dock', label = tr('DOCK'), widget = dock },
        { id = 'chat', label = tr('CHAT'), widget = gi.getBottomPanel(), resizable = 'both' },
        { id = 'actionbar', label = tr('ACTION BAR'), widget = gi.getBottomActionPanel() },
        -- the right column is full height: it moves sideways only
        { id = 'column', label = tr('PANEL COLUMN'), widget = gi.getRightPanel(), sideways = true, resizable = 'width' },
    }
    local ids = {}
    for id in pairs(registeredPanels) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local part = registeredPanels[id]
        if part.widget and not part.widget:isDestroyed() then parts[#parts + 1] = part end
    end
    return parts
end

local function spotOf(widget)
    local area = widget:getParent():getRect()
    local rect = widget:getRect()
    local spot = {}
    local left, right = rect.x - area.x, area.x + area.width - rect.x - rect.width
    local top, bottom = rect.y - area.y, area.y + area.height - rect.y - rect.height
    if left <= right then spot.left = left else spot.right = right end
    if top <= bottom then spot.top = top else spot.bottom = bottom end
    return spot
end

-- full-height parts keep their top and bottom anchors and only take the horizontal spot
local function anchorFullHeight(widget)
    widget:addAnchor(AnchorTop, 'parent', AnchorTop)
    widget:addAnchor(AnchorBottom, 'parent', AnchorBottom)
    widget:setMarginTop(MARGIN)
    widget:setMarginBottom(MARGIN)
end

local function placeAt(widget, spot, sideways)
    spot = { left = tonumber(spot.left), right = tonumber(spot.right), top = tonumber(spot.top), bottom = tonumber(spot.bottom) }
    local area = widget:getParent():getRect()
    local maxX = math.max(0, area.width - widget:getWidth())
    local maxY = math.max(0, area.height - widget:getHeight())
    widget:breakAnchors()
    if sideways then
        anchorFullHeight(widget)
        spot.top, spot.bottom = nil, nil
    end
    if spot.right then
        widget:addAnchor(AnchorRight, 'parent', AnchorRight)
        widget:setMarginRight(math.min(math.max(spot.right, 0), maxX))
    else
        widget:addAnchor(AnchorLeft, 'parent', AnchorLeft)
        widget:setMarginLeft(math.min(math.max(spot.left or 0, 0), maxX))
    end
    if sideways then
        return
    end
    if spot.bottom then
        widget:addAnchor(AnchorBottom, 'parent', AnchorBottom)
        widget:setMarginBottom(math.min(math.max(spot.bottom, 0), maxY))
    else
        widget:addAnchor(AnchorTop, 'parent', AnchorTop)
        widget:setMarginTop(math.min(math.max(spot.top or 0, 0), maxY))
    end
end

-- Feature modules register their own top-level window once. Future systems can join the saved
-- layout without changing this HUD module.
function registerPanel(id, label, widget, default)
    if not id or not widget then return end
    local part = { id = id, label = tr(label), widget = widget, default = default }
    registeredPanels[id] = part
    local previous = widget.onDragLeave
    widget.onDragLeave = function(self, ...)
        if previous then previous(self, ...) end
        if not g_game.isOnline() then return end
        local layout = loadLayout()
        layout.parts = layout.parts or {}
        layout.parts[id] = spotOf(self)
        saveLayout(layout)
    end
    if g_game.isOnline() then
        local saved = (loadLayout().parts or {})[id]
        if saved then placeAt(widget, saved) end
    end
end

function unregisterPanel(id)
    registeredPanels[id] = nil
end

function applySavedPlacements()
    local layout = loadLayout()
    local parts, sizes = layout.parts or {}, layout.sizes or {}
    for _, part in ipairs(movableParts()) do
        local size = sizes[part.id]
        if size and part.resizable and part.widget then
            if tonumber(size.width) then part.widget:setWidth(tonumber(size.width)) end
            if part.resizable == 'both' and tonumber(size.height) then
                part.widget:setHeight(tonumber(size.height))
            end
        end
        local spot = parts[part.id]
        if spot and part.widget then
            placeAt(part.widget, spot, part.sideways)
        end
    end
end

local function syncHandles()
    for _, handle in ipairs(layoutHandles) do
        if not handle:isDestroyed() and not handle.part.widget:isDestroyed() then
            handle:setRect(handle.part.widget:getRect())
        end
    end
end

local function createHandle(part)
    local root = modules.game_interface.getRootPanel()
    local handle = g_ui.createWidget('LfLayoutHandle', root)
    handle.part = part
    handle:setText(part.label)
    handle:setRect(part.widget:getRect())
    handle.onDragEnter = function(self, mousePos)
        local widget = self.part.widget
        widget:breakAnchors()
        self.reference = { x = mousePos.x - widget:getX(), y = mousePos.y - widget:getY() }
        return true
    end
    handle.onDragMove = function(self, mousePos)
        local widget = self.part.widget
        local y = self.part.sideways and widget:getY() or mousePos.y - self.reference.y
        widget:setPosition({ x = mousePos.x - self.reference.x, y = y })
        widget:bindRectToParent()
        self:setRect(widget:getRect())
        return true
    end
    handle.onDragLeave = function(self)
        local widget = self.part.widget
        local spot = spotOf(widget)
        placeAt(widget, spot, self.part.sideways)
        local layout = loadLayout()
        layout.parts = layout.parts or {}
        layout.parts[self.part.id] = spot
        if self.part.resizable then
            layout.sizes = layout.sizes or {}
            layout.sizes[self.part.id] = {
                width = widget:getWidth(), height = widget:getHeight(),
            }
        end
        saveLayout(layout)
        addEvent(syncHandles)
        return true
    end
    return handle
end

local function setLayoutEditing(on)
    layoutEditing = on
    for _, handle in ipairs(layoutHandles) do
        if not handle:isDestroyed() then
            handle:destroy()
        end
    end
    layoutHandles = {}
    if layoutBar then
        layoutBar:setVisible(on)
    end
    if on then
        for _, part in ipairs(movableParts()) do
            if part.widget and part.widget:isVisible() then
                layoutHandles[#layoutHandles + 1] = createHandle(part)
            end
        end
        if layoutBar then
            layoutBar:raise()
        end
    end
    refreshDock()
end

toggleLayoutEditing = function()
    if active then
        setLayoutEditing(not layoutEditing)
    end
end

local function resetLayout()
    saveLayout({})
    setLayoutEditing(false)
    for _, part in pairs(registeredPanels) do restorePanelDefault(part) end
    if active then
        applyActiveLayout()
    end
end

local SLOT_NAMES = { 'Solo', 'Party', 'Raid' }

local function copyLayout(value)
    if type(value) ~= 'table' then return value end
    local copy = {}
    for key, item in pairs(value) do copy[key] = copyLayout(item) end
    return copy
end

local function snapshotLayout()
    local snapshot = { parts = {}, sizes = {}, column = columnKey(), open = {}, miniWindows = {} }
    for _, part in ipairs(movableParts()) do
        if part.widget and not part.widget:isDestroyed() then
            snapshot.parts[part.id] = spotOf(part.widget)
            if part.resizable then
                snapshot.sizes[part.id] = {
                    width = part.widget:getWidth(), height = part.widget:getHeight(),
                }
            end
        end
    end
    for id, part in pairs(registeredPanels) do
        snapshot.open[id] = part.widget:isVisible()
    end
    local gi = modules.game_interface
    local panels = { gi.getRootPanel() }
    for _, getter in ipairs(DOCK_PANELS) do panels[#panels + 1] = gi[getter]() end
    for _, panel in ipairs(panels) do
        for index, widget in ipairs(panel:getChildren()) do
            local id = widget:getId()
            if id and id ~= '' and type(widget.minimize) == 'function' then
                local canMinimize = widget:getChildById('contentsPanel')
                    and widget:getChildById('miniwindowScrollBar')
                    and widget:getChildById('bottomResizeBorder')
                    and widget:getChildById('minimizeButton')
                snapshot.miniWindows[id] = {
                    parent = panel:getId(), index = index, visible = widget:isVisible(),
                    minimized = canMinimize and widget:isOn() or false,
                    height = canMinimize and widget:isOn() and widget.maximizedHeight or widget:getHeight(),
                    spot = panel == gi.getRootPanel() and spotOf(widget) or nil,
                }
            end
        end
    end
    return snapshot
end

local function restoreMiniWindows(saved)
    if type(saved) ~= 'table' then return end
    local gi = modules.game_interface
    local root = gi.getRootPanel()
    local panels, windows = { [root:getId()] = root }, {}
    for _, widget in ipairs(root:getChildren()) do
        if type(widget.minimize) == 'function' then windows[widget:getId()] = widget end
    end
    for _, getter in ipairs(DOCK_PANELS) do
        local panel = gi[getter]()
        panels[panel:getId()] = panel
        for _, widget in ipairs(panel:getChildren()) do windows[widget:getId()] = widget end
    end
    local entries = {}
    for id, state in pairs(saved) do
        if windows[id] and type(state) == 'table' then
            entries[#entries + 1] = { widget = windows[id], state = state }
        end
    end
    table.sort(entries, function(a, b)
        if a.state.parent ~= b.state.parent then return a.state.parent < b.state.parent end
        return (tonumber(a.state.index) or 0) < (tonumber(b.state.index) or 0)
    end)
    for _, entry in ipairs(entries) do
        local widget, state = entry.widget, entry.state
        local panel = panels[state.parent]
        if panel and widget:getParent() ~= panel and not widget.moveOnlyToMain then
            widget:setParent(panel)
        end
        if panel == root and widget:getParent() == root and state.spot then
            placeAt(widget, state.spot)
            widget:saveParent()
        end
        local canMinimize = widget:getChildById('contentsPanel')
            and widget:getChildById('miniwindowScrollBar')
            and widget:getChildById('bottomResizeBorder')
            and widget:getChildById('minimizeButton')
        if canMinimize and widget:isOn() then widget:maximize() end
        if tonumber(state.height) and tonumber(state.height) > 0 then
            widget:setHeight(tonumber(state.height))
        end
        if canMinimize and state.minimized then widget:minimize() end
        if state.visible then widget:open() else widget:close() end
        panel = widget:getParent()
        if panel and panel ~= root and panels[panel:getId()] and tonumber(state.index) then
            panel:moveChildToIndex(widget, math.min(tonumber(state.index), panel:getChildCount()))
        end
    end
    for _, panel in pairs(panels) do
        if panel ~= root and panel.saveChildren then panel:saveChildren() end
    end
end

local function savedSlots()
    local node = g_settings.getNode(PRESET_NODE) or {}
    return node[g_game.getCharacterName()] or {}
end

local function refreshSlotButtons()
    local slots = savedSlots()
    local rows = layoutSlots:getChildById('slots')
    for _, name in ipairs(SLOT_NAMES) do
        rows:getChildById('slot' .. name):getChildById('load'):setEnabled(slots[name] ~= nil)
    end
end

local function saveSlot(name)
    local node = g_settings.getNode(PRESET_NODE) or {}
    local character = g_game.getCharacterName()
    node[character] = node[character] or {}
    node[character][name] = snapshotLayout()
    g_settings.setNode(PRESET_NODE, node)
    g_settings.save()
    refreshSlotButtons()
end

local function loadSlot(name)
    local saved = savedSlots()[name]
    if not saved then return end
    saveLayout(copyLayout(saved))
    setLayoutEditing(false)
    applyActiveLayout()
    restoreMiniWindows(saved.miniWindows)
    orderColumn(modules.game_interface.getRightPanel())
    lastColumnKey = columnKey()
    for id, visible in pairs(saved.open or {}) do
        local part = registeredPanels[id]
        if part and part.default then
            local action = visible and part.default.show or part.default.hide
            if action then action() end
        end
    end
    layoutSlots:hide()
end

openLayoutSlots = function()
    if not active then return end
    refreshSlotButtons()
    layoutSlots:show()
    layoutSlots:raise()
end

local function buildLayoutSlots()
    local rows = layoutSlots:getChildById('slots')
    for _, name in ipairs(SLOT_NAMES) do
        local row = g_ui.createWidget('LfLayoutSlot', rows)
        row:setId('slot' .. name)
        row:getChildById('name'):setText(tr(name))
        row:getChildById('save').onClick = function() saveSlot(name) end
        row:getChildById('load').onClick = function() loadSlot(name) end
    end
    layoutSlots:getChildById('close').onClick = function() layoutSlots:hide() end
    layoutSlots.onEscape = function() layoutSlots:hide() end
end

function applyActiveLayout()
    local gi = modules.game_interface
    local root = gi.getRootPanel()

    hud:show()
    hud:raise()
    vignette:lower()

    -- the dock replaces the top menu; MNU brings it back
    callModule('client_topmenu', 'hide')

    -- right column: minimap, battle, equipment and containers stack here
    local rightPanel = gi.getRightPanel()
    rightPanel:setWidth(COLUMN_WIDTH)
    rightPanel:breakAnchors()
    anchorFullHeight(rightPanel)
    rightPanel:addAnchor(AnchorRight, 'parent', AnchorRight)
    rightPanel:setMarginLeft(0)
    rightPanel:setMarginRight(MARGIN)
    if rightPanel:getLayout() then
        rightPanel:getLayout():setSpacing(12)
    end

    -- one column, as in the design: minimap and equipment come from the small top-right
    -- panel, and anything docked on the left joins too (the left side belongs to the vitals
    -- card, dock and chat). setParent detaches from the old panel; insertChild alone would not.
    local mainRightPanel = gi.getMainRightPanel()
    for index, child in ipairs(mainRightPanel:getChildren()) do
        child:setParent(rightPanel)
        rightPanel:moveChildToIndex(child, index)
        table.insert(movedToColumn, { widget = child, index = index, from = mainRightPanel })
    end
    -- its height was computed while the panels were still inside it
    mainRightPanel:setHeight(0)
    orderColumn(rightPanel)

    -- minimap and equipment are fixed parts of the design: open them, and stop the column's
    -- overflow handling (UIMiniWindowContainer:fitAll) from closing them. The dock still
    -- shows/hides them through their modules.
    for _, id in ipairs(PINNED) do
        local widget = rightPanel:getChildById(id)
        if widget then
            widget.close = pinnedClose
            widget:open(true)
        end
    end

    -- windows the player docked on the left stay there; vitals, dock and chat start after them
    local leftPanel = gi.getLeftPanel()
    if #leftPanel:getChildren() == 0 then
        leftPanel:setOn(false)
    end
    vitals:breakAnchors()
    vitals:addAnchor(AnchorTop, 'parent', AnchorTop)
    vitals:addAnchor(AnchorLeft, 'parent', AnchorLeft)
    vitals:setMarginTop(MARGIN)
    vitals:setMarginLeft(MARGIN + (leftPanel:isOn() and leftPanel:getWidth() or 0))
    dock:breakAnchors()
    dock:addAnchor(AnchorTop, 'vitals', AnchorBottom)
    dock:addAnchor(AnchorLeft, 'vitals', AnchorLeft)
    dock:setMarginTop(16)
    dock:setMarginLeft(0)

    -- the vitals card replaces the stock health/mana window
    local healthInfo = modules.game_healthinfo and modules.game_healthinfo.healthManaController
    if healthInfo and healthInfo.ui then
        healthInfo.ui:hide()
    end

    -- chat: floating panel, bottom-left
    local chat = gi.getBottomPanel()
    chat:breakAnchors()
    chat:setImageSource('/images/lionfell/panel')
    chat:setImageBorder(6)
    chat:setImageRepeated(false)
    chat:setImageColor('white')
    chat:setSize(CHAT_SIZE)
    chat:addAnchor(AnchorLeft, 'parent', AnchorLeft)
    chat:addAnchor(AnchorBottom, 'parent', AnchorBottom)
    chat:setMarginLeft(vitals:getMarginLeft())
    chat:setMarginBottom(MARGIN)

    -- the spell-group cooldown strip sits on top of the chat in stock OTClient; the design
    -- shows cooldowns on the action bar slots instead
    local cooldown = modules.game_cooldown and modules.game_cooldown.cooldownWindow
    local consolePanel = modules.game_console and modules.game_console.consolePanel
    if cooldown then
        cooldown:setVisible(false)
    end
    if consolePanel then
        consolePanel:removeAnchor(AnchorTop)
        consolePanel:addAnchor(AnchorTop, 'parent', AnchorTop)
        consolePanel:setMarginRight(0)
        consolePanel:setMarginBottom(0)
    end

    -- action bar: bottom centre, between the chat and the right column
    local actionBar = gi.getBottomActionPanel()
    -- placed from the screen edge (not anchored to the chat: stock extended view anchors the
    -- chat to the action bar, and anchoring back would make a loop)
    actionBar:breakAnchors()
    actionBar:addAnchor(AnchorBottom, 'parent', AnchorBottom)
    actionBar:addAnchor(AnchorLeft, 'parent', AnchorLeft)
    actionBar:setMarginBottom(MARGIN)
    actionBar:setMarginLeft(chat:getMarginLeft() + CHAT_SIZE.width + ACTIONBAR_GAP)
    actionBar:setMarginRight(0)
    actionBar:setWidth(ACTIONBAR_WIDTH)
    setActionBarArrows(actionBar, false)
    actionBar:setImageSource('/images/lionfell/panel')
    actionBar:setImageBorder(6)
    actionBar:setPadding(6)
    callModule('game_actionbar', 'updateVisibleWidgetsExternal')

    local messages = modules.game_textmessage and modules.game_textmessage.messagesPanel
    local statusLabel = messages and messages:recursiveGetChildById('statusLabel')
    if statusLabel then
        statusLabel:setMarginBottom(STATUS_LINE_BOTTOM)
    end

    -- classic chrome that has no place over a full-bleed map
    for _, id in ipairs({ 'bottomSplitter', 'lockPanel', 'gameTopPanel', 'gameBottomStatsBarPanel' }) do
        local widget = root:getChildById(id)
        if widget then
            widget:setVisible(false)
        end
    end

    restoreZoom()
    updateMapView()
    refreshVitals()
    refreshDock()
    updateMinimapFooter()

    if styleEvent then
        removeEvent(styleEvent)
    end
    hideStockChrome()
    flattenTopMenu()
    styleWindowTitles()
    lastColumnKey = nil
    rightPanel.onDrop = onColumnDrop
    -- the stock windows keep docking into the column for a moment after login (each restores
    -- its own saved slot), so the saved order is re-applied for a few cycles before changes
    -- count as the player's
    local settleCycles = 6
    styleEvent = cycleEvent(function()
        styleWindowTitles()
        hideStockChrome()
        styleChat()
        if settleCycles > 0 then
            settleCycles = settleCycles - 1
            orderColumn(rightPanel)
            lastColumnKey = columnKey()
        else
            keepColumnOrder(rightPanel)
        end
    end, 500)
    applySavedPlacements()
end

local function applyInactiveLayout()
    local gi = modules.game_interface
    local root = gi.getRootPanel()
    setLayoutEditing(false)
    closeMenu()
    layoutSlots:hide()
    hud:hide()
    vignette:hide()
    gi.getMapPanel():setMaxZoomIn(STOCK_MAX_ZOOM_IN)
    if styleEvent then
        removeEvent(styleEvent)
        styleEvent = nil
    end
    restoreStockChrome()
    restoreTopMenu()

    local rightPanel = gi.getRightPanel()
    local mainRightPanel = gi.getMainRightPanel()
    for _, entry in ipairs(movedToColumn) do
        if not entry.widget:isDestroyed() and entry.widget:getParent() == rightPanel then
            entry.widget:setParent(entry.from)
            entry.from:moveChildToIndex(entry.widget, math.min(entry.index, entry.from:getChildCount()))
        end
    end
    movedToColumn = {}
    for _, id in ipairs(PINNED) do
        local widget = rootWidget:recursiveGetChildById(id)
        if widget then
            widget.close = nil  -- back to UIMiniWindow.close
        end
    end
    rightPanel:setWidth(176)
    rightPanel.onDrop = nil  -- back to UIMiniWindowContainer.onDrop
    rightPanel:breakAnchors()
    rightPanel:addAnchor(AnchorTop, 'gameMainRightPanel', AnchorBottom)
    rightPanel:addAnchor(AnchorRight, 'parent', AnchorRight)
    rightPanel:addAnchor(AnchorBottom, 'parent', AnchorBottom)
    rightPanel:setMarginLeft(0)
    rightPanel:setMarginTop(0)
    rightPanel:setMarginRight(0)
    rightPanel:setMarginBottom(0)
    if rightPanel:getLayout() then
        rightPanel:getLayout():setSpacing(0)
    end

    local messages = modules.game_textmessage and modules.game_textmessage.messagesPanel
    local statusLabel = messages and messages:recursiveGetChildById('statusLabel')
    if statusLabel then
        statusLabel:setMarginBottom(7)
    end

    local cooldown = modules.game_cooldown and modules.game_cooldown.cooldownWindow
    local consolePanel = modules.game_console and modules.game_console.consolePanel
    if cooldown and consolePanel then
        cooldown:setVisible(modules.client_options.getOption('showSpellGroupCooldowns') ~= false)
        consolePanel:removeAnchor(AnchorTop)
        consolePanel:addAnchor(AnchorTop, cooldown:getId(), AnchorBottom)
    end

    local chat = gi.getBottomPanel()
    chat:setImageSource('/images/ui/background_dark')
    chat:setImageBorder(0)
    chat:setImageRepeated(true)
    chat:setMarginLeft(0)
    chat:setMarginBottom(0)

    local actionBar = gi.getBottomActionPanel()
    actionBar:breakAnchors()
    actionBar:addAnchor(AnchorLeft, 'bottomSplitter', AnchorLeft)
    actionBar:addAnchor(AnchorRight, 'bottomSplitter', AnchorRight)
    actionBar:addAnchor(AnchorTop, 'gameBottomStatsBarPanel', AnchorBottom)
    actionBar:setMarginBottom(0)
    actionBar:setMarginLeft(0)
    actionBar:setMarginRight(12)
    setActionBarArrows(actionBar, true)
    actionBar:setImageSource(nil)
    actionBar:setPadding(0)
    actionBar:setPaddingBottom(2)

    for _, id in ipairs({ 'bottomSplitter', 'lockPanel', 'gameTopPanel', 'gameBottomStatsBarPanel' }) do
        local widget = root:getChildById(id)
        if widget then
            widget:setVisible(true)
        end
    end

    local healthInfo = modules.game_healthinfo and modules.game_healthinfo.healthManaController
    if healthInfo and healthInfo.ui then
        healthInfo.ui:show()
    end
    callModule('game_actionbar', 'updateVisibleWidgetsExternal')
end

-- Called by game_interface.setupViewMode. Leaving the HUD restores the stock panels right
-- away, before the stock code (which runs next frame) expects them back in place. Entering
-- runs a little later so it lands after the stock extended-view setup (which reshows the top
-- menu and re-anchors the chat).
function onViewModeChange(mode)
    if layoutEvent then
        removeEvent(layoutEvent)
        layoutEvent = nil
    end
    if not hud then
        return
    end
    if mode ~= 2 then
        if active then
            applyInactiveLayout()
        end
        active = false
        return
    end
    layoutEvent = scheduleEvent(function()
        layoutEvent = nil
        if g_game.isOnline() then
            active = true
            applyActiveLayout()
        end
    end, 50)
end

local function onGameStart()
    resetXpTracker(g_game.getLocalPlayer())
    onViewModeChange(modules.game_interface.currentViewMode)
end

local function onGameEnd()
    if active then
        applyInactiveLayout()
    end
    active = false
end

function init()
    hud = g_ui.loadUI('hud', modules.game_interface.getRootPanel())
    hud:hide()
    vitals = hud:getChildById('vitals')
    dock = hud:getChildById('dock')
    menuBackdrop = hud:getChildById('menuBackdrop')
    menuWindow = hud:getChildById('menuWindow')
    menuOptions = menuWindow:getChildById('menuOptions')
    layoutSlots = hud:getChildById('layoutSlots')
    vignette = hud:getChildById('vignette')
    layoutBar = hud:getChildById('layoutBar')
    layoutBar:getChildById('done').onClick = function() setLayoutEditing(false) end
    layoutBar:getChildById('reset').onClick = resetLayout

    for _, block in ipairs({ 'hpBlock', 'mpBlock', 'xpBlock' }) do
        local bar = vitals:getChildById(block):getChildById('bar')
        bar.onGeometryChange = function(self)
            setBar(self, self.percent)
        end
    end

    buildDock()
    buildLayoutSlots()

    connect(g_game, {
        onGameStart = onGameStart,
        onGameEnd = onGameEnd
    })
    connect(LocalPlayer, {
        onHealthChange = onHealthChange,
        onManaChange = onManaChange,
        onStatesChange = onStatesChange,
        onLevelChange = onLevelChange,
        onExperienceChange = onExperienceChange
    })
    connect(modules.game_interface.getMapPanel(), {
        onGeometryChange = updateMapView,
        onZoomChange = updateMapView,
        onMouseWheel = onMapMouseWheel
    })
    local minimapUi = modules.game_minimap and modules.game_minimap.mapController and modules.game_minimap.mapController.ui
    if minimapUi then
        connect(minimapUi.minimapBorder.minimap, { onCameraPositionChange = updateMinimapFooter })
    end

    if g_game.isOnline() then
        onGameStart()
    end
end

function terminate()
    if layoutEvent then
        removeEvent(layoutEvent)
        layoutEvent = nil
    end
    if active then
        applyInactiveLayout()
    end
    active = false

    disconnect(g_game, {
        onGameStart = onGameStart,
        onGameEnd = onGameEnd
    })
    disconnect(LocalPlayer, {
        onHealthChange = onHealthChange,
        onManaChange = onManaChange,
        onStatesChange = onStatesChange,
        onLevelChange = onLevelChange,
        onExperienceChange = onExperienceChange
    })
    disconnect(modules.game_interface.getMapPanel(), {
        onGeometryChange = updateMapView,
        onZoomChange = updateMapView,
        onMouseWheel = onMapMouseWheel
    })
    local minimapUi = modules.game_minimap and modules.game_minimap.mapController and modules.game_minimap.mapController.ui
    if minimapUi then
        disconnect(minimapUi.minimapBorder.minimap, { onCameraPositionChange = updateMinimapFooter })
    end

    hud:destroy()
    hud, vitals, dock, menuBackdrop, menuWindow, menuOptions, layoutSlots, vignette, layoutBar = nil, nil, nil, nil, nil, nil, nil, nil, nil
end
