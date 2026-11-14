local _, ns = ...

-- Ensure the ForeverTaxi channel is joined (must be called from user interaction / slash cmd)
function ns.EnsureChannelJoined(verbose)
    local id = GetChannelName(ns.CHANNEL_NAME)
    if id and id > 0 then
        if verbose then
            ns.Print("Already connected to channel |cffffffff" .. ns.CHANNEL_NAME .. "|r (#" .. id .. ").")
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

-- Broadcast a message to the ForeverTaxi channel (Hardware event required!)
function ns.BroadcastToChannel(text)
    local id = ns.EnsureChannelJoined()
    if id and id > 0 then
        SendChatMessage(text, "CHANNEL", nil, id)
        return true
    else
        ns.Print("|cffffaa00Channel '" .. ns.CHANNEL_NAME .. "' is still initializing. Click the button again in 1 second.|r")
        return false
    end
end

-- Send a silent addon whisper handshake
function ns.SendAddonWhisper(target, payload)
    if not target or target == "" then return end
    C_ChatInfo.SendAddonMessage(ns.ADDON_PREFIX, payload, "WHISPER", target)
end

-- Passenger: Broadcast a portal request (called via button click)
function ns.PassengerBroadcastRequest(cityName, tipAmount)
    local cityData = ns.ResolveCity(cityName, true)
    if not cityData then
        ns.Print("|cffff5555Invalid destination city for your faction.|r")
        return false
    end

    local tip = tonumber(tipAmount) or ns.db.defaultTip or 2
    if tip < 0 then tip = 0 end

    local location = ns.GetCurrentLocation()
    local restTag = IsResting() and "RESTED" or "NOT_RESTED"

    -- Format: [FT:REQ] Orgrimmar | Brill (Gallows' End Tavern) | 2g | RESTED
    local msg = string.format("[FT:REQ] %s | %s | %dg | %s", cityData.name, location, tip, restTag)
    if ns.BroadcastToChannel(msg) then
        ns.state.myRequest = {
            city = cityData.name,
            spell = cityData.spell,
            location = location,
            tip = tip,
            timestamp = GetTime(),
            claimedBy = nil,
        }
        ns.Print("Broadcasted request for |cff00ccff" .. cityData.name .. "|r (" .. tip .. "g tip).")
        if ns.UpdateUI then ns.UpdateUI() end
        return true
    end
    return false
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

-- Mage: Broadcast active taxi advertisement (called via button click)
function ns.MageBroadcastAdvert()
    if not ns.state.isMage then return end
    local cities = ns.CITIES[ns.state.faction] or {}
    local names = {}
    for _, c in ipairs(cities) do
        table.insert(names, c.name)
    end
    local cityList = table.concat(names, ", ")
    local msg = string.format("[FT:MAGE] Active | Cities: %s | Whisper '!taxi <city>' or use ForeverTaxi addon!", cityList)
    if ns.BroadcastToChannel(msg) then
        ns.Print("Posted Mage Taxi advertisement to #" .. ns.CHANNEL_NAME .. ".")
    end
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

    -- Lock locally and send silent CLAIM handshake to customer
    ns.state.activeJob = {
        customer = req.sender,
        city = req.city,
        spell = req.spell,
        location = req.location,
        tip = req.tip,
        isResting = req.isResting,
        source = req.source,
        confirmed = (req.source == "WHISPER"), -- Non-addon whisperers don't send ACK
    }

    -- Remove from open queue
    ns.state.requests[customerName] = nil

    if req.source == "CHANNEL" then
        ns.SendAddonWhisper(req.sender, "CLAIM:" .. req.city)
    end

    -- Send polite confirmation whisper so both addon and non-addon users know
    SendChatMessage(
        string.format("[ForeverTaxi] Accepted your portal request to %s! Make sure you are inside an inn so I can port to you.", req.city),
        "WHISPER",
        nil,
        req.sender
    )

    if ns.ShowSecureHUD then ns.ShowSecureHUD() end
    if ns.UpdateUI then ns.UpdateUI() end
end

-- Add or update a request in the Mage's queue
local function UpsertRequest(sender, cityData, location, tip, isResting, source)
    local normSender = ns.NormalizeName(sender)
    if not normSender or normSender == ns.NormalizeName(UnitName("player")) then return end

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

-- Parse public channel messages ([FT:REQ] and [FT:MAGE])
local function ParseChannelMessage(msg, sender)
    local normSender = ns.NormalizeName(sender)
    if not normSender then return end

    -- 1. Passenger Request: [FT:REQ] Orgrimmar | Brill (Inn) | 2g | RESTED
    local reqBody = string.match(msg, "^%[FT:REQ%]%s*(.+)$")
    if reqBody then
        local cityPart, locPart, tipPart, restPart = strsplit("|", reqBody)
        local cityData = ns.ResolveCity(cityPart, true)
        if cityData then
            local tip = tonumber(string.match(tipPart or "", "(%d+)")) or 0
            local location = strtrim(locPart or "Unknown")
            local isResting = (strtrim(restPart or "") ~= "NOT_RESTED")
            UpsertRequest(normSender, cityData, location, tip, isResting, "CHANNEL")
        end
        return
    end

    -- 2. Mage Advertisement: [FT:MAGE] Active | ...
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

-- Parse whisper fallback command (!taxi <city>)
local function ParseWhisperCommand(msg, sender)
    if not ns.state.isMage or not ns.state.mageActive then return end

    local arg = string.match(strtrim(msg), "^![Tt][Aa][Xx][Ii]%s+(.+)$")
    if not arg then return end

    local normSender = ns.NormalizeName(sender)
    local cityData = ns.ResolveCity(arg, true)
    if not cityData then
        local validList = {}
        for _, c in ipairs(ns.CITIES[ns.state.faction] or {}) do
            table.insert(validList, c.aliases[1])
        end
        SendChatMessage(
            "[ForeverTaxi] Unknown city '" .. arg .. "'. Valid options: " .. table.concat(validList, ", "),
            "WHISPER",
            nil,
            normSender
        )
        return
    end

    UpsertRequest(normSender, cityData, "Whisper Request (Verify Inn)", ns.db.defaultTip or 2, true, "WHISPER")
    SendChatMessage(
        string.format("[ForeverTaxi] Queued your request for %s! Please ensure you are inside an inn.", cityData.name),
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

    -- Passenger receives CLAIM from a Mage
    if cmd == "CLAIM" then
        if ns.state.myRequest then
            if not ns.state.myRequest.claimedBy then
                -- First mage wins the race condition
                ns.state.myRequest.claimedBy = normSender
                ns.SendAddonWhisper(normSender, "ACK:" .. (IsResting() and "1" or "0"))
                ns.Print("|cff55ff55Mage " .. normSender .. "|r claimed your taxi to |cff00ccff" .. ns.state.myRequest.city .. "|r! Expect a party invite shortly.")
                if ns.UpdateUI then ns.UpdateUI() end
            elseif ns.state.myRequest.claimedBy ~= normSender then
                -- Tell competing mages the job is already taken
                ns.SendAddonWhisper(normSender, "CLAIMED_BY_OTHER:" .. ns.state.myRequest.claimedBy)
            end
        else
            ns.SendAddonWhisper(normSender, "CANCEL")
        end

    -- Mage receives ACK from Passenger
    elseif cmd == "ACK" then
        if ns.state.activeJob and ns.state.activeJob.customer == normSender then
            ns.state.activeJob.confirmed = true
            ns.state.activeJob.isResting = (arg == "1")
            ns.Print("|cff55ff55" .. normSender .. " confirmed your taxi!|r Rested: " .. (arg == "1" and "Yes" or "|cffff5555NO|r"))
            if ns.UpdateSecureHUD then ns.UpdateSecureHUD() end
        end

    -- Mage learns another Mage claimed the customer milliseconds earlier
    elseif cmd == "CLAIMED_BY_OTHER" then
        if ns.state.activeJob and ns.state.activeJob.customer == normSender then
            ns.Print("|cffffaa00Job taken:|r " .. normSender .. " was already claimed by |cffffffff" .. (arg or "another Mage") .. "|r.")
            ns.state.activeJob = nil
            if ns.HideSecureHUD then ns.HideSecureHUD() end
        end
        ns.state.requests[normSender] = nil
        if ns.UpdateUI then ns.UpdateUI() end

    -- Customer updated their rested status while waiting
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

    -- Customer cancelled their request
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

-- Periodic TTL Sweep (cleans expired requests & stale mages every 5 seconds)
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
        if (now - mage.timestamp) > 600 then -- 10 min TTL for mage adverts
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