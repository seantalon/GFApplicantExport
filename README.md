# GF Applicant Export

A minimal World of Warcraft addon that exports pending Premade Group Finder
applicants as JSON, ready to paste into an external screening tool that runs
raider.io and Warcraft Logs checks against their characters.

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
[GF Applicant Export] v0.1.0 loaded. Type /gfae to open.
```

## Usage

1. Create a listing in the Premade Group Finder (you must be hosting; the API
   only exposes applicants for groups you advertise).
2. Wait for applications to come in.
3. Type `/gfae` (or `/applicantexport`) to open the export window.
4. Click **Export**. The JSON payload is written to the EditBox and the text
   is auto-selected.
5. Press **Ctrl+C** to copy.
6. Alt-Tab to your screening tool, paste, run the checks.

While the export window is open, it auto-refreshes whenever the applicant
list changes (`LFG_LIST_APPLICANT_LIST_UPDATED`), so you can keep it floating
on a second monitor.

## Output schema

```json
{
  "schema_version": 1,
  "exported_at": 1746950400,
  "region": "US",
  "interface_version": 120005,
  "listing": {
    "name": "+12 weekly chest 950io+",
    "activity_id": 1234,
    "comment": "exp only, link rio"
  },
  "applicants": [
    {
      "app_id": 42,
      "display_order": 1,
      "member_index": 1,
      "is_premade": false,
      "premade_size": 1,
      "is_new": true,
      "comment": "exp resto sham, 950io",
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
- Spec is **not** exported. The LFG API's `specID` return is unreliable for
  premade applicants (returns garbage values like `0`, `19990`, or random
  ints when `numMembers > 1`). Resolve current spec via raider.io's
  `mythic_plus_scores_by_season:current` field instead.
- Premades come through with a shared `app_id` and incrementing
  `member_index` (1..N). Group them on `app_id` to show "applied together."
- `dungeon_score` is the current-season M+ rating, same number raider.io
  shows as the headline score. You can use it as-is to skip an extra
  raider.io call when you only need the number.

## SavedVariables

The addon ships with a `GFAEDB` SavedVariables table. v0.1.0 only writes
`last_export` (metadata only, no PII), but the schema is in place for future
features: per-applicant notes, blocklist, export history, etc.
