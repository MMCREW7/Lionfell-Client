-- Lionfell teleport rock: the server sends the cities when the rock is used; a click sends the
-- choice back (extended opcode 127, data/scripts/lionfell/items/teleport_rock.lua).

local OPCODE = 127
local window

function hide()
    if window then
        window:hide()
    end
end

local function go(name)
    local protocol = g_game.getProtocolGame()
    if protocol then
        protocol:sendExtendedOpcode(OPCODE, 'go|' .. name)
    end
    hide()
end

local function show(names)
    local list = window:getChildById('cities')
    list:destroyChildren()
    for name in names:gmatch('[^,]+') do
        local button = g_ui.createWidget('LfTeleportCity', list)
        button:setText(name)
        button.onClick = function() go(name) end
    end
    window:setHeight(14 + 20 + 4 + 18 + 12 + list:getChildCount() * 44 + 12 + 34 + 16)
    window:show()
    window:raise()
    window:focus()
end

local function onMessage(protocol, opcode, buffer)
    local names = buffer:match('^cities|(.*)$')
    if names then
        show(names)
    end
end

function init()
    window = g_ui.loadUI('teleport', modules.game_interface.getRootPanel())
    window:hide()
    ProtocolGame.registerExtendedOpcode(OPCODE, onMessage)
    connect(g_game, { onGameEnd = hide })
end

function terminate()
    ProtocolGame.unregisterExtendedOpcode(OPCODE)
    disconnect(g_game, { onGameEnd = hide })
    if window then
        window:destroy()
        window = nil
    end
end
