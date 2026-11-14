local addonName, ns = ...

-- Initialize shared namespace
ns.name = addonName
ns.version = "1.0.1"
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
}

-- SavedVariables defaults
local defaults = {
    defaultTip = 2,
    autoAcceptInvite = true,
    filterChatSpam = true,
    soundAlert = true,
    minimapAngle = 220,
    hudPos = { point = "CENTER", relativePoint = "CENTER", x = 0, y = 180 },
    knownPortals = {},   -- Keyed by "PlayerName-Realm" -> { ["Orgrimmar"] = true, ... }
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
        local knowsSpell = (c.spellID and IsSpellKnown(c.spellID)) or (GetSpellInfo(c.spell) ~= nil)
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
        ns.Print("|cff55ff55Mage Taxi mode ENABLED.|r Listening for requests in channel and whispers (!taxi <city>).")
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

    elseif cmd == "status" then
        local restStr = ns.state.isResting and "|cff55ff55Inside Inn|r" or "|cffff5555Outside Inn|r"
        local modeStr = ns.state.mageActive and "|cff55ff55Active Mage|r" or "|cffaaaaaaStandby|r"
        ns.Print("Status: " .. modeStr .. " | Rested: " .. restStr .. " | Faction: " .. (ns.state.faction or "Unknown"))
        if ns.state.isMage then
            local s, r = ns.GetMageReagentCounts()
            ns.Print("Reagents: " .. s .. "x Scroll of Liminal Passage, " .. r .. "x Rune of Portals")
        end

    else
        ns.Print("Commands: |cff00ccff/taxi|r (Toggle UI), |cff00ccff/taxi active|r, |cff00ccff/taxi off|r, |cff00ccff/taxi join|r, |cff00ccff/taxi status|r")
    end
end