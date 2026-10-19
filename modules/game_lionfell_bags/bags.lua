-- Lionfell bags window. Every character carries an adventurer's pack (server:
-- data/scripts/lionfell/lf_pack.lua): 24 item slots plus up to 4 bags. This window opens the pack
-- and every bag in it and shows them together: the bag sockets, the pack's slots, then each bag.
-- The cells are ordinary item cells (drag, use, look and hover cards work as in any container).

local PACK_SLOTS = 24
local BAG_SOCKETS = 4

local window, content, summary
local packCid
local bagCids = {}       -- [container id] = pack slot, for the bags shown here
local adopted = {}       -- [container id] = true: bags that were already open in their own window
local refreshEvent
local scheduleRebuild    -- (defined below; openBags needs it)
local view               -- what the window shows: widgets kept between updates (see rebuild)
local bagCache = {}      -- [pack slot] = { id, name, capacity, items }: a bag's last open view, shown
                         -- while it is being opened again so its section never vanishes

local function player()
    return g_game.getLocalPlayer()
end

local function packItem()
    local p = player()
    return p and p:getInventoryItem(InventorySlotBack)
end

local function containerByItemId(itemId)
    for _, container in pairs(g_game.getContainers()) do
        local item = container:getContainerItem()
        if item and item:getId() == itemId then
            return container
        end
    end
end

local function packContainer()
    local pack = packItem()
    if not pack then
        return nil
    end
    if packCid then
        local container = g_game.getContainer(packCid)
        if container then
            return container
        end
    end
    return containerByItemId(pack:getId())
end

-- the stock container windows of the pack and its bags stay out of sight while this is open
local function hideStockWindow(container)
    if container and container.window and not container.window:isDestroyed() then
        container.window:hide()
    end
end

local function isOurs(container)
    local pack = packContainer()
    return container and ((pack and container:getId() == pack:getId()) or bagCids[container:getId()])
end

-- ---------------------------------------------------------------------------------------------
-- Building

local function cell(parent, item, position)
    local widget = g_ui.createWidget('LfContainerItem', parent)
    widget:setItem(item)
    widget.position = position
    if item then
        ItemsDatabase.setRarityItem(widget, item)
        ItemsDatabase.setTier(widget, item)
        widget:setShowCharges(true)
    end
    return widget
end

-- An equipment-style bag socket: labelled "bag N" while empty, like the ring or boots slot.
local function styleSocket(widget, number, bag)
    local label = widget.socketLabel
    if not label then
        label = g_ui.createWidget('LfSlotLabel', widget)
        label:setId('socketLabel')
        widget.socketLabel = label
    end
    label:setText(tr('bag %d', number))
    label:setEnabled(bag == nil) -- LfSlotLabel shows only while enabled (as on the equipment slots)
    widget:setTooltip(bag == nil and tr('Bag slot %d: drop a bag or backpack here', number) or nil)
end

-- The coin purse socket, after the bag sockets: always there, can't be moved; it shows a gold
-- pouch and opens the purse (game_lionfell_purse: the money in the bank).
local function purse()
    return modules.game_lionfell_purse
end

local function updatePurseSocket(widget)
    local module = purse()
    local balance = module and module.getBalance and module.getBalance() or 0
    widget:setTooltip(tr('Coin purse: %s gp\nLooted gold goes here and is safe when you die. Click to open.',
        module and module.formatGold and module.formatGold(balance) or tostring(balance)))
end

local function purseSocket(parent)
    local widget = g_ui.createWidget('LfContainerItem', parent)
    widget:setId('purseSocket')
    widget:setVirtual(true)
    widget:setDraggable(false)
    local pouch = Item.create(23721) -- Tibia's red gold pouch: unlike any bag
    if pouch then
        widget:setItem(pouch)
        widget:setShowCount(false)
    end
    widget.onMouseRelease = function(self, mousePos, button)
        if button == MouseLeftButton and self:containsPoint(mousePos) then
            local module = purse()
            if module then
                module.toggle()
            end
            return true
        end
        return false
    end
    updatePurseSocket(widget)
    return widget
end

-- The teleport rock socket, after the purse: every account has the rock for good (it is no item),
-- and a click opens the city picker next to it (game_lionfell_teleport).
local ROCK_LOOK = 3251 -- the red rock the teleport rock used to be

local function rockSocket(parent)
    local widget = g_ui.createWidget('LfContainerItem', parent)
    widget:setId('rockSocket')
    widget:setVirtual(true)
    widget:setDraggable(false)
    local rock = Item.create(ROCK_LOOK)
    if rock then
        widget:setItem(rock)
        widget:setShowCount(false)
    end
    widget:setTooltip(tr('Teleport rock: travel to any city. Yours for good - it is never lost. Click to choose a city.'))
    widget.onMouseRelease = function(self, mousePos, button)
        if button == MouseLeftButton and self:containsPoint(mousePos) then
            local module = modules.game_lionfell_teleport
            if module and module.request then
                local rect = self:getRect()
                module.request({ x = rect.x + rect.width, y = rect.y })
            end
            return true
        end
        return false
    end
    return widget
end

local function clearSocket(widget)
    if widget.socketLabel then
        widget.socketLabel:destroy()
        widget.socketLabel = nil
        widget:setTooltip(nil)
    end
end

-- the pack's bags and items, in the pack's own order
local function splitPack(pack)
    local bags, items = {}, {}
    for slot = 0, pack:getItemsCount() - 1 do
        local item = pack:getItem(slot)
        if item and item:isContainer() then
            bags[#bags + 1] = { item = item, slot = slot }
        elseif item then
            items[#items + 1] = { item = item, slot = slot }
        end
    end
    return bags, items
end

function isPack(container)
    local pack = packItem()
    local item = container and container:getContainerItem()
    return pack ~= nil and item ~= nil and item:getId() == pack:getId()
        and container:getCapacity() == PACK_SLOTS + BAG_SOCKETS
end

-- The pack's own container window (game_containers): the first row holds the four bag sockets,
-- the 24 item slots follow. Each cell still points at its item's real place in the pack, so
-- dragging in and out works as usual; an empty cell takes whatever is dropped on it.
function layoutPack(container)
    if not container or not container.itemsPanel or not isPack(container) then
        return
    end
    local panel = container.itemsPanel
    -- the sockets get a row of their own: invisible spacers fill the rest of it, however wide
    -- the window is
    local layout = panel:getLayout()
    local columns = layout and layout.getNumColumns and layout:getNumColumns() or BAG_SOCKETS
    local withPurse = columns > BAG_SOCKETS -- room for the purse in the socket row
    local withRock = columns > BAG_SOCKETS + 1 -- ... and for the teleport rock after it
    local wanted = math.max(0, columns - BAG_SOCKETS - (withPurse and 1 or 0) - (withRock and 1 or 0))
    if withPurse and not panel.lfPurse then
        panel.lfPurse = purseSocket(nil)
        panel:insertChild(BAG_SOCKETS + 1, panel.lfPurse)
    elseif not withPurse and panel.lfPurse then
        panel.lfPurse:destroy()
        panel.lfPurse = nil
    end
    if withRock and not panel.lfRock then
        panel.lfRock = rockSocket(nil)
        panel:insertChild(BAG_SOCKETS + 2, panel.lfRock)
    elseif not withRock and panel.lfRock then
        panel.lfRock:destroy()
        panel.lfRock = nil
    end
    panel.lfSpacers = panel.lfSpacers or {}
    while #panel.lfSpacers > wanted do
        table.remove(panel.lfSpacers):destroy()
    end
    while #panel.lfSpacers < wanted do
        local spacer = g_ui.createWidget('UIWidget')
        spacer:setPhantom(true)
        panel:insertChild(BAG_SOCKETS + 1 + (panel.lfPurse and 1 or 0) + (panel.lfRock and 1 or 0), spacer)
        table.insert(panel.lfSpacers, spacer)
    end
    if not panel.lfResizeHooked then
        panel.lfResizeHooked = true
        panel.onGeometryChange = function()
            if not panel.lfRelayout then
                panel.lfRelayout = true
                addEvent(function()
                    panel.lfRelayout = nil
                    if container.itemsPanel == panel then
                        layoutPack(container)
                    end
                end)
            end
        end
    end

    local bags, items = splitPack(container)

    local append = container:getSlotPosition(container:getItemsCount())
    for i = 0, container:getCapacity() - 1 do
        local widget = panel:getChildById('item' .. i)
        if widget then
            local entry
            if i < BAG_SOCKETS then
                entry = bags[i + 1]
                styleSocket(widget, i + 1, entry and entry.item)
            else
                entry = items[i - BAG_SOCKETS + 1]
                clearSocket(widget)
            end
            widget:setItem(entry and entry.item)
            widget.position = entry and container:getSlotPosition(entry.slot) or append
            ItemsDatabase.setRarityItem(widget, entry and entry.item)
            ItemsDatabase.setTier(widget, entry and entry.item)
        end
    end
end

-- The pack window opens tall enough for the socket row and its items (game_containers sizes a
-- window by its item count only). Called once, after the window is set up.
function sizePack(container)
    local panel = container and container.itemsPanel
    if not panel or not container.window or not isPack(container) then
        return
    end
    local layout = panel:getLayout()
    local columns = math.max(1, layout:getNumColumns())
    local _, items = splitPack(container)
    local step = layout:getCellSize().height + layout:getCellSpacing()
    local itemRows = math.max(1, math.ceil(#items / columns))
    local chrome = container:hasPages() and 55 or 31
    container.window:setContentHeight((1 + itemRows) * step + chrome)
end

local function section(text)
    local label = g_ui.createWidget('LfBagSectionTitle', content)
    label:setText(text)
    return g_ui.createWidget('LfBagGrid', content)
end

-- Opens the next bag in the pack that isn't open yet. One at a time: the client picks a free
-- container number only once the server has answered, so two at once would share a number.
local pendingOpen

-- Which open container is which bag, worked out again from the pack as it is now. Bags were
-- remembered by their slot in the pack, but the slots shift whenever an item goes in or out (the
-- server puts new items first): the window then took an open bag for a closed one and "used" it
-- again, which closes it - bags vanished and came back on every loot pickup. Now the open bag
-- containers are matched to the pack's bags by item type, in order.
local function remapBags(pack)
    local open = {} -- [item id] = sorted container ids
    for cid, container in pairs(g_game.getContainers()) do
        local containerItem = container:getContainerItem()
        if cid ~= pack:getId() and containerItem and (bagCids[cid] or adopted[cid]) then
            local list = open[containerItem:getId()] or {}
            open[containerItem:getId()] = list
            list[#list + 1] = cid
        end
    end
    for _, list in pairs(open) do
        table.sort(list)
    end
    local mapped = {}
    for slot = 0, pack:getItemsCount() - 1 do
        local item = pack:getItem(slot)
        local list = item and item:isContainer() and open[item:getId()]
        if list and #list > 0 then
            mapped[table.remove(list, 1)] = slot
        end
    end
    -- the bag still on its way (asked for, not open yet)
    if pendingOpen and bagCids[pendingOpen] and not mapped[pendingOpen] then
        mapped[pendingOpen] = bagCids[pendingOpen]
    end
    -- bags this window opened that left the pack: close them (their stock window is hidden)
    for cid in pairs(bagCids) do
        local container = g_game.getContainer(cid)
        if not mapped[cid] and container and not adopted[cid] and cid ~= pendingOpen then
            g_game.close(container)
        end
    end
    bagCids = mapped
end

local function openBags(pack)
    remapBags(pack)
    if pendingOpen then
        return
    end
    for slot = 0, pack:getItemsCount() - 1 do
        local item = pack:getItem(slot)
        if item and item:isContainer() then
            local open = false
            for _, openSlot in pairs(bagCids) do
                if openSlot == slot then
                    open = true
                end
            end
            if not open then
                -- already open in a window of its own (opening it again would close it, as in Tibia)
                for cid, container in pairs(g_game.getContainers()) do
                    local containerItem = container:getContainerItem()
                    if not open and not bagCids[cid] and cid ~= pack:getId() and containerItem
                        and containerItem:getId() == item:getId() then
                        bagCids[cid] = slot
                        adopted[cid] = true
                        hideStockWindow(container)
                        open = true
                    end
                end
            end
            if not open then
                local cid = g_game.open(item, nil)
                if cid then
                    bagCids[cid] = slot
                    pendingOpen = cid
                    -- no answer: the server already had it open (after a reconnect), so that "use"
                    -- closed it there; using it once more opens it
                    scheduleEvent(function()
                        if pendingOpen ~= cid or not window:isVisible() then
                            return
                        end
                        bagCids[cid] = nil
                        pendingOpen = nil
                        -- a slow answer (busy server) is not "no answer": if the bag is open by now,
                        -- keep it. Using an open bag again closes it, which made bags vanish and
                        -- come back.
                        for openCid, container in pairs(g_game.getContainers()) do
                            local containerItem = container:getContainerItem()
                            if containerItem and containerItem:getId() == item:getId() and openCid ~= pack:getId()
                                and not bagCids[openCid] then
                                bagCids[openCid] = slot
                                hideStockWindow(container)
                                scheduleRebuild()
                                openBags(pack)
                                return
                            end
                        end
                        local again = g_game.open(item, nil)
                        if again then
                            bagCids[again] = slot
                            pendingOpen = again
                        end
                    end, 2500)
                end
                return
            end
        end
    end
end

-- What the window shows, section by section: { title, cells = { { item, position } }, socket }.
local function describe(pack)
    local bags, items = splitPack(pack)
    local append = pack:getSlotPosition(pack:getItemsCount())
    local sections = {}

    local sockets = {}
    for i = 1, BAG_SOCKETS do
        local entry = bags[i]
        sockets[i] = { entry and entry.item, entry and pack:getSlotPosition(entry.slot) or append }
    end
    sections[1] = { title = tr('BAGS  %d / %d', #bags, BAG_SOCKETS), cells = sockets, socket = true }

    local slots = {}
    for i = 1, PACK_SLOTS do
        local entry = items[i]
        slots[i] = { entry and entry.item, entry and pack:getSlotPosition(entry.slot) or append }
    end
    sections[2] = { title = tr('PACK  %d / %d', #items, PACK_SLOTS), cells = slots }

    local used, total = #items, PACK_SLOTS
    for _, entry in ipairs(bags) do
        local bag
        for cid, slot in pairs(bagCids) do
            local container = g_game.getContainer(cid)
            if container and slot == entry.slot then
                bag = container
            end
        end
        local name = entry.item:getMarketData() and entry.item:getMarketData().name or tr('bag')
        if bag then
            hideStockWindow(bag)
            local cached = { id = entry.item:getId(), name = name, capacity = bag:getCapacity(), items = {} }
            local cells = {}
            for slot = 0, bag:getCapacity() - 1 do
                cells[#cells + 1] = { bag:getItem(slot), bag:getSlotPosition(slot) }
                cached.items[slot + 1] = cells[#cells]
            end
            bagCache[entry.slot] = cached
            sections[#sections + 1] = { title = string.upper(string.format('%s  %d / %d', name, bag:getItemsCount(), bag:getCapacity())),
                cells = cells }
            used, total = used + bag:getItemsCount(), total + bag:getCapacity()
        else
            -- not open (yet, or again): its last view, so the section doesn't vanish meanwhile
            local cached = bagCache[entry.slot]
            if cached and cached.id == entry.item:getId() then
                local count = 0
                for _, c in ipairs(cached.items) do
                    count = count + (c[1] and 1 or 0)
                end
                sections[#sections + 1] = { title = string.upper(string.format('%s  %d / %d', cached.name, count, cached.capacity)),
                    cells = cached.items }
                used, total = used + count, total + cached.capacity
            end
        end
    end
    return sections, tr('%d / %d', used, total)
end

local function shapeOf(sections)
    local parts = {}
    for _, section in ipairs(sections) do
        parts[#parts + 1] = #section.cells
    end
    return table.concat(parts, ',')
end

local function setCell(widget, item, position)
    widget:setItem(item)
    widget.position = position
    ItemsDatabase.setRarityItem(widget, item)
    ItemsDatabase.setTier(widget, item)
    if item then
        widget:setShowCharges(true)
    end
end

-- Builds the window, or when only items changed (the same sections and sizes), updates the cells it
-- already has: tearing everything down on every loot pickup made the window flash.
local function rebuild()
    refreshEvent = nil
    if not window:isVisible() then
        return
    end
    -- never while an item is being dragged: the cell it came from would vanish under the mouse
    if g_ui.getDraggingWidget() then
        refreshEvent = scheduleEvent(rebuild, 150)
        return
    end
    local pack = packContainer()
    if not pack then
        if not view then
            content:destroyChildren()
            summary:setText('')
            local label = g_ui.createWidget('LfBagSectionTitle', content)
            label:setText(tr('Opening your pack...'))
        end
        return -- keep showing the last view while the pack reopens
    end
    hideStockWindow(pack)

    local sections, total = describe(pack)
    local shape = shapeOf(sections)
    if view and view.shape == shape and not view.stale then
        for s, section in ipairs(sections) do
            local built = view.sections[s]
            built.label:setText(section.title)
            for c, data in ipairs(section.cells) do
                setCell(built.cells[c], data[1], data[2])
                if section.socket then
                    styleSocket(built.cells[c], c, data[1])
                end
            end
        end
        summary:setText(total)
        return
    end

    content:destroyChildren()
    view = { shape = shape, sections = {} }
    for s, section in ipairs(sections) do
        local label = g_ui.createWidget('LfBagSectionTitle', content)
        label:setText(section.title)
        local grid = g_ui.createWidget('LfBagGrid', content)
        local built = { label = label, cells = {} }
        for c, data in ipairs(section.cells) do
            local widget = cell(grid, data[1], data[2])
            if section.socket then
                styleSocket(widget, c, data[1])
            end
            built.cells[c] = widget
        end
        if section.socket then
            purseSocket(grid)
            rockSocket(grid)
        end
        view.sections[s] = built
    end
    summary:setText(total)
end

scheduleRebuild = function()
    if window and window:isVisible() and not refreshEvent then
        refreshEvent = scheduleEvent(rebuild, 50)
    end
end

-- ---------------------------------------------------------------------------------------------
-- Container events

local function onContainerOpen(container)
    if not window:isVisible() then
        -- the pack opened from the equipment slot (right click / use): show the whole bags view,
        -- not the pack's own 24-slot window
        if isPack(container) then
            packCid = container:getId()
            addEvent(function()
                hideStockWindow(container)
                show()
            end)
        end
        return
    end
    local pack = packItem()
    local item = container:getContainerItem()
    if pack and item and item:getId() == pack:getId() and not packCid then
        packCid = container:getId()
    end
    if container:getId() == pendingOpen then
        pendingOpen = nil
    end
    local pack = packContainer()
    if pack then
        openBags(pack) -- the next bag, if any
    end
    if isOurs(container) then
        container.packSlot = bagCids[container:getId()]
        addEvent(function() hideStockWindow(container) end)
    end
    scheduleRebuild()
end

local function onContainerClose(container)
    if container:getId() == packCid then
        packCid = nil
        -- the pack's window was closed while this one is open: the bags window needs it
        if window:isVisible() and packItem() then
            addEvent(function()
                if window:isVisible() and not packContainer() then
                    g_game.open(packItem(), nil)
                end
            end)
        end
    end
    bagCids[container:getId()] = nil
    adopted[container:getId()] = nil
    scheduleRebuild()
end

local function onContainerChange(container)
    if isOurs(container) then
        local pack = packContainer()
        if pack and container:getId() == pack:getId() then
            openBags(pack) -- a bag was added
        end
        scheduleRebuild()
    end
end

-- ---------------------------------------------------------------------------------------------
-- Window

function show()
    if not g_game.isOnline() then
        return
    end
    window:show()
    window:raise()
    local pack = packContainer()
    if pack then
        packCid = pack:getId()
        openBags(pack)
    elseif packItem() then
        g_game.open(packItem(), nil)
    end
    scheduleRebuild()
end

function hide()
    window:hide()
    view = nil
    -- close what this window opened; bags that were open before get their own windows back
    for cid in pairs(bagCids) do
        local container = g_game.getContainer(cid)
        if container and adopted[cid] then
            if container.window and not container.window:isDestroyed() then
                container.window:show()
            end
        elseif container then
            g_game.close(container)
        end
    end
    adopted = {}
    bagCids, pendingOpen = {}, nil
    -- the pack closes with this window (its own 24-slot window would stay behind otherwise)
    local pack = packContainer()
    if pack then
        g_game.close(pack)
    end
    packCid = nil
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

local function onGameEnd()
    window:hide()
    view, bagCache = nil, {}
    bagCids, packCid, pendingOpen, adopted = {}, nil, nil, {}
end

function init()
    window = g_ui.loadUI('bags', modules.game_interface.getRootPanel())
    content = window:getChildById('content')
    summary = window:getChildById('summary')
    window.onEscape = hide
    connect(Container, {
        onOpen = onContainerOpen,
        onClose = onContainerClose,
        onAddItem = onContainerChange,
        onRemoveItem = onContainerChange,
        onUpdateItem = onContainerChange,
        onSizeChange = onContainerChange,
    })
    connect(g_game, { onGameEnd = onGameEnd })
    -- the purse sockets' tooltips follow the balance
    if purse() and purse().onBalance then
        purse().onBalance(function()
            for _, container in pairs(g_game.getContainers()) do
                local panel = container.itemsPanel
                if panel and panel.lfPurse and not panel.lfPurse:isDestroyed() then
                    updatePurseSocket(panel.lfPurse)
                end
            end
            local socket = content and content:recursiveGetChildById('purseSocket')
            if socket then
                updatePurseSocket(socket)
            end
        end)
    end
    -- B opens the bags (only while the chat input is closed: then B types instead)
    Keybind.new("UI", "Open bags", { [CHAT_MODE.ON] = "", [CHAT_MODE.OFF] = "B" }, "")
    Keybind.bind("UI", "Open bags", { { type = KEY_DOWN, callback = toggle } })
end

function terminate()
    disconnect(Container, {
        onOpen = onContainerOpen,
        onClose = onContainerClose,
        onAddItem = onContainerChange,
        onRemoveItem = onContainerChange,
        onUpdateItem = onContainerChange,
        onSizeChange = onContainerChange,
    })
    disconnect(g_game, { onGameEnd = onGameEnd })
    Keybind.delete("UI", "Open bags")
    if refreshEvent then
        removeEvent(refreshEvent)
    end
    window:destroy()
end
