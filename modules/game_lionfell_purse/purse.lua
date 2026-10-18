-- Lionfell coin purse. The server keeps a player's money in the bank (looted coins go straight
-- there: data/scripts/lionfell/lf_purse.lua); this window shows it as the coins it would make and
-- takes coins out into the backpack. Opened from the purse socket next to the pack's bag sockets
-- (game_lionfell_bags).
--
-- Opcode 124: we send "open" | "take|<amount>", the server answers with JSON
-- ({"type":"balance","balance":N} or {"type":"result","ok":bool,"message":"..."}).

local OPCODE = 124
-- coin client ids, largest first, and their worth in gold
local COINS = { { id = 3043, worth = 10000 }, { id = 3035, worth = 100 }, { id = 3031, worth = 1 } }
local STACK = 100
local MAX_CELLS = 18

window = nil
local balance = 0
local listeners = {}

local function send(...)
    local protocol = g_game.getProtocolGame()
    if protocol then
        protocol:sendExtendedOpcode(OPCODE, table.concat({ ... }, '|'))
    end
end

function formatGold(value)
    local text = tostring(math.floor(value or 0))
    return (text:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', ''))
end

function getBalance()
    return balance
end

-- other modules (the purse socket) hear about balance changes: onBalance(callback)
function onBalance(callback)
    listeners[#listeners + 1] = callback
end

-- the coin stacks that make up an amount: crystal, platinum, gold, at most 100 to a stack
local function stacks(amount)
    local list = {}
    for _, coin in ipairs(COINS) do
        local count = math.floor(amount / coin.worth)
        amount = amount - count * coin.worth
        while count > 0 do
            list[#list + 1] = { id = coin.id, count = math.min(STACK, count) }
            count = count - STACK
        end
    end
    return list
end

local function refresh()
    if not window then
        return
    end
    window:getChildById('total'):setText(formatGold(balance) .. ' gp')
    local grid = window:getChildById('coins')
    grid:destroyChildren()
    local list = stacks(balance)
    for i, stack in ipairs(list) do
        if i == MAX_CELLS and #list > MAX_CELLS then
            local more = g_ui.createWidget('LfPurseCoin', grid)
            more:setText('+' .. (#list - MAX_CELLS + 1))
            break
        end
        local cell = g_ui.createWidget('LfPurseCoin', grid)
        local item = Item.create(stack.id)
        if item then
            item:setCount(stack.count) -- the pile art follows the count
            cell:setItem(item)
        end
        cell:setPhantom(false)
        cell:setTooltip(string.format('%d %s', stack.count, stack.id == 3043 and 'crystal coins' or
            (stack.id == 3035 and 'platinum coins' or 'gold coins')))
    end
    if #list == 0 then
        local empty = g_ui.createWidget('LfMuted', grid)
        empty:setText(tr('Empty.'))
    end
end

local function setStatus(text, ok)
    if not window then
        return
    end
    local status = window:getChildById('status')
    status:setText(text or '')
    status:setColor(ok == false and '#b9625a' or '#8d8a86')
end

local function onMessage(protocol, opcode, buffer)
    local ok, message = pcall(json.decode, buffer)
    if not ok or type(message) ~= 'table' then
        return
    end
    if message.type == 'balance' then
        balance = tonumber(message.balance) or 0
        refresh()
        for _, callback in ipairs(listeners) do
            pcall(callback, balance)
        end
    elseif message.type == 'result' then
        setStatus(message.message, message.ok)
        if message.ok then
            window:getChildById('amount'):setText('')
        end
    end
end

function take()
    local text = window:getChildById('amount'):getText():gsub('[^%d]', '')
    local amount = tonumber(text)
    if not amount or amount < 1 then
        setStatus(tr('Enter an amount of gold.'), false)
        return
    end
    send('take', amount)
end

function show()
    if not window or not g_game.isOnline() then
        return
    end
    setStatus('')
    window:show()
    window:raise()
    window:focus()
    window:getChildById('amount'):focus()
    send('open')
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

local function onGameStart()
    send('open') -- the socket's tooltip shows the balance from the start
end

function init()
    window = g_ui.loadUI('purse', modules.game_interface.getRootPanel())
    window:hide()
    -- Enter in the amount box takes the coins out (text fields have no Enter event of their own)
    window:getChildById('amount').onKeyDown = function(self, keyCode)
        if keyCode == KeyEnter then
            take()
            return true
        end
        return false
    end
    ProtocolGame.registerExtendedOpcode(OPCODE, onMessage)
    connect(g_game, { onGameStart = onGameStart, onGameEnd = hide })
    if g_game.isOnline() then
        onGameStart()
    end
end

function terminate()
    disconnect(g_game, { onGameStart = onGameStart, onGameEnd = hide })
    ProtocolGame.unregisterExtendedOpcode(OPCODE)
    if window then
        window:destroy()
        window = nil
    end
end
