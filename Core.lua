local addonName, ns = ...

-- Initialize shared namespace
ns.name = addonName
ns.version = "1.2.3"
ns.CHANNEL_NAME = "ForeverTaxi"
ns.ADDON_PREFIX = "FTAXI"
ns.REQUEST_TTL = 180 -- Seconds before a taxi request expires

-- Runtime state
ns.state = {
    isMage = false,
    mageActive = false,
    faction = nil,
    isResting = false,
    requests = {},       -- Keyed by Ambiguate(sender, "none")
    activeMages = {},    -- Keyed by Ambiguate(sender, "none")
    activeJob = nil,     -- Mage's current accepted customer table
    myRequest = nil,     -- Passenger's current outgoing request table
    advertCycleIdx = 0,  -- Tracks round-robin index across selected advert channels
}

-- Format a numeric tip cleanly (e.g., 2 -> "2", 0.5 -> "0.5")
function ns.FormatTipNumber(val)
    local num = tonumber(val)
    if not num or num < 0 then return "0" end
    if math.floor(num) == num then
        return tostring(math.floor(num))
    end
    local s = string.format("%.2f", num)
    s = string.gsub(s, "0+$", "")
    s = string.gsub(s, "%.$", "")
    return s
end

-- Normalize the Mage's advertised price string (e.g., "1" -> "1g", "0.5g" -> "0.5g")
function ns.GetFormattedMagePrice()
    local raw = strtrim((ns.db and ns.db.magePrice) or "1g")
    if raw == "" then raw = "1g" end
    if tonumber(raw) then
        return ns.FormatTipNumber(raw) .. "g"
    end
    return raw
end

-- Default whisper auto-reply template ({city} and {price} are substituted dynamically)
function ns.GetDefaultWhisperReplyTemplate()
    return "Hey! Got you down for a {city} portal — make sure you're inside an inn and I'll invite you shortly!"
end

-- Default message templates per channel ({cities}, {cmds}, and {price} are substituted dynamically)
function ns.GetDefaultChannelTemplate(channelName)
    local lower = string.lower(strtrim(channelName or ""))
    if lower == string.lower(ns.CHANNEL_NAME) then
        return "[FT:MAGE] Active ~ Cities: {cities} ~ Whisper {cmds} or use ForeverTaxi! Price: {price}"
    elseif lower == "trade" then
        return "Inn-to-City Mage Portals ({cities}) from ANY inn! Whisper {cmds} for an instant invite. Join the channel /join ForeverTaxi to always be able to request (or get the Addon ForeverTaxi)! Price: {price}"
    elseif lower == "general" then
        return "Inn-to-City Mage Portals ({cities}) from ANY inn! Whisper {cmds} for an instant invite (or grab the ForeverTaxi addon to request from anywhere! Or just join the Channel /join ForeverTaxi). Price: {price}"
    else
        return "Inn-to-City Mage Portals ({cities}) from ANY inn! Whisper {cmds} for an instant invite. Price: {price}"
    end
end

-- Previous v1.2.0 templates so existing SavedVariables auto-migrate cleanly
local LEGACY_TEMPLATES = {
    ["[FT:MAGE] Active ~ Cities: {cities} ~ Whisper {cmds} or use ForeverTaxi!"] = true,
    ["Inn-to-Inn Mage Portals ({cities}) from ANY inn! Whisper {cmds} for an instant invite (or grab the ForeverTaxi addon to request from anywhere!)."] = true,
    ["Inn-to-Inn Mage Portals ({cities}) from ANY inn! Whisper {cmds} for an instant invite."] = true,
}

-- SavedVariables defaults
local defaults = {
    defaultTip = 2,
    magePrice = "1g",
    autoAcceptInvite = true,
    filterChatSpam = true,
    soundAlert = true,
    whisperAutoReply = true,
    whisperReplyTemplate = ns.GetDefaultWhisperReplyTemplate(),
    minimapAngle = 220,
    hudPos = { point = "CENTER", relativePoint = "CENTER", x = 0, y = 180 },
    knownPortals = {},   -- Keyed by "PlayerName-Realm" -> { ["Orgrimmar"] = true, ... }
    advertChannels = {   -- Ordered list of { name = "ChannelName", enabled = bool, template = string }
        { name = "ForeverTaxi", enabled = true, template = ns.GetDefaultChannelTemplate("ForeverTaxi") },
        { name = "Trade",       enabled = true, template = ns.GetDefaultChannelTemplate("Trade") },
        { name = "General",     enabled = true, template = ns.GetDefaultChannelTemplate("General") },
    },
}

-- Faction city definitions, spell IDs (Classic Era), and aliases
ns.CITIES = {
    Horde = {
        { name = "Orgrimmar",     spell = "Portal: Orgrimmar",     spellID = 11417, aliases = { "org", "og", "orgrimmar" } },
        { name = "Undercity",     spell = "Portal: Undercity",     spellID = 11418, aliases = { "uc", "undercity" } },
        { name = "Thunder Bluff", spell = "Portal: Thunder Bluff", spellID = 11420, aliases = { "tb", "thunder", "thunderbluff", "thunder bluff" } },
    },
    Alliance = {
        { name = "Stormwind",     spell = "Portal: Stormwind",     spellID = 10059, aliases = { "sw", "stormwind" } },
        { name = "Ironforge",     spell = "Portal: Ironforge",     spellID = 11416, aliases = { "if", "ironforge" } },
        { name = "Darnassus",     spell = "Portal: Darnassus",     spellID = 11419, aliases = { "darn", "darnassus", "dn" } },
    },
}

-- Lookup map for fast alias/city resolution
ns.CITY_LOOKUP = {}
for faction, cities in pairs(ns.CITIES) do
    for _, data in ipairs(cities) do
        ns.CITY_LOOKUP[string.lower(data.name)] = { name = data.name, spell = data.spell, spellID = data.spellID, faction = faction }
        for _, alias in ipairs(data.aliases) do
            ns.CITY_LOOKUP[alias] = { name = data.name, spell = data.spell, spellID = data.spellID, faction = faction }
        end
    end
end

-- Utility: Formatted chat output
function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[ForeverTaxi]|r " .. tostring(msg))
end

-- Utility: Normalize player name
function ns.NormalizeName(name)
    if not name or name == "" then return nil end
    return Ambiguate(name, "none")
end

-- Utility: Get unique character key for SavedVariables
function ns.GetCharKey()
    local name = UnitName("player") or "Unknown"
    local realm = GetRealmName() or "Realm"
    return name .. "-" .. realm
end

-- Utility: Safe spellbook check compatible with 1.15+ C_Spell API
function ns.DoesPlayerKnowSpell(spellID, spellName)
    if spellID and IsSpellKnown and IsSpellKnown(spellID) then
        return true
    end
    if spellName and C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellName)
        if info then return true end
    elseif spellName and GetSpellInfo then
        if GetSpellInfo(spellName) then return true end
    end
    return false
end

-- Utility: Auto-detect learned portal spells in spellbook if not yet configured
function ns.SyncKnownPortals(forceAutoDetect)
    if not ns.state.isMage or not ns.db then return end
    local charKey = ns.GetCharKey()
    ns.db.knownPortals = ns.db.knownPortals or {}

    local charPortals = ns.db.knownPortals[charKey]
    local isFirstSetup = (charPortals == nil)
    if isFirstSetup then
        charPortals = {}
        ns.db.knownPortals[charKey] = charPortals
    end

    local cities = ns.CITIES[ns.state.faction] or {}
    for _, c in ipairs(cities) do
        local knowsSpell = ns.DoesPlayerKnowSpell(c.spellID, c.spell)
        if isFirstSetup or forceAutoDetect then
            charPortals[c.name] = knowsSpell and true or false
        elseif knowsSpell and charPortals[c.name] == nil then
            charPortals[c.name] = true
        end
    end
end

-- Utility: Check if this Mage currently offers a specific city portal
function ns.IsPortalEnabled(cityName)
    if not ns.state.isMage or not ns.db or not ns.db.knownPortals then return false end
    local charPortals = ns.db.knownPortals[ns.GetCharKey()]
    if not charPortals then return false end
    return charPortals[cityName] == true
end

-- Utility: Set whether a portal city is enabled for this Mage
function ns.SetPortalEnabled(cityName, enabled)
    if not ns.state.isMage or not ns.db then return end
    local charKey = ns.GetCharKey()
    ns.db.knownPortals = ns.db.knownPortals or {}
    ns.db.knownPortals[charKey] = ns.db.knownPortals[charKey] or {}
    ns.db.knownPortals[charKey][cityName] = enabled and true or false
end

-- Utility: Get list of enabled city objects for this Mage
function ns.GetEnabledMageCities()
    local result = {}
    local cities = ns.CITIES[ns.state.faction] or {}
    for _, c in ipairs(cities) do
        if ns.IsPortalEnabled(c.name) then
            table.insert(result, c)
        end
    end
    return result
end

-- Utility: Add a channel to the advert list (deduplicated case-insensitively)
function ns.AddAdvertChannel(channelName)
    if not ns.db then return false end
    local clean = strtrim(channelName or "")
    clean = string.gsub(clean, "^[#/%d%.%s]+", "")
    if clean == "" then return false end

    ns.db.advertChannels = ns.db.advertChannels or {}
    for _, entry in ipairs(ns.db.advertChannels) do
        if string.lower(entry.name) == string.lower(clean) then
            entry.enabled = true
            if not entry.template or entry.template == "" then
                entry.template = ns.GetDefaultChannelTemplate(entry.name)
            end
            ns.Print("Channel |cffffffff#" .. entry.name .. "|r is already in the list (enabled).")
            return true
        end
    end

    table.insert(ns.db.advertChannels, {
        name = clean,
        enabled = true,
        template = ns.GetDefaultChannelTemplate(clean),
    })
    ns.Print("Added |cffffffff#" .. clean .. "|r to advert channels.")
    return true
end

-- Utility: Remove a custom channel from the advert list (keeps ForeverTaxi core channel)
function ns.RemoveAdvertChannel(channelName)
    if not ns.db or not ns.db.advertChannels then return end
    if string.lower(channelName) == string.lower(ns.CHANNEL_NAME) then
        ns.Print("|cffffaa00Cannot remove the core #ForeverTaxi channel (you can uncheck it instead).|r")
        return
    end
    for i, entry in ipairs(ns.db.advertChannels) do
        if string.lower(entry.name) == string.lower(channelName) then
            table.remove(ns.db.advertChannels, i)
            ns.Print("Removed |cffffffff#" .. entry.name .. "|r from advert channels.")
            return
        end
    end
end

-- Utility: Update a channel's custom advert template
function ns.SetAdvertChannelTemplate(channelName, text)
    if not ns.db or not ns.db.advertChannels then return end
    local cleanText = strtrim(text or "")
    for _, entry in ipairs(ns.db.advertChannels) do
        if string.lower(entry.name) == string.lower(channelName) then
            if cleanText == "" then
                entry.template = ns.GetDefaultChannelTemplate(entry.name)
            else
                entry.template = cleanText
            end
            ns.Print("Saved advert text for |cffffffff#" .. entry.name .. "|r.")
            return
        end
    end
end

-- Utility: Reset a single channel's advert template back to default
function ns.ResetAdvertChannelTemplate(channelName)
    if not ns.db or not ns.db.advertChannels then return end
    for _, entry in ipairs(ns.db.advertChannels) do
        if string.lower(entry.name) == string.lower(channelName) then
            entry.template = ns.GetDefaultChannelTemplate(entry.name)
            ns.Print("Reset advert text for |cffffffff#" .. entry.name .. "|r to default.")
            return
        end
    end
end

-- Utility: Reset all channel advert templates back to their defaults
function ns.ResetAllAdvertChannelTemplates()
    if not ns.db or not ns.db.advertChannels then return end
    for _, entry in ipairs(ns.db.advertChannels) do
        entry.template = ns.GetDefaultChannelTemplate(entry.name)
    end
    ns.Print("Reset all channel advert texts to default.")
end

-- Utility: Update custom whisper auto-reply template
function ns.SetWhisperReplyTemplate(text)
    if not ns.db then return end
    local cleanText = strtrim(text or "")
    if cleanText == "" then
        ns.db.whisperReplyTemplate = ns.GetDefaultWhisperReplyTemplate()
    else
        ns.db.whisperReplyTemplate = cleanText
    end
    ns.Print("Saved whisper auto-reply text.")
end

-- Utility: Reset whisper auto-reply template to default
function ns.ResetWhisperReplyTemplate()
    if not ns.db then return end
    ns.db.whisperReplyTemplate = ns.GetDefaultWhisperReplyTemplate()
    ns.Print("Reset whisper auto-reply text to default.")
end

-- Utility: Get formatted current location
function ns.GetCurrentLocation()
    local zone = GetZoneText() or "Unknown"
    local subZone = GetSubZoneText()
    if subZone and subZone ~= "" and subZone ~= zone then
        return zone .. " (" .. subZone .. ")"
    end
    return zone
end

-- Utility: Resolve a user string or alias into canonical city data
function ns.ResolveCity(input, restrictToPlayerFaction)
    if not input or input == "" then return nil end
    local clean = string.lower(strtrim(input))
    local entry = ns.CITY_LOOKUP[clean]
    if not entry then return nil end
    if restrictToPlayerFaction and entry.faction ~= ns.state.faction then
        return nil
    end
    return entry
end

-- Utility: Inventory reagent checks for Mages
function ns.GetMageReagentCounts()
    local scrolls = GetItemCount("Scroll of Liminal Passage", false, false) or 0
    local runes = GetItemCount("Rune of Portals", false, false) or 0
    return scrolls, runes
end

-- Utility: Toggle Mage Active state
function ns.SetMageActive(active)
    if not ns.state.isMage then
        ns.Print("|cffff5555Only Mages can activate Taxi Driver mode.|r")
        return
    end

    if active then
        local enabledCities = ns.GetEnabledMageCities()
        if #enabledCities == 0 then
            ns.Print("|cffff5555Warning:|r You have no portals selected in the Mage Dashboard! Check at least one city first.")
            return
        end
        if not IsResting() then
            ns.Print("|cffffaa00Warning:|r You are not inside an inn! Scroll of Liminal Passage requires both players to be rested.")
        end
        local scrolls, runes = ns.GetMageReagentCounts()
        if scrolls == 0 then
            ns.Print("|cffff5555Warning:|r You have 0x |cffffffffScroll of Liminal Passage|r in your bags!")
        end
        if runes == 0 then
            ns.Print("|cffffaa00Warning:|r You have 0x |cffffffffRune of Portals|r in your bags!")
        end

        ns.EnsureChannelJoined()
        ns.state.mageActive = true
        ns.Print("|cff55ff55Mage Taxi mode ENABLED.|r Listening for requests in channel and whispers (e.g. 'org', 'uc', 'taxi org').")
    else
        ns.state.mageActive = false
        ns.Print("|cffffaa00Mage Taxi mode DISABLED.|r")
    end

    if ns.UpdateUI then ns.UpdateUI() end
end

-- Core Event Frame
local coreFrame = CreateFrame("Frame")
coreFrame:RegisterEvent("ADDON_LOADED")
coreFrame:RegisterEvent("PLAYER_LOGIN")
coreFrame:RegisterEvent("SPELLS_CHANGED")
coreFrame:RegisterEvent("PLAYER_UPDATE_RESTING")
coreFrame:RegisterEvent("PARTY_INVITE_REQUEST")
coreFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
coreFrame:RegisterEvent("CHANNEL_UI_UPDATE")

coreFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        if type(ForeverTaxiDB) ~= "table" then
            ForeverTaxiDB = {}
        end
        for k, v in pairs(defaults) do
            if ForeverTaxiDB[k] == nil then
                ForeverTaxiDB[k] = v
            end
        end
        ns.db = ForeverTaxiDB

        -- Backfill / migrate default templates onto existing SavedVariables channel entries
        if type(ns.db.advertChannels) == "table" then
            for _, entry in ipairs(ns.db.advertChannels) do
                if not entry.template or entry.template == "" or LEGACY_TEMPLATES[entry.template] then
                    entry.template = ns.GetDefaultChannelTemplate(entry.name)
                end
            end
        end

    elseif event == "PLAYER_LOGIN" then
        local _, classFile = UnitClass("player")
        ns.state.isMage = (classFile == "MAGE")
        ns.state.faction = UnitFactionGroup("player")
        ns.state.isResting = IsResting() and true or false

        ns.SyncKnownPortals(false)

        if ns.InitComms then ns.InitComms() end
        if ns.InitSecureHUD then ns.InitSecureHUD() end
        if ns.InitUI then ns.InitUI() end

        ns.Print("v" .. ns.version .. " loaded. Type |cff00ccff/taxi|r or |cff00ccff/ft|r to open.")

    elseif event == "SPELLS_CHANGED" then
        if ns.state.isMage then
            ns.SyncKnownPortals(false)
            if ns.UpdateUI then ns.UpdateUI() end
        end

    elseif event == "CHANNEL_UI_UPDATE" then
        if ns.UpdateUI then ns.UpdateUI() end

    elseif event == "PLAYER_UPDATE_RESTING" then
        local nowResting = IsResting() and true or false
        if nowResting ~= ns.state.isResting then
            ns.state.isResting = nowResting

            if ns.state.activeJob then
                if not nowResting then
                    ns.Print("|cffff5555ALERT:|r You left the inn! Re-enter an inn before using Scroll of Liminal Passage.")
                else
                    ns.Print("|cff55ff55You are back inside an inn.|r")
                end
                if ns.UpdateSecureHUD then ns.UpdateSecureHUD() end
            end

            if ns.state.myRequest and ns.state.myRequest.claimedBy then
                ns.SendRestStatus(ns.state.myRequest.claimedBy, nowResting)
                if not nowResting then
                    ns.Print("|cffff5555ALERT:|r You left the inn! Your Mage cannot port to you unless you are rested.")
                end
            end

            if ns.UpdateUI then ns.UpdateUI() end
        end

    elseif event == "PARTY_INVITE_REQUEST" then
        local inviter = ns.NormalizeName(arg1)
        if ns.db.autoAcceptInvite and ns.state.myRequest and ns.state.myRequest.claimedBy then
            if inviter == ns.state.myRequest.claimedBy then
                ns.Print("Auto-accepting party invite from your Taxi Mage: |cffffffff" .. inviter .. "|r")
                AcceptGroup()
                StaticPopup_Hide("PARTY_INVITE")
            end
        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        if ns.UpdateSecureHUD then ns.UpdateSecureHUD() end
    end
end)

-- Slash Commands (/taxi and /ft)
SLASH_FOREVERTAXI1 = "/taxi"
SLASH_FOREVERTAXI2 = "/ft"
SlashCmdList["FOREVERTAXI"] = function(msg)
    local cmd = string.lower(strtrim(msg or ""))

    if cmd == "" or cmd == "ui" or cmd == "show" then
        ns.EnsureChannelJoined()
        if ns.ToggleMainWindow then
            ns.ToggleMainWindow()
        end

    elseif cmd == "active" or cmd == "on" then
        ns.SetMageActive(true)

    elseif cmd == "off" or cmd == "offline" then
        ns.SetMageActive(false)

    elseif cmd == "toggle" then
        ns.SetMageActive(not ns.state.mageActive)

    elseif cmd == "join" then
        ns.EnsureChannelJoined(true)

    elseif cmd == "test" then
        if ns.InjectTestRequest then
            ns.InjectTestRequest()
        end

    elseif cmd == "status" then
        local restStr = ns.state.isResting and "|cff55ff55Inside Inn|r" or "|cffff5555Outside Inn|r"
        local modeStr = ns.state.mageActive and "|cff55ff55Active Mage|r" or "|cffaaaaaaStandby|r"
        ns.Print("Status: " .. modeStr .. " | Rested: " .. restStr .. " | Faction: " .. (ns.state.faction or "Unknown"))
        if ns.state.isMage then
            local s, r = ns.GetMageReagentCounts()
            ns.Print("Reagents: " .. s .. "x Scroll of Liminal Passage, " .. r .. "x Rune of Portals")
        end

    else
        ns.Print("Commands: |cff00ccff/taxi|r (Toggle UI), |cff00ccff/taxi active|r, |cff00ccff/taxi off|r, |cff00ccff/taxi join|r, |cff00ccff/taxi test|r, |cff00ccff/taxi status|r")
    end
end