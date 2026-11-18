# AGENTS.md

This file provides guidance to coding agents (Claude Code reads it at session start) when working with code in this folder.

Keep it as the only instructions file here: a `CLAUDE.md` or `CLAUDE.local.md` in this folder or above it would make Claude Code read that instead and ignore this file.

## What this directory is

This is the live `Interface\AddOns` folder of a World of Warcraft **Forever** client (`_forever_`, `## Interface: 16001`, max level 60, modern `C_*` APIs). It is not a git repo; ARL's repo is a separate clone (below). Each top-level folder is one addon that the client loads directly.

Almost every folder is a **third-party addon that auto-updates** (EllesmereUI*, Questie*, GearQuestForever*, ItemTree*, Auctionator, Leatrix_Plus, RareScanner, ForeverSnackTrack, etc.). An update replaces the whole folder, so any edit made inside one is lost.

The user's own code is **ARL Extensions** (`ARLExtensions/` + the `ARLE_*` packs, `## Author: aredpanda, andreg1`), the only folders to change. **Edit ARL only in the git clone** (on this machine `C:\Users\andre\source\wow-forever-arl`) and deploy it here with `make` (see "Versioning" and "Testing and debugging"). `make publish-local` replaces `ARLExtensions` and every `ARLE_*` folder in AddOns, so an edit made in AddOns is lost on the next deploy. This AddOns folder keeps a copy of this AGENTS.md, because Claude Code sessions start here and `make` doesn't deploy it: copy it over from the clone whenever it changes. It replaced the user's earlier standalone addons, which were moved out of this folder on 2026-11-16 to `..\AddOns_standalone_backup\` (not loaded; kept so one can be copied back to let ARL import its saved data, see "Switching over" below).

## ARL Extensions

One `/arl` window where each feature is turned on, off and configured, for members of the guild "Associação Rei Leão" only (`ARLExtensions/Core/Guild.lua`, a client-side name check).

- **Host** `ARLExtensions/`: core (`Core/`: Init, DB, Guild, Comm, Options, Modules, Commands), helpers (`Lib/`), secure buttons and macros (`Secure/`), adapters for outside addons (`Bridge/`: Questie, FDJ, FLB, Auctionator, EUI), UI (`UI/`: Skin, Kit, Window, Alert, Panel), built-in entries (`Builtin/`: Settings, Officer Tools, EUI options).
- **Packs** (LoadOnDemand, loaded once the guild check passes and a feature in them is on): `ARLE_QoL`, `ARLE_Questie`, `ARLE_EllesmereUI`, `ARLE_Auctionator`, `ARLE_DungeonJournal`, `ARLE_OpenMap`. Each feature is one Lua file that calls `ARLE:RegisterModule(def)`.
- **Feature API** (`Core/Modules.lua`): `OnEnable`/`OnDisable`; `self:On` / `OnUnit` (pcall RegisterEvent, return false on an event this client lacks), `Hook`, `HookScript` (deferred out of combat), `Wrap` (replaces a function in another addon's table while on), `After`, `Debounce`, `Ticker`, `OutOfCombat`, `Command`, `Comm`, `Alert`, `Print`, `Debug(fmt, ...)` (a trace line, free unless `/arl debug <feature>` is on), `Script(frame, script, fn)` (SetScript on the feature's own frames with errors caught). Everything these run, plus enable/disable/Import/option changes/status lines/commands and `Wrap` wrappers, goes through `ARLE.Debug.Call` (`Core/Debug.lua`): errors are recorded per feature with their stack (`ARLExtensionsCharDB.debug`), said once in chat, still passed to the game's handler, and a feature with 20 errors in 60 s is turned off (circuit breaker). A failing `Wrap` wrapper falls back to the original's results, so it can't break the other addon; an error inside the original itself is re-raised as the other addon's, not counted against the feature, and the original isn't run twice. A feature whose `OnEnable` fails gets `OnDisable` + Cleanup. The breaker turns a feature off even while `SetModuleEnabled` would refuse (the guild check). Data: `self.db` = this character's settings incl. the on/off switch (`ARLExtensionsCharDB.modules`, seeded once from the old account-wide `ARLExtensionsDB.modules`); `self.char` = this character's data (`ARLExtensionsCharDB.features`); `self.shared` = data shared by all characters (`ARLExtensionsDB.modules`, e.g. Darkmoon learned counts). Theme, accent and login message stay account-wide. Features enable only out of combat; Cleanup on disable unregisters events, commands and comms and hides the feature's alert.
- **Commands** belong to whoever registered them first: a feature can't take or remove another's command or alias (`RegisterCommand` refuses and says so; `UnregisterCommand(name, module)`).
- **Pack tocs** list features so the panel shows them before the pack loads: `## X-ARLE-Features: A, B` and `## X-ARLE-Feature-<id>: title=...; extends=<addon>; group=<group>; cmd=<word>; default=off; replaces=<standalone addon>`. A toc change needs a full client restart.
- **Switching over** (`replaces=`): while the named standalone addon is loaded, the feature stays paused (state "conflict") and `def:Import(old)` copies that addon's saved data each session. Import must never write `db.enabled` (the host's on/off switch). Since the standalones are no longer in this folder, a character that never ran ARL with them can only get its old data by copying that folder back from `..\AddOns_standalone_backup\`, logging in once with the ARL feature on, then removing it again.
- **Secure buttons** are made by the host at login (`Secure/Secure.lua`: `ARLE_SecureFishingSwap`, `ARLE_SecureRareScan`, `ARLE_SecureBuffBack` with key bindings in the host's `Bindings.xml`, and `ARLE_SecureUseItem` / `ARLE_SecureUseFood` / `ARLE_SecureLayerSwap` (a macro, `click = true`, also bound), clickable buttons with `useOnKeyDown=false` + `AnyUp`; a new button needs a full client restart); features only change their attributes, out of combat. Macros a feature owns go through `Secure/Macro.lua` (refuses in combat; only edits a macro whose body still looks like its own).
- **Addon messages** (`Core/Comm.lua`): one prefix `ARLE`, `"<kind>\t<payload>"`, several handlers per kind, token-bucket throttle (8 burst, then 1/s), throttled sends retried. Whispers are heard only from guildmates and the group, and our own messages are dropped by our full name (`ARLE:MyName()`, "First Surname"). Officer Tools' version messages are accepted only from guildmates and only as plain version numbers.
- **No Blizzard globals**: never assign `StaticPopupDialogs` or any game global; confirmations use the two-click "armed" button pattern.

### Features (pack, file, command) and their design notes

The notes come from the standalone versions; the ARL ports keep these behaviors.
- **Item Lock** (`ARLE_EllesmereUI/ItemLock.lua`, `/arl lock`, needs EllesmereUI Bags): Alt+Right-click locks a bag item (per character, by itemID) so it can't be sold or destroyed; items in the character's gear sets get the same protection (by itemID via `C_EquipmentSet.GetItemIDs`, because `GetItemLocations` crashes the Forever client). Padlocked items go to a runtime "Locked" category via `EUI_CategoryManager:RegisterVirtualCategory`. Overlay through `EUI_Bags.RegisterItemOverlayIcon` (`EllesmereUIBags/EUI_Bags_Slots.lua`), unregistered on disable.
- **Quest Tracker** (`ARLE_EllesmereUI/QuestTracker.lua`, `/arl qt`, needs EllesmereUI Quest Tracker): item icon right of a quest title when the objective needs a used item (Blizzard's `GetQuestLogSpecialItemInfo`, else QuestieDB `sourceItemId`/`requiredSourceItems` filtered to items with a use spell), via the public `EllesmereUI.RegisterQuestTrackerRow` (`EllesmereUI/PLUGINS_API.md`); "Also uses" lists further items; missing-item warnings (remembered items per character). Clicking uses the item: a pool of our own `SecureActionButtonTemplate` buttons under UIParent laid by screen coordinates over owned items' icons (never on EUI's rows), re-placed after each redraw and on a 0.25 s ticker out of combat, hidden when the row scrolls out of the tracker's ScrollFrame; they stay put in combat.
  - **Zone focus:** on a zone change it writes EUI's fold state, `EllesmereUI.CharData("questTracker").ctCollapsed`, with `z:<header>` and questID keys. Only when the zone differs from the last one focused (`char.focusedZone`), so a `/reload` or a loading screen back into the same zone keeps the player's own folds.
  - **Use buttons and EUI's fading:** a button is laid only over an icon whose effective alpha is above 0.05 (mouseover mode, auto-hide). On `PLAYER_REGEN_DISABLED` they're hidden when the tracker may hide in that fight (a raid, or `EllesmereUI.VisDependsOnCombat` / `GetVisibilitySelection` say so; unknown counts as may).
  - **"Show only the quests for where I am"** (`zoneOnly`): switches EUI's own Quest Tools settings `filterEnabled` + `filterZone` + `autoTrackZone` through `EQT.Set` + `EQT.ApplyQuestWatches()` (`EQT` = `_G.EllesmereUIQuestTracker`). The values from before are kept in `char.euiBefore` and put back when it, or the feature, goes off.
  - **"Objectives here"** (`objectivesHere`, needs QuestieDB): `self:Wrap(EQT, "QuestInArea")` and `"IsQuestFiltered"`.
    - The custom tracker calls both through the table on every rebuild. EUI's own rule is the header == zone, or the game's `isOnMap`, which vanilla quests mostly lack.
    - A quest also counts when `ARLE.Lib.QuestPlaces.IsHere` puts one of its unfinished objectives, or its turn-in once complete, in the player's zone. Open world only.
    - In `IsQuestFiltered`, such a quest is re-judged by EUI's other filters only (completed, trivial, repeatable).
    - Quests keep their own zone group. Zone focus unfolds that group, with only those quests unfolded in it.
    - Only the custom tracker benefits: Blizzard-tracker mode calls EUI's local `InArea`.
  - `/arl qt here` lists such quests and why.
- **`ARLExtensions/Lib/QuestPlaces.lua`** (host): the zone maps of a quest's unfinished objectives, read from QuestieDB.
  - **Sources:**
    - creature / object / item objectives (an item's maps come from its `npcDrops` / `objectDrops`)
    - kill credit
    - `triggerEnd` exploration
    - or `finishedBy` once the quest is complete.
  - **Finished objectives:** matched by name against `C_QuestLog.GetQuestObjectives` and skipped.
  - **Cache:** per quest by progress signature.
  - **Player zone maps:** follow `C_Map.GetBestMapForUnit` on every call. A reset by event could come after EUI had already rebuilt for the new zone.
  - Rare Objectives uses its `NpcMaps` / `WalkToZone`.
- **New in Forever** (`ARLE_Questie/NewInForever.lua`, `/arl new`): star on Questie map icons and the map tooltip for quests new in Forever (quest ID >= 10000; cutoff 10000/60000/90000). Wraps `QuestieMap:DrawWorldIcon`, `QuestieFramePool:GetFrame` and `MapIconTooltip.ShowOnTooltip` (via `QuestieLoader:ImportModule`).
- **Sub-Quest Filter** (`ARLE_Questie/SubQuestFilter.lua`, `/arl subq`): hides Questie's child quests (parent in the log) until their level and `QuestieDB.IsDoable` requirements are met, because Questie's `_DrawChildQuests` and the parent bypass in `IsLevelRequirementsFulfilled` skip those checks. Wraps `AvailableQuests.DrawAvailableQuest` and `CalculateAndDrawAll`; only redraws once Questie has started (`Questie.started`, `QuestieDB.QuestPointers`). Quests an NPC actually offers are always shown; nothing is hidden persistently (the user rejected that).
- **Rare Objectives** (`ARLE_Questie/RareObjectives.lua`, `/arl rare`, needs QuestieDB): watches for rare / one-off quest mobs still needed by incomplete quests (rare = NpcDB rank 2/4, or an objective needing exactly 1 kill / 1 item from a single dropper), only in their zone; scans nameplates, target, mouseover and vignettes every second; alerts and waypoints. Markers and pings can't come from addon code (`SetRaidTarget` triggers ADDON_ACTION_FORBIDDEN), so the scan text does them: `/cleartarget`, `/targetexact` each mob, `/tm`, `/ping [@target,harm,nodead]`, `/targetlasttarget [noexists]`, then `/cleartarget [dead]` (`/targetexact` can pick a corpse). The text goes to the host button `ARLE_SecureRareScan` and to the character macro `QRareScan` (255-char limit, optional extra last line). A macro can't `/click` a macro-type button. `/click` typed in chat sends the up edge, inside a macro the down edge, a key binding both: PreClick sets `useOnKeyDown` to the first edge and ignores the other within 0.8 s. Ping cooldown takes the ping line out after a hit.
- **Quest Search** (`ARLE_Questie/QuestSearch.lua`, `/arl qs`, `/arl qs find <words>`): search over QuestieDB's `QuestDB`/`NpcDB`/`ObjectDB`: text (name + objectives), "leads into zone", All/Alliance/Horde filter.
- **Darkmoon Tickets** (`ARLE_Auctionator/DarkmoonTickets.lua`, `/arl dmf`, needs Auctionator): ranks the 21 Darkmoon Faire turn-ins by cost per Prize Ticket from `Auctionator.API.v1` prices; built-in counts from community guides, real counts learned from the quest window (`QUEST_PROGRESS` + `QUEST_COMPLETE`, ticket 19182) into `self.shared.learned`; tiers past approximate DMF rep caps greyed; tooltip line; "Search all" via `MultiSearchExact`.
- **Sleeping Bag** (`ARLE_QoL/SleepingBag.lua`, `/arl bag`): reminder for the Cozy Sleeping Bag / Well-Rested buff, clickable via the host's `UseItem` button. Timeline option: while lying in the bag (area aura 429960), a 0-3 bar with "next stack / 3/3 in" (one stack per 60 s from the last stack or expiration change, Forever SnackTrack's model).
- **XP Food** (`ARLE_QoL/XPFood.lua`, `/arl food`, `/arl food debug`, replaces ForeverSnackTrack): own rewrite of SnackTrack (it has no license, so none of its code). XP food and the XP buff are found by tooltip text (`C_TooltipInfo.GetBagItem` / `GetUnitBuff`; a line with per-locale "experience" + "kill" + "increase" words; the nearest `N%`), food = class 0 / subclass 5; unreadable tooltips are never cached as "no XP". Gourmand (Legacy talent 1225499 via `C_Traits`) sets serving length 15 + 5 x rank min for the supply line. States: food beats the buff / no food (option); low-stock line once; chat warning before the buff ends. Off at 60, while resting (option), in combat; alert hidden dead / flying / taxi. Food icon = host secure button `UseFood` (`type1=item`, right-click opens our own menu), separate from `UseItem` because both alerts can be up at once. Import reads `ForeverSnackTrackCharDB`, else the legacy account-wide `ForeverSnackTrackDB` / `ForeverExpFoodDB`.
- **Quick Loot** (`ARLE_QoL/QuickLoot.lua`, `/arl loot`): own implementation (EllesmereUI's Quick Loot is all rights reserved); stands aside while `EllesmereUIDB.quickLoot` is on. On `LOOT_READY` (also with the client's Auto Loot on, like EUI; not with Shift) loots slot by slot 0.05 s apart and closes an empty window; leaves locked slots (rolls, master loot), BoP confirms (never answered, window never closed while a slot is left) and items that surely don't fit (free slots by bag family + partial stacks counted first; anything it can't judge, such as unloaded item data or keys, is tried; `ERR_INV_FULL` / `ERR_BAG_FULL` stop the remaining items but not coins/currency, only while a loot window is open; `ERR_ITEM_MAX_COUNT` (a unique item) doesn't).
- **Loot Sparkles** (`ARLE_QoL/LootSparkles.lua`, `/arl sparkle`, replaces ForeverLootSparkles): own code (the original is GPL-3, ARL is MIT). Keeps `outlineModeShowLootEffectWhenDisabled` at 1: on enable, world entry (+5 s), and 1 s after `CVAR_UPDATE` for `graphicsquality` / `raidgraphicsquality` / itself; out of combat. Off writes 0, and the sparkles only go after a client restart.
- **Buff Back** (`ARLE_QoL/BuffBack.lua` + `BuffBackData.lua`, `/arl buff`, `/arl buff queue`, replaces Manners):
  - **Origin:** our own smaller take on Manners (MIT). Its Forever spell data is reused in `BuffBackData.lua`: ids, rank levels, blockers and chat nicknames, with Manners' MIT notice.
  - **Queue, in order:** people who *asked* in chat (60 s), people who *buffed you* (3 min), and the *group* (missing buffs, or yours ending within N min).
  - **Spotting favours:** there's no combat log on Forever. A favour is a new aura from `UNIT_AURA` `addedAuras` (never a full update; quiet for 3 s after a loading screen) whose `sourceUnit` is a player. A stranger with no unit token can't be named.
  - **The key:** the host secure button `ARLE_SecureBuffBack` (CLICK binding).
    - Its macro is `/targetexact <name>`, `/cast <spell>(Rank N)`, then `/targetlasttarget [help]` (or `/cleartarget` if you had no target). `[@unit]` doesn't resolve on Forever, and a macro doesn't down-rank by itself.
    - It's re-armed on a 1 s ticker and in PreClick, out of combat only.
    - A cast that lands (`UNIT_SPELLCAST_SUCCEEDED`) settles the entry. Three presses that don't land drop the person, and a group member then waits 60 s.
  - **Grid:** class × your buffs, per character in `db.grid`, sparse overrides of the defaults: manaOnly, meleeOnly, Thorns for tanks, opt-in buffs off.
  - **Paladins:** one blessing per target from you, unless they ask for one by name.
  - **Skipped:** PvP-flagged players (option), the ignore list, people out of range, dead, or too low for your lowest rank.
- **Layer Bridge** (`ARLE_QoL/LayerBridge.lua`, `/arl layer`, `/arl layer ask`, `/arl layer log`, `/arl layer button`; no `extends`: standalone, needs neither addon, and works alongside either):
  - **Why:** AutoLayer (raizo) and LayerSwap (Adam5288) don't understand each other on Forever. Neither has a license, so this speaks their message formats only; no code copied.
    - AutoLayer asks with a visible `"<SEG> inv layer [n,n]"` in the `layer` channels (`AutoLayer/Modules/Hopping.lua` `SendLayerRequest`), which live Forever realms refuse from addons (`C_ChatInfo.AreOutgoingAddonChatMessagesRestricted`). It hosts from any line with "layer" (`Layering.lua` `ProcessMessage`) and drops lines with digits without NovaWorldBuffs.
    - LayerSwap asks by `/who` on the zone, then a hidden addon whisper to each name: prefix `LayerSwap`, `inv layer <LS <zoneMap> [want <id>|not <id>...] [x,y]>` (`LayerSwap.lua` `routeText`/`routeTag`, `Who.send`). Users in the zone answer `heard <asker>|<id|->|<zone|->|<h|->`, a host on the asker's layer `same` (`replyHeard`, `onNote`). Layer id = creature GUID `server-zoneUID`; only `server` tells layers apart on Forever (`Layer.key`). On restricted realms it ignores channel lines.
  - **Layer reading:** own, from nameplates / target / mouseover creature GUIDs; 2 agreeing readings set it, 3 of the last 5 change it.
  - **Switches:** `layerswap` (`/arl layer set ls`: hidden asks, answering LayerSwap asks) and `autolayer` (`set al`: the chat box line, inviting AutoLayer asks). **ARL never joins the `layer` channel and sends no AutoLayer line on restricted realms** (`C_ChatInfo.AreOutgoingAddonChatMessagesRestricted`, live Forever): the game bars a character from a channel after a line it refused there, or even after a join (LayerSwap's notes, 6-7 Nov 2026; seen here 2026-11-16: after ARL's join and refused lines, `/leave layer` did nothing). There every press goes to LayerSwap hosts. `autolayer` off, or the feature off, still leaves a channel an older ARL joined (`char.joinedLayer`). `host` (default off) gates every invite and every answer.
  - **Lanes:**
    - **Hosting LayerSwap askers** (`host` on, LayerSwap not loaded, since it answers its own): answers hidden asks and typed `<LS ...>` lines with heard/same, then invites with `F:Invite` (60 s per asker, 6 per 10 min, 1 s apart, leader or solo). With AutoLayer loaded and hosting, the invite goes through `AutoLayer:ProcessMessage("CHAT_MSG_WHISPER", "inv layer", sender)` instead.
    - **Hosting AutoLayer askers** (`host` + `autolayer` on, AutoLayer not hosting, since it answers its own): invites plain `inv layer` lines in `layer*` channels with `F:Invite`. Numbered asks (NovaWorldBuffs layer numbers) are skipped.
    - **Asking:** `self:Hook(AutoLayer, "SendLayerRequest")` (the hop click keeps the hardware event for `C_FriendList.SendWho`), the panel button or `/arl layer ask` run the `/who` and whisper the LayerSwap ask, 8 a second, up to 49 names (`ASK_MAX`), guildmates first; the game's who windows are kept off `WHO_LIST_UPDATE` meanwhile.
    - **The "inv layer" line for AutoLayer hosts:** live realms refuse addon-posted chat, and a line an addon puts into the chat box isn't sent as a channel line either (measured 2026-11-16: Enter on `/6 inv layer` from `ChatFrameUtil.OpenChat` answered "Type '/help'..."). So the host's secure `ARLE_SecureLayerSwap` says it on the player's click. Its macrotext (`/<layer channel #> inv layer`) never showed in the channel either (2026-11-16: no echo, no AutoLayer invite; earlier invites turned out to be LayerSwap's), so the button now runs a stored character macro "ARL Layer" (`ARLE.Macro:Ensure`, `type=macro`, `macro=<name>`; macrotext only when no slot is free), re-armed on `CHANNEL_UI_UPDATE` and in PreClick (set with SetScript: a hooked PreClick didn't run on this template), deleted when the feature goes off. Whether the stored macro gets through is still to be measured. Other ways of asking (`/arl layer ask`, AutoLayer's hook on restricted realms, LayerSwap's own button) only print what to type.
    - **Swap layer button:** our own movable box (`char.position`) showing the read layer, with `ARLE_SecureLayerSwap` laid over its visible button (shown/hidden via `ARLE.Secure:Run`, since it holds a secure child). PostClick runs the ask: always our own `/who` (15 s wait) + hidden asks, with or without LayerSwap / AutoLayer installed; replies to our asks are read even with LayerSwap loaded (only answering other people's asks is left to it). It no longer presses `LayerSwapPanelSwapButton`: LayerSwap 1.14.29 only creates it once its panel is opened, and the press silently did nothing.
    - **Reaching LayerSwap hosts like LayerSwap does** (measured 2026-11-16: ARL's plain burst got 0 answers where LayerSwap found hosts): a book of LayerSwap users (`shared.book`, anyone who sent us a LayerSwap message, plus `LayerSwapDB.book` when installed; 7 days) asked first, hosts first; then players whose `/who` area is our zone; strangers who didn't answer aren't whispered again for 6 h (`shared.asked`; LayerSwap notes players reported for spam). 3 s and 10 s after the burst, hosts that answered `heard` with layer `-` (they haven't read their own layer, so they skip any ask naming the layer we leave) get the ask once more without it (`F:Anyway`, LayerSwap's `Who.anyway`). Searches in a zone are spaced 60 s apart (the server answers "Unable to complete your request" otherwise); in between, known hosts are asked directly (one the game answers "No player named ... is currently playing" for is left out 1 h, `book[name].offline`, and that line is hidden by a `CHAT_MSG_SYSTEM` chat filter for names our asks whispered in the last 10 s). Each search asks the zone's map for one class in turn (all classes first), as LayerSwap's `Who.query`. Like LayerSwap's `requestSwap`: no ask from a group, and no LayerSwap ask before our layer is read (else hosts on it invite for nothing); guildmates go last; hosts that answered from our own layer are left out 20 s (`Who.avoidHost`); a late `heard` from an unread host triggers the re-ask at once.
    - **Two buttons** (user's choice 2026-11-16): the box holds a plain **LayerSwap** button (`F:Ask(via, "layerswap")`) and an **AutoLayer** button with `ARLE_SecureLayerSwap` laid over it (`F:Ask(via, "autolayer")`; greyed out while `autolayer` is off or we're not in the channel; its tooltip warns on restricted realms). `/arl layer ask` and AutoLayer's hop button still go through `F:Pool`.
    - **`F:Pool`, one pool per press** (for the paths without a button choice): AutoLayer hosts first (only the macro line); LayerSwap hosts (only the hidden asks) while AutoLayer is on cooldown: 5 min after an invite that followed our line (`char.alInvitedAt`; AutoLayer hosts won't invite the same player from the channel again), or 60 s after a line that brought none (`char.lineAt`). `ArmButton` (also in PreClick) empties the macro for `ASK_GAP` (10 s) after a line went out, so fast clicks don't repeat it in the channel. The host button is laid with `AttachSecure` when the pad is painted and handed back with `ARLE.Secure:Detach` when the feature goes off. A `same` reply counts only from someone our ask whispered (`whisperedAt`). `F:Asked()` (which arms leaving a joined group) runs only when an ask actually went out. The pad's second line says where the next press goes.
    - **Leaving:** after our ask, a joined group is left 4 s after the read layer changes.
  - **Debugging a swap:** every press records its steps whether or not tracing is on (`F:Step`: search sent/answered, whispers sent/refused with the result code, replies, the box line and whether our own line echoed back, `CHAT_MSG_SYSTEM` / `UI_ERROR_MESSAGE` / channel notices, invites, group join, layer change). A one-line "Swap result" prints 25 s after a press; `/arl layer last` lists the steps; `/arl report` includes them through `def:ReportDetails()`.
- **Share Location** (`ARLE_QoL/ShareLocation.lua`, `/arl share`, **on by default**, the user's choice 2026-11-17; no `extends`): guildmates with OpenMap see the player as a live dot. Speaks OpenMap's format only (`OpenMap/Map/Friends.lua`): prefix `OpenMapLoc`, GUILD, `L1\t<uiMapID>\t<x>\t<y>\t<CLASS>\t<level>` every 10 s moving / 60 s still, `L0` once on stopping (instance, feature off); OpenMap drops a dot after 150 s silence. Micro/dungeon/orphan maps are walked up to their zone (OpenMap only places zones and cities). Stands aside, without an `L0`, while OpenMap is loaded with its own `friendsShare` on; shares nothing (an `L0` if it was) while OpenMap says the player declined (`shareAsked` true and `friendsShare` false). Guild only (no friends/Battle.net).
- **Sharer Markers** (`ARLE_OpenMap/SharerMarkers.lua`, `/arl markers`, needs OpenMap): OpenMap draws group members and guild/friend sharers as the same class-coloured circle (group ones only add a thin gold ring, `Nav.lua`). `self:Wrap(OpenMap.MapStitch, "AddPin")` (`_G.OpenMap` = its namespace) swaps the look of a sharer's dot (the only pin with `data = { full, p, roster }`) for our class-tinted diamond `Media/SharerDiamond.tga` (white fill, dark outline, made by a script) and puts the name beside it (our FontString in a weak table; that pin set only holds sharer dots, so every reuse passes through AddPin). Redraws via the `worldmap` module's `RefreshFriends()`.
- **Fishing Pole Alert** (`ARLE_QoL/FishingPoleAlert.lua`, `/arl fish`): alert in combat with a fishing pole in the main hand; remembers the last non-pole weapons out of combat; `ARLE_SecureFishingSwap` runs `/equipslot 16|17 item:<id>`, its macrotext only rewritten out of combat.
- **Spec Gear Swap** (`ARLE_QoL/SpecGearSwap.lua`, `/arl gear`): equips a gear set when the talent group changes (`ACTIVE_TALENT_GROUP_CHANGED` / `PLAYER_TALENT_UPDATE` vs `GetActiveTalentGroup`; EllesmereUI listens for retail `PLAYER_SPECIALIZATION_CHANGED`, which this client never fires). Set per spec: explicit link, else a set named like the main talent tree; learn mode. Gear auto-save re-saves the worn set (the last one put on) when a piece changes, skipped when a set slot is empty (off hand allowed with a 2H), the main hand is a fishing pole, another set fully matches, or more than 4 slots changed; debounced 0.7 s, rechecked after combat. Action bar restore: per-spec backup of every slot, refilled at 1 s and 3 s after a switch (filled slots never replaced); 6+ slots emptied within 1 s up to 15 s after a switch count as a wipe (limited to after a switch because ActionBarSaverReloaded also empties many slots and can't be hooked).
- **LFG Role Filter** (`ARLE_QoL/LFGRoleFilter.lua`, `/arl lfg`): side panel right of the Group Browser (`LFGBrowseFrame`) filtering results by Tank/Healer/DPS (solo players by listed roles, groups by missing roles); Whisper / Invite. Never calls, hooks or anchors to the LFG window (that taints it and breaks searching until `/reload`, see `ForeverDungeonJournal/Systems/LFGButton.lua`): reads `C_LFGList` getters after `LFG_LIST_SEARCH_RESULTS_RECEIVED`, follows `LFGBrowseFrame:IsVisible()` from its own OnUpdate, places itself by coordinates. Auto-invite tank / healer (session-only): one solo player per role for an activity in your own listing, while leader with room; one pending invite per role (60 s), nobody twice per session, turns off when the role is filled.
- **Leveling BiS Spec** (`ARLE_QoL/LevelingBiSSpec.lua`, `/arl spec`, needs Forever Leveling BiS by Thunder): FLB has no talent detection and its `ForeverLevelingBiS_API` is read-only, so this writes `ForeverLevelingBiSDB.chars[<GetUnitName("player", true)>-<realm>].spec` (what its Talent spec box writes via `UI.SetMainSpec`, also clearing own-class `sim.spec`) from the active group's most-pointed tree (tab order = `API.GetSpecs`; Druid feral/bear and Hunter survival/survivalmelee keep the current pick), only when "group:tab" changes, so a manual pick stays until the next switch/respec. FLB's license forbids copying its code: public API and that one field only.
- **Auto Uprank** (`ARLE_QoL/AutoUprank.lua`, `/arl uprank`, `/arl uprank all`): when you or your pet learn a higher rank, swaps lower ranks of that spell on action slots 1-180 (`C_Spell.PickupSpell` / `PlaceAction` / `ClearCursor`, out of combat, empty cursor). Highest ranks remembered per character and per pet; the first check only records. Own implementation: EllesmereUI's similar option (`EllesmereUIForeverEssentials_Uprank.lua`) is all rights reserved, so none of its code is used; this stands aside while `EllesmereUIDB.spellUprank.enabled` is on.
- **Dungeon Helper** (`ARLE_DungeonJournal/`, `/arl dh [loot|quests|timers|reset]`, shortcuts `/arl bis`, `/arl quests`, `/arl timers` (not `/arl loot`: Quick Loot's), needs DungeonJournal = ForeverDungeonJournal, FLB and QuestieDB optional): one two-pane window (list left, the selection's details right; `DungeonHelper.lua` holds the window, events, commands; each tab gives `Create(bar, list, detail)`, `RenderList(w)`, `RenderDetail(w)` and optionally `Badge()` (the count on its tab)). Look (0.9.0, the user asked for less text and a more game-like window): a banner with FDJ's card art (`DUNGEON_HOME_ART` / `DUNGEON_HOME_TEXCOORD`, optional), level range, zone and the run clock; icon tabs; two-line rows with framed portraits / quality-edged item icons, class icons as party marks, raid-star and green-number badges; details open on a banner (`H.Banner`) with tags (`H.Badge`), stat tiles (`H.Tiles`) for times, the quest card's status strip, reward cells like the game's quest frame and the chain as a step track. Explanations live in tooltips, not in the panes. The widgets are in `Shared.lua` (`H.Pic`, `H.Row` + `H.PaintRow(r, opts)`, `H.Section`, `H.Bar`, `H.Badge`, `H.Tile`, `H.Banner`, `H.Empty`, `H.PartyStrip`, `H.Pool`). Reads FDJ's internal `ForeverDungeonJournal_NS` (warns once if fields are missing).
  - **Bosses & Loot** (`Loot.lua`): each ARL member scores the drops with their own FLB and sends gains + worn items to the party (`BG`/`BE`); members without ARL get no marks (the 0.7.0 inspect-and-estimate path was removed on purpose, user's choice 2026-11-17).
  - **Quests** (`Quests.lua`): FDJ's dungeon list; prerequisites from FDJ's curated `QUEST_PREREQ_CHAINS` (`QUEST_GUIDE_CHAINS` = how-to steps, never blocking), else QuestieDB `preQuestGroup` / `preQuestSingle` walked back; follow-ups from QuestieDB `nextQuestInChain`. State `c` = level OK but earlier chain steps missing. Party states over `QS`.
  - **Clear Times** (`Times.lua`): clear rules follow FDJ's `RunLog.lua` (optional/summoned bosses skipped, `fightGroup` folded); kills from ENCOUNTER events plus `PARTY_KILL`/`UNIT_DIED` by NPC ID; the run in progress is per character. Records go to the party (`BT`) and to the guild leaderboard (`BT` on GUILD after a record, and in answer to `BR <dungeon>`, asked at most every 15 min per dungeon, answers jittered 1-6 s and at most one a minute), kept account-wide in `shared.board` for 120 days. The board takes `BT` from the GUILD channel only (a party member who turned `guildBoard` off still sends to the party), times under 10 s or over a day are dropped, and an empty `BT` on GUILD (sent by Clear my records) removes the sender. A run whose pull wasn't seen (`run.noRecord`) makes no time records. A `childOf` group (the Altar's guardians) counts as killed with its last guardian. Messages are registered through `H.Comm` (then `mod:Comm` on enable).
- Removed on purpose: **Rank Macros** (the standalone HighestRankMacros): EllesmereUI covers the user's need.

### Repo

ARL lives in its own **private** repo, https://github.com/andreg1/wow-forever-arl (root = `ARLExtensions/` + the `ARLE_*` folders, plus `README.md` with a feature table and an MIT `LICENSE` naming aredpanda and andreg1; this AGENTS.md, the `Makefile` and `tools/make.ps1` are in the repo root too). Keep the README's feature table in sync when a feature or its command changes. Confirm with the user before every push.

Work straight on `main` (no feature branches; pull first, others push there too). A release is a version bump (see "Versioning") committed to `main`, tagged `v<version>` on that commit, and published as a GitHub release with `dist/ARLExtensions-<version>.zip` attached (`gh release create v<version> <zip>`).

**Every push that carries a version bump gets its release right away**: patch, minor or major, in the same step as the push, without asking again (andreg1's standing instruction).
1. Push, then tag the bump commit with `git tag v<version> <full sha>` and `git push origin v<version>`. `gh release create --target` refused a short sha.
2. Run `gh release create v<version> dist/ARLExtensions-<version>.zip --verify-tag --title "ARL Extensions <version>" --notes-file <notes>`.
3. Write the notes in the 0.2.0 release's shape:
   - **Install:** extract into AddOns, and say whether `/reload` is enough or a restart is needed (a `.toc` change or a new secure button means a restart).
   - **New / Changed / Fixed:** in player words.
   - End with "New features start turned off" when there are new features.
   - Cover every version since the last release.

Pushes with no version bump (docs, Makefile) get no release.

**Discord:** `.github/workflows/discord-release.yml` posts every published release to the guild's Discord channel (the zip attached, title and notes cut to 2,000 characters) through the channel webhook in the repo secret `DISCORD_WEBHOOK`. Never put that URL in code, commits or chat. Re-post an older release with Actions > "Post release to Discord" > Run workflow (tag), or `gh workflow run discord-release.yml -R andreg1/wow-forever-arl -f tag=v<version>`. The release notes are what guildmates read there: keep them in player words.

**Pull from the remote first, every time**, because aredpanda pushes to `main` too:
- Run `git pull --rebase` in the clone before starting any work on ARL, and again right before every `git push`.
- Tell the user what came in (`git log --oneline HEAD@{1}..HEAD`). If it changed AGENTS.md, copy it to AddOns. If it changed addon code, deploy it with `make`.
- If a rebase conflicts, resolve it by hand and keep both sides' intent; never drop either side silently.
- Never force-push.

## GitHub and tools (this Windows machine)

- **Tools:** Git for Windows (`git`), GNU make (`winget install ezwinports.make`) and the GitHub CLI (`C:\Program Files\GitHub CLI\gh.exe`, logged in as `andreg1` with `repo` scope; `gh auth setup-git` makes git use that login).
  - A shell opened before they were installed lacks them on PATH: reload it from the Machine + User `Path`.
- **Clone settings** (in its own config):
  - It commits as `andreg1` with GitHub's noreply address. Never put a personal email in commits.
  - `core.autocrlf=false`, so files stay LF like the repo.
- **Makefile on Windows:** GNU make on Windows runs a `.ONESHELL` recipe as a `.bat` through cmd.exe whatever `SHELL` says, and Windows' `tar.exe` has no `-s`. So each Windows recipe is one cmd line calling `tools/make.ps1`, which holds the logic. Keep the two in step when a recipe changes.
- The **public** repo https://github.com/andreg1/wow-forever-addons holds the old standalone addons (last pushed `5b199c0`, 2026-11-16). They are no longer developed here and the user asked to leave that repo untouched: don't push to it unless asked.

## The core rule: never patch third-party addons

To add or change behavior in a third-party addon, do **not** edit it. Add an ARL feature instead (in the pack for that addon, or a new `ARLE_<Addon>` pack with its own toc metadata). A feature:
- names the addon it needs with `extends=` (and the pack lists it in `## OptionalDeps`);
- keeps its state in `self.db` / `self.char` / `self.shared`, never in another addon's tables;
- hooks only public surfaces: globals the original exposes, Blizzard API, `self:Hook` (hooksecurefunc), `self:HookScript`, or `self:Wrap` for another addon's module tables (never Blizzard functions). If a target might be missing after an update, `self:Hook` prints a warning instead of erroring; do the same for other lookups.

Reading third-party source to find extension points is fine. For EllesmereUIBags, the overlay hook API is in `EllesmereUIBags/EUI_Bags_Slots.lua` (`RegisterItemOverlayIcon` / `UnregisterItemOverlayIcon` / `RunItemOverlays`). Check a third-party license before reusing any of its code (EllesmereUI: all rights reserved; Forever Leveling BiS: forbids copying; Forever SnackTrack: no license, so all rights reserved; Forever Loot Sparkles: GPL-3, can't go into MIT ARL; Manners: MIT, reusable with its copyright and permission notice kept, as in `BuffBackData.lua`; AutoLayer and LayerSwap: no license, so only their message formats are spoken; OpenMap: MIT, though ARL only speaks its message format and wraps its `MapStitch.AddPin`).

## Feature standards

Every feature follows these, so they all read the same and their failures end up in the same place (`/arl errors`, `/arl report`). They were set after the 2026-11-18 code review: each rule below replaced several local variants. A new feature, or a change to an old one, follows them; code that doesn't is brought in line when it's touched.

### File skeleton

```lua
-- <Title>: <one line on what the player gets>.
--
-- <Design: which public surfaces of which addon it uses (and their license),
-- what it protects, how it avoids taint; the standalone it replaces.>
local ADDON = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local Lib = ARLE.Lib

local SOME_LIMIT = 10 -- constants first, UPPER_CASE, with their unit

local F = {
  id = "MyFeature",          -- also the SavedVariables key: never rename
  addon = ADDON,
  title = "My Feature",
  group = "QualityOfLife",
  extends = "OtherAddon",    -- only when it needs one (and the pack's OptionalDeps lists it)
  command = "word",          -- /arl word; check no other feature or built-in has it
  commandHelp = "what /arl word does, in player words",
  description = "One or two sentences for the panel.",
  options = {
    { type = "info", text = function(def) return def:GetStatus() end },
    { key = "thing", type = "boolean", label = "Do the thing", default = true },
  },
}

local state = {} -- module state as file locals; per-frame state in weak-keyed tables

function F:OnEnable()
  -- reset queued flags and caches here (a wait from the last time it was on was dropped)
  self:On("SOME_EVENT", self.OnSomething)
end

function F:OnDisable()
  -- put back what it changed outside the feature API (frames, CVars, other addons' settings)
end

function F:GetStatus()
  return "Active · <what it's doing right now>"
end

ARLE:RegisterModule(F)
```

- **Order:** the design comment, the requires, constants, `local F = {...}`, then helpers before their first use, then `OnEnable` / `OnDisable` / `OnOptionChanged` / `GetStatus` / `ReportDetails`, then `ARLE:RegisterModule(F)` as the last line.
- **Fields of `F`:** in the order shown: `id, addon, title, group, extends, command, commandAliases, commandArgs, commandHelp, mainHelp, commandUsage, commands, description, pages, panePage, defaults, options`. Leave out the ones it doesn't use.
- **The table is called `F`.** Dungeon Helper keeps `mod`, because its five files share it through `ns.mod` / `H.mod`.
- **Status line:** every feature has `F:GetStatus()` returning `"Active · ..."`, saying what it's doing or waiting for, not just "on". A feature with steps worth checking adds `F:ReportDetails()` (lines for `/arl report`).

### Shared helpers instead of local copies

Use `ARLExtensions/Lib/Util.lua` and the host, never a local copy of the same thing. If a helper you need isn't there and a second file would need it, add it to `Lib`. Don't copy it into the next feature.

| Need | Use |
|---|---|
| Is this value hidden (secret)? | `Lib.IsSecret(v)` |
| The value, or nil when hidden | `Lib.Plain(v)` |
| A client table that can be read | `Lib.Readable(t)` (a secret table says "table" to `type()` but throws when read) |
| A non-empty, readable string | `Lib.Str(v)` |
| Call an API that may be missing, throw or return hidden values | `Lib.Call(fn, ...)`. For one value only, write `(Lib.Call(fn, ...))` |
| A spell's name | `Lib.SpellName(id)` |
| A unit's name as chat and `/targetexact` know it ("First Surname"; Forever has surnames, not realms) | `Lib.UnitFullName(unit)` |
| Our own name | `ARLE:MyName()`, never `UnitName("player")` alone (that's only the first name) |
| "Name-Realm" to "Name" | `Lib.StripRealm(name)` (any realm), `ARLE:ShortName(name)` (only our own realm) |
| Is someone in our group or guild? | `ARLE:InMyGroup(name)`, `ARLE:IsGuildmate(name)` |
| Items, counts, links | `ARLE.Lib.Items` |
| Questie, QuestieDB, Auctionator, FLB, EllesmereUI | `ARLE.Bridge.*` (each lookup is checked, and a missing piece is warned about) |
| Quest objective zones | `ARLE.Lib.QuestPlaces` |
| Group members | `Lib.Members()`, `Lib.Me()` |

### Events, timers and hooks

- **Events:** `self:On(event, fn)` / `self:OnUnit(event, unit, fn)`. Never a private `CreateFrame("Frame")` with `RegisterEvent`. These calls are unregistered when the feature goes off, and an event this client lacks is skipped instead of throwing.
- **Timers:** `self:After`, `self:Ticker`, `self:Debounce`, `self:OutOfCombat`. Never `C_Timer`.
  - **They're dropped when the feature goes off.** So a "queued" flag set before a wait (`queued = true; F:After(0, Run)`) must be reset in `OnEnable`, or it stays stuck.
  - **The one exception** is work that must finish even if the feature goes off mid-way, such as Quest Search's sliced search. Say so in a comment.
- **Scripts on our own frames and on the host's secure buttons:** `F:Script(frame, script, fn)`. Its errors are recorded under the feature, so the handler needs no `ARLE.Debug.Call` of its own. A plain `SetScript` only goes in a per-frame `OnUpdate` that's too hot for the wrapper, with a comment saying so (XP Food's pulse).
- **Other addons' frames:** `F:HookScript(frame, script, fn)`. It's deferred out of combat, runs once per frame however often it's called, and does nothing while the feature is off. Never `frame:HookScript` directly.
- **Other addons' functions:** `self:Hook(tbl, name, fn)` (hooksecurefunc) or `self:Wrap(tbl, name, fn)` (replace while on). Never hook or wrap a Blizzard function.
- **Addon messages:** `self:Comm(kind, fn)` in `OnEnable`, never `ARLE:RegisterComm` at file load. A pack of several files collects them like Dungeon Helper's `H.Comm`. Whispers only arrive from guildmates and the group. Still check every field of a payload before storing it (type, range, length): it comes from another player's client.
- **Commands:** `def.command` + `def.commands`, or `self:Command(c)`. A word belongs to whoever registered it first, so pick one no other feature uses (`/arl help` lists them).

### Popups and alerts

Every popup a feature puts on the screen is built the same way, so they look and behave alike in every theme. A popup is a reminder, an alert, a status line or a small control box, such as XP Food's reminder, Sleeping Bag's reminder and timeline, Buff Back's line, Layer Bridge's box, or the alert bar.

- **Build it with `ARLE.UI.Kit.Card(def, spec)`** (`ARLExtensions/UI/Kit.lua`), never from `Skin:CreateTooltipWindow` by hand. The card gives:
  - the themed box with a thin accent edge on the left (`card:SetAccent(r, g, b)`; the theme's accent by default, red for urgent);
  - an optional icon at the top left (`spec.icon = true`);
  - three lines: `card.text` (the message, `GameFontHighlight`, or `spec.titleFont`), `card.sub` (`GameFontNormalSmall`), `card.note` (`GameFontDisableSmall`), all set with `card:SetLines(text, sub, note)`;
  - small buttons at the bottom right (`card:AddButton(label, width, fn)`, right to left in the order added);
  - a height that fits its lines (`card:Fit()`; `SetLines` calls it). Content of your own under the lines adds its height to `card.extra` (Sleeping Bag's bar).
- **Size:** the standard metrics are in `Kit.CARD`: width 280, padding 8, icon 32, accent edge 3, button height 16. Use them, not your own numbers. Change `width` only when the content needs it: Layer Bridge's two buttons take 230, and the alert bar 300. Popups are compact: one short sentence of message, details in `sub` / `note`, longer explanations in a tooltip.
- **Placing:** `spec.move = { x, y, secure, key, onMoved }` makes it draggable through `Kit.Movable`, and the place is kept in `def.char.position` (or `key`). `card.place()` puts it back. The "Reset position" preset clears it (and the alert bar's `alertPos`). Strata is `MEDIUM`, `HIGH` only for the alert bar.
- **Urgent alerts** (in combat, something wrong right now) use the host alert bar: `self:Alert({ text, sub, icon, color, warning, pulse, duration })`, plus `ARLE.UI.Alert:Nag` for the sound, raid warning and taskbar flash, following the feature's `ARLE.Options.Preset.Alert()` settings. Don't build a second alert bar.
- **A clickable icon** (use an item or food) is the host's secure button laid exactly over the card's icon: `Secure:Attach(key, card, { "TOPLEFT", Kit.CARD.pad + Kit.CARD.edge, -Kit.CARD.pad }, Kit.CARD.icon)`. A card holding one is protected, so it's sized, shown and hidden only out of combat (`move.secure = true`, `ARLE.Secure:Run`).
- **Every popup reminder offers a way out:** Dismiss (until the reason changes) and, where it repeats, Snooze; the feature's settings decide whether it shows at all (chat line, on-screen alert).
- **Not popups:** full windows (Quest Search, Darkmoon Tickets, Dungeon Helper, the LFG side panel) use `ARLE.UI.Window` / their own layout, and right-click menus stay menus.

### State and chat

- **Where data lives:** settings in `self.db` (per character, defaults in `options` / `defaults`), this character's data in `self.char`, data every character shares in `self.shared`. Never in another addon's tables, and never as a field written onto someone else's frame or a secure button. Per-frame state goes in a weak-keyed local table.
- **New shared data:** a new `self.shared` key also goes into `SHARED_ONLY` in `Core/DB.lua`, so new characters don't copy it into their settings.
- **Chat:**
  - `self:Print` / `F:Print` (it adds the ARL prefix), never `ARLE:Print` or a local `Say`.
  - A listing prints its indented lines with `print("   ...")`.
  - What's said is in player words: what happened and what to do.
- **Tracing:** `self:Debug(fmt, ...)` at every decision a player could ask "why didn't it...?" about (skipped, waiting, which branch was taken, what was refused). It costs nothing unless `/arl debug <feature>` is on.

### Before you commit

1. Compile every changed file (see "Testing and debugging").
2. Search the changed files for the old ways. Each hit is either rewritten to the standard way or carries a comment saying why not:
   - `SetScript(`, `C_Timer.`, `RegisterEvent(`
   - `issecretvalue`, `ARLE:Print(`, `UnitName("player")`
   - `hooksecurefunc(`, `:HookScript(`
   - a `local function` named `Secret`, `Plain`, `Call` or `SpellName`
   - `CreateTooltipWindow(` outside `ARLExtensions/UI` (a popup that isn't a `Kit.Card`; full windows are fine)
3. Check that the feature's `GetStatus`, its `README.md` row and its AGENTS.md entry still say what it does.
4. Bump the version with `make patch|minor|major` (see "Versioning").

## Conventions

- A feature file opens with a block comment explaining the design: which public surfaces it uses, what it protects, and how it avoids taint; credits the standalone it came from when there is one.
- Defensive API use (with the `Lib` helpers from "Feature standards"): feature-check and `pcall` (`Lib.Call`) APIs that differ between clients (`C_UnitAuras.GetPlayerAuraBySpellID`, `C_Item.GetItemCount` vs `GetItemCount`, `C_Spell.PickupSpell` vs `PickupSpell`, `GetMouseFoci` vs `GetMouseFocus`, `GLOBAL_MOUSE_UP`); guard values with `issecretvalue` where the client may hide them. That includes **tables**: in combat or an instance an aura (`GetAuraDataByIndex`, `GetPlayerAuraBySpellID`), `UNIT_AURA`'s `updateInfo.addedAuras`, or tooltip data can come back as a secret table. `type()` still says "table", but indexing, `ipairs` or comparing a secret number field throws ("table expected, got secret"). Check `issecretvalue(t)` before touching a table from the client, and each field before comparing it.
- **Protected functions**: the client runs Blizzard's modern addon restrictions. Calling a Blizzard-UI-only function (seen so far: `SetRaidTarget`; pings are restricted the same way) shows a "blocked from an action only available to the Blizzard UI" popup even out of combat, and `pcall` doesn't prevent it. Do it through a secure button or macro the player clicks, or leave it out.
- **Taint safety**: never write fields onto another addon's frames or secure buttons; keep per-frame state in weak-keyed local tables. Secure buttons: create, move, show/hide and set attributes only out of combat (`ARLE.Secure:Run` queues past combat; `self:OutOfCombat` is dropped if the feature is turned off first, so disable-time work uses `ARLE.Secure:Run`). Position overlay frames by coordinates, never by anchoring to secure frames.
- **Frames holding a secure button are protected too**: a feature frame that a host button is parented to, or anchored onto, is protected, so in combat the game blocks its SetPoint, SetSize, SetScale, Show/Hide, Enable/Disable and StartMoving with `[ADDON_ACTION_BLOCKED] ... 'UNKNOWN()'`, even while it's hidden (seen 2026-11-17 from Layer Bridge's AutoLayer button). Put such changes in `ARLE.Secure:Run(fn, key)`: with a key, a change repeated in combat runs once afterwards, as its latest version. Lay host buttons with `ARLE.Secure:Attach(key, holder, point, w, h)` and hand them back with `ARLE.Secure:Detach(key, holder, attrs)`. Make a movable box with `ARLE.UI.Kit.Movable(frame, def, { x, y, secure, onMoved })`. It saves the centre offset in `def.char.position`, which the Reset position preset clears. It returns `place()`, and `secure = true` blocks dragging and defers moves in combat.

## Testing and debugging

There is no Lua interpreter or test runner; behavior is tested in-game:
- **Start with ARL's own tools:**
  - `/arl errors`: what ARL caught on this character, per feature, kept across `/reload`.
  - `/arl report`: a copyable window with versions, every feature's state, the errors with stacks, and the trace. Ask the player (or aredpanda) to paste it. A feature can add its own section by defining `def:ReportDetails()` returning a list of lines (Layer Bridge does).
  - `/arl debug <feature>`: traces that feature's decisions in chat and in the report.
  - A feature's status line in `/arl` shows its errors this session.
- From a clone, `make` (= `make package` + `make publish-local`) rebuilds while working; finish every change with `make patch|minor|major` (see "Versioning"). `make` builds `dist/ARLExtensions-<version>.zip` (gitignored, version from `## Version` in `ARLExtensions.toc`) and deploys the working tree to the AddOns folder set by `make setup` (`local.mk`, gitignored), replacing only `ARLExtensions` and the `ARLE_*` folders. If `local.mk` is missing, ask the dev to run `make setup` (it prompts); don't guess the path. A new top-level `ARLE_*` folder is picked up automatically.
- `/reload` picks up Lua changes. A new addon folder or `.toc` change needs a full client restart.
- Turn on Lua errors with `/console scriptErrors 1` (no BugSack/BugGrabber is installed).
- The client writes every Lua error, with its stack and the addon taint is blamed on ("execution tainted by 'X'"), to `..\..\Logs\General.log` (`[E][Lua]` lines), even with scriptErrors off. Group them by message to find the source. This catches what ARL's catcher can't: errors from other addons, taint, and frame scripts set with plain `SetScript`.
- `RegisterEvent` on an event this client doesn't have throws (`LEARNED_SPELL_IN_TAB` doesn't exist here); `self:On` handles it for features.
- Syntax check without the game: Cheat Engine's `C:\Program Files\Cheat Engine 7.5\lua53-64.dll` compiles a file through `luaL_loadbufferx` from PowerShell `Add-Type` (nothing runs). It's Lua 5.3, so also grep for 5.3-only syntax (`goto`, `//`, bitwise operators).
- State checks in game: `/arl` (panel, each feature's status line), `/arl help`, `/arl <cmd>` (status), `/arl <cmd> set` (settings).
- SavedVariables are written to `..\..\WTF\Account\<account>\SavedVariables\` (account-wide: `ARLExtensionsDB`) and `...\<account>\<realm>\<character>\SavedVariables\` (per character: `ARLExtensionsCharDB`), only on logout or `/reload`. Client logs are in `..\..\Logs\`.

## Versioning

Every change to the addon (anything in `ARLExtensions/` or an `ARLE_*` folder) ships as a new version. Make it with the commands, never by editing `## Version` by hand: `make patch`, `make minor` or `make major` sets the same version in every `.toc`, then packages and publishes locally. Bump once per change, when it's done, not on every rebuild while testing (use plain `make` for that). Changes outside the addon folders (Makefile, README, AGENTS.md) don't get a version.

- **patch** (0.1.0 -> 0.1.1): a change to settings or options, a fix or a small tweak to an existing feature.
- **minor** (0.1.1 -> 0.2.0): a new feature (module) is added, or an existing one is overhauled.
- **major** (0.2.0 -> 1.0.0): the extension manager (the host `ARLExtensions/` core: module lifecycle, DB, panel, comm) is reworked, or we explicitly decide to package a bigger release. Don't pick major on your own: propose it and let the user confirm.

When one change mixes levels, use the highest. Commit the bumped `.toc` files with the change they belong to.

## Multi-client TOCs

Some third-party addons ship one TOC per client (`_Camelot`, `_Forever`, `_Vanilla`, `_TBC`, `_Mists`, `_Mainline`). Loader directives like `[AllowLoadGameType camelot]` in WhatsTraining suggest `camelot` is this client's game type. ARL's tocs list `16001, 120105, 120107`.
