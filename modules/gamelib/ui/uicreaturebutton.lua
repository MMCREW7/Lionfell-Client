-- @docclass
UICreatureButton = extends(UIWidget, 'UICreatureButton')

local CreatureButtonColors = {
    onIdle = {
        notHovered = '#CFCCC7',
        hovered = '#F1EFEC'
    },
    onTargeted = {
        notHovered = '#D9A29B',
        hovered = '#E8BDB7'
    },
    onFollowed = {
        notHovered = '#A8C3A3',
        hovered = '#C3D8BF'
    }
}

local LifeBarColors = {} -- Must be sorted by percentAbove
table.insert(LifeBarColors, {
    percentAbove = 60,
    color = '#8FB08A'
})
table.insert(LifeBarColors, {
    percentAbove = 30,
    color = '#C2A46A'
})
table.insert(LifeBarColors, {
    percentAbove = -1,
    color = '#B9625A'
})

function UICreatureButton.create()
    local button = UICreatureButton.internalCreate()
    button:setFocusable(false)
    button.creature = nil
    button.isHovered = false
    button.isTarget = false
    button.isFollowed = false
    return button
end

function UICreatureButton.getCreatureButtonColors()
    return CreatureButtonColors
end

function UICreatureButton:setCreature(creature)
    self.creature = creature
end

function UICreatureButton:getCreature()
    return self.creature
end

function UICreatureButton:getCreatureId()
    return self.creature:getId()
end

function UICreatureButton:setup(creature, onlyOutfit)
    self.creature = creature

    local creatureWidget = self:getChildById('creature')
    local labelWidget = self:getChildById('label')
    --local lifeBarWidget = self:getChildById('lifeBar')

    labelWidget:setText(creature:getName())
    if onlyOutfit == true then
        creatureWidget:setOutfit(creature:getOutfit())
    else
        creatureWidget:setCreature(creature)
    end

    self:setId('CreatureButton_' .. creature:getName():gsub('%s', '_'))
    self:setLifeBarPercent(creature:getHealthPercent())

    self:updateSkull(creature:getSkull())
    self:updateEmblem(creature:getEmblem())
    self:updateIcons(creature:getIcons())
end

function UICreatureButton:update()
    local color = CreatureButtonColors.onIdle
    if self.isTarget then
        color = CreatureButtonColors.onTargeted
    elseif self.isFollowed then
        color = CreatureButtonColors.onFollowed
    end
    color = self.isHovered and color.hovered or color.notHovered

    if self.isHovered or self.isTarget or self.isFollowed then
        self.creature:showStaticSquare(color)
        self:getChildById('label'):setColor(color)
    else
        self.creature:hideStaticSquare()
        self:getChildById('label'):setColor(color)
    end
    self:getChildById('creature'):setBorderWidth(0)

    if self.isTarget then
        self:setBorderWidth(1)
        self:setBorderColor('#7A4540')
    elseif self.isFollowed then
        self:setBorderWidth(1)
        self:setBorderColor('#4F6A4B')
    else
        self:setBorderWidth(0)
    end
end

function UICreatureButton:updateSkull(skullId)
    if not self.creature then
        return
    end
    local skullId = skullId or self.creature:getSkull()
    local skullWidget = self:getChildById('skull')
    local labelWidget = self:getChildById('label')

    if skullId ~= SkullNone then
        skullWidget:setWidth(skullWidget:getHeight())
        local imagePath = getSkullImagePath(skullId)
        skullWidget:setImageSource(imagePath)
        labelWidget:setMarginLeft(5)
    else
        skullWidget:setWidth(0)
        if self.creature:getEmblem() == EmblemNone then
            labelWidget:setMarginLeft(2)
        end
    end
end

function UICreatureButton:updateEmblem(emblemId)
    if not self.creature then
        return
    end
    local emblemId = emblemId or self.creature:getEmblem()
    local emblemWidget = self:getChildById('emblem')
    local labelWidget = self:getChildById('label')

    if emblemId ~= EmblemNone then
        emblemWidget:setWidth(emblemWidget:getHeight())
        local imagePath = getEmblemImagePath(emblemId)
        emblemWidget:setImageSource(imagePath)
        emblemWidget:setMarginLeft(5)
        labelWidget:setMarginLeft(5)
    else
        emblemWidget:setWidth(0)
        emblemWidget:setMarginLeft(0)
        if self.creature:getSkull() == SkullNone then
            labelWidget:setMarginLeft(2)
        end
    end
end

function UICreatureButton:setLifeBarPercent(percent)
    local lifeBarWidget = self:getChildById('lifeBar')
    lifeBarWidget:setPercent(percent)

    local color
    for i, v in pairs(LifeBarColors) do
        if percent > v.percentAbove then
            color = v.color
            break
        end
    end

    lifeBarWidget:setBackgroundColor(color)
end

function UICreatureButton:updateIcons(icons)
    if not self.creature or not icons or #icons == 0 then
        return
    end
    -- player bots: robot badge before the name
    local badge = self:getChildById('botBadge')
    if badge then
        local isBot = false
        for _, iconData in pairs(icons) do
            if iconData[1] == CreatureIconBot and iconData[2] == 0 then
                isBot = true
            end
        end
        badge:setImageSource(isBot and BotBadgeImage or '')
        badge:setWidth(isBot and 11 or 0)
        self:getChildById('skull'):setMarginLeft(isBot and 4 or 0)
    end

    if not self.creature:isMonster() then
        return
    end
    for index, iconData in pairs(icons) do
        if index > 3 then
            break
        end
        local iconId = iconData[1] -- uint8_t icon
        -- local category = iconData[2] -- uint8_t category  
        -- local count = iconData[3] -- uint16_t count
        local widget = self:getChildById('iconsMonsterSlot' .. index)
        if widget then
            widget:setImageSource("/images/game/creatureicons/modifications")
            widget:setImageClip(torect((iconId - 1) * 11 .. ' 0 11 11'))
        end
    end
end

function UICreatureButton:resetState()
    self.isHovered = false
    self.isTarget = false
    self.isFollowed = false
    if self.creature then
        self.creature:hideStaticSquare()
    end
    self:getChildById('creature'):setBorderWidth(0)
    self:setBorderWidth(0)
    self:getChildById('label'):setColor(CreatureButtonColors.onIdle.notHovered)
    self:getChildById('skull'):setImageSource('')
    self:getChildById('emblem'):setImageSource('')
    for i = 1, 3 do
        self:getChildById('iconsMonsterSlot' .. i):setImageSource('')
    end
end
