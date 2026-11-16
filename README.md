# ARL Extensions

Associação Rei Leão's Extensions for WoW Forever: small extensions for the addons you already use, in one window (`/arl`) where each one can be turned on, off and configured. Only members of the guild **Associação Rei Leão** can use them.

## Install

Copy every folder of this repo (`ARLExtensions` and the `ARLE_*` packs) into `World of Warcraft\_forever_\Interface\AddOns\`, then restart the game. Type `/arl` to open the window, `/arl help` for commands.

`ARLExtensions` is the host. The `ARLE_*` packs load on demand, only when a feature in them is turned on.

## Features

| Pack | Feature | Command | Needs |
|---|---|---|---|
| Quality of Life | Sleeping Bag: reminder to use the Cozy Sleeping Bag for Well-Rested, with a stack timeline while you lie in it | `/arl bag` | Nothing |
| Quality of Life | XP Food: reminds you to eat your experience food when its buff is missing, weaker or ending, and when you run low; click the icon to eat | `/arl food` | Nothing |
| Quality of Life | Fishing Pole Alert: warns when you fight with a fishing pole, with a key to put your weapons back on | `/arl fish` | Nothing |
| Quality of Life | Spec Gear Swap: equips a spec's gear set on a spec switch, keeps the set saved, restores emptied action bars | `/arl gear` | Nothing |
| Quality of Life | LFG Role Filter: filters the Group Browser by role, with Whisper / Invite and optional auto-invite | `/arl lfg` | Nothing |
| Quality of Life | Leveling BiS Spec: sets Forever Leveling BiS's Talent spec to the spec you play, and follows dual spec switches | `/arl spec` | Forever Leveling BiS |
| Quality of Life | Auto Uprank: swaps lower spell ranks on your action bars for a new rank when you (or your pet) learn it | `/arl uprank` | Nothing |
| Quality of Life | Quick Loot: loots everything at once (Shift opens the window normally); leaves rolls, bind-on-pickup confirms and items that don't fit | `/arl loot` | Nothing |
| Quality of Life | Loot Sparkles: keeps the sparkle on lootable quest items, even after a graphics preset turns it off | `/arl sparkle` | Nothing |
| Questie | New in Forever: star on quests that are new in WoW Forever | `/arl new` | Questie |
| Questie | Sub-Quest Filter: hides sub-quests until you can pick them up | `/arl subq` | Questie |
| Questie | Rare Objectives: alerts and a scan key for rare quest mobs you still need | `/arl rare` | QuestieDB |
| Questie | Quest Search: search quests by text, by zone they lead into, by faction | `/arl qs` | QuestieDB |
| EllesmereUI | Quest Tracker: clickable quest item buttons and missing-item warnings in the quest tracker | `/arl qt` | EllesmereUI Quest Tracker |
| EllesmereUI | Item Lock: Alt+Right-click locks a bag item so it can't be sold or destroyed | `/arl lock` | EllesmereUI Bags |
| Auctionator | Darkmoon Tickets: Darkmoon Faire turn-ins ranked by gold per Prize Ticket | `/arl dmf` | Auctionator |
| DungeonJournal | Dungeon Helper: dungeon window with BiS Finder, Quests and Clear Times | `/arl dh` | DungeonJournal (Forever Leveling BiS optional) |

Officers and the Guild Master also get **Officer Tools**: who in the guild runs the addon, and which version.

## Something went wrong?

When a feature hits an error, ARL says so once in chat. A feature that keeps failing turns itself off, so it can't slow the game down.
- `/arl errors` lists what was caught on this character.
- `/arl report` opens a window with everything needed to fix it: versions, each feature's state, the errors and the trace. Click **Select all**, press Ctrl+C, and paste it to us.
- `/arl debug <feature>`: for "it didn't do what I expected" without an error. It shows what the feature decides, in chat and in the report. Run it again to turn it off.

## Coming from the standalone addons

Several features started as standalone addons (ForeverSleepingBag, FishingPoleAlert, SpecGearSwap, LFGRoleFilter, Questie_NewInForever, Questie_SubQuestFilter, Questie_RareObjectives, QuestieDB_Search, EllesmereUIQuestTracker_QuestItems, EllesmereUIBags_ItemLock, Auctionator_DarkmoonTickets, ForeverLevelingBiS_AutoSpec), and XP Food and Loot Sparkles take over from Forever SnackTrack and Forever Loot Sparkles. While one of those is still turned on, its feature here stays paused, so the two don't run twice, and copies the old addon's saved data (locks, gear set links, macros, settings). Turn the old addon off in the AddOns list and `/reload` to switch over.

## Development

From a clone:

- `make setup`: asks for your `...\_forever_\Interface\AddOns` folder (kept in `local.mk`, not committed).
- `make package`: builds `dist/ARLExtensions-<version>.zip` to share; it's extracted into the AddOns folder. The version comes from `## Version` in `ARLExtensions.toc`.
- `make publish-local`: copies the working tree into your AddOns folder, replacing only ARL's own folders. Then `/reload` in game (restart the client after a `.toc` change).
- `make`: package and publish-local, to rebuild while working on a change.
- `make patch` / `make minor` / `make major`: sets a new version in every `.toc`, then packages and publishes. Finish every change with one of these: patch for settings changes and fixes, minor for a new or overhauled feature, major for a rework of the extension manager or an explicitly bigger release.

Works on Linux (sh + bsdtar) and Windows 10+ (PowerShell + built-in tar; get make with `winget install ezwinports.make`).

## License

[MIT](LICENSE)
