-- Dungeon Helper, shared parts: the module definition and its options, the
-- data sources, the group, the comms every tab uses, and small helpers.
--
-- The window (DungeonHelper.lua) has three tabs, each in its own file:
--   BiS.lua     BiS Finder: which boss drops are BiS or upgrades for whom
--   Quests.lua  the dungeon's quests and who in the party has them
--   Times.lua   clear times: splits by boss, records, party members' records
--
-- Sources (all read-only, through their public namespaces):
--   DungeonJournal        bosses, loot, quests, encounter IDs, boss portraits
--                         (ForeverDungeonJournal_NS)
--   Forever Leveling BiS  item gains for the player (ForeverLevelingBiS_API);
--                         only the BiS Finder needs it
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
  commandArgs = "[bis|quests|timers]",
  commandHelp = "opens or closes the Dungeon Helper, optionally on a tab",
  commandSection = "Dungeon Helper",
  mainHelp = "opens or closes the window on the last tab",
  commandUsage = {
    { "dh bis | quests | timers", "opens it on that tab" },
    { "dh reset", "restarts the run timer" },
    { "dh spec <name> <spec>", "sets the spec scored for an estimated party member" },
  },
  description = "A dungeon window with three tabs: BiS Finder, Quests and Clear Times.",
  defaults = {
    autoOpen = true,
    openOnPull = true,
    openOnKill = true,
    maxHeight = 420,
    tab = "bis",
    showShared = true,
    showOther = true,
    filter = "all",
    questFilter = "all",
    questShowDone = true,
    timerStart = "pull",
    timerInTitle = true,
    announceRecords = true,
  },
  pages = { -- child entries in /arl, one per tab of the window
    {
      key = "bis",
      label = "BiS Finder",
      notes = "Boss drops, and who each one is BiS or an upgrade for.",
      requires = "ForeverLevelingBiS",
    },
    {
      key = "quests",
      label = "Quests",
      notes = "The dungeon's quests, and who in the party has them.",
    },
    {
      key = "times",
      label = "Clear Times",
      notes = "A run timer with splits per boss, and your records.",
    },
  },
  panePage = "times", -- the records list goes on the Clear Times entry
  options = {
    { type = "header", label = "Window" },
    { key = "autoOpen", type = "boolean", label = "Open automatically inside dungeons" },
    {
      key = "openOnPull",
      type = "boolean",
      label = "Jump to the boss when a fight starts",
      tooltip = "Opens the window on the BiS Finder, folds every boss and unfolds the one you are fighting.",
    },
    {
      key = "openOnKill",
      type = "boolean",
      label = "Open when a boss dies",
      tooltip = "When a boss dies inside a dungeon, opens the BiS Finder on that boss (even if you closed or "
        .. "folded it), so you can see what it drops and who it's for while the loot is rolled.",
    },
    { key = "maxHeight", type = "number", label = "Window height (200-800)", min = 200, max = 800 },
    {
      key = "tab",
      type = "select",
      label = "Tab",
      tooltip = "The tab the window shows. Clicking a tab in the window changes this too.",
      values = {
        { value = "bis", label = "BiS Finder" },
        { value = "quests", label = "Quests" },
        { value = "times", label = "Clear Times" },
      },
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
      label = "Show \"Other loot\" below the bosses",
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
      },
    },
    { page = "quests", key = "questShowDone", type = "boolean", label = "List quests you have done (at the bottom)" },
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
      label = "Show the running time in the title bar",
      tooltip = "Visible on every tab, and when the window is folded.",
    },
    {
      page = "times",
      key = "announceRecords",
      type = "boolean",
      label = "Tell me in chat about new records",
    },
  },
}
ns.mod = mod
H.mod = mod

-------------------------------------------------------------------------------
-- Sources
-------------------------------------------------------------------------------

H.FDJ = ARLE.Bridge.FDJ
H.FLB = ARLE.Bridge.FLB

local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
H.GetItemInfo = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo
H.GetItemIcon = (C_Item and C_Item.GetItemIconByID) or _G.GetItemIcon

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
  local list, rares = { parent = {}, group = {}, npc = {} }, {}
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
function H.Plain(v)
  if issecretvalue and issecretvalue(v) then
    return nil
  end
  return v
end

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

H.tabs = {} -- filled by BiS.lua, Quests.lua, Times.lua, in that order

-- Splits "head~<part>~<total>~<list>" messages into as many as it takes.
function H.SendChunks(kind, head, items, sep, channel)
  ARLE:SendChunks(kind, head, items, sep, channel)
end

local sendTimers = {}
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
  C_Timer.After(1.5, function()
    sendTimers[key] = nil
    local channel = ARLE:GroupChannel()
    if not mod._active or not channel then
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
    ARLE:Send("BQ", H.shown, channel)
    H.QueueSend(H.shown, nil, true)
    for _, tab in ipairs(H.tabs) do
      if tab.OnRequest then
        tab:OnRequest()
      end
    end
  end
end

ARLE:RegisterComm("BQ", function(_, dungeon)
  if mod._active and H.FDJ() and H.FDJ().DB[dungeon] then
    H.QueueSend(dungeon, nil, true)
  end
end)

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

function H.Render()
  -- replaced by the window (DungeonHelper.lua)
end

-- Shared helpers now live in ARLE.Lib and ARLE.UI.Kit; these names stay so
-- the tab files read the same.
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
