-- Lionfell theme: imports the shared Lf* styles and restyles MiniWindow so every
-- floating HUD panel uses the same flat 9-slice skin from data/images/lionfell.

-- Windows opened in game stay clear of the right-hand bar (minimap, battle list, equipment): one
-- that would reach under it moves into the free space to its left, and stays on screen.
local MARGIN = 8

local function keepClear(window)
    if window:isDestroyed() or not window:isVisible() or not g_game.isOnline() then
        return
    end
    local gameInterface = modules.game_interface
    local root = gameInterface and gameInterface.getRootPanel and gameInterface.getRootPanel()
    if not root or (window:getParent() ~= root and window:getParent() ~= rootWidget) then
        return -- side panel windows (containers, skills...) manage themselves
    end
    local area = root:getRect()
    local right = gameInterface.getRightPanel and gameInterface.getRightPanel()
    local limit = area.x + area.width
    if right and right:isVisible() and right:getWidth() > 0 then
        limit = math.min(limit, right:getX() - MARGIN)
    end
    -- bigger than the free space (small screens): shrink it to fit
    local maxWidth, maxHeight = limit - area.x - 2 * MARGIN, area.height - 2 * MARGIN
    if window:getWidth() > maxWidth and maxWidth > 200 then
        window:setWidth(maxWidth)
    end
    if window:getHeight() > maxHeight and maxHeight > 200 then
        window:setHeight(maxHeight)
    end
    local rect = window:getRect()
    local x, y = rect.x, rect.y
    if rect.x + rect.width > limit then
        -- centred in the space left of the bar (flush left when it doesn't fit)
        x = math.max(area.x + MARGIN, area.x + math.floor((limit - area.x - rect.width) / 2))
    end
    y = math.max(area.y, math.min(y, area.y + area.height - rect.height))
    if x ~= rect.x or y ~= rect.y then
        window:breakAnchors()
        window:setPosition({ x = x, y = y })
    end
end

local baseVisibilityChange
local scanEvent

-- top-level windows (and message / input boxes, which are windows too)
local WINDOW_CLASSES = { UIWindow = true, UIMessageBox = true, UIInputBox = true }

-- Windows that open already visible never change visibility, so the hook below misses them:
-- every half second, each window not placed yet is placed once (never while being dragged).
local function scan()
    if not g_game.isOnline() then
        return
    end
    local gameInterface = modules.game_interface
    local root = gameInterface and gameInterface.getRootPanel and gameInterface.getRootPanel()
    for _, parent in ipairs({ root, rootWidget }) do
        if parent then
            for _, child in ipairs(parent:getChildren()) do
                if not child.lfPlaced and child:isVisible() and WINDOW_CLASSES[child:getClassName()]
                    and g_ui.getDraggingWidget() ~= child then
                    child.lfPlaced = true
                    keepClear(child)
                end
            end
        end
    end
end

function init()
    g_ui.importStyle('styles/lionfell')
    g_ui.importStyle('styles/miniwindow')
    g_ui.importStyle('styles/game')

    baseVisibilityChange = UIWindow.onVisibilityChange
    UIWindow.onVisibilityChange = function(self, visible)
        if baseVisibilityChange then
            baseVisibilityChange(self, visible)
        end
        if visible then
            -- after the layout has placed it (anchored windows get their spot on the next frame)
            addEvent(function()
                self.lfPlaced = true
                keepClear(self)
            end)
        else
            self.lfPlaced = nil -- placed again the next time it opens
        end
    end
    scanEvent = cycleEvent(scan, 500)
end

function terminate()
    removeEvent(scanEvent)
    UIWindow.onVisibilityChange = baseVisibilityChange
end
