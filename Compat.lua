local _, ns = ...

-- Compatibility polyfills for WoW 1.15.3+ / 16001 clients where legacy globals
-- were moved into C_* namespaces (e.g., C_Item, C_Spell, C_PartyInfo).
-- Only defines globals if they are missing, so existing shims remain untouched.

if C_Item then
    if not GetItemCount and C_Item.GetItemCount then
        GetItemCount = C_Item.GetItemCount
    end
    if not GetItemInfo and C_Item.GetItemInfo then
        GetItemInfo = C_Item.GetItemInfo
    end
    if not GetItemInfoInstant and C_Item.GetItemInfoInstant then
        GetItemInfoInstant = C_Item.GetItemInfoInstant
    end
    if not GetItemIcon and C_Item.GetItemIconByID then
        GetItemIcon = C_Item.GetItemIconByID
    end
end

if C_Spell then
    if not GetSpellInfo and C_Spell.GetSpellInfo then
        GetSpellInfo = function(spellIdentifier)
            local info = C_Spell.GetSpellInfo(spellIdentifier)
            if not info then return nil end
            return info.name, nil, info.iconID, info.castTime, info.minRange, info.maxRange, info.spellID, info.originalIconID
        end
    end
end

if C_PartyInfo then
    if not InviteUnit and C_PartyInfo.InviteUnit then
        InviteUnit = C_PartyInfo.InviteUnit
    end
end