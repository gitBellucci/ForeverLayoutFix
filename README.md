# Squid

Named layout profiles for **WoW Forever**: addon options, macros, keybinds, action bars, CVars, and Edit Mode. Save a layout on one character, Enable it on a new character or to switch layouts on the same one.

Formerly ForeverLayoutFix.

[CurseForge](https://www.curseforge.com/wow/addons/foreverlayoutfix) · Version **4.1** · Flavor **Forever** · Interface **16001** · License **MIT**

## Why this exists

Addon SavedVariables now persist on their own. Squid is not a disk/CMD workaround for a load bug.

It is a **layout profile manager**:

1. **Save** the UI you already have (addons, bars, binds, macros).
2. **Enable** that named profile on another character, or to switch layouts on the same character.

Login no longer rewrites other addons’ SavedVariables. Nothing is applied until you click **Enable**.

## Install

1. Copy the `!ForeverLayoutFix` folder into `World of Warcraft\_classic_beta_\Interface\AddOns\`.
2. Keep the folder name **`!ForeverLayoutFix`**. That keeps existing profiles loading. The addon list shows **Squid**.
3. `/reload` and enable the addon.

You do **not** need `!FLF_Data`, `FLF_Setup.cmd`, or any publish step. If those are still installed from an older version, delete them.

## How to use (`/squid`)

Type **`/squid`** (or `/flf` / `/ff`). That window is the whole workflow.

| Button | What it does |
|--------|----------------|
| **Save settings** | Snapshots your current UI into the named profile (create a name first if the list is empty). |
| **Enable** | Applies that profile on this character, then type `/reload`. Also restores Edit Mode, UI CVars, macros, and action bars. |
| **New / Rename** | Named layouts, not tied to a character, race, or class. Any alt can Enable the same profile. |

### First-time setup (main character)

1. Log into the character whose UI you want to keep.
2. Set up bars, minimap, quest guide, bags, loot, and the rest.
3. `/squid` → type a name → **Save settings**.

### New character or another alt

1. Log in.
2. `/squid` → select the profile → **Enable** → type `/reload`.

### Switch layouts on the same character

Save each layout under its own name. Enable whichever one you want, then `/reload`.

## What a profile actually copies

**Addons** (examples): Bartender, SexyMap (including skin / shape / borders), XLoot (including Frame / Monitor / Group namespaces), Platynator, Leatrix Plus / Maps, Baganator / Syndicator, DamageForever / Details (window settings and positions, not combat logs), RXP (guide, step, window size/position, theme, level-splits and other AceDB settings), MinimapButtonButton (including collector position), WIM, MSUF, Ellesmere, and other SavedVariables the snapshot can see. If Leatrix **Faster movie skip** is on, a new character’s opening cinematic is cancelled as soon as the profile loads.

**Blizzard UI:** Edit Mode layout, a whitelist of UI CVars, key bindings, account + character macros, action bars 1–120.

**Not copied (on purpose):**

- **Questie** quest database / compiled streams (copying them crashes Questie).
- RXP tracking dumps that are not the guide itself.
- Details combat history.

Leatrix Plus live settings sit in memory until logout. After you change Leatrix, **logout** (or Save, then close WoW) so they land in the profile.

After **Enable**, type `/reload`. That applies Platynator, RXP size, SexyMap, XLoot, and other addon tables that cannot be swapped mid-session.

Action bars need a hardware click: click **Enable** out of combat.

## Commands

| Command | Purpose |
|---------|---------|
| `/squid` | Profile window (Save / Enable / rename) |
| `/squid save` | Overwrite the last layout used on this character |
| `/squid list` | Names of snapshot SavedVariables tables |
| `/squid debug` | Support dump (Select All → Ctrl+C) |
| `/squid verbose` | Toggle inject/snapshot log spam |
| `/squid help` | Command list |
| `/flf` / `/ff` | Same as `/squid` |

If something specific does not restore, run `/squid debug`, copy the report, and send it with a bug report.

## Notes

- Some addons only write their locals on logout. A `/reload` after `/squid save` is the real test.
- If a CurseForge update breaks the TOC, delete the addon folder and install it again.
- Variable names are read from each addon’s TOC, plus known extras (Leatrix, RXP, SexyMap, XLoot, DamageForever, WIM, MSUF, EllesmereUI, and similar).

## Changelog

### 4.1

- Renamed to **Squid**. `/squid` opens layouts; `/flf` and `/ff` still work.
- Save and Enable now keep **SexyMap** skin, shape, and borders.
- Save and Enable now keep **XLoot** settings (including AceDB namespaces: Frame, Monitor, Group, and the rest).

### 4.0

- Blizzard now loads SavedVariables. This addon no longer rewrites other addons at login and no longer needs `FLF_Setup.cmd` / `!FLF_Data`.
- Profiles still live in `/squid`: Save on one character, Enable on any other (or switch layouts on the same character).
