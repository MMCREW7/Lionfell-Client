-- Lionfell NPC buttons: when an NPC talks to the player, the keywords in its message ("ask me for a
-- {trade}") become buttons in a small box above its head - or Yes / No for a question - and a click
-- says that word to the NPC, as if typed in the NPC channel. The box follows the NPC and closes on Bye, when the player walks away,
-- the NPC leaves the screen, or the conversation goes quiet.

local MAX_DISTANCE = 4
local IDLE_MS = 60000
local box, npc, lastTalk, updateEvent

local function hide()
    if box then
        box:hide()
    end
    npc = nil
    if updateEvent then
        removeEvent(updateEvent)
        updateEvent = nil
    end
end

local function say(word)
    g_game.talkChannel(MessageModes.NpcTo, 0, word)
    lastTalk = g_clock.millis()
end

-- keep the box above the NPC's head; close it when the conversation is over
local function place()
    local player = g_game.getLocalPlayer()
    if not npc or not player or npc:isRemoved() then
        return hide()
    end
    local pos, ppos = npc:getPosition(), player:getPosition()
    if pos.z ~= ppos.z or math.max(math.abs(pos.x - ppos.x), math.abs(pos.y - ppos.y)) > MAX_DISTANCE
        or g_clock.millis() - lastTalk > IDLE_MS then
        return hide()
    end
    local map = modules.game_interface.getMapPanel()
    local rect = map and map:getTileRect(pos)
    if not rect or rect.width <= 1 then
        return box:hide()
    end
    -- creatures are drawn a little up and left of their tile; the name sits above that
    local x = rect.x + rect.width / 2 - box:getWidth() / 2
    local y = rect.y - rect.height * 0.6 - box:getHeight() - 14
    box:setPosition({ x = math.floor(x), y = math.floor(y) })
    if not box:isVisible() then
        box:show()
    end
end

local function findNpc(name, position)
    local player = g_game.getLocalPlayer()
    if not player then
        return nil
    end
    for _, creature in ipairs(g_map.getSpectators(player:getPosition(), false)) do
        if creature:isNpc() and creature:getName() == name then
            local at = creature:getPosition()
            if not position or position.x == 0
                or (at.z == position.z and math.max(math.abs(at.x - position.x), math.abs(at.y - position.y)) <= 1) then
                return creature
            end
        end
    end
    return nil
end

local function show(creature, keywords)
    box:destroyChildren()
    for _, word in ipairs(keywords) do
        local button = g_ui.createWidget('LfNpcKeyword', box)
        button:setText(word)
        button.onClick = function() say(word) end
    end
    local bye = g_ui.createWidget('LfNpcKeywordBye', box)
    bye:setText(tr('Bye'))
    bye.onClick = function() say('bye') hide() end
    npc = creature
    lastTalk = g_clock.millis()
    box:raise()
    if not updateEvent then
        updateEvent = cycleEvent(place, 50)
    end
    place()
end

local function onTalk(name, level, mode, message, channelId, creaturePos)
    if mode ~= MessageModes.NpcFrom and mode ~= MessageModes.NpcFromStartBlock then
        return
    end
    local creature = findNpc(name, creaturePos)
    if not creature then
        return
    end
    local keywords, seen = {}, {}
    for word in message:gmatch('{([^{}]+)}') do
        local key = word:lower()
        if not seen[key] and key ~= 'bye' then
            seen[key] = true
            keywords[#keywords + 1] = word
        end
    end
    if #keywords == 0 and message:find('%?%s*$') and npc == creature then
        -- a question without keywords ("... for 500 gold?"): answer it with a click
        keywords = { 'yes', 'no' }
    end
    if #keywords == 0 then
        -- a reply without new keywords (a price, a farewell): keep the current buttons
        if npc == creature then
            lastTalk = g_clock.millis()
        end
        return
    end
    show(creature, keywords)
end

function init()
    box = g_ui.loadUI('npcchat', modules.game_interface.getRootPanel())
    box:hide()
    connect(g_game, { onTalk = onTalk, onGameEnd = hide })
end

function terminate()
    disconnect(g_game, { onTalk = onTalk, onGameEnd = hide })
    hide()
    if box then
        box:destroy()
        box = nil
    end
end
