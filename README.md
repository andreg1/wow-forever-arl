# ARL Extensions

Associação Rei Leão's Extensions for WoW Forever: small extensions for the addons you already use, in one window (`/arl`) where each one can be turned on, off and configured. Only members of the guild **Associação Rei Leão** can use them.

## Install

Copy every folder of this repo (`ARLExtensions` and the `ARLE_*` packs) into `World of Warcraft\_forever_\Interface\AddOns\`, then restart the game. Type `/arl` to open the window, `/arl help` for commands.

`ARLExtensions` is the host. The `ARLE_*` packs load on demand, only when a feature in them is turned on.

## Features

| Pack | Feature | Command | Needs |
|---|---|---|---|
| Quality of Life | Sleeping Bag: reminder to use the Cozy Sleeping Bag for Well-Rested | `/arl bag` | Nothing |
| Quality of Life | Fishing Pole Alert: warns when you fight with a fishing pole, with a key to put your weapons back on | `/arl fish` | Nothing |
| Quality of Life | Spec Gear Swap: equips a spec's gear set on a spec switch, keeps the set saved, restores emptied action bars | `/arl gear` | Nothing |
| Quality of Life | LFG Role Filter: filters the Group Browser by role, with Whisper / Invite and optional auto-invite | `/arl lfg` | Nothing |
| Quality of Life | Leveling BiS Spec: sets Forever Leveling BiS's Talent spec to the spec you play, and follows dual spec switches | `/arl spec` | Forever Leveling BiS |
| Quality of Life | Auto Uprank: swaps lower spell ranks on your action bars for a new rank when you (or your pet) learn it | `/arl uprank` | Nothing |
| Questie | New in Forever: star on quests that are new in WoW Forever | `/arl new` | Questie |
| Questie | Sub-Quest Filter: hides sub-quests until you can pick them up | `/arl subq` | Questie |
| Questie | Rare Objectives: alerts and a scan key for rare quest mobs you still need | `/arl rare` | QuestieDB |
| Questie | Quest Search: search quests by text, by zone they lead into, by faction | `/arl qs` | QuestieDB |
| EllesmereUI | Quest Tracker: clickable quest item buttons and missing-item warnings in the quest tracker | `/arl qt` | EllesmereUI Quest Tracker |
| EllesmereUI | Item Lock: Alt+Right-click locks a bag item so it can't be sold or destroyed | `/arl lock` | EllesmereUI Bags |
| Auctionator | Darkmoon Tickets: Darkmoon Faire turn-ins ranked by gold per Prize Ticket | `/arl dmf` | Auctionator |
| DungeonJournal | Dungeon Helper: dungeon window with BiS Finder, Quests and Clear Times | `/arl dh` | DungeonJournal (Forever Leveling BiS optional) |

Officers and the Guild Master also get **Officer Tools**: who in the guild runs the addon, and which version.

## Coming from the standalone addons

Several features started as standalone addons (ForeverSleepingBag, FishingPoleAlert, SpecGearSwap, LFGRoleFilter, Questie_NewInForever, Questie_SubQuestFilter, Questie_RareObjectives, QuestieDB_Search, EllesmereUIQuestTracker_QuestItems, EllesmereUIBags_ItemLock, Auctionator_DarkmoonTickets, ForeverLevelingBiS_AutoSpec). While one of those is still turned on, its feature here stays paused, so the two don't run twice, and copies the old addon's saved data (locks, gear set links, macros, settings). Turn the old addon off in the AddOns list and `/reload` to switch over.

## License

[MIT](LICENSE)
