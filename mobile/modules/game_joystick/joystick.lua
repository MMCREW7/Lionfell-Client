local overlay
local keypad
local keypadUpdateEvent
local keypadMousePos = {x=0.5, y=0.5}
local firstStep = true
local moveListener

function init()
  if not g_platform.isMobile() then return end

  overlay = g_ui.displayUI('joystick')
  keypad = overlay.keypad

  connect(keypad, {
    onMousePress = onKeypadTouchPress,
    onMouseRelease = onKeypadTouchRelease,  
    onMouseMove = onKeypadTouchMove
  })

  connect(g_game, {
    onGameStart = onGameStart,
    onGameEnd = onGameEnd 
  })
end

function terminate()
  if not g_platform.isMobile() then return end

  removeEvent(keypadUpdateEvent)

  disconnect(keypad, {
    onMousePress = onKeypadTouchPress,
    onMouseRelease = onKeypadTouchRelease,  
    onMouseMove = onKeypadTouchMove
  })

  disconnect(g_game, {
    onGameStart = onGameStart,
    onGameEnd = onGameEnd 
  })

  overlay:destroy()
  overlay = nil
  keypadUpdateEvent = nil
end

function hide()
  overlay:hide()
end

function show()
  overlay:show()
end

function onGameStart()
  keypad:raise()
  keypad:show()
end

function onGameEnd()
  keypad:hide()
end

function addOnJoystickMoveListener(callback)
  moveListener = callback
end

-- Lionfell: the walk handler (for tools/lionfell_testclient tests of joystick walking)
function getMoveListener()
  return moveListener
end

function onKeypadTouchPress(widget, pos, button)
  if button ~= MouseLeftButton then return false end

  keypadMousePos = {x=(pos.x - widget:getPosition().x) / widget:getWidth(), 
                    y=(pos.y - widget:getPosition().y) / widget:getHeight()}

  firstStep = true
  executeWalk()

  return true
end

function onKeypadTouchMove(widget, pos, offset)
  keypadMousePos = {x=(pos.x - widget:getPosition().x) / widget:getWidth(), 
                    y=(pos.y - widget:getPosition().y) / widget:getHeight()}

  return true
end

function onKeypadTouchRelease(widget, pos, button)
  if button ~= MouseLeftButton then return false end

  keypadMousePos = {x=(pos.x - widget:getPosition().x) / widget:getWidth(), 
                    y=(pos.y - widget:getPosition().y) / widget:getHeight()}

  firstStep = false
  lastSector = nil
  executeWalk()
  removeEvent(keypadUpdateEvent)

  keypad.pointer:setMarginTop(0)
  keypad.pointer:setMarginLeft(0)

  return true
end

-- Lionfell (phone): the walking direction from the thumb's offset from the pad's centre (-0.5 ..
-- 0.5). By angle: the four straight directions get 60 degrees each, the diagonals 30 (diagonal
-- steps take 1.4x as long, and the old corner squares tipped a slightly-off push into one), and
-- the current direction is kept until the thumb is HYSTERESIS degrees past its edge, so the
-- character doesn't flicker between two directions. Inside DEADZONE: no step.
local DEADZONE = 0.12
local STRAIGHT_HALF, DIAGONAL_HALF = 30, 15
local HYSTERESIS = 8
-- sector centres (degrees; 0 = east, 90 = south on screen)
local SECTORS = {
  { 0, 'East' }, { 45, 'SouthEast' }, { 90, 'South' }, { 135, 'SouthWest' },
  { 180, 'West' }, { -135, 'NorthWest' }, { -90, 'North' }, { -45, 'NorthEast' },
}
local lastSector

local function angleDiff(a, b)
  local d = (a - b) % 360
  return d > 180 and 360 - d or d
end

function directionFor(dx, dy)
  if math.sqrt(dx * dx + dy * dy) < DEADZONE then
    lastSector = nil
    return nil
  end
  local angle = math.deg(math.atan2(dy, dx))
  if lastSector then
    local half = (lastSector[1] % 90 == 0) and STRAIGHT_HALF or DIAGONAL_HALF
    if angleDiff(angle, lastSector[1]) <= half + HYSTERESIS then
      return Directions[lastSector[2]]
    end
  end
  for _, sector in ipairs(SECTORS) do
    local half = (sector[1] % 90 == 0) and STRAIGHT_HALF or DIAGONAL_HALF
    if angleDiff(angle, sector[1]) <= half then
      lastSector = sector
      return Directions[sector[2]]
    end
  end
end

function executeWalk()
  removeEvent(keypadUpdateEvent)
  keypadUpdateEvent = nil

  if not g_mouse.isPressed(MouseLeftButton) then
    keypad.pointer:setMarginTop(0)
    keypad.pointer:setMarginLeft(0)
    return
  end

  keypadUpdateEvent = scheduleEvent(executeWalk, 20)
  keypadMousePos.x = math.min(1, math.max(0, keypadMousePos.x))
  keypadMousePos.y = math.min(1, math.max(0, keypadMousePos.y))
  local angle = math.atan2(keypadMousePos.x - 0.5, keypadMousePos.y - 0.5)
  local maxTop = math.abs(math.cos(angle)) * 75
  local marginTop = math.max(-maxTop, math.min(maxTop, (keypadMousePos.y - 0.5) * 150))
  local maxLeft = math.abs(math.sin(angle)) * 75
  local marginLeft = math.max(-maxLeft, math.min(maxLeft, (keypadMousePos.x - 0.5) * 150))
  keypad.pointer:setMarginTop(marginTop)
  keypad.pointer:setMarginLeft(marginLeft)
  local dir = directionFor(keypadMousePos.x - 0.5, keypadMousePos.y - 0.5)

  if dir and moveListener then
    moveListener(dir, firstStep)
  end
end

function getPanel()
  return keypad
end