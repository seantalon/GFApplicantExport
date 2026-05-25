# GF Applicant Export

A minimal World of Warcraft addon that exports pending Premade Group Finder
applicants — plus a snapshot of your current group — as JSON, ready to paste
into an external screening tool that runs raider.io and Warcraft Logs checks
against their characters.

**Tested against:** WoW Midnight 12.0.5 (Interface 120005)

## Install

Drop the `GFApplicantExport` folder into:

```
World of Warcraft\_retail_\Interface\AddOns\
```

Final path should look like:

```
...\Interface\AddOns\GFApplicantExport\GFApplicantExport.toc
...\Interface\AddOns\GFApplicantExport\GFApplicantExport.lua
```

Reload your UI (`/reload`) or restart the client. You should see:

```
[GF Applicant Export] v0.1.2 loaded. Type /gfae to open.
```

## Usage

1. Be in (or host) a group with an active Premade Group Finder listing. Any
   group member can read the applicant list — you don't have to be the leader
   or the one who advertised.
2. Type `/gfae` (or `/applicantexport`) to open the export window. The JSON
   payload is built immediately, written to the EditBox, and auto-selected.
3. Press **Ctrl+C** to copy. If you lose the selection (clicked elsewhere),
   the **Select All** button re-highlights everything.
4. Alt-Tab to your screening tool, paste, run the checks.

While the window is open, it auto-refreshes on:

- `LFG_LIST_APPLICANT_LIST_UPDATED` — someone applied, withdrew, or you
  declined them.
- `GROUP_ROSTER_UPDATE` — someone joined or left your party/raid, so the
  `group_members` snapshot stays current.

## Output schema

```json
{
  "schema_version": 1,
  "exported_at": 1746950400,
  "region": "US",
  "interface_version": 120005,
  "group_members": [
    { "name": "Avaren",  "realm": "Stormrage",   "class": "MAGE",   "role": "DAMAGER", "spec_id": 64 },
    { "name": "Burno",   "realm": "Tichondrius", "class": "MONK",   "role": "TANK",    "spec_id": 0  },
    { "name": "Zoranna", "realm": "Khaz'goroth", "class": "SHAMAN", "role": "HEALER",  "spec_id": 0  }
  ],
  "applicants": [
    {
      "app_id": 42,
      "display_order": 1,
      "member_index": 1,
      "is_premade": false,
      "premade_size": 1,
      "is_new": true,
      "comment": "[K:l25]",
      "name": "Healbot",
      "realm": "Area 52",
      "full_name": "Healbot-Area 52",
      "class": "SHAMAN",
      "class_localized": "Shaman",
      "level": 90,
      "ilvl": 681,
      "pvp_ilvl": 0,
      "honor_level": 50,
      "dungeon_score": 952,
      "assigned_role": "HEALER",
      "offered_tank": false,
      "offered_healer": true,
      "offered_damage": false,
      "is_friend": false
    }
  ]
}
```

### Notes for the consumer

- `realm` is raw (e.g. `"Area 52"`, `"Wyrmrest Accord"`). Slugify on the
  Python side: lowercase, strip apostrophes, replace spaces with `-`.
- `class` is the non-localized, uppercase, stable form (`"MAGE"`,
  `"DEATHKNIGHT"`). Use it as a key for class lookups; use
  `class_localized` for display.
- Applicant spec is **not** exported. The LFG API's `specID` return is
  unreliable for premade applicants (returns garbage like `0`, `19990`, or
  random ints when `numMembers > 1`). Resolve current spec via raider.io's
  `mythic_plus_scores_by_season:current` field instead.
- Group-member `spec_id` is the numeric Blizzard spec ID (e.g. 64 = Frost
  Mage, 252 = Unholy DK). `0` means the client hasn't cached that member's
  spec yet — common right after joining. Map the ID → spec name with a
  static table on the consumer side.
- Premade applicants come through with a shared `app_id` and incrementing
  `member_index` (1..N). Group them on `app_id` to show "applied together."
- `dungeon_score` is the current-season M+ rating, same number raider.io
  shows as the headline score. Use it as-is to skip an extra raider.io call
  when you only need the number.

### About the `comment` field

WoW's client tokenizes most applicant comments before exposing them to
addons. Instead of plaintext, the API returns an opaque ID like `|Kl25|k`
that the WoW *renderer* resolves to text at display time — but addons never
see the resolved string. There's no Lua-accessible way to decode it.

This addon rewrites those tokens as `[K:<id>]` (e.g. `[K:l25]`) so the
EditBox doesn't choke on the raw `|K` escape. The bracketed form preserves
two useful properties:

- **Same comment text → same token ID** within a single login session, even
  across different applicants and across `/reload`. So a consumer can
  cluster applicants by `comment` to find groups of identical messages.
- A small number of unique tokens usually accounts for most applicants
  (default phrases get reused heavily), so clustering is meaningful.

Non-tokenized comments (rare; the consumer may see plaintext occasionally)
pass through unchanged. An empty string means the applicant submitted no
comment at all.

## SavedVariables

The addon registers a `GFAEDB` SavedVariables table. Currently only one
field is written: `last_export = { at = <unix ts>, count = <int> }`. Useful
for debugging; no PII is persisted.

## Credits

Co-developed with [Claude](https://claude.com/claude-code) (Anthropic).
