local _, ns = ...

local hudFrame
local inviteBtn, scrollBtn, portalBtn, clearBtn
local customerText, locationText, destText, statusText, reagentText
local pendingPortalSpell = nil

-- Scan player bags to find the exact Item ID of Scroll of Liminal Passage
local function FindLiminalScrollItemString()
    local targetName = "Scroll of Liminal Passage"
    if C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo then
        for bag = 0, 4 do
            local numSlots = C_Container.GetContainerNumSlots(bag) or 0
            for slot = 1, numSlots do
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if info and info.itemID then
                    local name = GetItemInfo(info.itemID)
                    if name == targetName then
                        return "item:" .. tostring(info.itemID), info.itemID
                    end
                end
            end
        end
    end
    -- Fallback to item name if not yet cached
    return targetName, nil
end

-- Safely update secure button attributes outside of combat lockdown
local function ApplySecureAttributes()
    if not hudFrame or not ns.state.activeJob then return end

    if InCombatLockdown() then
        pendingPortalSpell = ns.state.activeJob.spell
        hudFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end

    -- 1. Scroll of Liminal Passage button (prefer exact "item:<ID>" from bags)
    local itemAttr = FindLiminalScrollItemString()
    scrollBtn:SetAttribute("type", "item")
    scrollBtn:SetAttribute("type1", "item")
    scrollBtn:SetAttribute("item", itemAttr)
    scrollBtn:SetAttribute("item1", itemAttr)

    -- 2. Dynamic Portal Spell button
    local spellName = ns.state.activeJob.spell
    portalBtn:SetAttribute("type", "spell")
    portalBtn:SetAttribute("type1", "spell")
    portalBtn:SetAttribute("spell", spellName)
    portalBtn:SetAttribute("spell1", spellName)
    portalBtn:SetText("Cast " .. spellName)

    pendingPortalSpell = nil
end

function ns.UpdateSecureHUD()
    if not hudFrame then return end
    local job = ns.state.activeJob
    if not job then
        hudFrame:Hide()
        return
    end

    local tipStr = ns.FormatTipNumber and ns.FormatTipNumber(job.tip) or tostring(job.tip)
    customerText:SetText("|cffffffffCustomer:|r |cff00ccff" .. job.customer .. "|r  (|cffffd100" .. tipStr .. "g|r)")
    locationText:SetText("|cffffffffLocation:|r " .. job.location)
    destText:SetText("|cffffffffDestination:|r |cff55ff55" .. job.city .. "|r")

    -- Check group & rested status
    local shortName = Ambiguate(job.customer, "short")
    local inGroup = UnitInParty(job.customer) or UnitInParty(shortName) or UnitInRaid(job.customer) or UnitInRaid(shortName)
    if inGroup then
        inviteBtn:SetText("In Party")
        inviteBtn:Disable()
    else
        inviteBtn:SetText("Invite Customer")
        inviteBtn:Enable()
    end

    -- Check rested conditions
    local mageRested = IsResting()
    local custRested = job.isResting
    if mageRested and custRested then
        statusText:SetText("|cff55ff55Ready to Port (Both in Inn)|r")
    elseif not mageRested then
        statusText:SetText("|cffff5555You are NOT in an Inn!|r")
    else
        statusText:SetText("|cffffaa00Customer NOT in an Inn!|r")
    end

    -- Check reagent inventory
    local scrolls, runes = ns.GetMageReagentCounts()
    local scrollColor = (scrolls > 0) and "|cff55ff55" or "|cffff5555"
    local runeColor = (runes > 0) and "|cff55ff55" or "|cffff5555"
    reagentText:SetText(string.format("Scrolls: %s%d|r  |  Runes: %s%d|r", scrollColor, scrolls, runeColor, runes))

    ApplySecureAttributes()
end

function ns.ShowSecureHUD()
    if not hudFrame then return end
    ns.UpdateSecureHUD()
    hudFrame:Show()
end

function ns.HideSecureHUD()
    if not hudFrame then return end
    if InCombatLockdown() then
        ns.Print("|cffffaa00Cannot hide Secure HUD during combat; it will close when combat ends.|r")
        hudFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    hudFrame:Hide()
end

function ns.InitSecureHUD()
    hudFrame = CreateFrame("Frame", "ForeverTaxiSecureHUD", UIParent, "BackdropTemplate")
    hudFrame:SetSize(280, 215)
    hudFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    hudFrame:SetBackdropColor(0.06, 0.08, 0.12, 0.94)
    hudFrame:SetBackdropBorderColor(0.0, 0.75, 1.0, 0.9)

    local pos = ns.db.hudPos or { point = "CENTER", relativePoint = "CENTER", x = 0, y = 180 }
    hudFrame:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)

    -- Draggable setup
    hudFrame:SetMovable(true)
    hudFrame:EnableMouse(true)
    hudFrame:RegisterForDrag("LeftButton")
    hudFrame:SetScript("OnDragStart", hudFrame.StartMoving)
    hudFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relativePoint, x, y = self:GetPoint()
        ns.db.hudPos = { point = point, relativePoint = relativePoint, x = x, y = y }
    end)

    -- Header
    local title = hudFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -10)
    title:SetText("|cff00ccffForeverTaxi|r - Active Job")

    -- Info Lines
    customerText = hudFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    customerText:SetPoint("TOPLEFT", 14, -30)

    locationText = hudFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    locationText:SetPoint("TOPLEFT", 14, -45)
    locationText:SetWidth(252)
    locationText:SetJustifyH("LEFT")

    destText = hudFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    destText:SetPoint("TOPLEFT", 14, -60)

    statusText = hudFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statusText:SetPoint("TOPLEFT", 14, -76)

    reagentText = hudFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    reagentText:SetPoint("TOPLEFT", 14, -91)

    -- Button 1: Invite Customer (uses 1.15+ C_PartyInfo.InviteUnit)
    inviteBtn = CreateFrame("Button", nil, hudFrame, "UIPanelButtonTemplate")
    inviteBtn:SetSize(250, 24)
    inviteBtn:SetPoint("TOP", 0, -110)
    inviteBtn:SetText("Invite Customer")
    inviteBtn:SetScript("OnClick", function()
        local job = ns.state.activeJob
        if not job or not job.customer then return end
        if C_PartyInfo and C_PartyInfo.InviteUnit then
            C_PartyInfo.InviteUnit(job.customer)
        elseif InviteUnit then
            InviteUnit(job.customer)
        end
        ns.Print("Sent party invite to |cffffffff" .. job.customer .. "|r.")
        ns.UpdateSecureHUD()
    end)

    -- Button 2: Use Scroll of Liminal Passage (SecureActionButtonTemplate)
    scrollBtn = CreateFrame("Button", "ForeverTaxiScrollBtn", hudFrame, "SecureActionButtonTemplate, UIPanelButtonTemplate")
    scrollBtn:SetSize(250, 24)
    scrollBtn:SetPoint("TOP", 0, -137)
    scrollBtn:SetText("Use Scroll of Liminal Passage")
    scrollBtn:RegisterForClicks("AnyDown", "AnyUp")
    scrollBtn:SetAttribute("type", "item")
    scrollBtn:SetAttribute("type1", "item")
    scrollBtn:SetAttribute("item", "Scroll of Liminal Passage")
    scrollBtn:HookScript("PreClick", function()
        local scrolls = ns.GetMageReagentCounts()
        if scrolls == 0 then
            ns.Print("|cffff5555Missing item:|r You have 0x Scroll of Liminal Passage!")
        elseif not IsResting() then
            ns.Print("|cffff5555Warning:|r You are not in an inn! The scroll will fail.")
        end
    end)

    -- Button 3: Cast Portal (SecureActionButtonTemplate)
    portalBtn = CreateFrame("Button", "ForeverTaxiPortalBtn", hudFrame, "SecureActionButtonTemplate, UIPanelButtonTemplate")
    portalBtn:SetSize(250, 24)
    portalBtn:SetPoint("TOP", 0, -164)
    portalBtn:SetText("Cast Portal")
    portalBtn:RegisterForClicks("AnyDown", "AnyUp")
    portalBtn:HookScript("PreClick", function()
        local _, runes = ns.GetMageReagentCounts()
        if runes == 0 then
            ns.Print("|cffff5555Missing reagent:|r You have 0x Rune of Portals!")
        end
    end)

    -- Button 4: Complete / Clear Job (whispers thank-you to customer and clears HUD)
    clearBtn = CreateFrame("Button", nil, hudFrame, "UIPanelButtonTemplate")
    clearBtn:SetSize(250, 20)
    clearBtn:SetPoint("TOP", 0, -190)
    clearBtn:SetText("Complete / Clear Job")
    clearBtn:SetScript("OnClick", function()
        local job = ns.state.activeJob
        if job and job.customer and job.customer ~= "TestRider" then
            SendChatMessage(
                string.format("Thanks for riding ForeverTaxi! Enjoy %s and safe travels!", job.city),
                "WHISPER",
                nil,
                job.customer
            )
        end
        ns.state.activeJob = nil
        ns.Print("Job completed and cleared.")
        ns.HideSecureHUD()
        if ns.UpdateUI then ns.UpdateUI() end
    end)

    -- Deferred combat lockdown handler
    hudFrame:SetScript("OnEvent", function(self, event)
        if event == "PLAYER_REGEN_ENABLED" then
            self:UnregisterEvent("PLAYER_REGEN_ENABLED")
            if not ns.state.activeJob then
                self:Hide()
            elseif pendingPortalSpell then
                ApplySecureAttributes()
            end
        end
    end)

    hudFrame:Hide()
end