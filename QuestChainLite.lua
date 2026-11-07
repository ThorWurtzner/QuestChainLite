local addonName = ...
local fields = { "preQuestSingle", "preQuestGroup", "nextQuestInChain", "childQuests", "parentQuest", "zoneOrSort" }
local indexFields = { "preQuestSingle", "preQuestGroup", "nextQuestInChain" }
local maxSteps = 60
local maxNames = 3
local chainIcon = "|TInterface\\AddOns\\QuestChainLite\\Icon.tga:13:13:0:0|t"
local dungeonIcon = "|A:Dungeon:13:13:0:0|a"
local indexDB, links, questieTags
local refreshChainPanel

-- QuestieDB AreaTable IDs for confirmed dungeon areas. Used for future quests
-- whose tags the client may not have cached. Mixed areas such as Spire need a tag.
local dungeonAreas = {
    [209] = true, [491] = true, [717] = true, [718] = true, [719] = true,
    [721] = true, [722] = true, [796] = true, [978] = true, [1176] = true,
    [1337] = true, [1417] = true, [1477] = true, [1517] = true, [1581] = true,
    [1584] = true, [1585] = true, [1717] = true, [2017] = true, [2057] = true,
    [2100] = true, [2437] = true, [2557] = true, [10029] = true,
    [16544] = true, [16558] = true, [16559] = true, [16560] = true, -- City of Dalaran
    [16611] = true, [16612] = true, [16614] = true, [16615] = true, [16617] = true, -- Ruins of Lordaeron
    [16732] = true, [16877] = true, [16878] = true, [16879] = true, [16880] = true, -- Excavation Site
    [16919] = true, [17803] = true, -- Hall of Thanes and Blackrock Depths
}

local function isID(id)
    return type(id) == "number" and not (issecretvalue and issecretvalue(id)) and id > 0
end

local function addID(list, id)
    if not isID(id) then return end
    for _, existing in ipairs(list) do
        if existing == id then return end
    end
    list[#list + 1] = id
end

local function recordLink(index, from, to)
    if not isID(from) or from == to then return end
    index[from] = index[from] or {}
    addID(index[from], to)
end

local function startIndex(db)
    if not db or db == indexDB or type(db.GetAllIds) ~= "function" or type(db.GetAll) ~= "function" then return end
    local ok, ids = pcall(db.GetAllIds)
    if not ok or type(ids) ~= "table" or #ids == 0 then return end
    indexDB, links = db, nil

    -- Build only the reverse links absent from QuestieDB, a little at a time.
    local result = { previous = {}, unlocks = {} }
    local offset = 1
    local function scanBatch()
        for i = offset, math.min(offset + 119, #ids) do
            local id = ids[i]
            local row = db.GetAll(id, indexFields)
            if row then
                recordLink(result.previous, row[3], id)
                for _, previous in ipairs(row[1] or row[2] or {}) do
                    recordLink(result.unlocks, math.abs(previous), id)
                end
            end
        end
        offset = offset + 120
    end
    local function tick()
        if db ~= indexDB or not pcall(scanBatch) then return end
        if offset <= #ids then
            C_Timer.After(0, tick)
        else
            links = result
            if refreshChainPanel then refreshChainPanel() end
        end
    end
    C_Timer.After(0, tick)
end

local function nativeChain(id, mapID)
    local api = C_QuestLine
    if not api or not api.GetQuestLineInfo or not api.GetQuestLineQuests then return end
    local info = api.GetQuestLineInfo(id, mapID)
    if not info and mapID then info = api.GetQuestLineInfo(id) end
    if not info or not isID(info.questLineID) then return end

    local ids = api.GetQuestLineQuests(info.questLineID)
    if type(ids) ~= "table" or #ids < 2 then return end
    local seen, step = {}, nil
    for index, questID in ipairs(ids) do
        if not isID(questID) or seen[questID] then return end
        seen[questID] = true
        if questID == id then step = index end
    end
    if step then
        return { step = step, total = #ids, previous = ids[step - 1], next = ids[step + 1], ids = ids, name = info.questLineName }
    end
end

local function dbChain(db, id, needsCount, needsList)
    local index = db == indexDB and links
    local cache = {}
    local function read(questID)
        if cache[questID] ~= nil then return cache[questID] end
        local values = db.GetAll(questID, fields)
        if not values then
            cache[questID] = false
            return false
        end

        local single, group, nextID, children, parent, area = unpack(values, 1, #fields)
        local row = { before = {}, followUps = {}, parent = parent, area = area, previous = index and index.previous[questID] }
        -- Questie uses the group only if the single-prerequisite field is absent.
        for _, previous in ipairs(single or group or {}) do
            if not single then previous = math.abs(previous) end
            if previous ~= questID then addID(row.before, previous) end
        end
        row.requires = #row.before > 1 and (single and "Requires any" or "Requires all") or "Requires"
        -- The short summary prefers the explicit link. Dungeon detection can also follow branches.
        local explicit = isID(nextID) and nextID ~= questID
        if explicit then addID(row.followUps, nextID) end
        for _, child in ipairs(children or {}) do
            if child ~= questID then addID(row.followUps, child) end
        end
        for _, child in ipairs(index and index.unlocks[questID] or {}) do addID(row.followUps, child) end
        row.after = explicit and { nextID } or row.followUps
        row.earlier = row.previous or row.before
        cache[questID] = row
        return row
    end

    local row = read(id)
    if not row or not needsCount or not index or (#row.earlier == 0 and #row.after == 0) then return row, read end

    -- Count a linear chain only if both ends of each link agree. Stop on a branch,
    -- a missing row, a loop or an active-parent requirement that changes the order.
    local visited, total = { [id] = true }, 1
    local function walk(direction, reverse, ordered)
        local currentID, current = id, row
        local distance = 0
        while true do
            local links = current[direction]
            if #links > 1 or isID(current.parent) then return end
            if #links == 0 then return distance end
            local otherID = links[1]
            if visited[otherID] or total >= maxSteps then return end
            local other = read(otherID)
            if not other or #other[reverse] ~= 1 or other[reverse][1] ~= currentID then return end
            visited[otherID] = true
            if ordered then ordered[#ordered + 1] = otherID end
            total = total + 1
            distance = distance + 1
            currentID, current = otherID, other
        end
    end

    local previousIDs, nextIDs = needsList and {}, needsList and {}
    local earlier = walk("earlier", "after", previousIDs)
    if earlier and walk("after", "earlier", nextIDs) then
        row.step, row.total = earlier + 1, total
        if needsList then
            local ids = {}
            for i = #previousIDs, 1, -1 do ids[#ids + 1] = previousIDs[i] end
            ids[#ids + 1] = id
            for _, nextID in ipairs(nextIDs) do ids[#ids + 1] = nextID end
            row.ids = ids
        end
    end
    return row, read
end

local function isDungeonQuest(id, area)
    local tag
    if questieTags then
        local ok, corrected = pcall(questieTags, id)
        if ok then tag = corrected end
    end
    if not tag and C_QuestLog and C_QuestLog.GetQuestTagInfo then
        local ok, info = pcall(C_QuestLog.GetQuestTagInfo, id)
        if ok and info then tag = info.tagID end
    end
    if tag == 81 or tag == 85 then return true end -- Dungeon or Heroic
    if tag == 41 or tag == 62 or tag == 88 or tag == 89 then return false end -- PvP or raid
    return dungeonAreas[area] == true
end

local function leadsToDungeon(id, native, read)
    local queue, seen = { id }, { [id] = true }
    local function enqueue(questID)
        if #queue < maxSteps and not seen[questID] then
            seen[questID] = true
            queue[#queue + 1] = questID
        end
    end

    if native then
        for i = native.step + 1, math.min(native.total, native.step + maxSteps - 1) do
            enqueue(native.ids[i])
        end
    end
    local i = 1
    while queue[i] do
        local questID = queue[i]
        local row = read and read(questID)
        if isDungeonQuest(questID, row and row.area) then return true end
        if row then
            for _, nextID in ipairs(row.followUps) do enqueue(nextID) end
        end
        i = i + 1
    end
    return false
end

local function questName(db, id)
    local title = C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(id)
    if (not title or title == "") and db and type(db.name) == "function" then
        local ok, name = pcall(db.name, id)
        if ok then title = name end
    end
    if type(title) == "string" and title ~= "" then return title end
    return "Quest #" .. id, true
end

local function addNames(tooltip, db, label, ids)
    local names = {}
    for i = 1, math.min(#ids, maxNames) do names[i] = questName(db, ids[i]) end
    if #ids > maxNames then names[#names + 1] = ("+%d more"):format(#ids - maxNames) end
    tooltip:AddLine(label .. ": " .. table.concat(names, ", "), 1, 1, 1, true)
end

local function getChain(id, mapID, needsList)
    local db = LibQuestieDB and LibQuestieDB.Quest
    local ok, native = pcall(nativeChain, id, mapID)
    if not ok then native = nil end
    local data, read
    if db and type(db.GetAll) == "function" then
        ok, data, read = pcall(dbChain, db, id, not native, needsList)
        if not ok then data = nil end
    end
    return db, native, data, read
end

local function addChain(tooltip, id, mapID, onMap)
    local db, native, data, read = getChain(id, mapID)
    local before = data and data.before or {}
    local previous = native and { native.previous } or data and data.previous or {}
    local after = native and { native.next } or data and data.after or {}
    local parent = data and data.parent

    if not native and #before == 0 and #previous == 0 and #after == 0 and not isID(parent) then return end

    tooltip:AddLine(" ")
    local count = native or data
    local checked, dungeon = pcall(leadsToDungeon, id, native, read)
    local icon = checked and dungeon and dungeonIcon or chainIcon
    local prefix = ""
    if onMap or count.step then
        local caption = icon
        if count.step then caption = caption .. (" %d/%d"):format(count.step, count.total) end
        if onMap then caption = caption .. "  " .. questName(db, id) end
        tooltip:AddLine(caption, 0.78, 0.78, 0.78, true)
    else
        prefix = icon .. " "
    end

    local function addDetail(label, ids)
        addNames(tooltip, db, prefix .. label, ids)
        prefix = ""
    end
    if #previous > 0 and not (#previous == 1 and #before == 1 and previous[1] == before[1]) then
        addDetail("Previous", previous)
    end
    if #before > 0 then addDetail(data.requires, before) end
    if isID(parent) then addDetail("Requires active", { parent }) end
    if #after > 0 then addDetail(#after == 1 and "Next" or "Follow-ups", after) end
    return true
end

local function relatedQuests(id, read)
    local seen = { [id] = true }
    local function collect(earlier)
        local queue = { id }
        local function enqueue(questID)
            if #queue < maxSteps and isID(questID) and not seen[questID] then
                seen[questID] = true
                queue[#queue + 1] = questID
            end
        end
        local i = 1
        while queue[i] do
            local row = read(queue[i])
            if row then
                if earlier then
                    for _, previousID in ipairs(row.before) do enqueue(previousID) end
                    for _, previousID in ipairs(row.previous or {}) do enqueue(previousID) end
                    enqueue(row.parent)
                else
                    for _, nextID in ipairs(row.followUps) do enqueue(nextID) end
                end
            end
            i = i + 1
        end
        return queue
    end

    local before, after = collect(true), collect(false)
    if #before == 1 and #after == 1 then return end
    local entries = {}
    if #before > 1 then
        entries[#entries + 1] = "Earlier quests"
        for i = #before, 2, -1 do entries[#entries + 1] = before[i] end
    end
    entries[#entries + 1] = id
    if #after > 1 then
        entries[#entries + 1] = "Follow-ups"
        for i = 2, #after do entries[#entries + 1] = after[i] end
    end
    return entries
end

local panel, mapPanelHooked, questGiverHooked, panelRefreshQueued
local requestedTitles = {}
local headerHeight = 54

local function createChainPanel(host)
    local frame = CreateFrame("Frame", nil, host)
    frame:Hide()
    frame:SetFrameLevel(host:GetFrameLevel() + 6)
    frame:SetClampedToScreen(true)

    local paper = frame:CreateTexture(nil, "BACKGROUND")
    paper:SetAllPoints(frame)
    paper:SetAtlas("QuestDetailsBackgrounds")

    local header = frame:CreateTexture(nil, "ARTWORK", nil, -1)
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -4)
    header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    header:SetHeight(headerHeight - 4)
    header:SetAtlas("questlog-reward-top-frame")

    local border = CreateFrame("Frame", nil, frame, "QuestLogBorderFrameTemplate")
    border:ClearAllPoints()
    border:SetAllPoints(frame)
    border:SetFrameLevel(frame:GetFrameLevel() + 1)

    frame.title = frame:CreateFontString(nil, "OVERLAY", "QuestFont_Huge")
    frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -11)
    frame.title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, -11)
    frame.title:SetTextColor(0.90, 0.79, 0.67)
    frame.title:SetMaxLines(1)

    frame.progress = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.progress:SetPoint("TOP", frame, "TOP", 0, -33)
    frame.progress:SetTextColor(0.82, 0.70, 0.54)

    local scroll = CreateFrame("ScrollFrame", "QuestChainLiteChainScroll", frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 11, -headerHeight)
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -25, 10)
    scroll.scrollBarHideable = true
    frame.scroll, frame.bar = scroll, scroll.ScrollBar or QuestChainLiteChainScrollScrollBar
    frame.body = CreateFrame("Frame", nil, scroll)
    frame.body:SetSize(1, 1)
    scroll:SetScrollChild(frame.body)
    frame.rows = {}
    return frame
end

local function positionChainPanel(frame, details, map)
    local anchor = map or details
    local scale = frame:GetEffectiveScale()
    local function edge(owner, method)
        local value = owner[method](owner)
        return value and value * owner:GetEffectiveScale() / scale
    end
    local anchorTop = edge(anchor, "GetTop")
    local detailTop = edge(details, "GetTop")
    if not anchorTop or not detailTop then return end

    local screenBottom = edge(UIParent, "GetBottom") or 0
    local screenLeft = edge(UIParent, "GetLeft") or 0
    local screenRight = edge(UIParent, "GetRight") or 0
    local rightWidth = screenRight - (edge(anchor, "GetRight") or screenRight) - 20
    local leftWidth = (edge(anchor, "GetLeft") or screenLeft) - screenLeft - 20
    local top = detailTop - 12
    local rightTop = top
    if map then
        for _, tab in ipairs(QuestMapFrame.TabButtons or {}) do
            if tab:IsVisible() then rightTop = math.min(rightTop, (edge(tab, "GetBottom") or rightTop) - 8) end
        end
    end
    local portrait = QuestModelScene
    if portrait and portrait:IsVisible() and portrait:GetParent() == anchor then
        rightTop = math.min(rightTop, (edge(portrait, "GetBottom") or rightTop) - 8)
        local text = portrait.ModelTextFrame
        if text and text:IsVisible() then rightTop = math.min(rightTop, (edge(text, "GetBottom") or rightTop) - 8) end
    end

    frame:ClearAllPoints()
    local width
    local minWidth = map and 200 or 160
    if rightWidth >= minWidth and rightTop - screenBottom >= 180 then
        top, width = rightTop, rightWidth
        frame:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 9, top - anchorTop)
    elseif leftWidth >= minWidth then
        width = leftWidth
        frame:SetPoint("TOPRIGHT", anchor, "TOPLEFT", -9, top - anchorTop)
    elseif map then
        -- Keep the quest parchment clear even when there is no room outside the map.
        width = math.max(160, (edge(details, "GetLeft") or screenLeft) - screenLeft - 19)
        frame:SetPoint("TOPRIGHT", details, "TOPLEFT", -9, top - detailTop)
    else
        return
    end
    return math.min(248, width), math.max(132, math.min(420, top - screenBottom - 12))
end

local function getPanelRow(frame, i)
    if frame.rows[i] then return frame.rows[i] end
    local row = CreateFrame("Frame", nil, frame.body)
    row.highlight = row:CreateTexture(nil, "BACKGROUND")
    row.highlight:SetAllPoints(row)
    row.highlight:SetColorTexture(0.69, 0.38, 0.09, 0.30)
    row.number = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    row.number:SetPoint("TOPRIGHT", row, "TOPLEFT", 20, -5)
    row.number:SetShadowOffset(0, 0)
    row.number:SetTextColor(0.42, 0.24, 0.10)
    row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.text:SetJustifyH("LEFT")
    row.text:SetShadowOffset(0, 0)
    row.text:SetWordWrap(true)
    row.text:SetNonSpaceWrap(true)
    row.done = row:CreateTexture(nil, "ARTWORK")
    row.done:SetPoint("TOPRIGHT", row, "TOPRIGHT", -3, -4)
    row.done:SetSize(13, 13)
    row.done:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
    frame.rows[i] = row
    return row
end

local function hideChainPanel()
    if panel then
        panel:Hide()
        panel.questID = nil
    end
end

local function showChainPanel(host, map, id, db, chain, entries, read, isDungeon)
    panel = panel or createChainPanel(host)
    local reopening = panel.questID ~= id or panel:GetParent() ~= host
    if panel:GetParent() ~= host then
        panel:SetParent(host)
        panel:SetFrameLevel(host:GetFrameLevel() + 6)
    end
    local width, maxHeight = positionChainPanel(panel, host, map)
    if not width then hideChainPanel() return end
    local previousScroll = not reopening and panel.scroll:GetVerticalScroll() or 0
    panel.questID = id
    panel:SetWidth(width)
    local bodyWidth = width - 36
    panel.body:SetWidth(bodyWidth)
    local title = chain and chain.name
    panel.title:SetText(type(title) == "string" and title ~= "" and title or "Quest Chain")
    local progress = chain and ("%d of %d"):format(chain.step, chain.total) or "Known links"
    panel.progress:SetText((isDungeon and dungeonIcon or chainIcon) .. "  " .. progress)

    local offset, selectedTop, selectedBottom = 4, 0, 0
    for i, entry in ipairs(entries) do
        local row = getPanelRow(panel, i)
        local section = type(entry) == "string"
        local selected = entry == id
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", panel.body, "TOPLEFT", 0, -offset)
        row:SetWidth(bodyWidth)
        row.highlight:SetShown(selected)
        row.text:ClearAllPoints()
        row.text:SetPoint("TOPLEFT", row, "TOPLEFT", section and 6 or 28, -5)
        row.text:SetWidth(bodyWidth - (section and 12 or 46))
        if section then
            row.number:SetText("")
            row.text:SetText(entry)
            row.text:SetTextColor(0.44, 0.24, 0.09)
            row.done:Hide()
        else
            local name, missing = questName(db, entry)
            if missing and not requestedTitles[entry] and C_QuestLog and C_QuestLog.RequestLoadQuestByID then
                requestedTitles[entry] = true
                pcall(C_QuestLog.RequestLoadQuestByID, entry)
            end
            local completed = not selected and C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted
                and C_QuestLog.IsQuestFlaggedCompleted(entry)
            local ok, record = false, nil
            if read then ok, record = pcall(read, entry) end
            local dungeon = isDungeonQuest(entry, ok and record and record.area)
            row.number:SetText(chain and tostring(i) or (selected and ">" or "-"))
            row.text:SetText(dungeon and (dungeonIcon .. " " .. name) or name)
            if selected then
                row.text:SetTextColor(0.22, 0.10, 0.03)
            elseif completed then
                row.text:SetTextColor(0.26, 0.31, 0.15)
            else
                row.text:SetTextColor(0.27, 0.18, 0.10)
            end
            row.done:SetShown(completed and true or false)
        end
        local height = math.max(section and 24 or 22, row.text:GetStringHeight() + 10)
        row:SetHeight(height)
        row:Show()
        if selected then selectedTop, selectedBottom = offset, offset + height end
        offset = offset + height
    end
    for i = #entries + 1, #panel.rows do panel.rows[i]:Hide() end

    local bodyHeight = offset + 4
    local height = math.min(maxHeight, headerHeight + bodyHeight + 10)
    local viewport = height - headerHeight - 10
    panel.body:SetHeight(bodyHeight)
    panel:SetHeight(height)
    panel:Show()
    panel.scroll:UpdateScrollChildRect()
    if reopening and selectedBottom > viewport then
        previousScroll = math.max(0, selectedTop - math.floor(viewport / 3))
    end
    panel.scroll:SetVerticalScroll(math.min(previousScroll, math.max(0, bodyHeight - viewport)))
    if panel.bar then panel.bar:SetShown(bodyHeight > viewport) end
end

local function isVisible(frame)
    return frame and frame:IsVisible()
end

local function viewedQuest()
    if isVisible(QuestFrame) and (isVisible(QuestFrameDetailPanel)
        or isVisible(QuestFrameProgressPanel) or isVisible(QuestFrameRewardPanel)) then
        local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
        return QuestFrame, GetQuestID(), mapID
    end
    local details = QuestMapFrame and QuestMapFrame.DetailsFrame
    if WorldMapFrame and isVisible(details) then
        return details, details.questID, WorldMapFrame:GetMapID(), WorldMapFrame
    end
end

local function updateChainPanel()
    local host, id, mapID, map = viewedQuest()
    if not isID(id) then
        hideChainPanel()
        return
    end
    local db, native, data, read = getChain(id, mapID, true)
    local chain = native or (data and data.ids and data)
    local entries = chain and chain.ids
    if not entries and data and read then
        local ok, related = pcall(relatedQuests, id, read)
        if ok then entries = related end
    end
    if entries then
        local checked, dungeon = pcall(leadsToDungeon, id, native, read)
        showChainPanel(host, map, id, db, chain, entries, read, checked and dungeon)
    else
        hideChainPanel()
    end
end

refreshChainPanel = function()
    if panelRefreshQueued then return end
    panelRefreshQueued = true
    C_Timer.After(0, function()
        panelRefreshQueued = false
        updateChainPanel()
    end)
end

local function onPanelHostHidden(host)
    if panel and panel:GetParent() == host then hideChainPanel() end
    refreshChainPanel()
end

local function hookChainPanel()
    if not questGiverHooked and QuestFrame then
        questGiverHooked = true
        QuestFrame:HookScript("OnShow", refreshChainPanel)
        QuestFrame:HookScript("OnHide", onPanelHostHidden)
        refreshChainPanel()
    end
    if mapPanelHooked or not QuestMapFrame or not QuestMapFrame.DetailsFrame or not WorldMapFrame
        or type(QuestMapFrame_ShowQuestDetails) ~= "function" then return end
    mapPanelHooked = true
    hooksecurefunc("QuestMapFrame_ShowQuestDetails", refreshChainPanel)
    QuestMapFrame.DetailsFrame:HookScript("OnShow", refreshChainPanel)
    QuestMapFrame.DetailsFrame:HookScript("OnHide", onPanelHostHidden)
    WorldMapFrame:HookScript("OnSizeChanged", refreshChainPanel)
    refreshChainPanel()
end

-- The stock quest log fires this after building its existing hover tooltip.
if EventRegistry and EventRegistry.RegisterCallback then
    EventRegistry:RegisterCallback("QuestMapLogTitleButton.OnEnter", function(_, button, id)
        if not isID(id) or not GameTooltip:IsOwned(button) then return end
        local mapID = WorldMapFrame and WorldMapFrame:GetMapID()
        if addChain(GameTooltip, id, mapID, false) then GameTooltip:Show() end
    end, {})
end

-- Questie's map tooltip layout is optional. Post-hook rendering so the summary
-- survives Questie's modifier-key redraws and stays inside its normal tooltip.
local function hookQuestieMap()
    if not QuestieLoader or type(QuestieLoader.ImportModule) ~= "function" then return end
    local imported, db = pcall(QuestieLoader.ImportModule, QuestieLoader, "QuestieDB")
    if imported and db and type(db.GetQuestTagInfo) == "function" then questieTags = db.GetQuestTagInfo end
    local ok, layout = pcall(QuestieLoader.ImportModule, QuestieLoader, "TooltipLayout")
    if not ok or not layout or type(layout.Render) ~= "function" then return end
    hooksecurefunc(layout, "Render", function(_, tooltip)
        local icon = tooltip._owner
        local data = icon and icon.data
        if not data or not data.QuestData or icon.miniMapIcon or not isID(data.Id) then return end
        if not tooltip._Rebuild or not tooltip:IsOwned(icon) then return end
        addChain(tooltip, data.Id, icon.UiMapID, true)
    end)
    return true
end

local function indexWhenReady()
    local function build()
        startIndex(LibQuestieDB and LibQuestieDB.Quest)
    end
    local api = Questie and Questie.API
    if api and type(api.RegisterOnReady) == "function" then
        api.RegisterOnReady(build)
    else
        build()
    end
end

local loader = CreateFrame("Frame")
local mapHooked = hookQuestieMap()
hookChainPanel()
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("QUEST_DATA_LOAD_RESULT")
loader:RegisterEvent("QUEST_TURNED_IN")
loader:RegisterEvent("QUEST_DETAIL")
loader:RegisterEvent("QUEST_PROGRESS")
loader:RegisterEvent("QUEST_COMPLETE")
loader:RegisterEvent("QUEST_GREETING")
loader:RegisterEvent("QUEST_FINISHED")
loader:RegisterEvent("DISPLAY_SIZE_CHANGED")
loader:RegisterEvent("UI_SCALE_CHANGED")
loader:SetScript("OnEvent", function(_, event, arg, success)
    if event == "ADDON_LOADED" then
        hookChainPanel()
        if arg == addonName or arg == "Questie" or arg == "QuestieDB" then
            if not mapHooked then mapHooked = hookQuestieMap() end
            indexWhenReady()
        end
    elseif event ~= "QUEST_DATA_LOAD_RESULT" or (success and requestedTitles[arg]) then
        refreshChainPanel()
    end
end)
