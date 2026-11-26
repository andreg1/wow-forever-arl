-- Dungeon Helper, shared parts: the module definition and its options, the
-- data sources, the group, the comms every tab uses, and the row widgets the
-- tabs draw their lists with.
--
-- The window (DungeonHelper.lua) has two panes: a list on the left and the
-- selected entry's details on the right. Three tabs, each in its own file:
--   Loot.lua    Bosses & Loot: bosses, their drops, and who in the party (ARL
--               members) each drop is BiS or an upgrade for
--   Quests.lua  the dungeon's quests, their prerequisites and the rest of
--               their chain, and the party's progress
--   Times.lua   clear times: splits by boss, records, the party's records and
--               the guild leaderboard
--
-- Sources (all read-only, through their public namespaces):
--   DungeonJournal        bosses, loot, quests and their prerequisite chains,
--                         encounter IDs, boss portraits (ForeverDungeonJournal_NS)
--   Forever Leveling BiS  item gains for the player (ForeverLevelingBiS_API);
--                         only Bosses & Loot needs it
--   QuestieDB (optional)  prerequisites DungeonJournal doesn't list, and the
--                         quests that follow (ARLE.Bridge.QuestieDB)
--
-- What is shared, and with whom: only ARL members see any of it (one addon
-- prefix, guild-gated in Core/Comm.lua). The party gets each member's gains
-- for the shown dungeon, quest states and records; the guild gets records
-- only, for the leaderboard (Times.lua).
local ADDON, ns = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end

local H = {}
ns.H = H

local Lib, Kit = ARLE.Lib, ARLE.UI.Kit

local mod = {
  id = "BiSDungeonHelper", -- kept from the BiS Helper so saved settings carry over
  addon = ADDON,
  title = "Dungeon Helper",
  group = "ForeverDungeonJournal",
  extends = "ForeverDungeonJournal",
  command = "dh",
  commandAliases = { "dungeon" },
  commandArgs = "[loot|quests|timers]",
  commandHelp = "opens or closes the Dungeon Helper, optionally on a tab",
  commandSection = "Dungeon Helper",
  mainHelp = "opens or closes the window on the last tab",
  commandUsage = {
    { "dh loot | quests | timers", "opens it on that tab" },
    { "dh reset", "restarts the run timer" },
  },
  description = "Everything about the dungeon you're in, in one small window: its quests (with every quest "
    .. "that leads to them, class quests too), its bosses and their loot (BiS for you from Forever Leveling BiS "
    .. "or GearQuest, and for your ARL partymates), and clear times with the guild's leaderboard.",
  defaults = {
    layout = "compact",
    autoOpen = true,
    openTab = "quests",
    showInGroup = false,
    combat = "hide",
    stayClosed = true,
    openOnPull = false,
    onKill = "open",
    scale = 100,
    maxHeight = 460,
    tab = "quests",
    showShared = true,
    showOther = true,
    useGearQuest = true,
    filter = "all",
    questFilter = "all",
    questShowDone = true,
    questExtras = true,
    timerStart = "pull",
    timerInTitle = true,
    announceRecords = true,
    guildBoard = true,
  },
  pages = { -- child entries in /arl, one per tab of the window
    {
      key = "bis",
      label = "Bosses & Loot",
      notes = "Each boss's drops, and who in the party each one is BiS or an upgrade for.",
    },
    {
      key = "quests",
      label = "Quests",
      notes = "The dungeon's quests and class quests, every quest that leads to them, and the party's progress.",
    },
    {
      key = "times",
      label = "Clear Times",
      notes = "A run timer with splits per boss, your records, and the guild's.",
    },
  },
  panePage = "times", -- the records list goes on the Clear Times entry
  options = {
    { type = "info", text = function(def) return def:GetStatus() end },
    { type = "header", label = "When it shows" },
    { key = "autoOpen", type = "boolean", label = "Open when I enter a dungeon",
      tooltip = "Once per visit: closing it keeps it closed until you leave (see below)." },
    {
      key = "openTab",
      type = "select",
      label = "Open on",
      values = {
        { value = "quests", label = "Quests" },
        { value = "bis", label = "Bosses & Loot" },
        { value = "times", label = "Clear Times" },
        { value = "last", label = "The last tab I used" },
      },
    },
    { key = "showInGroup", type = "boolean", label = "Also open in a group outside dungeons",
      tooltip = "Shows the dungeon your group is going to (pick it with the dungeon menu) while you're grouped "
        .. "in the open world, e.g. to check quests before you go in." },
    {
      key = "combat",
      type = "select",
      label = "In combat",
      values = {
        { value = "hide", label = "Hide it, back after the fight" },
        { value = "fade", label = "Fade it out" },
        { value = "keep", label = "Leave it as it is" },
      },
    },
    { key = "stayClosed", type = "boolean", label = "Closing it keeps it closed until I leave the dungeon",
      tooltip = "Nothing opens it again by itself (a pull, a boss kill) after you closed it, until your next "
        .. "visit. /arl dh still opens it." },
    { type = "header", label = "Key moments" },
    {
      key = "onKill",
      type = "select",
      label = "When a boss dies",
      tooltip = "Rares and optional bosses never open it. Its loot shows on Bosses & Loot while it's rolled.",
      values = {
        { value = "open", label = "Open it on that boss's loot" },
        { value = "shown", label = "Only switch to its loot if it's open" },
        { value = "never", label = "Do nothing" },
      },
    },
    { key = "openOnPull", type = "boolean", label = "Open on the boss when a fight starts",
      tooltip = "Selects the boss you pull on Bosses & Loot (and opens the window, unless it's hidden in "
        .. "combat: then once the fight is over)." },
    { type = "header", label = "Window" },
    {
      key = "layout",
      type = "select",
      label = "Size",
      tooltip = "Compact: one narrow list; picking an entry opens its details beside it. Full: list and "
        .. "details side by side with the dungeon's banner. The window's arrows button switches too.",
      values = {
        { value = "compact", label = "Compact" },
        { value = "full", label = "Full" },
      },
    },
    { key = "scale", type = "range", label = "Scale (%)", min = 70, max = 150, step = 5 },
    { key = "maxHeight", type = "range", label = "Highest it grows (pixels)", min = 240, max = 900, step = 20 },
    ARLE.Options.Preset.ResetPosition(),
    {
      page = "bis",
      key = "useGearQuest",
      type = "boolean",
      label = "Use GearQuest's picks too",
      tooltip = "With GearQuest Forever installed, drops in its top list for your character are marked (its #1 "
        .. "for a slot counts as best in slot), next to Forever Leveling BiS's numbers.",
    },
    {
      page = "bis",
      key = "showShared",
      type = "boolean",
      label = "Include shared boss loot",
      tooltip = "Items with a small chance to drop from many bosses (DungeonJournal's \"Shared Loot\").",
    },
    {
      page = "bis",
      key = "showOther",
      type = "boolean",
      label = "List \"Other loot\" below the bosses",
      tooltip = "Drops from the dungeon's mobs, chests and other spawns (DungeonJournal's Trash Drops and loot "
        .. "chests), and every recipe found in the dungeon. Gear in it counts for BiS and upgrades too.",
    },
    {
      page = "bis",
      key = "filter",
      type = "select",
      label = "Show drops",
      values = {
        { value = "all", label = "All" },
        { value = "party", label = "Party: BiS or an upgrade for someone" },
        { value = "mine", label = "Mine: BiS or an upgrade for you" },
      },
    },
    {
      page = "quests",
      key = "questFilter",
      type = "select",
      label = "Show quests",
      values = {
        { value = "all", label = "All" },
        { value = "todo", label = "To do: not done yet" },
        { value = "party", label = "Party: in someone's quest log" },
        { value = "class", label = "Class quests only" },
      },
    },
    { page = "quests", key = "questShowDone", type = "boolean", label = "List quests you have done (at the bottom)" },
    { page = "quests", key = "questExtras", type = "boolean", label = "Add QuestieDB's quests for the dungeon",
      tooltip = "Quests DungeonJournal doesn't list whose work is in the dungeon: class quests and others, for "
        .. "your class and faction (needs QuestieDB)." },
    {
      page = "times",
      key = "timerStart",
      type = "select",
      label = "Start the timer",
      values = {
        { value = "pull", label = "On the first pull" },
        { value = "enter", label = "When entering the dungeon" },
      },
    },
    {
      page = "times",
      key = "timerInTitle",
      type = "boolean",
      label = "Show the running time on the window",
    },
    {
      page = "times",
      key = "announceRecords",
      type = "boolean",
      label = "Tell me in chat about new records",
    },
    {
      page = "times",
      key = "guildBoard",
      type = "boolean",
      label = "Share my records with the guild leaderboard",
      tooltip = "Your best clear and boss splits go to the ARL members of the guild when you set a record, and "
        .. "when someone looks at that dungeon's leaderboard. Off: you still see theirs, they don't see yours.",
    },
  },
}
ns.mod = mod
H.mod = mod

-- Addon messages: each file names its handlers here, and they're registered
-- through the feature (mod:Comm) when it's turned on, so their errors are
-- caught and listed under it, and they go away when it's turned off.
H.comms = {}
function H.Comm(kind, fn)
  H.comms[#H.comms + 1] = { kind = kind, fn = fn }
end
function H.RegisterComms()
  for _, c in ipairs(H.comms) do
    mod:Comm(c.kind, function(_, sender, payload, channel)
      mod:Debug("got %s from %s on %s (%d chars)", c.kind, tostring(sender), tostring(channel),
        type(payload) == "string" and #payload or 0)
      return c.fn(sender, payload, channel)
    end)
  end
end

-------------------------------------------------------------------------------
-- Sources
-------------------------------------------------------------------------------

H.FDJ = ARLE.Bridge.FDJ
H.FLB = ARLE.Bridge.FLB

-- GearQuest Forever (Henrik8210; no license, so only its public tables are
-- read): its ranked upgrade list per paper-doll slot for this character.
-- GQ.Data:GetTopUpgradesForSlot(slot) -> { { itemId, pipelineScore, ... }, ... },
-- best first (its #1 counts as best in slot here).
local GQ_SLOT = {
  INVTYPE_HEAD = "Head", INVTYPE_NECK = "Neck", INVTYPE_SHOULDER = "Shoulder", INVTYPE_CLOAK = "Back",
  INVTYPE_CHEST = "Chest", INVTYPE_ROBE = "Chest", INVTYPE_WRIST = "Wrist", INVTYPE_HAND = "Hands",
  INVTYPE_WAIST = "Waist", INVTYPE_LEGS = "Legs", INVTYPE_FEET = "Feet", INVTYPE_FINGER = "Finger",
  INVTYPE_TRINKET = "Trinket", INVTYPE_WEAPON = "MainHand", INVTYPE_2HWEAPON = "MainHand",
  INVTYPE_WEAPONMAINHAND = "MainHand", INVTYPE_WEAPONOFFHAND = "SecondaryHand", INVTYPE_SHIELD = "SecondaryHand",
  INVTYPE_HOLDABLE = "SecondaryHand", INVTYPE_RANGED = "Ranged", INVTYPE_RANGEDRIGHT = "Ranged",
  INVTYPE_THROWN = "Ranged", INVTYPE_RELIC = "Ranged",
}
local gqRanks, gqWarned = nil, false

function H.GQ()
  if not mod.db.useGearQuest or not ARLE:IsAddonLoaded("GearQuestForever") then
    return nil
  end
  local gq = rawget(_G, "GearQuest")
  local data = type(gq) == "table" and gq.Data
  if type(data) ~= "table" or type(data.GetTopUpgradesForSlot) ~= "function" then
    if not gqWarned then
      gqWarned = true
      mod:Print("GearQuest Forever has changed (GearQuest.Data.GetTopUpgradesForSlot is missing): its picks "
        .. "aren't shown.")
    end
    return nil
  end
  return data
end

-- GearQuest's rank of an item for this character (1 = its best), or nil.
-- Ranks are read once per slot until H.ClearGQ (gear, level or spec changed).
function H.GQRank(itemID, loc)
  local data = H.GQ()
  local slot = data and GQ_SLOT[loc or ""]
  if not slot then
    return nil
  end
  gqRanks = gqRanks or {}
  local ranks = gqRanks[slot]
  if not ranks then
    ranks = {}
    local ok, list = pcall(data.GetTopUpgradesForSlot, data, slot)
    if ok and type(list) == "table" then
      for i, entry in ipairs(list) do
        local id = type(entry) == "table" and tonumber(entry.itemId)
        if id and not ranks[id] then
          ranks[id] = i
        end
      end
    else
      mod:Debug("GearQuest: no list for %s (%s)", slot, tostring(list))
    end
    gqRanks[slot] = ranks
  end
  return ranks[itemID]
end

function H.ClearGQ()
  gqRanks = nil
  H.gearGen = (H.gearGen or 0) + 1 -- (the picker's per-dungeon counts are worked out again)
end

-- A line in the player's chat box, sent by their own Enter (addons can't
-- post chat on live Forever). Only an empty box is used. chatType: "PARTY",
-- "GUILD", "INSTANCE_CHAT"...
function H.PrefillChat(text, chatType)
  local util = rawget(_G, "ChatFrameUtil")
  local active = (type(util) == "table" and util.GetActiveWindow) or rawget(_G, "ChatEdit_GetActiveWindow")
  local typing = type(active) == "function" and active() or nil
  if typing and (typing:GetText() or "") ~= "" then
    return false
  end
  local open = (type(util) == "table" and util.OpenChat) or rawget(_G, "ChatFrame_OpenChat")
  if type(open) ~= "function" or not pcall(open, text, DEFAULT_CHAT_FRAME) then
    return false
  end
  local box = (type(active) == "function" and active()) or (DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.editBox)
  if box and chatType then
    pcall(box.SetAttribute, box, "chatType", chatType)
    if box.UpdateHeader then
      pcall(box.UpdateHeader, box)
    elseif type(rawget(_G, "ChatEdit_UpdateHeader")) == "function" then
      pcall(ChatEdit_UpdateHeader, box)
    end
  end
  return true
end

local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
H.GetItemInfo = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo
H.GetItemIcon = (C_Item and C_Item.GetItemIconByID) or _G.GetItemIcon
H.GetItemInstant = GetItemInfoInstant

local function EquipLoc(itemID)
  local _, _, _, loc, _, classID = GetItemInfoInstant(itemID)
  if loc and loc ~= "" and loc ~= "INVTYPE_NON_EQUIP_IGNORE" and loc ~= "INVTYPE_BAG"
      and (classID == 2 or classID == 4) then
    return loc
  end
end

local bossCache = {}

-- { { name, aliases, rare, raw, items = { {id, name, quality, loc}, ... } }, ... }
-- in DungeonJournal's own order, the one its Dungeon Tracker uses: the
-- journal's boss list with rares moved after the bosses. Like the tracker,
-- the Altar Bosses' six guardians (childOf) are not listed on their own:
-- they share the group entry's loot. list.parent maps a child's names to its
-- group, so a fight with one of them still finds the group. Every boss is
-- listed, gear drops or not (Clear Times needs them all); items holds only
-- gear.
-- Like DungeonJournal's run tracker (Systems/RunLog.lua AllBossesDown):
-- entry.optional marks the bosses a clear doesn't need (rares, and bosses
-- that need a quest or a summoning item to show up, or are flagged
-- optional), and entry.group is the fight a boss is one of (fightGroup:
-- the Ring of Law's challengers, of which one shows up). list.group maps a
-- fight's name and its bosses' names to the fight; list.npc maps NPC IDs to
-- the name a kill is counted under (the fight, or the Altar group).
function H.Bosses(dungeon)
  local key = dungeon .. (mod.db.showShared and "+s" or "")
  if bossCache[key] then
    return bossCache[key]
  end
  local fdj = H.FDJ()
  local d = fdj and fdj.DB[dungeon]
  local list, rares = { parent = {}, group = {}, npc = {}, kids = {} }, {}
  if not d then
    return list
  end
  for _, boss in ipairs(d.bosses or {}) do
    if type(boss) == "table" and boss.name and boss.childOf then
      list.parent[boss.name:lower()] = boss.childOf
      for _, alias in ipairs(boss.aliases or {}) do
        list.parent[tostring(alias):lower()] = boss.childOf
      end
      if tonumber(boss.npcID) then
        list.npc[tonumber(boss.npcID)] = boss.childOf
        -- (how many must die before the group counts: the Altar's six guardians)
        list.kids[boss.childOf] = (list.kids[boss.childOf] or 0) + 1
      end
    elseif type(boss) == "table" and boss.name and not boss.trash and not boss.recipeTab and not boss.lootChest then
      local group = type(boss.fightGroup) == "string" and boss.fightGroup ~= "" and boss.fightGroup or nil
      local entry = { name = boss.name, aliases = boss.aliases or {}, rare = boss.rare == true, raw = boss, items = {},
        group = group,
        optional = (boss.rare or boss.spawnQuest or boss.summonItem or boss.optional) and true or false }
      if group then
        list.group[group:lower()] = group
        list.group[boss.name:lower()] = group
        for _, alias in ipairs(boss.aliases or {}) do
          list.group[tostring(alias):lower()] = group
        end
      end
      if tonumber(boss.npcID) then
        list.npc[tonumber(boss.npcID)] = group or boss.name
      end
      local seen = {}
      local function Add(item)
        local id = tonumber(item[1])
        local loc = id and EquipLoc(id)
        if loc and not seen[id] then
          seen[id] = true
          entry.items[#entry.items + 1] = { id = id, name = item[2], quality = tonumber(item[4]) or 2, loc = loc }
        end
      end
      for _, item in ipairs(boss.loot or {}) do
        Add(item)
      end
      local shared = mod.db.showShared and fdj.SHARED_BY_BOSS and fdj.SHARED_BY_BOSS[dungeon]
      for _, item in ipairs(shared and shared[boss.name] or {}) do
        Add(item)
      end
      if entry.rare then
        rares[#rares + 1] = entry
      else
        list[#list + 1] = entry
      end
    end
  end
  for _, entry in ipairs(rares) do
    list[#list + 1] = entry
  end
  bossCache[key] = list
  return list
end

local otherCache, gearCache = {}, {}

-- Loot that isn't a boss's own gear: everything from the dungeon's trash and
-- loot chests (DungeonJournal's "Trash Drops", tribute chests...), plus the
-- recipes any boss or mob drops. Quest items and DungeonJournal's own
-- Recipes & Patterns page (a view of the same drops) are left out.
-- { {id, name, quality, loc (gear only), kind, sources = {...}}, ... }:
-- gear first, then the rest, each by quality then name.
function H.OtherLoot(dungeon)
  if otherCache[dungeon] then
    return otherCache[dungeon]
  end
  local fdj = H.FDJ()
  local d = fdj and fdj.DB[dungeon]
  local list, byID = {}, {}
  local function Add(item, source)
    local id = tonumber(item[1])
    if not id then
      return
    end
    local _, _, _, _, _, classID = GetItemInfoInstant(id)
    if classID == 12 or item[3] == "Quest Item" then
      return
    end
    local entry = byID[id]
    if not entry then
      entry = { id = id, name = item[2], quality = tonumber(item[4]) or 1, loc = EquipLoc(id),
        kind = type(item[3]) == "string" and item[3] or nil, sources = {} }
      byID[id] = entry
      list[#list + 1] = entry
    end
    for _, s in ipairs(entry.sources) do
      if s == source then
        return
      end
    end
    entry.sources[#entry.sources + 1] = source
  end
  local function IsRecipe(item)
    local id = tonumber(item[1])
    local classID = id and select(6, GetItemInfoInstant(id))
    return classID == 9 or (type(item[3]) == "string" and item[3]:find("^Recipe") ~= nil)
  end
  for _, boss in ipairs(d and d.bosses or {}) do
    if type(boss) == "table" and boss.name and not boss.recipeTab and type(boss.loot) == "table" then
      for _, item in ipairs(boss.loot) do
        if boss.trash or boss.lootChest then
          -- Trash drops name the mob that drops them (item[5]) when known.
          local mob = type(item[5]) == "string" and item[5] ~= "" and not item[5]:lower():find("trash", 1, true)
            and item[5] or boss.name
          Add(item, mob)
        elseif IsRecipe(item) then
          Add(item, boss.name)
        end
      end
    end
  end
  table.sort(list, function(a, b)
    if (a.loc ~= nil) ~= (b.loc ~= nil) then
      return a.loc ~= nil
    end
    if a.quality ~= b.quality then
      return a.quality > b.quality
    end
    return tostring(a.name) < tostring(b.name)
  end)
  otherCache[dungeon] = list
  return list
end

-- Every gear item the dungeon can drop that the BiS Finder scores: the
-- bosses' gear, and the gear in Other loot (when that section is on).
function H.GearItems(dungeon)
  local key = dungeon .. (mod.db.showShared and "+s" or "") .. (mod.db.showOther and "+o" or "")
  if gearCache[key] then
    return gearCache[key]
  end
  local items = {}
  for _, boss in ipairs(H.Bosses(dungeon)) do
    for _, item in ipairs(boss.items) do
      items[#items + 1] = item
    end
  end
  if mod.db.showOther then
    for _, item in ipairs(H.OtherLoot(dungeon)) do
      if item.loc then
        items[#items + 1] = item
      end
    end
  end
  gearCache[key] = items
  return items
end

function H.ClearBossCache()
  wipe(bossCache)
  wipe(otherCache)
  wipe(gearCache)
end

function H.Dungeons()
  local fdj = H.FDJ()
  local names = {}
  for name, d in pairs(fdj and fdj.DB or {}) do
    if type(d) == "table" and type(d.bosses) == "table" then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

function H.CurrentDungeon()
  local fdj = H.FDJ()
  if fdj and fdj.CurrentDungeon then
    local ok, name = pcall(fdj.CurrentDungeon)
    if ok and name and fdj.DB[name] then
      return name
    end
  end
end

-- Which boss of which dungeon an encounter is: DungeonJournal's encounter
-- table first, then the boss names and aliases of the shown and current
-- dungeons. Altar guardians resolve to their group, a fight's bosses (the
-- Ring of Law) to the fight. The third value is the encounter's other bosses
-- (DungeonJournal's "also": Gyth with Rend), or nil.
function H.BossFor(encounterID, encounterName)
  local fdj = H.FDJ()
  local byID = fdj and type(fdj.RUNLOG_ENCOUNTERS) == "table" and fdj.RUNLOG_ENCOUNTERS[encounterID]
  if type(byID) == "table" and byID[1] and byID[2] then
    local list = H.Bosses(byID[1])
    local lower = tostring(byID[2]):lower()
    return byID[1], list.parent[lower] or list.group[lower] or byID[2], type(byID.also) == "table" and byID.also or nil
  end
  local wanted = (type(encounterName) == "string" and encounterName or ""):lower()
  if wanted == "" then
    return nil
  end
  for _, dungeon in ipairs(H.LookupDungeons(false)) do
    local name = H.ResolveBoss(dungeon, wanted)
    if name then
      return dungeon, name
    end
  end
end

-- The name a kill of `name` (any case) counts under in a dungeon, or nil.
function H.ResolveBoss(dungeon, name)
  local list = dungeon and H.Bosses(dungeon)
  local wanted = type(name) == "string" and name:lower()
  if not list or not wanted then
    return nil
  end
  if list.parent[wanted] then
    return list.parent[wanted]
  end
  if list.group[wanted] then
    return list.group[wanted]
  end
  for _, boss in ipairs(list) do
    if boss.name:lower() == wanted then
      return boss.group or boss.name
    end
    for _, alias in ipairs(boss.aliases) do
      if tostring(alias):lower() == wanted then
        return boss.group or boss.name
      end
    end
  end
end

-- A value the client may hand over as "secret" (newer clients): nil then.
H.Plain = Lib.Plain

-- Creature-0-server-map-zoneUID-npcID-spawnUID: npcID, the instance copy
-- ("server:zoneUID", as DungeonJournal's run log reads it), the map ID.
function H.ParseGUID(guid)
  guid = H.Plain(guid)
  if type(guid) ~= "string" then
    return nil
  end
  local kind, _, server, map, zone, npc = strsplit("-", guid)
  if kind ~= "Creature" and kind ~= "Vehicle" then
    return nil
  end
  npc = tonumber(npc)
  if not npc then
    return nil
  end
  return npc, tostring(server) .. ":" .. tostring(zone), tonumber(map)
end

-- Which boss an NPC ID is, in the current dungeon (then the shown one).
function H.BossForNPC(npc)
  if not npc then
    return nil
  end
  for _, dungeon in ipairs(H.LookupDungeons(true)) do
    local name = H.Bosses(dungeon).npc[npc]
    if name then
      return dungeon, name
    end
  end
end

-- The shown and the current dungeon (current first when asked), without
-- gaps: ipairs stops at the first nil.
function H.LookupDungeons(currentFirst)
  local shown, current = H.shown, H.CurrentDungeon()
  local list = {}
  for _, d in ipairs(currentFirst and { current or false, shown or false } or { shown or false, current or false }) do
    if d and d ~= list[1] then
      list[#list + 1] = d
    end
  end
  return list
end

-- A boss's face, the way DungeonJournal finds it, from its public data only:
-- its own icon, a display ID it lists or has resolved before, or a portrait
-- it captured. A skull when it knows none.
local SKULL = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull"
function H.SetPortrait(tex, boss)
  tex:SetTexCoord(0, 1, 0, 1)
  local raw = boss and boss.raw or {}
  if raw.customIcon then
    tex:SetTexture(raw.customIcon)
    return
  end
  local fdj = H.FDJ() or {}
  local sv = type(_G.ForeverDungeonJournalDB) == "table" and _G.ForeverDungeonJournalDB or {}
  local npc = raw.npcID or raw.portraitNpcID
  local display = raw.displayID
    or (npc and fdj.STATIC_DISPLAY_IDS and fdj.STATIC_DISPLAY_IDS[npc])
    or (npc and type(sv.displayIDs) == "table" and tonumber(sv.displayIDs[npc]))
  if type(display) == "number" and display > 0 then
    if fdj.SetBakedPortrait then
      local ok, done = pcall(fdj.SetBakedPortrait, tex, display)
      if ok and done then
        return
      end
    end
    if SetPortraitTextureFromCreatureDisplayID and pcall(SetPortraitTextureFromCreatureDisplayID, tex, display) then
      return
    end
  end
  local captured = npc and type(sv.portraitTexturesByNpcID) == "table" and sv.portraitTexturesByNpcID[npc]
  if captured then
    tex:SetTexture(captured)
    tex:SetTexCoord(0.04, 0.96, 0.04, 0.96)
    return
  end
  tex:SetTexture(SKULL)
end

-------------------------------------------------------------------------------
-- Group
-------------------------------------------------------------------------------

H.Me = Lib.Me
H.Members = Lib.Members

-------------------------------------------------------------------------------
-- Comms: one query ("BQ <dungeon>") asks the group for everything each tab
-- shares about a dungeon; every tab answers with its own message kinds.
-------------------------------------------------------------------------------

H.tabs = {} -- filled by Loot.lua, Quests.lua, Times.lua, in that order

-- Splits "head~<part>~<total>~<list>" messages into as many as it takes.
function H.SendChunks(kind, head, items, sep, channel)
  ARLE:SendChunks(kind, head, items, sep, channel)
end

local sendTimers = {}
function H.ResetSends()
  wipe(sendTimers)
end
-- Sends every tab's data for a dungeon (or only one tab's), a moment from now,
-- once per burst. Tabs may skip sending what they sent last time, unless
-- forced (someone asked, or the group changed).
function H.QueueSend(dungeon, only, force)
  if not dungeon then
    return
  end
  local key = dungeon .. "\0" .. (only or "")
  local pending = sendTimers[key]
  if pending then
    pending.force = pending.force or force
    return
  end
  pending = { force = force }
  sendTimers[key] = pending
  mod:After(1.5, function()
    sendTimers[key] = nil
    local channel = ARLE:GroupChannel()
    if not channel then
      return
    end
    for _, tab in ipairs(H.tabs) do
      if tab.Send and (not only or only == tab.key) then
        tab:Send(dungeon, channel, pending.force)
      end
    end
  end)
end

-- Ask the group for their data on the shown dungeon, and send ours.
function H.Request()
  local channel = ARLE:GroupChannel()
  if channel and H.shown then
    local names = {}
    for _, m in ipairs(H.Members()) do
      names[#names + 1] = tostring(m.name)
    end
    mod:Debug("asking %s for %s; group: %s", channel, H.shown, table.concat(names, ", "))
    H.askedAt = GetTime()
    ARLE:Send("BQ", H.shown, channel)
    H.QueueSend(H.shown, nil, true)
  end
end

H.Comm("BQ", function(_, dungeon)
  if mod._active and H.FDJ() and H.FDJ().DB[dungeon] then
    H.QueueSend(dungeon, nil, true)
  end
end)

-- With the Dungeon Helper off, the pack is still loaded for this (host's
-- LoadBackgroundPacks: Leveling BiS and DungeonJournal installed, Settings'
-- "Share my Leveling BiS numbers" on): a partymate's question about a
-- dungeon is answered with this player's gains and equipped items only, so
-- the group leader's numbers don't depend on everyone turning it on. Item
-- data still loading is sent again as it arrives (a few tries).
local backgroundAt = {}
local function BackgroundSend(dungeon, tries)
  if mod._active or not ARLE:SharesLoot() or not H.FLB() then
    return
  end
  local channel = ARLE:GroupChannel()
  local bis
  for _, t in ipairs(H.tabs) do
    if t.key == "bis" then
      bis = t
    end
  end
  if not channel or not bis or not bis.Send then
    return
  end
  bis:Send(dungeon, channel, tries == 0)
  if bis.Loading and bis.Loading(dungeon) and tries < 6 then
    C_Timer.After(3, function()
      local ok, err = pcall(BackgroundSend, dungeon, tries + 1)
      if not ok then
        ARLE.Debug:Record(mod, err)
      end
    end)
  end
end
ARLE:RegisterComm("BQ", function(_, dungeon, channel)
  if mod._active or channel == "GUILD" or channel == "WHISPER" or not ARLE:SharesLoot() then
    return
  end
  if not (H.FLB() and H.FDJ() and H.FDJ().DB[dungeon]) then
    return
  end
  -- (one answer per dungeon per few seconds: several members may ask at once)
  if backgroundAt[dungeon] and GetTime() - backgroundAt[dungeon] < 5 then
    return
  end
  backgroundAt[dungeon] = GetTime()
  C_Timer.After(1 + math.random(), function()
    local ok, err = pcall(BackgroundSend, dungeon, 0)
    if not ok then
      ARLE.Debug:Record(mod, err)
    end
  end)
end)

-- Why a partymate shares no quests or times (those need their Dungeon Helper
-- on, unlike loot numbers): a few words for a row or tooltip.
function H.Quiet(m)
  local info = ARLE:PartyInfo(m.name)
  if not info then
    local known = ARLE.KnownVersion and ARLE.KnownVersion(m.name)
    return known and ("ARL v" .. known .. "?") or "no ARL"
  end
  return info.dh and "no answer yet" or "Dungeon Helper off"
end

-- A partymate's presence (Core/Comm.lua "AP") can change why they have no
-- numbers: redraw.
ARLE:RegisterComm("AP", function()
  if mod._active then
    H.Render()
  end
end)

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

function H.Render()
  -- replaced by the window (DungeonHelper.lua)
end

-- Sets a script on one of our own frames, its errors caught (Feature:Script).
function H.Script(frame, script, fn)
  mod:Script(frame, script, fn)
end

H.ClassColor = Lib.ClassColor
H.ColorName = Lib.ColorName
H.QualityColor = Lib.QualityColor
H.TooltipSide = Kit.TooltipSide
H.SimpleTooltip = Kit.SimpleTooltip
H.SmallButton = Kit.SmallButton
H.FormatTime = Lib.FormatTime
H.FormatDelta = Lib.FormatDelta
H.Now = Lib.Now

-- A row of filter buttons; picking one redraws the window.
function H.FilterButtons(bar, list, get, set)
  return Kit.FilterButtons(bar, list, get, function(key)
    set(key)
    H.Render()
  end)
end

-- A tooltip on hover for one of our frames.
function H.Tip(frame, title, text)
  H.Script(frame, "OnEnter", function(self)
    H.SimpleTooltip(self, type(title) == "function" and title(self) or title,
      type(text) == "function" and text(self) or text)
  end)
  H.Script(frame, "OnLeave", GameTooltip_Hide)
end


-------------------------------------------------------------------------------
-- Widgets, the same in every tab and both panes. The look is ARL's flat skin
-- (1px edges, the accent colour) with the game's own art for what a player
-- reads at a glance: boss portraits, item icons edged in their quality
-- colour, class icons, quest marks, the raid-target star. Words go into
-- tooltips; the rows carry pictures, numbers and short tags.
--   H.Edge(frame)          a 1px edge around a frame (H.SetEdge recolours it)
--   H.Pic(parent, size)    a framed picture: portrait, item or quest icon,
--                          with an optional corner mark and a bottom label
--   H.Section(parent)      a section header: accent label, a rule, a note
--   H.Row(parent, h, pic)  a clickable row: picture, name over a sub line (or
--                          a progress bar), a note (and a line under it) on
--                          the right, and member marks: class icons, gold-
--                          edged = strong (BiS, ready), faded = weak
--   H.Bar(parent)          a thin progress bar
--   H.Badge(parent)        a small tag: tinted fill, optional icon, text
--   H.Tile(parent)         a stat tile: a big value over a small label
--   H.Banner(parent)       the details' header: big picture, title, tags
-- Lists keep their widgets in a pool and Place them top to bottom.
-------------------------------------------------------------------------------

H.MARK, H.MAX_MARKS = 14, 5

-- Art from the game (every client has these).
H.ICON = {
  star = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1",
  skull = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8",
  bossSkull = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull",
  ready = "Interface\\RaidFrame\\ReadyCheck-Ready",
  waiting = "Interface\\RaidFrame\\ReadyCheck-Waiting",
  no = "Interface\\RaidFrame\\ReadyCheck-NotReady",
  available = "Interface\\GossipFrame\\AvailableQuestIcon",
  active = "Interface\\GossipFrame\\ActiveQuestIcon",
  lock = "Interface\\PetBattles\\PetBattle-LockIcon",
  dungeon = "Interface\\Minimap\\Dungeon",
  watch = "Interface\\Icons\\INV_Misc_PocketWatch_01",
  bag = "Interface\\Icons\\INV_Misc_Bag_10",
  scroll = "Interface\\Icons\\INV_Misc_Note_01",
  cog = "Interface\\Icons\\INV_Misc_Gear_01",
  class = "Interface\\Icons\\INV_Misc_Book_09",
}

-- Inline art for a FontString: |T...|t.
function H.Inline(path, size)
  size = size or 12
  return "|T" .. path .. ":" .. size .. ":" .. size .. "|t"
end

local GREEN, GOLD, GREY = { 0.4, 1, 0.45 }, { 1, 0.82, 0 }, { 0.6, 0.6, 0.6 }
H.GREEN, H.GOLD, H.GREY = GREEN, GOLD, GREY

local EDGES = {
  { "TOPLEFT", "TOPRIGHT", false },
  { "BOTTOMLEFT", "BOTTOMRIGHT", false },
  { "TOPLEFT", "BOTTOMLEFT", true },
  { "TOPRIGHT", "BOTTOMRIGHT", true },
}

function H.Edge(frame, layer)
  frame.edge = {}
  for i, e in ipairs(EDGES) do
    local t = frame:CreateTexture(nil, layer or "BORDER")
    t:SetPoint(e[1])
    t:SetPoint(e[2])
    if e[3] then
      t:SetWidth(1)
    else
      t:SetHeight(1)
    end
    frame.edge[i] = t
  end
  H.SetEdge(frame, 0, 0, 0, 1)
end

function H.SetEdge(frame, r, g, b, a)
  for _, t in ipairs(frame.edge or {}) do
    t:SetColorTexture(r, g, b, a or 1)
  end
end

-- Class icon (the character-creation sheet), or a class-coloured square on
-- a client without the coordinates.
local CLASS_SHEET = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"
function H.SetClassIcon(tex, class)
  local c = class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
  if c then
    tex:SetTexture(CLASS_SHEET)
    tex:SetTexCoord(c[1] + 0.015, c[2] - 0.015, c[3] + 0.015, c[4] - 0.015)
  else
    tex:SetTexCoord(0, 1, 0, 1)
    tex:SetColorTexture(H.ClassColor(class))
  end
end

-- A framed picture. pic.tex is the texture (H.SetPortrait works on it);
-- pic.corner a small mark at the bottom right; pic.label a line over the
-- bottom edge.
function H.Pic(parent, size)
  local p = CreateFrame("Frame", nil, parent)
  p:SetSize(size, size)
  p.back = p:CreateTexture(nil, "BACKGROUND")
  p.back:SetAllPoints()
  p.back:SetColorTexture(0, 0, 0, 0.6)
  p.tex = p:CreateTexture(nil, "ARTWORK")
  p.tex:SetPoint("TOPLEFT", 1, -1)
  p.tex:SetPoint("BOTTOMRIGHT", -1, 1)
  H.Edge(p, "OVERLAY")
  p.corner = p:CreateTexture(nil, "OVERLAY", nil, 2)
  local c = math.max(math.floor(size * 0.45), 10)
  p.corner:SetSize(c, c)
  p.corner:SetPoint("BOTTOMRIGHT", 3, -3)
  p.corner:Hide()
  p.label = Kit.Text(p, "NumberFontNormalSmall")
  p.label:SetPoint("BOTTOMRIGHT", -1, 2)
  p.label:SetJustifyH("RIGHT")
  return p
end

-- An icon (item, spell, quest mark) in the picture, trimmed of its border.
function H.SetIcon(pic, path, trim)
  pic.tex:SetDesaturated(false)
  pic.tex:SetVertexColor(1, 1, 1)
  pic.tex:SetTexture(path or 134400)
  if trim == false then
    pic.tex:SetTexCoord(0, 1, 0, 1)
  else
    pic.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  end
end

-- An item's icon, edged in its quality colour.
function H.SetItemPic(pic, itemID, quality)
  H.SetIcon(pic, H.GetItemIcon(itemID) or 134400)
  local r, g, b = H.QualityColor(quality or 1)
  H.SetEdge(pic, r, g, b, 0.9)
end

function H.SetCorner(pic, path)
  if path then
    pic.corner:SetTexture(path)
    pic.corner:Show()
  else
    pic.corner:Hide()
  end
end

-------------------------------------------------------------------------------
-- Section header: LABEL ───────────── note
-------------------------------------------------------------------------------

function H.Section(parent)
  local h = CreateFrame("Button", nil, parent)
  h:SetHeight(20)
  h.icon = h:CreateTexture(nil, "ARTWORK")
  h.icon:SetSize(14, 14)
  h.icon:SetPoint("LEFT", 4, 0)
  h.icon:Hide()
  h.label = Kit.Text(h, "GameFontNormal")
  h.label:SetWordWrap(false)
  h.note = Kit.Text(h, "GameFontHighlightSmall")
  h.note:SetPoint("RIGHT", -4, 0)
  h.note:SetJustifyH("RIGHT")
  h.rule = h:CreateTexture(nil, "ARTWORK")
  h.rule:SetHeight(1)
  h.rule:SetPoint("LEFT", h.label, "RIGHT", 6, 0)
  h.rule:SetPoint("RIGHT", h.note, "LEFT", -6, 0)
  return h
end

-- label, note, icon (texture path, "atlas:<name>" or nil)
function H.PaintSection(h, label, note, icon)
  local ar, ag, ab = ARLE.Skin:Accent()
  h.label:SetText(label)
  h.label:SetTextColor(ar, ag, ab)
  h.rule:SetColorTexture(ar, ag, ab, 0.3)
  h.note:SetText(note or "")
  h.label:ClearAllPoints()
  if icon then
    h.icon:Show()
    if not (type(icon) == "string" and icon:find("^atlas:") and h.icon.SetAtlas
        and pcall(h.icon.SetAtlas, h.icon, icon:sub(7))) then
      local path = type(icon) == "string" and (icon:gsub("^atlas:", "")) or icon
      h.icon:SetTexture(path)
    end
    h.label:SetPoint("LEFT", h.icon, "RIGHT", 4, 0)
  else
    h.icon:Hide()
    h.label:SetPoint("LEFT", 4, 0)
  end
end

-------------------------------------------------------------------------------
-- Progress bar
-------------------------------------------------------------------------------

function H.Bar(parent)
  local b = CreateFrame("Frame", nil, parent)
  b:SetSize(60, 5)
  b.back = b:CreateTexture(nil, "BACKGROUND")
  b.back:SetAllPoints()
  b.back:SetColorTexture(1, 1, 1, 0.1)
  b.fill = b:CreateTexture(nil, "ARTWORK")
  b.fill:SetPoint("TOPLEFT")
  b.fill:SetPoint("BOTTOMLEFT")
  return b
end

-- value/max filled, in r, g, b (the accent when not given).
function H.SetBar(b, value, max, r, g, b2)
  local frac = (max and max > 0) and math.min(math.max((value or 0) / max, 0), 1) or 0
  if not r then
    r, g, b2 = ARLE.Skin:Accent()
  end
  b.fill:SetColorTexture(r, g, b2, 0.9)
  b.fill:SetWidth(math.max((b.width or b:GetWidth() or 0) * frac, 0.01))
  b.fill:SetShown(frac > 0)
end

-------------------------------------------------------------------------------
-- Badge: a small tag
-------------------------------------------------------------------------------

function H.Badge(parent)
  local b = CreateFrame("Frame", nil, parent)
  b:SetHeight(16)
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints()
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetSize(12, 12)
  b.icon:SetPoint("LEFT", 3, 0)
  b.text = Kit.Text(b, "GameFontHighlightSmall")
  b.text:SetWordWrap(false)
  return b
end

-- spec = { text, color = {r,g,b}, icon, tip = {title, text} }. Returns its width.
function H.PaintBadge(b, spec)
  local c = spec.color or GREY
  b.bg:SetColorTexture(c[1], c[2], c[3], 0.16)
  b.text:SetTextColor(c[1], c[2], c[3])
  b.text:SetText(spec.text or "")
  b.text:ClearAllPoints()
  if spec.icon then
    b.icon:SetTexture(spec.icon)
    b.icon:Show()
    b.text:SetPoint("LEFT", b.icon, "RIGHT", 2, 0)
  else
    b.icon:Hide()
    b.text:SetPoint("LEFT", 5, 0)
  end
  local w = math.ceil((b.text:GetStringWidth() or 20) + (spec.icon and 22 or 10))
  b:SetWidth(w)
  b.tip = spec.tip
  b:EnableMouse(spec.tip ~= nil)
  if spec.tip and not b.tipSet then
    b.tipSet = true
    H.Tip(b, function(self)
      return self.tip and self.tip[1] or ""
    end, function(self)
      return self.tip and self.tip[2]
    end)
  end
  b:Show()
  return w
end

-- Lays badges left to right from a point; returns the pool's count used.
function H.LayBadges(pool, anchor, point, relPoint, x, y, specs, maxWidth)
  local used, prev = 0, nil
  for _, spec in ipairs(specs or {}) do
    local b = pool:Get()
    local w = H.PaintBadge(b, spec)
    b:ClearAllPoints()
    if prev then
      b:SetPoint("LEFT", prev, "RIGHT", 4, 0)
    else
      b:SetPoint(point, anchor, relPoint, x, y)
    end
    used = used + w + 4
    if maxWidth and used > maxWidth then
      b:Hide()
    end
    prev = b
  end
  return used
end

-------------------------------------------------------------------------------
-- Stat tile: a big value over a small label
-------------------------------------------------------------------------------

function H.Tile(parent)
  local t = CreateFrame("Frame", nil, parent)
  t:SetHeight(42)
  t.bg = t:CreateTexture(nil, "BACKGROUND")
  t.bg:SetAllPoints()
  H.Edge(t)
  t.value = Kit.Text(t, "GameFontHighlightLarge")
  t.value:SetPoint("TOP", 0, -6)
  t.value:SetJustifyH("CENTER")
  t.label = Kit.Text(t, "GameFontDisableSmall")
  t.label:SetPoint("BOTTOM", 0, 5)
  t.label:SetJustifyH("CENTER")
  return t
end

-- tiles = { {value, label, color, tip}, ... } in one row: y = Tiles(pool, y, width, tiles)
function H.Tiles(pool, y, width, tiles)
  local n = #tiles
  if n == 0 then
    return y
  end
  local ar, ag, ab = ARLE.Skin:Accent()
  local gap = 4
  local w = (width - 12 - (n - 1) * gap) / n
  for i, spec in ipairs(tiles) do
    local t = pool:Get()
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", 6 + (i - 1) * (w + gap), -y)
    t:SetWidth(w)
    t.bg:SetColorTexture(ar, ag, ab, spec.strong and 0.14 or 0.06)
    H.SetEdge(t, ar, ag, ab, spec.strong and 0.5 or 0.18)
    t.value:SetText(spec.value or "")
    local c = spec.color
    t.value:SetTextColor(c and c[1] or 1, c and c[2] or 1, c and c[3] or 1)
    t.label:SetText(spec.label or "")
    t.label:SetWidth(w - 6)
    t.label:SetWordWrap(false)
    t.tip = spec.tip
    t:EnableMouse(spec.tip ~= nil)
    if spec.tip and not t.tipSet then
      t.tipSet = true
      H.Tip(t, function(self)
        return self.tip and self.tip[1] or ""
      end, function(self)
        return self.tip and self.tip[2]
      end)
    end
    t:Show()
  end
  return y + 42 + 6
end

-------------------------------------------------------------------------------
-- Rows
-------------------------------------------------------------------------------

function H.Row(parent, height, picture)
  local r = CreateFrame("Button", nil, parent)
  r:SetHeight(height)
  r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  r.bg = r:CreateTexture(nil, "BACKGROUND")
  r.bg:SetAllPoints()
  r.bg:SetColorTexture(0, 0, 0, 0)
  r.bar = r:CreateTexture(nil, "ARTWORK")
  r.bar:SetWidth(2)
  r.bar:SetPoint("TOPLEFT", 0, 0)
  r.bar:SetPoint("BOTTOMLEFT", 0, 0)
  r.bar:Hide()
  local size = picture or (height - 6)
  r.pic = H.Pic(r, size)
  r.pic:SetPoint("LEFT", 6, 0)
  r.name = Kit.Text(r, height >= 26 and "GameFontHighlight" or "GameFontHighlightSmall")
  r.name:SetWordWrap(false)
  r.sub = Kit.Text(r, "GameFontDisableSmall")
  r.sub:SetWordWrap(false)
  r.note = Kit.Text(r, height >= 26 and "GameFontHighlight" or "GameFontHighlightSmall")
  r.note:SetJustifyH("RIGHT")
  r.noteSub = Kit.Text(r, "GameFontDisableSmall")
  r.noteSub:SetJustifyH("RIGHT")
  r.markIcons = {}
  for k = 1, H.MAX_MARKS do
    local edge = r:CreateTexture(nil, "ARTWORK")
    edge:SetSize(H.MARK + 2, H.MARK + 2)
    edge:SetPoint("RIGHT", -(6 + (k - 1) * (H.MARK + 4)), 0)
    edge:SetColorTexture(1, 0.82, 0, 1)
    local icon = r:CreateTexture(nil, "OVERLAY")
    icon:SetSize(H.MARK, H.MARK)
    icon:SetPoint("CENTER", edge, "CENTER")
    r.markIcons[k] = { edge = edge, icon = icon }
  end
  r.more = Kit.Text(r, "GameFontDisableSmall")
  r.more:SetPoint("RIGHT", -(6 + H.MAX_MARKS * (H.MARK + 4)), 0)
  r.hl = r:CreateTexture(nil, "HIGHLIGHT")
  r.hl:SetAllPoints()
  r.hl:SetColorTexture(1, 1, 1, 0.06)
  return r
end

-- o = {
--   name, sub, note, noteSub,       texts (sub: under the name; noteSub: under the note)
--   color = {r,g,b},                the name's colour (white)
--   marks = { {class, strong, weak}, ... },
--   progress = {have, need, r,g,b}, a bar under the name, the sub after it
--   selected, dim,                  the accent bar and tint; faded
--   tint = {r,g,b,a},               a background tint when not selected
-- }
function H.PaintRow(r, o)
  local ar, ag, ab = ARLE.Skin:Accent()
  local marks = o.marks or {}
  local n = math.min(#marks, H.MAX_MARKS)
  for k = 1, H.MAX_MARKS do
    local sq, mk = r.markIcons[k], marks[k]
    if mk and k <= n then
      H.SetClassIcon(sq.icon, mk.class)
      sq.icon:SetDesaturated(mk.weak and true or false)
      sq.icon:SetAlpha(mk.weak and 0.45 or 1)
      sq.icon:Show()
      sq.edge:SetShown(mk.strong and true or false)
    else
      sq.icon:Hide()
      sq.edge:Hide()
    end
  end
  local extra = #marks - n
  r.more:SetText(extra > 0 and ("+" .. extra) or "")
  local right = 6 + n * (H.MARK + 4) + (extra > 0 and 16 or 0) + (n > 0 and 2 or 0)

  local two = (o.sub and o.sub ~= "") or o.progress ~= nil
  local noteTwo = o.noteSub and o.noteSub ~= ""
  r.note:SetText(o.note or "")
  r.noteSub:SetText(o.noteSub or "")
  r.note:ClearAllPoints()
  r.note:SetPoint("RIGHT", r, "RIGHT", -right, noteTwo and 6 or 0)
  r.noteSub:ClearAllPoints()
  r.noteSub:SetPoint("RIGHT", r, "RIGHT", -right, -7)
  r.noteSub:SetShown(noteTwo and true or false)
  local noteW = math.max(r.note:GetStringWidth() or 0, noteTwo and (r.noteSub:GetStringWidth() or 0) or 0)
  local nameRight = right + (noteW > 0 and (noteW + 8) or 2)

  r.name:SetText(o.name or "")
  r.name:ClearAllPoints()
  r.name:SetPoint("LEFT", r.pic, "RIGHT", 7, two and 7 or 0)
  r.name:SetPoint("RIGHT", r, "RIGHT", -nameRight, two and 7 or 0)
  local c = o.color
  local fade = o.dim and 0.55 or 1
  r.name:SetTextColor((c and c[1] or 1) * fade, (c and c[2] or 1) * fade, (c and c[3] or 1) * fade)

  r.sub:ClearAllPoints()
  if o.progress then
    if not r.prog then
      r.prog = H.Bar(r)
    end
    local p = o.progress
    r.prog:ClearAllPoints()
    r.prog:SetPoint("LEFT", r.pic, "RIGHT", 7, -7)
    r.prog:SetWidth(56)
    r.prog:Show()
    H.SetBar(r.prog, p[1], p[2], p[3], p[4], p[5])
    r.sub:SetPoint("LEFT", r.prog, "RIGHT", 5, 0)
  else
    if r.prog then
      r.prog:Hide()
    end
    r.sub:SetPoint("LEFT", r.pic, "RIGHT", 7, -7)
  end
  r.sub:SetPoint("RIGHT", r, "RIGHT", -nameRight, -7)
  r.sub:SetText(o.sub or "")
  r.sub:SetShown(two and true or false)

  r.pic:SetAlpha(o.dim and 0.55 or 1)
  r.pic.tex:SetDesaturated(o.dim and true or false)
  r.bar:SetColorTexture(ar, ag, ab, 1)
  r.bar:SetShown(o.selected and true or false)
  if o.selected then
    r.bg:SetColorTexture(ar, ag, ab, 0.16)
  elseif o.tint then
    r.bg:SetColorTexture(o.tint[1], o.tint[2], o.tint[3], o.tint[4] or 0.08)
  else
    r.bg:SetColorTexture(0, 0, 0, 0)
  end
end

-------------------------------------------------------------------------------
-- Banner: the details' header
--   [picture] Title
--             [tag] [tag] [tag]
-------------------------------------------------------------------------------

H.BANNER_H = 60

function H.Banner(parent, size)
  local b = CreateFrame("Frame", nil, parent)
  b:SetHeight(H.BANNER_H)
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints()
  b.line = b:CreateTexture(nil, "ARTWORK")
  b.line:SetHeight(1)
  b.line:SetPoint("BOTTOMLEFT")
  b.line:SetPoint("BOTTOMRIGHT")
  b.pic = H.Pic(b, size or 48)
  b.pic:SetPoint("LEFT", 6, 0)
  b.title = Kit.Text(b, "GameFontNormalLarge")
  b.title:SetPoint("TOPLEFT", b.pic, "TOPRIGHT", 9, -3)
  b.title:SetWordWrap(false)
  b.badges = H.Pool(function()
    return H.Badge(b)
  end)
  return b
end

-- title, color ({r,g,b}; the accent when nil), badges (specs), rightInset
-- (room kept for buttons at the top right). The picture is the caller's.
function H.PaintBanner(b, title, color, badges, rightInset)
  local ar, ag, ab = ARLE.Skin:Accent()
  b.bg:SetColorTexture(ar, ag, ab, 0.07)
  b.line:SetColorTexture(ar, ag, ab, 0.35)
  b.title:SetText(title or "")
  b.title:SetPoint("RIGHT", b, "RIGHT", -(rightInset or 6), 0)
  if color then
    b.title:SetTextColor(color[1], color[2], color[3])
  else
    b.title:SetTextColor(ar, ag, ab)
  end
  local maxW = (b:GetWidth() or 300) - (b.pic:GetWidth() or 48) - 20
  H.LayBadges(b.badges, b.pic, "BOTTOMLEFT", "BOTTOMRIGHT", 9, 4, badges, maxW)
  b.badges:Done()
  b:Show()
end

-------------------------------------------------------------------------------
-- Layout
-------------------------------------------------------------------------------

-- Places frames top to bottom in a pane: y = Place(frame, y, height, gap).
function H.Place(frame, y, height, gap)
  frame:ClearAllPoints()
  frame:SetPoint("TOPLEFT", 0, -y)
  frame:SetPoint("RIGHT")
  frame:Show()
  return y + height + (gap or 1)
end

-- A pool of widgets made on demand: pool:Get() for the next, pool:Done()
-- hides the ones not used since the last Done.
function H.Pool(make)
  local pool = { used = 0, list = {} }
  function pool:Get()
    self.used = self.used + 1
    local w = self.list[self.used]
    if not w then
      w = make()
      self.list[self.used] = w
    end
    return w
  end
  function pool:Done()
    for i = self.used + 1, #self.list do
      self.list[i]:Hide()
    end
    self.used = 0
  end
  return pool
end

-- A paragraph of text in a pane: y = Para(fs, y, width, text, gap, indent).
-- The width is set outright, so the height is right before the pane is laid
-- out.
function H.Para(fs, y, width, text, gap, indent)
  indent = indent or 6
  fs:ClearAllPoints()
  fs:SetPoint("TOPLEFT", indent, -y)
  fs:SetWidth(math.max(width - indent - 6, 20))
  fs:SetWordWrap(true)
  fs:SetText(text or "")
  fs:Show()
  return y + math.max(fs:GetStringHeight() or 12, 12) + (gap or 4)
end

-- An empty pane's message: a faded picture over a short line.
function H.Empty(parent)
  local e = CreateFrame("Frame", nil, parent)
  e:SetHeight(90)
  e.icon = e:CreateTexture(nil, "ARTWORK")
  e.icon:SetSize(36, 36)
  e.icon:SetPoint("TOP", 0, -14)
  e.icon:SetAlpha(0.35)
  e.icon:SetDesaturated(true)
  e.text = Kit.Text(e, "GameFontDisable")
  e.text:SetPoint("TOP", e.icon, "BOTTOM", 0, -8)
  e.text:SetJustifyH("CENTER")
  return e
end

-- y = ShowEmpty(e, y, width, text, icon)
function H.ShowEmpty(e, y, width, text, icon)
  e.icon:SetTexture(icon or H.ICON.bossSkull)
  e.text:SetWidth(math.max(width - 24, 40))
  e.text:SetText(text or "")
  e:ClearAllPoints()
  e:SetPoint("TOPLEFT", 0, -y)
  e:SetPoint("RIGHT")
  e:SetHeight(14 + 36 + 8 + (e.text:GetStringHeight() or 12) + 10)
  e:Show()
  return y + e:GetHeight()
end

-------------------------------------------------------------------------------
-- Party strip (toolbars): "Party [c][c][c][c][c]", members with ARL in full
-- colour, the others faded. The tab gives the tooltip.
-------------------------------------------------------------------------------

function H.PartyStrip(parent)
  local f = CreateFrame("Button", nil, parent)
  f:SetSize(150, 20)
  f.label = Kit.Text(f, "GameFontDisableSmall")
  f.label:SetPoint("LEFT")
  f.label:SetText("Party")
  f.icons = {}
  for k = 1, 5 do
    local edge = f:CreateTexture(nil, "ARTWORK")
    edge:SetSize(18, 18)
    edge:SetPoint("LEFT", f.label, "RIGHT", 6 + (k - 1) * 21, 0)
    local icon = f:CreateTexture(nil, "OVERLAY")
    icon:SetSize(16, 16)
    icon:SetPoint("CENTER", edge, "CENTER")
    f.icons[k] = { edge = edge, icon = icon }
  end
  return f
end

-- Compact: no "Party" word and smaller icons (the compact toolbar is 288 px:
-- four filter buttons and the full strip overlapped there).
function H.LayoutPartyStrip(f, compact)
  if f.compact == compact then
    return
  end
  f.compact = compact
  local size, step = compact and 14 or 18, compact and 16 or 21
  f.label:SetShown(not compact)
  for k, slot in ipairs(f.icons) do
    slot.edge:SetSize(size, size)
    slot.icon:SetSize(size - 2, size - 2)
    slot.edge:ClearAllPoints()
    if compact then
      slot.edge:SetPoint("LEFT", f, "LEFT", (k - 1) * step, 0)
    else
      slot.edge:SetPoint("LEFT", f.label, "RIGHT", 6 + (k - 1) * step, 0)
    end
  end
  f:SetWidth(compact and (5 * step) or 150)
end

-- has(member) -> true when that member shares (runs ARL).
function H.PaintPartyStrip(f, members, has)
  local ar, ag, ab = ARLE.Skin:Accent()
  for k, slot in ipairs(f.icons) do
    local m = members[k]
    if m then
      local on = has(m) and true or false
      H.SetClassIcon(slot.icon, m.class)
      slot.icon:SetDesaturated(not on)
      slot.icon:SetAlpha(on and 1 or 0.35)
      slot.edge:SetColorTexture(ar, ag, ab, on and 0.8 or 0.15)
      slot.icon:Show()
      slot.edge:Show()
    else
      slot.icon:Hide()
      slot.edge:Hide()
    end
  end
end
