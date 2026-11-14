local _, ns = ...

local mainFrame
local tab1Frame, tab2Frame
local tab1Btn, tab2Btn
local selectedCity = nil

-- Passenger Tab Widgets
local cityDropdown, tipEditBox, locLabel, restWarnLabel, broadcastBtn, cancelReqBtn, activeReqLabel
local mageListContainer

-- Mage Tab Widgets
local toggleActiveBtn, advertBtn, reagentStatusLabel
local portalCheckboxes = {}
local requestRows = {}
local emptyQueueLabel

-- Minimap Button
local minimapBtn

-- Helper: Style a dark backdrop frame
local function ApplyDarkBackdrop(frame, borderAlpha)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    frame:SetBackdropColor(0.07, 0.09, 0.13, 0.96)
    frame:SetBackdropBorderColor(0.25, 0.55, 0.85, borderAlpha or 0.85)
end

-- Switch between Passenger (1) and Mage Dashboard (2) tabs
local function SelectTab(tabIndex)
    if tabIndex == 1 then
        tab1Frame:Show()
        tab2Frame:Hide()
        tab1Btn:Disable()
        tab2Btn:Enable()
    else
        tab1Frame:Hide()
        tab2Frame:Show()
        tab1Btn:Enable()
        tab2Btn:Disable()
    end
    ns.UpdateUI()
end

-- Refresh Passenger Tab UI
local function UpdatePassengerTab()
    locLabel:SetText("|cffffffffCurrent Location:|r " .. ns.GetCurrentLocation())

    if IsResting() then
        restWarnLabel:SetText("|cff55ff55Inn Status: Rested (Eligible for Liminal Passage)|r")
    else
        restWarnLabel:SetText("|cffff5555Inn Status: NOT Rested! Enter an inn before requesting.|r")
    end
    broadcastBtn:Enable()

    if ns.state.myRequest then
        local req = ns.state.myRequest
        if req.claimedBy then
            activeReqLabel:SetText(string.format("|cff55ff55Active Request:|r %s — Claimed by |cff00ccff%s|r", req.city, req.claimedBy))
        else
            activeReqLabel:SetText(string.format("|cffffd100Active Request:|r %s (%dg) — Waiting for a Mage...", req.city, req.tip))
        end
        cancelReqBtn:Show()
    else
        activeReqLabel:SetText("|cff888888No active taxi request.|r")
        cancelReqBtn:Hide()
    end

    local lines = {}
    for name, data in pairs(ns.state.activeMages) do
        local age = math.floor(GetTime() - data.timestamp)
        table.insert(lines, string.format("|cff00ccff%s|r  |cffaaaaaa(%ds ago)|r", name, age))
    end

    if #lines > 0 then
        mageListContainer.text:SetText(table.concat(lines, "\n"))
    else
        mageListContainer.text:SetText("|cff888888No active Mages spotted in #" .. ns.CHANNEL_NAME .. " yet.|r")
    end
end

-- Refresh Mage Dashboard Tab UI
local function UpdateMageTab()
    if not ns.state.isMage then
        toggleActiveBtn:Disable()
        advertBtn:Disable()
        reagentStatusLabel:SetText("|cffff5555Mage Dashboard is only available on Mage characters.|r")
        for _, cb in ipairs(portalCheckboxes) do
            cb:Disable()
        end
        return
    end

    toggleActiveBtn:Enable()
    if ns.state.mageActive then
        toggleActiveBtn:SetText("|cff55ff55Status: ACTIVE (Click to Go Offline)|r")
        advertBtn:Enable()
    else
        toggleActiveBtn:SetText("|cffffaa00Status: OFFLINE (Click to Go Active)|r")
        advertBtn:Disable()
    end

    -- Sync portal checkboxes with saved character selection & spellbook status
    for _, cb in ipairs(portalCheckboxes) do
        cb:Enable()
        cb:SetChecked(ns.IsPortalEnabled(cb.cityName))
        local knowsSpell = (cb.spellID and IsSpellKnown(cb.spellID)) or (GetSpellInfo(cb.spellName) ~= nil)
        if knowsSpell then
            cb.text:SetText("|cffffffff" .. cb.cityName .. "|r")
        else
            cb.text:SetText("|cff888888" .. cb.cityName .. " (Unlearned)|r")
        end
    end

    local scrolls, runes = ns.GetMageReagentCounts()
    reagentStatusLabel:SetText(string.format(
        "Reagents: |cffffffff%d|r Scrolls of Liminal Passage  |  |cffffffff%d|r Runes of Portals",
        scrolls, runes
    ))

    -- Collect and sort incoming requests by timestamp (oldest first), filtered by enabled portals
    local sorted = {}
    for _, req in pairs(ns.state.requests) do
        if ns.IsPortalEnabled(req.city) then
            table.insert(sorted, req)
        end
    end
    table.sort(sorted, function(a, b) return a.timestamp < b.timestamp end)

    local now = GetTime()
    for i, row in ipairs(requestRows) do
        local req = sorted[i]
        if req then
            local age = math.floor(now - req.timestamp)
            local restBadge = req.isResting and "|cff55ff55[Inn]|r" or "|cffff5555[Out]|r"
            local srcBadge = (req.source == "WHISPER") and "|cffff80ff[W]|r " or ""

            row.playerText:SetText(srcBadge .. "|cffffffff" .. req.sender .. "|r " .. restBadge)
            row.infoText:SetText(string.format("|cff00ccff%s|r  |  %s  |  |cffffd100%dg|r  |cff888888(%ds)|r", req.city, req.location, req.tip, age))
            row.customerName = req.sender
            row:Show()
        else
            row:Hide()
        end
    end

    if #sorted == 0 then
        emptyQueueLabel:Show()
    else
        emptyQueueLabel:Hide()
    end
end

function ns.UpdateUI()
    if not mainFrame or not mainFrame:IsShown() then return end
    if tab1Frame:IsShown() then
        UpdatePassengerTab()
    else
        UpdateMageTab()
    end
end

function ns.ToggleMainWindow()
    if not mainFrame then return end
    if mainFrame:IsShown() then
        mainFrame:Hide()
    else
        mainFrame:Show()
        ns.UpdateUI()
    end
end

-- Build Passenger Tab
local function CreatePassengerTab(parent)
    tab1Frame = CreateFrame("Frame", nil, parent)
    tab1Frame:SetAllPoints()

    local cities = ns.CITIES[ns.state.faction] or {}
    if cities[1] then selectedCity = cities[1].name end

    local cityTitle = tab1Frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    cityTitle:SetPoint("TOPLEFT", 18, -55)
    cityTitle:SetText("Destination City:")

    cityDropdown = CreateFrame("Frame", "ForeverTaxiCityDropdown", tab1Frame, "UIDropDownMenuTemplate")
    cityDropdown:SetPoint("TOPLEFT", 125, -48)
    UIDropDownMenu_SetWidth(cityDropdown, 150)
    UIDropDownMenu_SetText(cityDropdown, selectedCity or "Select City")

    UIDropDownMenu_Initialize(cityDropdown, function(_, level)
        for _, c in ipairs(cities) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = c.name
            info.checked = (selectedCity == c.name)
            info.func = function()
                selectedCity = c.name
                UIDropDownMenu_SetText(cityDropdown, c.name)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    local tipTitle = tab1Frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tipTitle:SetPoint("TOPLEFT", 18, -92)
    tipTitle:SetText("Tip Offer (Gold):")

    tipEditBox = CreateFrame("EditBox", nil, tab1Frame, "InputBoxTemplate")
    tipEditBox:SetSize(60, 22)
    tipEditBox:SetPoint("TOPLEFT", 145, -88)
    tipEditBox:SetAutoFocus(false)
    tipEditBox:SetNumeric(true)
    tipEditBox:SetText(tostring(ns.db.defaultTip or 2))
    tipEditBox:SetScript("OnTextChanged", function(self)
        local val = tonumber(self:GetText())
        if val then ns.db.defaultTip = val end
    end)

    locLabel = tab1Frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    locLabel:SetPoint("TOPLEFT", 18, -125)

    restWarnLabel = tab1Frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    restWarnLabel:SetPoint("TOPLEFT", 18, -143)

    broadcastBtn = CreateFrame("Button", nil, tab1Frame, "UIPanelButtonTemplate")
    broadcastBtn:SetSize(210, 28)
    broadcastBtn:SetPoint("TOPLEFT", 18, -170)
    broadcastBtn:SetText("Broadcast Taxi Request")
    broadcastBtn:SetScript("OnClick", function()
        if not selectedCity then return end
        ns.PassengerBroadcastRequest(selectedCity, tipEditBox:GetText())
    end)

    cancelReqBtn = CreateFrame("Button", nil, tab1Frame, "UIPanelButtonTemplate")
    cancelReqBtn:SetSize(110, 28)
    cancelReqBtn:SetPoint("LEFT", broadcastBtn, "RIGHT", 10, 0)
    cancelReqBtn:SetText("Cancel Request")
    cancelReqBtn:SetScript("OnClick", function()
        ns.PassengerCancelRequest()
    end)
    cancelReqBtn:Hide()

    activeReqLabel = tab1Frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    activeReqLabel:SetPoint("TOPLEFT", 18, -206)

    local autoInviteCB = CreateFrame("CheckButton", nil, tab1Frame, "UICheckButtonTemplate")
    autoInviteCB:SetPoint("TOPLEFT", 14, -228)
    autoInviteCB:SetChecked(ns.db.autoAcceptInvite)
    autoInviteCB.text:SetText("Auto-accept party invite from claimed Taxi Mage")
    autoInviteCB:SetScript("OnClick", function(self)
        ns.db.autoAcceptInvite = self:GetChecked() and true or false
    end)

    local mageHeader = tab1Frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    mageHeader:SetPoint("TOPLEFT", 18, -265)
    mageHeader:SetText("Active Taxi Mages Online:")

    mageListContainer = CreateFrame("Frame", nil, tab1Frame, "BackdropTemplate")
    mageListContainer:SetSize(424, 150)
    mageListContainer:SetPoint("TOPLEFT", 18, -285)
    ApplyDarkBackdrop(mageListContainer, 0.5)

    mageListContainer.text = mageListContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    mageListContainer.text:SetPoint("TOPLEFT", 10, -10)
    mageListContainer.text:SetWidth(404)
    mageListContainer.text:SetJustifyH("LEFT")
end

-- Build Mage Dashboard Tab
local function CreateMageTab(parent)
    tab2Frame = CreateFrame("Frame", nil, parent)
    tab2Frame:SetAllPoints()

    toggleActiveBtn = CreateFrame("Button", nil, tab2Frame, "UIPanelButtonTemplate")
    toggleActiveBtn:SetSize(245, 28)
    toggleActiveBtn:SetPoint("TOPLEFT", 18, -48)
    toggleActiveBtn:SetScript("OnClick", function()
        ns.SetMageActive(not ns.state.mageActive)
    end)

    advertBtn = CreateFrame("Button", nil, tab2Frame, "UIPanelButtonTemplate")
    advertBtn:SetSize(170, 28)
    advertBtn:SetPoint("LEFT", toggleActiveBtn, "RIGHT", 8, 0)
    advertBtn:SetText("Post Channel Advert")
    advertBtn:SetScript("OnClick", function()
        ns.MageBroadcastAdvert()
    end)

    reagentStatusLabel = tab2Frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    reagentStatusLabel:SetPoint("TOPLEFT", 18, -82)

    -- Learned / Offered Portals Selector Box
    local portalHeader = tab2Frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    portalHeader:SetPoint("TOPLEFT", 18, -102)
    portalHeader:SetText("Learned / Offered Portals:")

    local cities = ns.CITIES[ns.state.faction] or {}
    for idx, cityData in ipairs(cities) do
        local cb = CreateFrame("CheckButton", nil, tab2Frame, "UICheckButtonTemplate")
        cb:SetSize(22, 22)
        cb:SetPoint("TOPLEFT", 15 + ((idx - 1) * 140), -116)
        cb.cityName = cityData.name
        cb.spellName = cityData.spell
        cb.spellID = cityData.spellID
        cb.text:SetText(cityData.name)
        cb:SetScript("OnClick", function(self)
            ns.SetPortalEnabled(self.cityName, self:GetChecked())
            ns.UpdateUI()
        end)
        table.insert(portalCheckboxes, cb)
    end

    -- Request Queue List Container
    local queueHeader = tab2Frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    queueHeader:SetPoint("TOPLEFT", 18, -148)
    queueHeader:SetText("Incoming Passenger Requests:")

    local queueBox = CreateFrame("Frame", nil, tab2Frame, "BackdropTemplate")
    queueBox:SetSize(424, 228)
    queueBox:SetPoint("TOPLEFT", 18, -166)
    ApplyDarkBackdrop(queueBox, 0.5)

    emptyQueueLabel = queueBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    emptyQueueLabel:SetPoint("CENTER")
    emptyQueueLabel:SetWidth(380)
    emptyQueueLabel:SetText("|cff888888No pending taxi requests for your selected portals.|r")

    for i = 1, 5 do
        local row = CreateFrame("Frame", nil, queueBox, "BackdropTemplate")
        row:SetSize(408, 40)
        row:SetPoint("TOPLEFT", 8, -8 - ((i - 1) * 43))
        ApplyDarkBackdrop(row, 0.35)

        row.playerText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.playerText:SetPoint("TOPLEFT", 8, -6)

        row.infoText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.infoText:SetPoint("TOPLEFT", 8, -21)
        row.infoText:SetWidth(310)
        row.infoText:SetJustifyH("LEFT")

        local acceptBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        acceptBtn:SetSize(78, 24)
        acceptBtn:SetPoint("RIGHT", -8, 0)
        acceptBtn:SetText("Accept Job")
        acceptBtn:SetScript("OnClick", function()
            if row.customerName then
                ns.MageAcceptRequest(row.customerName)
            end
        end)

        row:Hide()
        requestRows[i] = row
    end

    -- Bottom Settings Checkboxes
    local filterCB = CreateFrame("CheckButton", nil, tab2Frame, "UICheckButtonTemplate")
    filterCB:SetPoint("TOPLEFT", 14, -402)
    filterCB:SetChecked(ns.db.filterChatSpam)
    filterCB.text:SetText("Hide [FT:...] protocol tags in chat")
    filterCB:SetScript("OnClick", function(self)
        ns.db.filterChatSpam = self:GetChecked() and true or false
    end)

    local soundCB = CreateFrame("CheckButton", nil, tab2Frame, "UICheckButtonTemplate")
    soundCB:SetPoint("TOPLEFT", 240, -402)
    soundCB:SetChecked(ns.db.soundAlert)
    soundCB.text:SetText("Sound alert on new request")
    soundCB:SetScript("OnClick", function(self)
        ns.db.soundAlert = self:GetChecked() and true or false
    end)
end

-- Create Draggable Minimap Button
local function CreateMinimapButton()
    minimapBtn = CreateFrame("Button", "ForeverTaxiMinimapButton", Minimap)
    minimapBtn:SetSize(31, 31)
    minimapBtn:SetFrameStrata("MEDIUM")
    minimapBtn:SetFrameLevel(8)
    minimapBtn:RegisterForClicks("AnyUp")
    minimapBtn:RegisterForDrag("LeftButton")

    local overlay = minimapBtn:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")

    local icon = minimapBtn:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetTexture("Interface\\Icons\\Spell_Arcane_PortalOrgrimmar")
    icon:SetPoint("CENTER", 0, 1)

    local function UpdatePosition()
        local angle = math.rad(ns.db.minimapAngle or 220)
        local x = math.cos(angle) * 80
        local y = math.sin(angle) * 80
        minimapBtn:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end

    minimapBtn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            ns.db.minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
            UpdatePosition()
        end)
    end)

    minimapBtn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    minimapBtn:SetScript("OnClick", function(_, button)
        if button == "RightButton" and ns.state.isMage then
            ns.SetMageActive(not ns.state.mageActive)
        else
            ns.EnsureChannelJoined()
            ns.ToggleMainWindow()
        end
    end)

    minimapBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cff00ccffForeverTaxi|r")
        GameTooltip:AddLine("|cffffffffLeft-Click:|r Toggle Taxi Window", 0.8, 0.8, 0.8)
        if ns.state.isMage then
            GameTooltip:AddLine("|cffffffffRight-Click:|r Toggle Mage Active Mode", 0.8, 0.8, 0.8)
        end
        GameTooltip:Show()
    end)

    minimapBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    UpdatePosition()
end

function ns.InitUI()
    mainFrame = CreateFrame("Frame", "ForeverTaxiMainFrame", UIParent, "BackdropTemplate")
    mainFrame:SetSize(460, 450)
    mainFrame:SetPoint("CENTER")
    ApplyDarkBackdrop(mainFrame, 0.9)

    table.insert(UISpecialFrames, "ForeverTaxiMainFrame")

    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart", mainFrame.StartMoving)
    mainFrame:SetScript("OnDragStop", mainFrame.StopMovingOrSizing)

    local title = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -12)
    title:SetText("|cff00ccffForever|r|cffffffffTaxi|r")

    local closeBtn = CreateFrame("Button", nil, mainFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -4, -4)

    tab1Btn = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    tab1Btn:SetSize(140, 22)
    tab1Btn:SetPoint("TOPLEFT", 145, -12)
    tab1Btn:SetText("Passenger")
    tab1Btn:SetScript("OnClick", function() SelectTab(1) end)

    tab2Btn = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    tab2Btn:SetSize(140, 22)
    tab2Btn:SetPoint("LEFT", tab1Btn, "RIGHT", 6, 0)
    tab2Btn:SetText("Mage Dashboard")
    tab2Btn:SetScript("OnClick", function() SelectTab(2) end)

    CreatePassengerTab(mainFrame)
    CreateMageTab(mainFrame)
    CreateMinimapButton()

    SelectTab(ns.state.isMage and 2 or 1)
    mainFrame:Hide()
end