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
| Quality of Life | LFG Role Filter: filters the Group Browser by role, class, level 60 or for a class run (every class once), with Whisper / Invite and optional auto-invite; messages every tank, healer or group it shows (one at a time, each sent with your Enter) and sorts their replies into positive, neutral and negative, with an optional goodbye to the negative ones | `/arl lfg`, `/arl lfg replies`, `/arl lfg stop` | Nothing |
| Quality of Life | Leveling BiS Spec: sets Forever Leveling BiS's Talent spec to the spec you play, and follows dual spec switches | `/arl spec` | Forever Leveling BiS |
| Quality of Life | Auto Uprank: swaps lower spell ranks on your action bars for a new rank when you (or your pet) learn it | `/arl uprank` | Nothing |
| Quality of Life | Quick Loot: loots everything at once (Shift opens the window normally); leaves rolls, bind-on-pickup confirms and items that don't fit | `/arl loot` | Nothing |
| Quality of Life | Loot Sparkles: keeps the sparkle on lootable quest items, even after a graphics preset turns it off | `/arl sparkle` | Nothing |
| Quality of Life | Buff Back: one key buffs back whoever buffed you, whoever asks in chat, and your group, and reminds you when your own buffs run out; you choose which buffs each class gets | `/arl buff` | Nothing |
| Quality of Life | Layer Bridge: one Swap button for every layer network on Forever (LayerSwap, AutoLayer, VoidNet, Forever Layer Hop), with or without their addons; accepts the right invite, declines same-layer ones, leaves after the move and learns the game's hourly limit; Host lets you move their users too; Networks, History (go back to a layer) and Options drawers | `/arl layer` | Nothing (pauses while Layer Anarchy is loaded) |
| Quality of Life | Share Location: guildmates who use OpenMap see you live as a dot where you stand on their map (guild only, never from dungeons, raids or battlegrounds); on unless you turn it off | `/arl share` | Nothing (you don't need OpenMap yourself) |
| Quality of Life | PallyPower Auto-Hide: hides PallyPower's buttons while nobody needs a blessing and none ends within 5 minutes (you choose the minutes); they come back by themselves, out of combat | `/arl pally` | PallyPower |
| Quality of Life | Soulstone Reminder: for warlocks in dungeons and raids, a card showing who wears your soulstone (hidden while it's on cooldown); when none is up, one click or key puts it on the healer (or your target), or makes one first | `/arl soulstone` | Nothing |
| Quality of Life | Auto Mail: pick one of your characters from a list, then click an item into the slot (or type rules like "* Cloth = Bank Alt"); at a mailbox the matching bag items are mailed to those characters at once (Shift skips), or with the card's Send button. Rules are shared by all your characters, and nothing is mailed to the character you're on. Soulbound and locked items stay | `/arl mail` | Nothing |
| Questie | New in Forever: star on quests that are new in WoW Forever | `/arl new` | Questie |
| Questie | Sub-Quest Filter: hides sub-quests until you can pick them up | `/arl subq` | Questie |
| Questie | Rare Objectives: alerts and a scan key for rare quest mobs you still need | `/arl rare` | QuestieDB |
| Questie | Quest Search: search quests by text, by zone they lead into, by faction | `/arl qs` | QuestieDB |
| EllesmereUI | Quest Tracker: clickable quest item buttons, missing-item warnings, zone focus, and "only the quests for where I am", including quests from other zones whose objectives or turn-in are here | `/arl qt` | EllesmereUI Quest Tracker (QuestieDB for "objectives here") |
| EllesmereUI | Item Lock: Alt+Right-click locks a bag item so it can't be sold or destroyed | `/arl lock` | EllesmereUI Bags |
| Auctionator | Darkmoon Tickets: Darkmoon Faire turn-ins ranked by gold per Prize Ticket | `/arl dmf` | Auctionator |
| DungeonJournal | Dungeon Helper: one compact window for the dungeon you're in (details open beside it; a full two-pane size too); a Home page to pick any dungeon or objective (raid attunements, Tier 0.5, class quests, battlegrounds) with your progress, and your dungeon quests in progress. Quests (DungeonJournal's plus QuestieDB's class quests and others, with the whole tree of quests that unlock them, lead-ins and follow-ups, party progress), Bosses & Loot (BiS and upgrades from Forever Leveling BiS, shared by ARL partymates even with it off, and GearQuest's picks for you), Clear Times (splits, records, guild leaderboard, a Report line for party or guild chat). Opens once per visit, stays closed when you close it, hides in combat; the cog opens its settings | `/arl dh` (`/arl bis`, `/arl quests`, `/arl timers`) | DungeonJournal (Forever Leveling BiS, GearQuest Forever and QuestieDB optional) |
| OpenMap | Sharer Markers: guildmates and friends who share where they are show as class-coloured diamonds with their names, so your party (round dots with a gold ring) stands apart | `/arl markers` | OpenMap |
| OneMoreQuest | Dungeon Lead-ins: a dungeon mark in OneMoreQuest's quest list, on the quest's page and on its quest givers (!) on the world map for dungeon quests and for quests whose chain leads to a dungeon quest you can still do, so you know what to pick up; hover for where it leads | `/arl leads` | OneMoreQuest (and QuestieDB) |

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
