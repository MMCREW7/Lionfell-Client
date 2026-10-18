-- Lionfell teleport rock: every account has one, in the sixth bag socket (game_lionfell_bags).
-- Clicking it asks the server (extended opcode 127, data/scripts/lionfell/items/teleport_rock.lua),
-- which answers with the cities unless the player is in a fight or the rock is recharging; a small
-- menu opens next to the socket and a click on a city travels there.

local OPCODE = 127
local layer, menu, anchor

local function send(text)
    local protocol = g_game.getProtocolGame()
    if protocol then
        protocol:sendExtendedOpcode(OPCODE, text)
    end
end

function hide()
    if layer and layer:isVisible() then
        rootWidget:unlockChild(layer)
        layer:hide()
    end
end

-- the socket was clicked: `point` is where the menu should open (next to the socket)
function request(point)
    anchor = point
    send('open')
end

local function go(name)
    send('go|' .. name)
    hide()
end

local function show(names)
    local list = menu:getChildById('cities')
    list:destroyChildren()
    for name in names:gmatch('[^,]+') do
        local button = g_ui.createWidget('LfTeleportCity', list)
        button:setText(name)
        button.onClick = function() go(name) end
    end
    layer:show()
    layer:raise()
    rootWidget:lockChild(layer)
    layer:focus()
    -- next to the socket, kept on screen (the height follows the cities once laid out)
    addEvent(function()
        if not layer:isVisible() then
            return
        end
        local screen = rootWidget:getSize()
        local point = anchor or g_window.getMousePosition()
        local x = math.min(point.x + 8, screen.width - menu:getWidth() - 8)
        local y = math.min(point.y, screen.height - menu:getHeight() - 8)
        menu:setPosition({ x = math.max(8, x), y = math.max(8, y) })
    end)
end

local function onMessage(protocol, opcode, buffer)
    local names = buffer:match('^cities|(.*)$')
    if names then
        show(names)
    end
end

function init()
    layer = g_ui.loadUI('teleport', rootWidget)
    layer:hide()
    menu = layer:getChildById('teleportMenu')
    layer.onKeyDown = function(self, keyCode)
        if keyCode == KeyEscape then
            hide()
        end
        return true
    end
    layer.onKeyPress = function() return true end
    ProtocolGame.registerExtendedOpcode(OPCODE, onMessage)
    connect(g_game, { onGameEnd = hide })
end

function terminate()
    hide()
    ProtocolGame.unregisterExtendedOpcode(OPCODE)
    disconnect(g_game, { onGameEnd = hide })
    if layer then
        layer:destroy()
        layer = nil
    end
end
