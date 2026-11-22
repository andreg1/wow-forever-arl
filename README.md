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
| Quality of Life | LFG Role Filter: filters the Group Browser by role, class and level 60, with Whisper / Invite and optional auto-invite | `/arl lfg` | Nothing |
| Quality of Life | Leveling BiS Spec: sets Forever Leveling BiS's Talent spec to the spec you play, and follows dual spec switches | `/arl spec` | Forever Leveling BiS |
| Quality of Life | Auto Uprank: swaps lower spell ranks on your action bars for a new rank when you (or your pet) learn it | `/arl uprank` | Nothing |
| Quality of Life | Quick Loot: loots everything at once (Shift opens the window normally); leaves rolls, bind-on-pickup confirms and items that don't fit | `/arl loot` | Nothing |
| Quality of Life | Loot Sparkles: keeps the sparkle on lootable quest items, even after a graphics preset turns it off | `/arl sparkle` | Nothing |
| Quality of Life | Buff Back: one key buffs back whoever buffed you, whoever asks in chat, and your group, and reminds you when your own buffs run out; you choose which buffs each class gets | `/arl buff` | Nothing |
| Quality of Life | Layer Bridge: AutoLayer and LayerSwap users change layer with each other; a LayerSwap button asks LayerSwap hosts out of sight, an AutoLayer button says "inv layer" in the layer channel, and with hosting on you invite both addons' users; remembers the layers you've been on (6 h) so a hop always goes somewhere new, and its History list takes you back to one | `/arl layer` | Nothing (works alongside AutoLayer / LayerSwap) |
| Quality of Life | Share Location: guildmates who use OpenMap see you live as a dot where you stand on their map (guild only, never from dungeons, raids or battlegrounds); on unless you turn it off | `/arl share` | Nothing (you don't need OpenMap yourself) |
| Quality of Life | PallyPower Auto-Hide: hides PallyPower's buttons while nobody needs a blessing and none ends within 5 minutes (you choose the minutes); they come back by themselves, out of combat | `/arl pally` | PallyPower |
| Quality of Life | Soulstone Reminder: for warlocks in dungeons and raids, a card always on screen showing whether your soulstone is up; when it isn't, one click or key puts it on the healer (or your target), or makes one first | `/arl soulstone` | Nothing |
| Questie | New in Forever: star on quests that are new in WoW Forever | `/arl new` | Questie |
| Questie | Sub-Quest Filter: hides sub-quests until you can pick them up | `/arl subq` | Questie |
| Questie | Rare Objectives: alerts and a scan key for rare quest mobs you still need | `/arl rare` | QuestieDB |
| Questie | Quest Search: search quests by text, by zone they lead into, by faction | `/arl qs` | QuestieDB |
| EllesmereUI | Quest Tracker: clickable quest item buttons, missing-item warnings, zone focus, and "only the quests for where I am", including quests from other zones whose objectives or turn-in are here | `/arl qt` | EllesmereUI Quest Tracker (QuestieDB for "objectives here") |
| EllesmereUI | Item Lock: Alt+Right-click locks a bag item so it can't be sold or destroyed | `/arl lock` | EllesmereUI Bags |
| Auctionator | Darkmoon Tickets: Darkmoon Faire turn-ins ranked by gold per Prize Ticket | `/arl dmf` | Auctionator |
| DungeonJournal | Dungeon Helper: two-pane dungeon window. Bosses & Loot (BiS and upgrades for you and your ARL partymates; members with Forever Leveling BiS share their numbers even with it turned off), Quests (prerequisites and follow-up chains, party progress), Clear Times (splits, records, guild leaderboard) | `/arl dh` (`/arl bis`, `/arl quests`, `/arl timers`) | DungeonJournal (Forever Leveling BiS and QuestieDB optional) |
| OpenMap | Sharer Markers: guildmates and friends who share where they are show as class-coloured diamonds with their names, so your party (round dots with a gold ring) stands apart | `/arl markers` | OpenMap |

Officers and the Guild Master also get **Officer Tools**: who in the guild runs the addon, and which version.

## Something went wrong?

When a feature hits an error, ARL says so once in chat. A feature that keeps failing turns itself off, so it can't slow the game down.
- `/arl errors` lists what was caught on this character.
- `/arl report` opens a window with everything needed to fix it: versions, each feature's state, the errors and the trace. Click **Select all**, press Ctrl+C, and paste it to us.
- `/arl debug <feature>`: for "it didn't do what I expected" without an error. It shows what the feature decides, in chat and in the report. Run it again to turn it off.

## Coming from the standalone addons

Several features started as standalone addons (ForeverSleepingBag, FishingPoleAlert, SpecGearSwap, LFGRoleFilter, Questie_NewInForever, Questie_SubQuestFilter, Questie_RareObjectives, QuestieDB_Search, EllesmereUIQuestTracker_QuestItems, EllesmereUIBags_ItemLock, Auctionator_DarkmoonTickets, ForeverLevelingBiS_AutoSpec), and XP Food, Loot Sparkles and Buff Back take over from Forever SnackTrack, Forever Loot Sparkles and Manners. Buff Back uses Manners' spell data (MIT, © 2026 Sacha); see `ARLE_QoL/BuffBackData.lua`. While one of those is still turned on, its feature here stays paused, so the two don't run twice, and copies the old addon's saved data (locks, gear set links, macros, settings). Turn the old addon off in the AddOns list and `/reload` to switch over.

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
