-- Lionfell map marks: point at a tile on the game map and press Ctrl+Shift+K. The coordinates go
-- to the clipboard; a note (what should go there) can be added, and Enter sends the mark to the
-- server's mark log (data/scripts/lionfell/lf_marks.lua, staff only). Extended opcode 126.

local OPCODE = 126
local KEY = 'Ctrl+Shift+K'
local window
local marked -- the position being marked

local function message(text)
    if modules.game_textmessage and modules.game_textmessage.displayMessage then
        modules.game_textmessage.displayMessage(MessageModes.Look, text)
    else
        g_logger.info(text)
    end
end

-- the tile under the mouse on the game map, or nil when the mouse is somewhere else
local function pointedPosition()
    local map = modules.game_interface.getMapPanel and modules.game_interface.getMapPanel()
    local mouse = g_window.getMousePosition()
    if not map or not map:isVisible() or not map:containsPoint(mouse) then
        return nil
    end
    local tile = map:getTile(mouse)
    return tile and tile:getPosition() or nil
end

local function positionText(pos)
    return string.format('%d, %d, %d', pos.x, pos.y, pos.z)
end

function show()
    if not g_game.isOnline() then
        return
    end
    local pos = pointedPosition()
    if not pos then
        message(tr('Point at a spot on the map, then press %s.', KEY))
        return
    end
    marked = pos
    g_window.setClipboardText(positionText(pos))
    window:getChildById('position'):setText(positionText(pos) .. '   ' .. tr('(copied)'))
    window:getChildById('note'):setText('')
    window:show()
    window:raise()
    window:focus()
    window:getChildById('note'):focus()
end

function hide()
    if window then
        window:hide()
    end
end

function save()
    if not marked then
        return hide()
    end
    local note = window:getChildById('note'):getText():gsub('[|%c]', ' ')
    local protocol = g_game.getProtocolGame()
    if protocol then
        protocol:sendExtendedOpcode(OPCODE, string.format('mark|%d|%d|%d|%s', marked.x, marked.y, marked.z, note))
    end
    hide()
end

local function onMessage(protocol, opcode, buffer)
    local kind, text = buffer:match('^(%a+)|(.*)$')
    if text then
        message(text)
    end
end

function init()
    window = g_ui.loadUI('marks', modules.game_interface.getRootPanel())
    window:hide()
    g_keyboard.bindKeyDown(KEY, show, modules.game_interface.getRootPanel())
    ProtocolGame.registerExtendedOpcode(OPCODE, onMessage)
    connect(g_game, { onGameEnd = hide })
end

function terminate()
    g_keyboard.unbindKeyDown(KEY, show, modules.game_interface.getRootPanel())
    ProtocolGame.unregisterExtendedOpcode(OPCODE)
    disconnect(g_game, { onGameEnd = hide })
    if window then
        window:destroy()
        window = nil
    end
end
