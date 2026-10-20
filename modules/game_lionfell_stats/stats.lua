-- Lionfell stats in the Skills window: the server (data/scripts/lionfell/lf_stats.lua, opcode 128)
-- sends what the item lines, gems and talents add up to, total armor and resistances; they are
-- listed under the skills in place of the Tibia special skills (critical hit, leech, fatal, dodge,
-- momentum...), which Lionfell doesn't use and which always showed 0.

local OPCODE = 128
local ROW_PREFIX = 'lionfellStat_'
-- the Tibia special-skill rows this replaces (game_skills skills.otui)
local TIBIA_ROWS = { 'skillId7', 'skillId8', 'skillId9', 'skillId10', 'skillId11', 'skillId12', 'skillId13',
    'skillId14', 'skillId15', 'skillId16' }
local ELEMENTS = { { 'physical', 'Physical' }, { 'fire', 'Fire' }, { 'ice', 'Ice' }, { 'energy', 'Energy' },
    { 'earth', 'Earth' }, { 'holy', 'Holy' }, { 'death', 'Death' } }
local HEADER_COLOR = '#E0C070'
local BONUS_COLOR = '#44AD25'

local last -- the last stats received

local function skillsWindow()
    return modules.game_skills and modules.game_skills.skillsWindow
end

local function percent(v) return v .. '%' end
local function plusPercent(v) return (v > 0 and '+' or '') .. v .. '%' end
local function plus(v) return (v > 0 and '+' or '') .. v end

-- rows: { name, value text, highlight? } or { header = text }; zero extras are left out
local function buildRows(s)
    local rows = {}
    local function add(name, value, show, highlight)
        if show then
            rows[#rows + 1] = { name, value, highlight }
        end
    end
    rows[#rows + 1] = { header = 'Offence' }
    add('Damage', plusPercent(s.damage), true, s.damage > 0)
    add('Spell Damage', plusPercent(s.spell), s.spell ~= 0, true)
    add('Critical Chance', percent(s.crit), true, s.crit > 0)
    add('Critical Damage', plusPercent(s.critDamage), s.crit > 0, false)
    add('Attack Twice', percent(s.double), s.double > 0, true)
    add('Life Leech', percent(s.leech), true, s.leech > 0)
    add('Mana from Spells', percent(s.focus), s.focus > 0, true)
    for _, e in ipairs(ELEMENTS) do
        local v = s.element and s.element[e[1]] or 0
        add(e[2] .. ' Damage', plus(v), v ~= 0, true)
    end
    rows[#rows + 1] = { header = 'Defence' }
    add('Armor', tostring(s.armor), true, false)
    add('Dodge', percent(s.dodge), true, s.dodge > 0)
    add('Fortitude (monsters)', percent(s.fortitude), s.fortitude > 0, true)
    add('Damage to Mana', percent(s.ward), s.ward > 0, true)
    add('Reflect', percent(s.reflect), s.reflect > 0, true)
    for _, e in ipairs(ELEMENTS) do
        local v = s.resist and s.resist[e[1]] or 0
        add(e[2] .. ' Resistance', percent(v), true, v > 0)
    end
    local extras = {
        { 'Healing', plusPercent(s.heal), s.heal ~= 0 },
        { 'Health Regen', plus(s.regen) .. ' / 6s', s.regen > 0 },
        { 'Mana Regen', plus(s.manaRegen) .. ' / 6s', s.manaRegen > 0 },
        { 'Speed', plus(s.speed), s.speed ~= 0 },
        { 'Capacity', plus(s.cap), s.cap ~= 0 },
        { 'Gold Found', plusPercent(s.gold), s.gold ~= 0 },
        { 'Experience', plusPercent(s.exp), s.exp ~= 0 },
    }
    local any = false
    for _, x in ipairs(extras) do
        any = any or x[3]
    end
    if any then
        rows[#rows + 1] = { header = 'Other' }
        for _, x in ipairs(extras) do
            add(x[1], x[2], x[3], true)
        end
    end
    return rows
end

local function clearRows(contents)
    for _, child in ipairs(contents:getChildren()) do
        if child:getId():find('^' .. ROW_PREFIX) then
            child:destroy()
        end
    end
end

local function show()
    local window = skillsWindow()
    if not window or not last then
        return
    end
    local contents = window:getChildById('contentsPanel')
    local separator = window:recursiveGetChildById('separadorOnOffenceInfoChange')
    if not contents or not separator then
        return
    end
    for _, id in ipairs(TIBIA_ROWS) do
        local row = window:recursiveGetChildById(id)
        if row then
            row:setVisible(false)
        end
    end
    clearRows(contents)
    local index = contents:getChildIndex(separator)
    for i, row in ipairs(buildRows(last)) do
        local widget = g_ui.createWidget('SmallSkillButton')
        widget:setId(ROW_PREFIX .. i)
        local name = g_ui.createWidget('SkillNameLabel', widget)
        if row.header then
            name:setText(row.header)
            name:setColor(HEADER_COLOR)
            widget:setMarginTop(i > 1 and 4 or 0)
        else
            name:setText(row[1])
            local value = g_ui.createWidget('SkillValueLabel', widget)
            value:setText(row[2])
            if row[3] then
                value:setColor(BONUS_COLOR)
            end
        end
        index = index + 1
        contents:insertChild(index, widget)
    end
    if modules.game_skills.updateHeight then
        modules.game_skills.updateHeight()
    end
end

local function onMessage(protocol, opcode, buffer)
    local ok, stats = pcall(json.decode, buffer)
    if ok and type(stats) == 'table' then
        last = stats
        show()
    end
end

local function request()
    local protocol = g_game.getProtocolGame()
    if protocol then
        protocol:sendExtendedOpcode(OPCODE, 'get')
    end
end

local function onGameStart()
    -- after game_skills has set up its rows (it shows/hides groups shortly after the game starts)
    scheduleEvent(request, 500)
end

local function onGameEnd()
    last = nil
    local window = skillsWindow()
    local contents = window and window:getChildById('contentsPanel')
    if contents then
        clearRows(contents)
    end
end

function init()
    ProtocolGame.registerExtendedOpcode(OPCODE, onMessage)
    connect(g_game, { onGameStart = onGameStart, onGameEnd = onGameEnd })
    if g_game.isOnline() then
        onGameStart()
    end
end

function terminate()
    disconnect(g_game, { onGameStart = onGameStart, onGameEnd = onGameEnd })
    ProtocolGame.unregisterExtendedOpcode(OPCODE)
    onGameEnd()
end
