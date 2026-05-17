-- GFApplicantExport.lua
-- Export pending PGF applicants to JSON for external screening.
--
-- API references verified for Midnight 12.0.5 (Interface 120005):
--   C_LFGList.GetApplicants() -> { applicantID, ... }
--   C_LFGList.GetApplicantInfo(applicantID) -> LfgApplicantData table:
--     { applicantID, applicationStatus, pendingApplicationStatus,
--       numMembers, isNew, comment, displayOrderID }
--   C_LFGList.GetApplicantMemberInfo(applicantID, memberIndex) -> 13 returns:
--     name, class, localizedClass, level, itemLevel, honorLevel,
--     tank, healer, damage, assignedRole, relationship,
--     dungeonScore, pvpItemLevel
--
-- NOTE: specID is NOT a reliable return from GetApplicantMemberInfo in 12.0.
-- Spec/class details are resolved downstream via raider.io.
--
-- Output schema (v1):
-- {
--   "schema_version": 1,
--   "exported_at": <unix timestamp>,
--   "region": "US" | "EU" | "KR" | "TW" | "CN",
--   "interface_version": 120005,
--   "group_members": [
--     { "name": "Avaren", "class": "MAGE",
--       "role": "TANK" | "HEALER" | "DAMAGER" | "NONE",
--       "spec_id": <int> },         -- 0 when client has no cached spec
--     ...
--   ],
--   "applicants": [
--     {
--       "app_id": <int>,                -- shared across members of a premade
--       "display_order": <int>,         -- preserves PGF sort order
--       "member_index": <int>,          -- 1-based position within the application
--       "is_premade": <bool>,
--       "premade_size": <int>,
--       "is_new": <bool>,
--       "comment": "...",            -- KString tokens shown as [K:<id>]
--       "name": "Charname",
--       "realm": "Realm Name",          -- raw, slugify Python-side
--       "full_name": "Charname-Realm Name",
--       "class": "MAGE",                -- non-localized
--       "class_localized": "Mage",
--       "level": <int>,
--       "ilvl": <int>,                  -- floored equipped ilvl
--       "pvp_ilvl": <int>,
--       "honor_level": <int>,
--       "dungeon_score": <int>,         -- current season M+ rating
--       "assigned_role": "TANK" | "HEALER" | "DAMAGER" | "NOROLE",
--       "offered_tank": <bool>,
--       "offered_healer": <bool>,
--       "offered_damage": <bool>,
--       "is_friend": <bool>             -- relationship was non-nil
--     },
--     ...
--   ]
-- }

local ADDON_NAME = "GFApplicantExport"

GFAEDB = GFAEDB or {}

----------------------------------------------------------------------
-- Minimal JSON encoder
----------------------------------------------------------------------
-- Rewrite WoW KString tokens (|K...|k) as bracketed [K:<id>] markers.
-- Two reasons: (1) the EditBox silently rejects any SetText containing a raw
-- |K, so the JSON must not contain one; (2) the token ID is stable for
-- identical comment text within a login session, which lets the downstream
-- screening tool cluster applicants by comment without the plaintext.
local function markKStrings(s)
    s = s:gsub("|K(.-)|k(.-)|k", "[K:%1/%2]")  -- long:   |Kflag|kid|k
    s = s:gsub("|K(.-)|k",       "[K:%1]")     -- medium: |Kid|k
    s = s:gsub("|K([%w]-)k",     "[K:%1]")     -- short:  |Kidk
    return s
end

-- Strip WoW UI escape sequences. These start with '|' and confuse the
-- client's own EditBox (a raw |K KString token causes SetText to silently
-- reject the whole string). Order matters: hyperlinks before the catch-all.
local function stripWowEscapes(s)
    s = s:gsub("|c%x%x%x%x%x%x%x%x", "")   -- color start
    s = s:gsub("|r", "")                    -- color reset
    s = s:gsub("|T.-|t", "")                -- inline texture
    s = s:gsub("|A.-|a", "")                -- atlas icon
    s = s:gsub("|K.-|k.-|k", "")            -- KString (long):   |Kf<flag>|k<id>|k
    s = s:gsub("|K.-|k", "")                -- KString (medium): |K<token>|k
    s = s:gsub("|K[%w]-k", "")              -- KString (short):  |K<token>k
    s = s:gsub("|H.-|h(.-)|h", "%1")        -- hyperlink: keep display text
    s = s:gsub("||", "\1"):gsub("|", ""):gsub("\1", "|")  -- collapse escaped pipes
    return s
end

local function encodeString(s)
    s = tostring(s)
    s = stripWowEscapes(s)
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    s = s:gsub('[%z\1-\31]', '')  -- strip remaining control chars
    return '"' .. s .. '"'
end

local function encode(v)
    local t = type(v)
    if t == "string" then
        return encodeString(v)
    elseif t == "number" then
        if v ~= v then return "null" end                       -- NaN
        if v == math.huge or v == -math.huge then return "null" end
        if v == math.floor(v) and math.abs(v) < 1e15 then
            return tostring(math.floor(v))
        end
        return tostring(v)
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "nil" then
        return "null"
    elseif t == "table" then
        if next(v) == nil then return "[]" end
        if v[1] ~= nil then
            local parts = {}
            for i, item in ipairs(v) do parts[i] = encode(item) end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, item in pairs(v) do
                parts[#parts + 1] = encodeString(tostring(k)) .. ":" .. encode(item)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

----------------------------------------------------------------------
-- Region detection
----------------------------------------------------------------------
local REGION_MAP = { [1] = "US", [2] = "KR", [3] = "EU", [4] = "TW", [5] = "CN" }
local function GetRegionString()
    local id = GetCurrentRegion and GetCurrentRegion() or 1
    return REGION_MAP[id] or "US"
end

----------------------------------------------------------------------
-- Interface version
----------------------------------------------------------------------
local function GetInterfaceVersion()
    -- GetBuildInfo returns: version, build, date, tocversion
    local _, _, _, tocVersion = GetBuildInfo()
    return tocVersion or 120005
end

----------------------------------------------------------------------
-- Name splitter
----------------------------------------------------------------------
-- LFG API always returns "Name-Realm Name" even for same-realm applicants.
-- Realm names contain spaces but never hyphens, so split on the FIRST '-'.
local function SplitNameRealm(fullName)
    if not fullName then return "Unknown", "Unknown" end
    local dash = fullName:find("-", 1, true)
    if not dash then return fullName, "Unknown" end
    return fullName:sub(1, dash - 1), fullName:sub(dash + 1)
end

----------------------------------------------------------------------
-- Current group (party or raid) snapshot
----------------------------------------------------------------------
-- Returns 0 when the client hasn't cached the unit's spec yet. We don't
-- fire NotifyInspect: too async for a synchronous export click.
local function GetUnitSpecID(unit)
    if UnitIsUnit(unit, "player") then
        local idx = GetSpecialization()
        if idx then
            local id = GetSpecializationInfo(idx)
            return id or 0
        end
        return 0
    end
    return GetInspectSpecialization(unit) or 0
end

local function CollectGroupMember(unit, members)
    local _, classToken = UnitClass(unit)
    if not classToken then return end  -- unit doesn't exist / out of range
    table.insert(members, {
        name    = UnitName(unit) or "",
        class   = classToken,
        role    = UnitGroupRolesAssigned(unit) or "NONE",
        spec_id = GetUnitSpecID(unit),
    })
end

local function GetGroupMembers()
    local members = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            CollectGroupMember("raid" .. i, members)
        end
    elseif IsInGroup() then
        CollectGroupMember("player", members)
        for i = 1, GetNumGroupMembers() - 1 do
            CollectGroupMember("party" .. i, members)
        end
    else
        CollectGroupMember("player", members)  -- solo: still show yourself
    end
    return members
end

----------------------------------------------------------------------
-- Build the export payload
----------------------------------------------------------------------
local function BuildPayload()
    local payload = {
        schema_version    = 1,
        exported_at       = time(),
        region            = GetRegionString(),
        interface_version = GetInterfaceVersion(),
        group_members     = GetGroupMembers(),
        applicants        = {},
    }

    local appIDs = C_LFGList.GetApplicants() or {}
    for _, appID in ipairs(appIDs) do
        local appInfo = C_LFGList.GetApplicantInfo(appID)
        if appInfo and appInfo.applicationStatus == "applied" then
            local numMembers   = appInfo.numMembers or 1
            local isPremade    = numMembers > 1
            local isNew        = appInfo.isNew and true or false
            local comment      = markKStrings(appInfo.comment or "")
            local displayOrder = appInfo.displayOrderID or 0

            for memberIdx = 1, numMembers do
                local name, class, localizedClass, level, itemLevel,
                      honorLevel, tank, healer, damage, assignedRole,
                      relationship, dungeonScore, pvpItemLevel
                    = C_LFGList.GetApplicantMemberInfo(appID, memberIdx)

                if name then
                    local charName, realm = SplitNameRealm(name)
                    table.insert(payload.applicants, {
                        app_id          = appID,
                        display_order   = displayOrder,
                        member_index    = memberIdx,
                        is_premade      = isPremade,
                        premade_size    = numMembers,
                        is_new          = isNew,
                        comment         = comment,
                        name            = charName,
                        realm           = realm,
                        full_name       = name,
                        class           = class or "",
                        class_localized = localizedClass or "",
                        level           = level or 0,
                        ilvl            = math.floor(itemLevel or 0),
                        pvp_ilvl        = math.floor(pvpItemLevel or 0),
                        honor_level     = honorLevel or 0,
                        dungeon_score   = math.floor(dungeonScore or 0),
                        assigned_role   = assignedRole or "NOROLE",
                        offered_tank    = tank and true or false,
                        offered_healer  = healer and true or false,
                        offered_damage  = damage and true or false,
                        is_friend       = relationship ~= nil,
                    })
                end
            end
        end
    end

    return payload
end

----------------------------------------------------------------------
-- Frame
----------------------------------------------------------------------
local frame
local function CreateExportFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "GFAEFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(560, 380)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:Hide()

    frame.TitleText:SetText("GF Applicant Export")

    -- Status line
    frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.status:SetPoint("TOPLEFT", 14, -32)
    frame.status:SetWidth(530)
    frame.status:SetJustifyH("LEFT")
    frame.status:SetText("")

    local scroll = CreateFrame("ScrollFrame", "GFAEScroll", frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -54)
    scroll:SetPoint("BOTTOMRIGHT", -32, 50)

    local edit = CreateFrame("EditBox", "GFAEEdit", scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(ChatFontNormal)
    edit:SetMaxBytes(1024 * 1024)
    edit:SetMaxLetters(1024 * 1024)
    edit:SetSize(scroll:GetWidth(), scroll:GetHeight())
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnKeyDown", function(self, key)
        if IsControlKeyDown() and key == "A" then self:HighlightText() end
    end)
    scroll:SetScrollChild(edit)
    frame.edit = edit

    local selectAll = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    selectAll:SetSize(120, 22)
    selectAll:SetPoint("BOTTOMLEFT", 14, 14)
    selectAll:SetText("Select All")
    selectAll:SetScript("OnClick", function()
        frame.edit:SetFocus()
        frame.edit:HighlightText()
    end)

    -- Copy hint
    frame.copyHint = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.copyHint:SetPoint("BOTTOMLEFT", selectAll, "TOPLEFT", 0, 4)
    frame.copyHint:SetText("Press Ctrl+C to copy, then paste into the screening tool.")

    -- Applicant count badge on the right
    frame.count = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    frame.count:SetPoint("BOTTOMRIGHT", -16, 16)
    frame.count:SetText("")

    -- Close button hook to clear focus
    frame.CloseButton:SetScript("OnClick", function()
        frame.edit:ClearFocus()
        frame:Hide()
    end)

    -- Refresh logic
    function frame:Refresh()
        local payload = BuildPayload()
        local n = #payload.applicants

        local json = encode(payload)
        self.edit:SetText(json)
        self.edit:HighlightText()
        self.edit:SetFocus()

        if n == 0 then
            self.status:SetText(
                "|cffffd200No pending applicants.|r Group snapshot exported.")
        else
            self.status:SetText(string.format(
                "|cff60ff60Exported %d pending applicant%s.|r",
                n, n == 1 and "" or "s"))
        end
        self.count:SetText(tostring(n))

        GFAEDB.last_export = { at = payload.exported_at, count = n }
    end

    return frame
end

----------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------
SLASH_GFAE1 = "/gfae"
SLASH_GFAE2 = "/applicantexport"
SlashCmdList["GFAE"] = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local f = CreateExportFrame()
    if msg == "hide" or msg == "close" then
        f:Hide()
    else
        f:Show()
        f:Refresh()
    end
end

----------------------------------------------------------------------
-- Event registration
----------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("LFG_LIST_APPLICANT_LIST_UPDATED")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == ADDON_NAME then
            -- In Midnight (12.0), GetAddOnMetadata moved to C_AddOns namespace.
            -- Keep a fallback to the legacy global for older clients.
            local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
            local v = getMeta and getMeta(ADDON_NAME, "Version") or "?"
            print(string.format(
                "|cff60ff60[GF Applicant Export]|r v%s loaded. Type /gfae to open.", v))
        end
    elseif event == "LFG_LIST_APPLICANT_LIST_UPDATED"
        or event == "GROUP_ROSTER_UPDATE" then
        if frame and frame:IsShown() then
            frame:Refresh()
        end
    end
end)
