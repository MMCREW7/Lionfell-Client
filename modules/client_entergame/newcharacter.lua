-- Lionfell: create a character from the character list.
--
-- The client never talks to the database. It posts the request to the Lionfell website
-- (lionfell_web ApiController, POST /api/characters on port 4000 of the game host), which checks
-- the account's name/email and password on every request, rate-limits failed log-ins and
-- creations, and validates the name, vocation and character limit exactly like its own sign-up
-- pages. The traffic stays on the tailnet (WireGuard-encrypted). The password is the one already
-- typed for this log-in; it is only held in memory and never written anywhere.

NewCharacter = {}

local VOCATIONS = { -- TFS vocation ids
    { id = 4, name = 'Knight' },
    { id = 3, name = 'Paladin' },
    { id = 1, name = 'Sorcerer' },
    { id = 2, name = 'Druid' },
}
local SEXES = { { id = 1, name = 'Male' }, { id = 0, name = 'Female' } }
local TIMEOUT = 15 -- seconds

local window
local choice = { vocation = nil, sex = 1 }
local pending -- the request in flight; replies to anything else are ignored

local function websiteUrl()
    local host = G.host or ''
    host = host:gsub('^https?://', ''):gsub('[:/].*$', '')
    if host == '' then
        host = (Servers_init and next(Servers_init)) or '127.0.0.1'
        host = tostring(host):gsub('^https?://', ''):gsub('[:/].*$', '')
    end
    return 'http://' .. host .. ':4000/api/characters'
end

local function setMessage(text, ok)
    if not window then return end
    local label = window:getChildById('message')
    label:setText(text or '')
    label:setColor(ok and '#8fb08a' or '#d9a29b')
end

local function setBusy(busy)
    if not window then return end
    window:getChildById('createButton'):setEnabled(not busy)
    window:getChildById('createButton'):setText(busy and tr('Creating...') or tr('Create'))
    window:getChildById('name'):setEnabled(not busy)
end

local function refreshSegments(bar, key)
    for _, segment in ipairs(bar:getChildren()) do
        segment:setOn(segment.value == choice[key])
    end
end

local function fillSegments(bar, list, key)
    bar:destroyChildren()
    for _, entry in ipairs(list) do
        local segment = g_ui.createWidget('NewCharacterSegment', bar)
        segment:setText(tr(entry.name))
        segment.value = entry.id
        segment.onClick = function()
            choice[key] = entry.id
            refreshSegments(bar, key)
        end
    end
    refreshSegments(bar, key)
end

-- "aldric   vane" -> "Aldric Vane" (the site does the same; this only gives faster feedback)
local function tidyName(text)
    text = (text or ''):gsub('^%s+', ''):gsub('%s+$', ''):gsub('%s+', ' ')
    return (text:lower():gsub("(%a)([%a]*)", function(first, rest) return first:upper() .. rest end))
end

local function checkLocally(name)
    if #name < 3 or #name > 24 or not name:match('^[%a ]+$') then
        return tr('Names are 3 to 24 letters and spaces.')
    end
    if not choice.vocation then
        return tr('Choose a vocation.')
    end
    return nil
end

local function describeErrors(errors)
    if type(errors) ~= 'table' then
        return tr('That character isn\'t allowed.')
    end
    local parts = {}
    for _, field in ipairs({ 'name', 'vocation', 'sex' }) do
        if type(errors[field]) == 'string' then
            table.insert(parts, errors[field])
        end
    end
    for field, text in pairs(errors) do
        if field ~= 'name' and field ~= 'vocation' and field ~= 'sex' and type(text) == 'string' then
            table.insert(parts, text)
        end
    end
    return #parts > 0 and table.concat(parts, ' ') or tr('That character isn\'t allowed.')
end

-- log in again so the list comes back from the server with the new character, focused
local function reloadList(name)
    g_settings.set('last-used-character', name)
    local focused = CharacterList.getFocusedWorld and CharacterList.getFocusedWorld()
    if focused then
        g_settings.set('last-used-world', focused)
    end
    local account, password = G.account, G.password
    NewCharacter.hide()
    -- the login screen forgets the password after logging in unless it is remembered; doLogin
    -- reads the fields, and clears them again the same way
    local enterGame = rootWidget:recursiveGetChildById('enterGame')
    if enterGame and EnterGame and EnterGame.doLogin then
        enterGame:getChildById('accountNameTextEdit'):setText(account or '')
        enterGame:getChildById('accountPasswordTextEdit'):setText(password or '')
        EnterGame.doLogin()
    end
end

local function onReply(request, data, err)
    if request ~= pending then
        return
    end
    pending = nil
    setBusy(false)
    if err then
        if tostring(err):find('http_status::413') then
            setMessage(tr('That request was too large.'))
        else
            g_logger.warning('[new character] request failed: ' .. tostring(err))
            setMessage(tr('Couldn\'t reach the Lionfell website. Try again in a moment, or create the character there.'))
        end
        return
    end
    if type(data) ~= 'table' then
        setMessage(tr('The website gave an unexpected answer.'))
        return
    end
    if data.ok == true and type(data.name) == 'string' then
        setMessage(tr('%s is ready.', data.name), true)
        scheduleEvent(function() reloadList(data.name) end, 600)
    elseif data.code == 'invalid' then
        setMessage(describeErrors(data.errors))
    else
        setMessage(type(data.error) == 'string' and data.error or tr('That didn\'t work. Try again.'))
    end
end

function NewCharacter.submit()
    if not window or pending then
        return
    end
    local nameEdit = window:getChildById('name')
    local name = tidyName(nameEdit:getText())
    nameEdit:setText(name)
    local problem = checkLocally(name)
    if problem then
        setMessage(problem)
        return
    end
    if not G.account or G.account == '' or not G.password or G.password == '' then
        setMessage(tr('Log out and log in with your account name and password first.'))
        return
    end
    if not g_http or not g_http.post then
        setMessage(tr('This client can\'t send web requests.'))
        return
    end

    local body = json.encode({
        account = G.account,
        password = G.password,
        name = name,
        sex = choice.sex,
        vocation = choice.vocation,
    })
    setMessage('')
    setBusy(true)
    local request = {}
    pending = request
    local operation = g_http.post(websiteUrl(), body, TIMEOUT, true)
    HTTP.operations[operation] = {
        type = 'post', json = true, url = 'api/characters',
        callback = function(data, err) onReply(request, data, err) end,
    }
    body = nil
end

function NewCharacter.show()
    if not window then
        window = g_ui.displayUI('newcharacter'):getChildById('newCharacterWindow')
        fillSegments(window:getChildById('vocations'), VOCATIONS, 'vocation')
        fillSegments(window:getChildById('sexes'), SEXES, 'sex')
    end
    pending = nil
    setBusy(false)
    setMessage('')
    window:getChildById('name'):setText('')
    window:getParent():raise()
    window:getParent():focus()
    window:getChildById('name'):focus()
end

function NewCharacter.hide()
    pending = nil
    if window then
        window:getParent():destroy() -- the scrim
        window = nil
    end
    choice.vocation = nil
end

function NewCharacter.terminate()
    NewCharacter.hide()
end
