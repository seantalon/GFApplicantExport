# TODO

## Secret values — unadopted API restriction (not currently broken)

Midnight (12.0) introduced a "secret value" system that lets the client hand
addons opaque values they can't inspect or serialize. The guard globals are
`canaccessvalue()`, `issecretvalue()`, and `issecrettable()`.

This addon uses **none** of them. That was fine through 12.0.5, and a live
export on 12.1.0 (2026-08-15) returned a full applicant row — name (including
non-ASCII), class, localized class, level, and assigned role all intact. So
this is a latent risk, not a live bug: Blizzard has not (yet) flagged the
applicant fields we read.

Why it matters more here than for most addons: a tooltip addon that reads a
secret just renders a blank, but this addon *serializes*. The paths that would
break on a secret value are string operations:

- `markKStrings(appInfo.comment or "")` — `:gsub` on the comment
  (`GFApplicantExport.lua:239`)
- `SplitNameRealm(name)` — `:find`/`:sub` on the applicant name
  (`GFApplicantExport.lua:160-165`)
- `encodeString()` — `tostring()` then `:gsub` on any string field
  (`GFApplicantExport.lua:93`)
- `appInfo.applicationStatus == "applied"` — equality against a secret
  (`GFApplicantExport.lua:235`)

Prior art in addons already installed here, if this ever needs doing:

```lua
-- !WilduTools/modules/wowheadQuickLink.lua:27  (nil check LAST, deliberately)
local function isAccessible(value)
    return canaccessvalue(value) and not issecretvalue(value) and value ~= nil
end

-- RaiderIO/core.lua:860  — compat shim for clients predating the API
local issecretvalue = issecretvalue or function(value) return false end

-- RaiderIO/core.lua:4394 — guards this exact applicant path
if applicantInfo and not issecretvalue(applicantInfo.applicantID) then
```

If adopting: the cheapest single choke point is an accessibility check at the
top of `encode()`, since every field funnels through it. Guarding
`BuildPayload()` field-by-field is more precise but wordier. Worth pairing with
a `redacted` flag per applicant so the consumer can tell a genuine `""`/`0`
from a suppressed one — silent fallbacks would otherwise look like real data.

**Trigger to act:** exports come back with empty names/comments, or a Lua error
fires in `BuildPayload`. Until then, leave it.

## `factionGroup` — 14th return, currently unused

`C_LFGList.GetApplicantMemberInfo` returns a 14th value, `factionGroup`, after
`pvpItemLevel`. The header comment in `GFApplicantExport.lua:9` documents the
signature as 13 returns, and the destructure at `:243-246` stops at 13.

Confirmed against `RaiderIO/core.lua:8665`, which reads position 14:

```lua
local fullName, _, _, _, _, _, _, _, _, _, _, dungeonScore, _, factionGroup
    = C_LFGList.GetApplicantMemberInfo(applicantID, memberIdx)
```

Nothing breaks by ignoring it — trailing returns just get dropped. Adding it
would mean a new `faction` field and a `schema_version` bump to 2, which the
downstream Python screening tool would need to accept. Only worth doing if
faction is actually useful for screening.

## Watch: `display_order` may just mirror `app_id`

In the 12.1.0 export below, a lone applicant came back with `display_order: 64`
and `app_id: 64` — identical. The README documents `display_order` as
preserving PGF sort order, which for a single applicant should be `1`.

Unconfirmed either way: no other addon installed here reads
`appInfo.displayOrderID`, so there's no call site to compare against.

**How to settle it:** export with 3+ pending applicants and look at the values.
If they come out `1, 2, 3` the field works as documented. If they mirror
`app_id`, then sorting on `display_order` downstream is meaningless and the
consumer should fall back to `app_id` or arrival order. Harmless until then —
nothing reads the field except the screening tool's sort.

## Verification status

The 12.1.0 TOC bump (`120005` → `120100`) is **confirmed working in-game** as of
2026-08-15. A live `/gfae` export on client `12.1.0.69299` produced valid JSON
with a complete applicant row and `"interface_version": 120100`, which
`GetBuildInfo()` reads from the running client — independent confirmation the
bump was correct.

The `GetApplicantMemberInfo` return order was confirmed against three
independent call sites in RaiderIO and ArchonTooltip; `pvpItemLevel` at
position 13 matches `ArchonTooltip/Tooltip.lua:852`.

Note for future readers: `ilvl` and `pvp_ilvl` came back equal (both `276`) in
that export. Not a bug — `pvpItemLevel` matches equipped ilvl for a character
with no PvP gear, and the row was internally coherent (level 90 with
`dungeon_score: 0` and `honor_level: 0`, i.e. a fresh alt).
