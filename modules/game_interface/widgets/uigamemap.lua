UIGameMap = extends(UIMap, 'UIGameMap')

function UIGameMap.create()
    local gameMap = UIGameMap.internalCreate()
    gameMap:setKeepAspectRatio(true)
    gameMap:setVisibleDimension({
        width = 15,
        height = 11
    })
    gameMap:setDrawLights(true)
    return gameMap
end

function UIGameMap:onDragEnter(mousePos)
    local tile = self:getTile(mousePos)
    if not tile then
        return false
    end

    local thing = tile:getTopMoveThing()
    if not thing then
        return false
    end

    if thing:isItem() and not thing:isNotMoveable() then
        UIDragIcon:display(thing)
    end

    self.currentDragThing = thing

    -- Use native cursor when enabled, otherwise use custom cursor
    if modules.client_options and modules.client_options.getOption('nativeCursor') then
        g_window.setSystemCursor('cross')
    else
        g_mouse.pushCursor('target')
    end
    self.allowNextRelease = false
    return true
end

function UIGameMap:onDragLeave(droppedWidget, mousePos)
    self.currentDragThing = nil
    self.hoveredWho = nil
    -- Restore cursor
    if modules.client_options and modules.client_options.getOption('nativeCursor') then
        g_window.restoreMouseCursor()
    else
        g_mouse.popCursor('target')
    end
    UIDragIcon:hide()
    return true
end

function UIGameMap:onDrop(widget, mousePos)
    if not self:canAcceptDrop(widget, mousePos) then
        return false
    end

    local tile = self:getTile(mousePos)
    if not tile then
        return false
    end

    local thing = widget.currentDragThing
    local thingPos = thing:getPosition()
    if not thingPos then
        return false
    end

    local thingTile = thing:getTile()
    if thingPos.x ~= 65535 then
        if not thingTile then
            return false
        end
        if thingTile:getThingStackPos(thing) == -1 then
            return false
        end
    end

    local toPos = tile:getPosition()
    if thingPos.x == toPos.x and thingPos.y == toPos.y and thingPos.z == toPos.z then
        return false
    end

    if thing:isItem() and thing:getCount() > 1 then
        modules.game_interface.moveStackableItem(thing, toPos)
    else
        g_game.move(thing, toPos, 1)
    end

    UIDragIcon:hide()
    return true
end

-- Lionfell: the creature a tap at pos most likely meant - on the tiles right of / below it (the
-- tiles whose creatures are drawn over pos), then one walking within a tile; nil when none
function UIGameMap.creatureNear(pos)
    local player = g_game.getLocalPlayer()
    for _, d in ipairs({ { 1, 0 }, { 0, 1 }, { 1, 1 } }) do
        local tile = g_map.getTile({ x = pos.x + d[1], y = pos.y + d[2], z = pos.z })
        local creature = tile and tile:getTopCreature()
        if creature and creature ~= player then
            return creature
        end
    end
    for _, creature in ipairs(g_map.getSpectatorsInRange(pos, false, 1, 1)) do
        if creature ~= player and creature:isWalking() then
            return creature
        end
    end
    return nil
end

function UIGameMap:onMousePress()
    if not self:isDragging() then
        self.allowNextRelease = true
    end
end

function UIGameMap:onMouseMove()
    return false
end

function UIGameMap:onMouseRelease(mousePosition, mouseButton)
    if not self.allowNextRelease then
        return true
    end

    local autoWalkPos = self:getPosition(mousePosition)

    -- happens when clicking outside of map boundaries
    if not autoWalkPos then
        return false
    end

    local localPlayerPos = g_game.getLocalPlayer():getPosition()
    if autoWalkPos.z ~= localPlayerPos.z then
        local dz = autoWalkPos.z - localPlayerPos.z
        autoWalkPos.x = autoWalkPos.x + dz
        autoWalkPos.y = autoWalkPos.y + dz
        autoWalkPos.z = localPlayerPos.z
    end

    local lookThing
    local useThing
    local creatureThing
    local multiUseThing
    local attackCreature

    local tile = self:getTile(mousePosition)
    if tile then
        lookThing = tile:getTopLookThing()
        useThing = tile:getTopUseThing()
        creatureThing = tile:getTopCreature()
    end

    local autoWalkTile = g_map.getTile(autoWalkPos)
    if autoWalkTile then
        attackCreature = autoWalkTile:getTopCreature()
    end

    -- Lionfell, phones: a finger rarely lands on a creature's own tile (creatures are drawn up and
    -- left of it, and a walking one belongs to the tile it walks to): a tap next to one counts
    if g_platform.isMobile() and not attackCreature and not (creatureThing and creatureThing ~= g_game.getLocalPlayer()) then
        local near = UIGameMap.creatureNear(autoWalkPos)
        if near then
            creatureThing = near
            attackCreature = near
        end
    end

    local ret = modules.game_interface.processMouseAction(mousePosition, mouseButton, autoWalkPos, lookThing, useThing,
        creatureThing, attackCreature)
    if ret then
        self.allowNextRelease = false
    end

    return ret
end

function UIGameMap:canAcceptDrop(widget, mousePos)
    if not widget or not widget.currentDragThing then
        return false
    end

    local children = rootWidget:recursiveGetChildrenByPos(mousePos)
    for i = 1, #children do
        local child = children[i]
        if child == self then
            return true
        elseif not child:isPhantom() then
            return false
        end
    end

    error('Widget ' .. self:getId() .. ' not in drop list.')
    return false
end
