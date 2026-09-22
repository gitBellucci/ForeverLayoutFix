# ForeverLayoutFix

Keeps addon and UI settings after `/reload` on **WoW Forever**, including when two-part character names stop SavedVariables from loading.

[CurseForge](https://www.curseforge.com/wow/addons/foreverlayoutfix) · Version **3.13** · Flavor **Forever** · Interface **16001** · License **MIT**

## Tutorial

https://github.com/user-attachments/assets/aaeddad0-9686-4cbe-9cd9-43af45a097b2


## Why this exists

WoW Forever often **writes** addon SavedVariables, then **fails to load** them on the next launch. Two-part character names (for example `Bellucci Walkers`) are the usual trigger: the game opens the wrong character folder, so Bartender, SexyMap, Platynator, Leatrix, bags, RXP, and the rest come back as defaults.

ForeverLayoutFix does two things:

1. **Snapshot** your UI into a named profile while you are in-game.
2. **Publish** that profile into the addon folder (the game cannot write AddOns itself) so **any character** can load it on the next login.

## Install

1. Copy the `!ForeverLayoutFix` folder into `World of Warcraft\_classic_beta_\Interface\AddOns\`.
2. Keep the folder name **`!ForeverLayoutFix`**. The `!` makes it load first. Do not rename it. Do not also install a second copy named `ForeverLayoutFix`.
3. `/reload` and enable the addon.

After the first Save + setup, a second addon appears: **`!FLF_Data`**. Keep **both** enabled.

## How to use (`/flf profiles`)

Type **`/flf profiles`** (or `/ff profiles`). That window is the whole workflow.

| Button | What it does |
|--------|----------------|
| **Save settings** | Snapshots your current UI into the named profile (create a name first if the list is empty). |
| **Enable** | Applies that profile on this character, then type `/reload`. Also restores Edit Mode, UI CVars, macros, and action bars. |
| **New / Rename** | Named layouts, not tied to a character, race, or class. Any alt can Enable the same profile. |

### First-time setup (main character)

1. Log into the character whose UI you want to keep.
2. Set up bars, minimap, quest guide, bags, and the rest.
3. `/flf profiles` → type a name → **Save settings**.
4. **Fully close WoW** (not just `/reload`).
5. Run `!ForeverLayoutFix\Setup\FLF_Setup.cmd`.
6. Log into **any** character → `/flf profiles` → select the profile → **Enable** → type `/reload`.

### After you change the layout

1. **Save settings** in `/flf profiles`.
2. Close WoW.
3. Run `FLF_Setup.cmd` again **before** switching characters.

If you skip the `.cmd`, the new Save stays in WTF and alts will not see it.

## What `FLF_Setup.cmd` does

WoW is not allowed to write into `Interface\AddOns`. Profiles that should survive a full game restart have to be copied there from Windows.

With WoW **closed**, the `.cmd` runs `FLF_Setup.ps1` and:

1. Finds your `WTF\Account\<id>\SavedVariables` folder.
2. Installs the companion addon **`!FLF_Data`**.
3. Creates a junction `!FLF_Data\Disk` → that SavedVariables folder (so the companion can read what the game wrote).
4. Reads `!FLF_Data.lua` (the in-game profile dump) and writes `!FLF_Data\PublishedProfiles.lua`.

On the next login, `!FLF_Data` loads **before** other addons and merges those published profiles into `ForeverLayoutFixProfilesDB`. That is why an alt can see a layout you saved on your main.

You only need Administrator permission if Windows blocks writing into Program Files.

## What a profile actually copies

**Addons** (examples): Bartender, SexyMap, Platynator, Leatrix Plus / Maps, Baganator / Syndicator, RXP (guide, step, window size/position, theme, level-splits and other AceDB settings), MinimapButtonButton (including collector position), WIM, MSUF, Ellesmere, and other SavedVariables the snapshot can see. If Leatrix **Faster movie skip** is on, a new character’s opening cinematic is cancelled as soon as the profile loads.

**Blizzard UI:** Edit Mode layout, a whitelist of UI CVars, key bindings, account + character macros, action bars 1–120.

**Not copied (on purpose):**

- **Questie** quest database / compiled streams (copying them crashes Questie).
- RXP tracking dumps that are not the guide itself.

Leatrix Plus live settings sit in memory until logout. After you change Leatrix, **logout** (or Save, then close WoW) so they land in the profile.

After **Enable**, type `/reload`. That applies Platynator, RXP size, and other addon tables that cannot be swapped mid-session.

Action bars need a hardware click: click **Enable** out of combat.

## Commands

| Command | Purpose |
|---------|---------|
| `/flf profiles` | Profile window (Save / Enable / rename) |
| `/flf save` | Snapshot addon tables without opening the window |
| `/flf list` | Names of mirrored SavedVariables tables |
| `/flf debug` | Support dump (Select All → Ctrl+C) |
| `/flf verbose` | Toggle inject/snapshot log spam |
| `/flf export` | Manual WTF copy if the disk bridge is off |
| `/flf help` | Command list |
| `/ff` | Same as `/flf` |

If something specific does not restore, run `/flf debug`, copy the report, and send it with a bug report.

## Notes

- Some addons only write their locals on logout. A `/reload` after `/flf save` is the real test.
- Keep **both** `!ForeverLayoutFix` and `!FLF_Data` enabled after setup.
- If a CurseForge update breaks the TOC, delete the addon folder and install it again.
- Variable names are read from each addon's TOC, plus known extras (Leatrix, RXP, SexyMap, WIM, MSUF, EllesmereUI, and similar).
