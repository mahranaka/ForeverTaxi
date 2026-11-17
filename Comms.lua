local _, ns = ...

local lastWhisperReply = {} -- Per-player cooldown to prevent whisper spam/loops

-- Ensure the ForeverTaxi channel is joined
function ns.EnsureChannelJoined(verbose)
    local id = GetChannelName(ns.CHANNEL_NAME)
    if id and id > 0 then
        if verbose then
            ns.Print("Connected to channel |cffffffff" .. ns.CHANNEL_NAME .. "|r (#" .. id .. ").")
        end
        return id
    end

    JoinTemporaryChannel(ns.CHANNEL_NAME)
    id = GetChannelName(ns.CHANNEL_NAME)
    if id and id > 0 then
        ns.Print("Joined channel |cffffffff" .. ns.CHANNEL_NAME .. "|r (#" .. id .. ").")
    elseif verbose then
        ns.Print("Joining channel |cffffffff" .. ns.CHANNEL_NAME .. "|r...")
    end
    return id
end

-- Find a joined channel ID by name (case-insensitive, supports "Trade" matching "Trade - City")
function ns.ResolveJoinedChannelId(targetName)
    if not targetName or targetName == "" then return nil, nil end
    local id, actualName = GetChannelName(targetName)
    if id and id > 0 then
        return id, actualName
    end

    local list = { GetChannelList() }
    local lowerTarget = string.lower(targetName)
    for i = 1, #list, 3 do
        local cId, cName = list[i], list[i + 1]
        if cId and cName then
            local lowerCName = string.lower(cName)
            if lowerCName == lowerTarget or string.find(lowerCName, "^" .. lowerTarget) then
                return cId, cName
            end
        end
    end
    return nil, nil
end

-- Pre-fill the active chat edit box and configure its chatType directly to the target channel
-- (Avoids raw '|' characters which WoW blocks as invalid UI escape sequences)
function ns.PrefillChannelChat(channelId, text, label)
    if not channelId or channelId <= 0 then return false end

    local editBox = ChatEdit_ChooseBoxForSend()
    ChatEdit_ActivateChat(editBox)
    editBox:SetAttribute("chatType", "CHANNEL")
    editBox:SetAttribute("channelTarget", channelId)
    ChatEdit_UpdateHeader(editBox)
    editBox:SetText(text)
    editBox:HighlightText()

    local chLabel = label and ("#" .. channelId .. " " .. label) or ("#" .. channelId)
    ns.Print("|cff00ccffChat ready for " .. chLabel .. "!|r Press |cffffffffEnter|r to send.")
    return true
end

-- Send a silent addon whisper handshake
function ns.SendAddonWhisper(target, payload)
    if not target or target == "" then return end
    C_ChatInfo.SendAddonMessage(ns.ADDON_PREFIX, payload, "WHISPER", target)
end

-- Passenger: Broadcast a portal request (supports decimal tip values like 0.5)
function ns.PassengerBroadcastRequest(cityName, tipAmount)
    local cityData = ns.ResolveCity(cityName, true)
    if not cityData then
        ns.Print("|cffff5555Invalid destination city for your faction.|r")
        return false
    end

    local ftId = ns.EnsureChannelJoined()
    if not ftId or ftId <= 0 then
        ns.Print("|cffffaa00Channel '" .. ns.CHANNEL_NAME .. "' is initializing. Click Broadcast again in 1 second.|r")
        return false
    end

    local cleanTipStr = string.gsub(strtrim(tostring(tipAmount or "")), ",", ".")
    local tip = tonumber(cleanTipStr)
    if tip == nil then
        tip = tonumber(ns.db.defaultTip) or 2
    end
    if tip < 0 then tip = 0 end

    local location = ns.GetCurrentLocation()
    local restTag = IsResting() and "RESTED" or "NOT_RESTED"
    local msg = string.format("[FT:REQ] %s ~ %s ~ %sg ~ %s", cityData.name, location, ns.FormatTipNumber(tip), restTag)

    ns.state.myRequest = {
        city = cityData.name,
        spell = cityData.spell,
        location = location,
        tip = tip,
        timestamp = GetTime(),
        claimedBy = nil,
    }

    ns.PrefillChannelChat(ftId, msg, ns.CHANNEL_NAME)
    if ns.UpdateUI then ns.UpdateUI() end
    return true
end

-- Passenger: Cancel active request
function ns.PassengerCancelRequest()
    if not ns.state.myRequest then return end
    if ns.state.myRequest.claimedBy then
        ns.SendAddonWhisper(ns.state.myRequest.claimedBy, "CANCEL")
    end
    ns.state.myRequest = nil
    ns.Print("Taxi request cancelled.")
    if ns.UpdateUI then ns.UpdateUI() end
end

-- Passenger: Notify Mage when rested state changes
function ns.SendRestStatus(mageName, isResting)
    if not mageName then return end
    ns.SendAddonWhisper(mageName, "REST_STATUS:" .. (isResting and "1" or "0"))
end

-- Helper: Format a channel's template with active {cities}, {cmds}, and {price}
function ns.FormatAdvertMessage(entry, cityList, cmdList)
    local template = (entry and entry.template and entry.template ~= "")
        and entry.template
        or ns.GetDefaultChannelTemplate(entry and entry.name or "")

    local priceStr = ns.GetFormattedMagePrice()

    -- Escape '%' in replacement strings so string.gsub doesn't treat them as capture references
    local safeCities = string.gsub(cityList or "", "%%", "%%%%")
    local safeCmds = string.gsub(cmdList or "", "%%", "%%%%")
    local safePrice = string.gsub(priceStr or "", "%%", "%%%%")

    local msg = string.gsub(template, "{cities}", safeCities)
    msg = string.gsub(msg, "{cmds}", safeCmds)
    msg = string.gsub(msg, "{price}", safePrice)
    -- Strip any accidental '|' characters that WoW chat blocks
    msg = string.gsub(msg, "|", "")
    return msg
end

-- Mage: Cycle through checked & joined advert channels and pre-fill the configured advert
function ns.MageBroadcastAdvert()
    if not ns.state.isMage then return end
    local enabledCities = ns.GetEnabledMageCities()
    if #enabledCities == 0 then
        ns.Print("|cffff5555Select at least one learned portal city before posting an advert.|r")
        return
    end

    local names = {}
    local aliasExamples = {}
    for _, c in ipairs(enabledCities) do
        table.insert(names, c.name)
        table.insert(aliasExamples, "'" .. c.aliases[1] .. "'")
    end
    local cityList = table.concat(names, ", ")
    local cmdList = table.concat(aliasExamples, " or ")

    local activeTargets = {}
    for _, entry in ipairs(ns.db.advertChannels or {}) do
        if entry.enabled then
            if string.lower(entry.name) == string.lower(ns.CHANNEL_NAME) then
                ns.EnsureChannelJoined()
            end
            local cId, actualName = ns.ResolveJoinedChannelId(entry.name)
            if cId then
                table.insert(activeTargets, {
                    id = cId,
                    name = actualName or entry.name,
                    entry = entry,
                })
            end
        end
    end

    if #activeTargets == 0 then
        ns.Print("|cffff5555None of your checked advert channels are currently joined!|r Check at least one active channel in the Mage Dashboard.")
        return
    end

    ns.state.advertCycleIdx = (ns.state.advertCycleIdx % #activeTargets) + 1
    local target = activeTargets[ns.state.advertCycleIdx]
    local msg = ns.FormatAdvertMessage(target.entry, cityList, cmdList)

    ns.PrefillChannelChat(target.id, msg, target.name)
    if ns.UpdateUI then ns.UpdateUI() end
end

-- Mage: Accept a request from the queue
function ns.MageAcceptRequest(customerName)
    local req = ns.state.requests[customerName]
    if not req then
        ns.Print("|cffff5555Request no longer exists or has expired.|r")
        return
    end

    if ns.state.activeJob then
        ns.Print("|cffffaa00Finish or clear your current active job first!|r")
        return
    end

    ns.state.activeJob = {
        customer = req.sender,
        city = req.city,
        spell = req.spell,
        location = req.location,
        tip = req.tip,
        isResting = req.isResting,
        source = req.source,
        confirmed = (req.source == "WHISPER"),
    }

    ns.state.requests[customerName] = nil

    if req.source == "CHANNEL" then
        ns.SendAddonWhisper(req.sender, "CLAIM:" .. req.city)
    end

    -- Don't whisper fake dummy test users
    if req.sender ~= "TestRider" then
        SendChatMessage(
            string.format("On my way with your %s portal! Make sure you're inside an inn so I can port right to you.", req.city),
            "WHISPER",
            nil,
            req.sender
        )
    end

    if ns.ShowSecureHUD then ns.ShowSecureHUD() end
    if ns.UpdateUI then ns.UpdateUI() end
end

-- Add or update a request in the Mage's queue
local function UpsertRequest(sender, cityData, location, tip, isResting, source)
    local normSender = ns.NormalizeName(sender)
    if not normSender then return end

    local shortSender = Ambiguate(sender, "short")
    if (UnitIsUnit and UnitIsUnit(sender, "player")) or shortSender == UnitName("player") then
        return
    end

    if ns.state.isMage and not ns.IsPortalEnabled(cityData.name) then
        return
    end

    local isNew = (ns.state.requests[normSender] == nil)
    ns.state.requests[normSender] = {
        sender = normSender,
        city = cityData.name,
        spell = cityData.spell,
        location = location or "Unknown Location",
        tip = tonumber(tip) or 0,
        isResting = isResting,
        source = source,
        timestamp = GetTime(),
    }

    if isNew and ns.state.mageActive and ns.db.soundAlert then
        PlaySound(SOUNDKIT.TELL_MESSAGE or 3081)
    end

    if ns.UpdateUI then ns.UpdateUI() end
end

-- Solo testing helper (/taxi test)
function ns.InjectTestRequest()
    local enabled = ns.GetEnabledMageCities()
    local cityData = enabled[1] or (ns.CITIES[ns.state.faction] and ns.CITIES[ns.state.faction][1])
    if not cityData then return end

    ns.state.requests["TestRider"] = {
        sender = "TestRider",
        city = cityData.name,
        spell = cityData.spell,
        location = "Crossroads (Inn)",
        tip = tonumber(ns.db.defaultTip) or 2,
        isResting = true,
        source = "WHISPER",
        timestamp = GetTime(),
    }
    ns.Print("Added dummy request from |cffffffffTestRider|r for |cff00ccff" .. cityData.name .. "|r.")
    if ns.UpdateUI then ns.UpdateUI() end
end

-- Parse public channel messages ([FT:REQ] and [FT:MAGE])
local function ParseChannelMessage(msg, sender)
    local normSender = ns.NormalizeName(sender)
    if not normSender then return end

    local reqBody = string.match(msg, "^%[FT:REQ%]%s*(.+)$")
    if reqBody then
        local cityPart, locPart, tipPart, restPart = strsplit("~", reqBody)
        local cityData = ns.ResolveCity(cityPart, true)
        if cityData then
            local tip = tonumber(string.match(tipPart or "", "(%d+%.?%d*)")) or 0
            local location = strtrim(locPart or "Unknown")
            local isResting = (strtrim(restPart or "") ~= "NOT_RESTED")
            UpsertRequest(normSender, cityData, location, tip, isResting, "CHANNEL")
        end
        return
    end

    local mageBody = string.match(msg, "^%[FT:MAGE%]%s*(.+)$")
    if mageBody then
        ns.state.activeMages[normSender] = {
            name = normSender,
            info = strtrim(mageBody),
            timestamp = GetTime(),
        }
        if ns.UpdateUI then ns.UpdateUI() end
        return
    end
end

-- Helper: Extract a requested faction city from natural player whispers
local function ExtractCityFromWhisper(lowerMsg)
    -- Ignore all automated addon replies
    if string.find(lowerMsg, "^%[forever")
        or string.find(lowerMsg, "^on my way")
        or string.find(lowerMsg, "^hey! got you down")
        or string.find(lowerMsg, "^sorry, i don't have") then
        return nil, false
    end

    -- Strip optional leading/trailing punctuation (!, ?, .) and normalize spaces
    local cleaned = string.gsub(lowerMsg, "[!%?%,]+", " ")
    cleaned = strtrim(string.gsub(cleaned, "%s+", " "))

    -- 1. Direct match on full message (e.g., "org", "uc", "orgrimmar")
    local direct = ns.ResolveCity(cleaned, true)
    if direct then
        return direct, true
    end

    -- 2. Command/phrase prefixes (e.g., "taxi org", "port to undercity", "portal org 0.5g", "tp uc")
    local stripped = string.gsub(cleaned, "^(taxi|port|portal|tp|summon|inv|invite|need|lf|looking for|can i get|pls|please|to|a)+%s+", "")
    stripped = string.gsub(stripped, "%s+(please|pls|ty|thanks|thx|inn|now|%d+%.?%d*g).*$", "")
    local prefixMatch = ns.ResolveCity(stripped, true)
    if prefixMatch then
        return prefixMatch, true
    end

    -- 3. Sentence scan: look for a city keyword combined with portal/taxi/port intent
    local hasIntent = string.find(cleaned, "port") or string.find(cleaned, "taxi") or string.find(cleaned, "tp") or string.find(cleaned, "inn")
    local factionCities = ns.CITIES[ns.state.faction] or {}
    for _, cityData in ipairs(factionCities) do
        for _, alias in ipairs(cityData.aliases) do
            if string.find(" " .. cleaned .. " ", " " .. alias .. " ") then
                if #alias >= 3 or hasIntent or #cleaned <= 12 then
                    return ns.CITY_LOOKUP[alias], (hasIntent ~= nil or #cleaned <= 12)
                end
            end
        end
    end

    return nil, false
end

-- Parse natural-language whispers from non-addon players
local function ParseWhisperCommand(msg, sender)
    if not ns.state.isMage or not ns.state.mageActive then return end
    if not sender or sender == "" then return end

    -- Strictly ignore whispers from yourself to prevent echo loops
    local shortSender = Ambiguate(sender, "short")
    local myShortName = UnitName("player")
    if (UnitIsUnit and UnitIsUnit(sender, "player")) or shortSender == myShortName then
        return
    end

    local normSender = ns.NormalizeName(sender)
    if not normSender then return end

    local lowerMsg = string.lower(strtrim(msg or ""))
    local cityData, confident = ExtractCityFromWhisper(lowerMsg)
    if not cityData or not confident then return end

    -- Enforce a 15-second reply cooldown per player
    local now = GetTime()
    if lastWhisperReply[normSender] and (now - lastWhisperReply[normSender]) < 15 then
        return
    end
    lastWhisperReply[normSender] = now

    local enabledCities = ns.GetEnabledMageCities()
    local validExamples = {}
    for _, c in ipairs(enabledCities) do
        table.insert(validExamples, string.format("%s ('%s')", c.name, c.aliases[1]))
    end
    local offeredStr = (#validExamples > 0) and table.concat(validExamples, ", ") or "None"

    if not ns.IsPortalEnabled(cityData.name) then
        SendChatMessage(
            "Sorry, I don't have Portal: " .. cityData.name .. " learned yet! I can currently port to: " .. offeredStr,
            "WHISPER",
            nil,
            normSender
        )
        return
    end

    local offeredTip = tonumber(string.match(lowerMsg, "(%d+%.?%d*)%s*g")) or tonumber(ns.db.defaultTip) or 2

    UpsertRequest(normSender, cityData, "Whisper Request (Verify Inn)", offeredTip, true, "WHISPER")
    SendChatMessage(
        string.format("Hey! Got you down for a %s portal — make sure you're inside an inn and I'll invite you shortly!", cityData.name),
        "WHISPER",
        nil,
        normSender
    )
end

-- Handle silent FTAXI addon whisper handshakes
local function HandleAddonMessage(prefix, msg, dist, sender)
    if prefix ~= ns.ADDON_PREFIX or dist ~= "WHISPER" then return end
    local normSender = ns.NormalizeName(sender)
    if not normSender then return end

    local cmd, arg = strsplit(":", msg, 2)

    if cmd == "CLAIM" then
        if ns.state.myRequest then
            if not ns.state.myRequest.claimedBy then
                ns.state.myRequest.claimedBy = normSender
                ns.SendAddonWhisper(normSender, "ACK:" .. (IsResting() and "1" or "0"))
                ns.Print("|cff55ff55Mage " .. normSender .. "|r claimed your taxi to |cff00ccff" .. ns.state.myRequest.city .. "|r! Expect a party invite shortly.")
                if ns.UpdateUI then ns.UpdateUI() end
            elseif ns.state.myRequest.claimedBy ~= normSender then
                ns.SendAddonWhisper(normSender, "CLAIMED_BY_OTHER:" .. ns.state.myRequest.claimedBy)
            end
        else
            ns.SendAddonWhisper(normSender, "CANCEL")
        end

    elseif cmd == "ACK" then
        if ns.state.activeJob and ns.state.activeJob.customer == normSender then
            ns.state.activeJob.confirmed = true
            ns.state.activeJob.isResting = (arg == "1")
            ns.Print("|cff55ff55" .. normSender .. " confirmed your taxi!|r Rested: " .. (arg == "1" and "Yes" or "|cffff5555NO|r"))
            if ns.UpdateSecureHUD then ns.UpdateSecureHUD() end
        end

    elseif cmd == "CLAIMED_BY_OTHER" then
        if ns.state.activeJob and ns.state.activeJob.customer == normSender then
            ns.Print("|cffffaa00Job taken:|r " .. normSender .. " was already claimed by |cffffffff" .. (arg or "another Mage") .. "|r.")
            ns.state.activeJob = nil
            if ns.HideSecureHUD then ns.HideSecureHUD() end
        end
        ns.state.requests[normSender] = nil
        if ns.UpdateUI then ns.UpdateUI() end

    elseif cmd == "REST_STATUS" then
        local rested = (arg == "1")
        if ns.state.activeJob and ns.state.activeJob.customer == normSender then
            ns.state.activeJob.isResting = rested
            if not rested then
                ns.Print("|cffff5555WARNING:|r Your customer |cffffffff" .. normSender .. "|r stepped outside an inn!")
            else
                ns.Print("|cff55ff55Customer " .. normSender .. " is now inside an inn.|r")
            end
            if ns.UpdateSecureHUD then ns.UpdateSecureHUD() end
        end
        if ns.state.requests[normSender] then
            ns.state.requests[normSender].isResting = rested
            if ns.UpdateUI then ns.UpdateUI() end
        end

    elseif cmd == "CANCEL" then
        if ns.state.activeJob and ns.state.activeJob.customer == normSender then
            ns.Print("|cffffaa00" .. normSender .. " cancelled their taxi request.|r")
            ns.state.activeJob = nil
            if ns.HideSecureHUD then ns.HideSecureHUD() end
        end
        ns.state.requests[normSender] = nil
        if ns.UpdateUI then ns.UpdateUI() end
    end
end

-- Chat filter to hide [FT:...] protocol messages from main chat tabs when enabled
local function ChatSpamFilter(_, _, msg, _, _, _, _, _, _, _, channelName)
    if not ns.db or not ns.db.filterChatSpam then
        return false
    end
    if channelName and string.lower(channelName) == string.lower(ns.CHANNEL_NAME) then
        if string.match(msg, "^%[FT:") then
            return true
        end
    end
    return false
end

-- Periodic TTL Sweep
local sweepElapsed = 0
local commsFrame = CreateFrame("Frame")
commsFrame:RegisterEvent("CHAT_MSG_CHANNEL")
commsFrame:RegisterEvent("CHAT_MSG_WHISPER")
commsFrame:RegisterEvent("CHAT_MSG_ADDON")

commsFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_CHANNEL" then
        local msg, sender, _, _, _, _, _, _, channelName = ...
        if channelName and string.lower(channelName) == string.lower(ns.CHANNEL_NAME) then
            ParseChannelMessage(msg, sender)
        end

    elseif event == "CHAT_MSG_WHISPER" then
        local msg, sender = ...
        ParseWhisperCommand(msg, sender)

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, msg, dist, sender = ...
        HandleAddonMessage(prefix, msg, dist, sender)
    end
end)

commsFrame:SetScript("OnUpdate", function(_, elapsed)
    sweepElapsed = sweepElapsed + elapsed
    if sweepElapsed < 5 then return end
    sweepElapsed = 0

    local now = GetTime()
    local changed = false

    for k, req in pairs(ns.state.requests) do
        if (now - req.timestamp) > ns.REQUEST_TTL then
            ns.state.requests[k] = nil
            changed = true
        end
    end

    for k, mage in pairs(ns.state.activeMages) do
        if (now - mage.timestamp) > 600 then
            ns.state.activeMages[k] = nil
            changed = true
        end
    end

    if changed and ns.UpdateUI then
        ns.UpdateUI()
    end
end)

function ns.InitComms()
    C_ChatInfo.RegisterAddonMessagePrefix(ns.ADDON_PREFIX)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", ChatSpamFilter)
end