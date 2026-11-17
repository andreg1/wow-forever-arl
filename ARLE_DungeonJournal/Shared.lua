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
  description = "A dungeon window: bosses and their loot (BiS and upgrades for you and your ARL partymates), "
    .. "quests with their prerequisites and chains, and clear times with a guild leaderboard.",
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
    guildBoard = true,
  },
  pages = { -- child entries in /arl, one per tab of the window
    {
      key = "bis",
      label = "Bosses & Loot",
      notes = "Each boss's drops, and who in the party each one is BiS or an upgrade for.",
      requires = "ForeverLevelingBiS",
    },
    {
      key = "quests",
      label = "Quests",
      notes = "The dungeon's quests, what unlocks them, what follows, and the party's progress.",
    },
    {
      key = "times",
      label = "Clear Times",
      notes = "A run timer with splits per boss, your records, and the guild's.",
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
      tooltip = "Opens the window on Bosses & Loot with the boss you are fighting selected.",
    },
    {
      key = "openOnKill",
      type = "boolean",
      label = "Open when a boss dies",
      tooltip = "When a boss dies inside a dungeon, opens Bosses & Loot on that boss (even if you closed or folded "
        .. "the window), so you can see what it drops and who it's for while the loot is rolled.",
    },
    { key = "maxHeight", type = "number", label = "Window height (200-800)", min = 200, max = 800 },
    {
      key = "tab",
      type = "select",
      label = "Tab",
      tooltip = "The tab the window shows. Clicking a tab in the window changes this too.",
      values = {
        { value = "bis", label = "Bosses & Loot" },
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

H.tabs = {} -- filled by Loot.lua, Quests.lua, Times.lua, in that order

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
        ARLE.Debug.Call(mod, tab.Send, tab, dungeon, channel, pending.force)
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
-- Row widgets, the same in every tab and both panes:
--   H.Section(parent)  a section header: accent label left, a note right
--   H.Row(parent, h)   a clickable row: a picture (portrait or icon), a
--                      name, a note on the right, and member marks (small
--                      class-coloured squares: gold-edged = strong, faded =
--                      weak). row.selected draws the accent bar on its left.
-- Lists keep their rows in a pool and Place them top to bottom.
-------------------------------------------------------------------------------

H.MARK, H.MAX_MARKS = 8, 5

function H.Section(parent)
  local h = CreateFrame("Button", nil, parent)
  h:SetHeight(18)
  h.bg = h:CreateTexture(nil, "BACKGROUND")
  h.bg:SetAllPoints()
  h.icon = h:CreateTexture(nil, "ARTWORK")
  h.icon:SetSize(14, 14)
  h.icon:SetPoint("LEFT", 4, 0)
  h.icon:Hide()
  h.label = Kit.Text(h, "GameFontNormalSmall")
  h.label:SetPoint("LEFT", 6, 0)
  h.label:SetWordWrap(false)
  h.note = Kit.Text(h, "GameFontHighlightSmall")
  h.note:SetPoint("RIGHT", -4, 0)
  h.note:SetJustifyH("RIGHT")
  h.label:SetPoint("RIGHT", h.note, "LEFT", -4, 0)
  return h
end

-- label, note, icon (texture path, atlas or nil)
function H.PaintSection(h, label, note, icon)
  local ar, ag, ab = ARLE.Skin:Accent()
  h.bg:SetColorTexture(ar, ag, ab, 0.1)
  h.label:SetText(label)
  h.label:SetTextColor(ar, ag, ab)
  h.note:SetText(note or "")
  h.label:ClearAllPoints()
  if icon then
    h.icon:Show()
    if not (type(icon) == "string" and icon:find("^atlas:") and h.icon.SetAtlas
        and pcall(h.icon.SetAtlas, h.icon, icon:sub(7))) then
      local path = type(icon) == "string" and (icon:gsub("^atlas:", "")) or icon
      h.icon:SetTexture(path)
    end
    h.label:SetPoint("LEFT", h.icon, "RIGHT", 3, 0)
  else
    h.icon:Hide()
    h.label:SetPoint("LEFT", 6, 0)
  end
  h.label:SetPoint("RIGHT", h.note, "LEFT", -4, 0)
end

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
  r.pic = r:CreateTexture(nil, "ARTWORK")
  r.pic:SetSize(picture or (height - 2), picture or (height - 2))
  r.pic:SetPoint("LEFT", 5, 0)
  r.name = Kit.Text(r, "GameFontHighlightSmall")
  r.name:SetPoint("LEFT", r.pic, "RIGHT", 4, 0)
  r.name:SetWordWrap(false)
  r.note = Kit.Text(r, "GameFontHighlightSmall")
  r.note:SetJustifyH("RIGHT")
  r.squares = {}
  for k = 1, H.MAX_MARKS do
    local edge = r:CreateTexture(nil, "ARTWORK")
    edge:SetSize(H.MARK + 2, H.MARK + 2)
    edge:SetPoint("RIGHT", -(4 + (k - 1) * (H.MARK + 4)), 0)
    edge:SetColorTexture(1, 0.82, 0, 1)
    local fill = r:CreateTexture(nil, "OVERLAY")
    fill:SetSize(H.MARK, H.MARK)
    fill:SetPoint("CENTER", edge, "CENTER")
    r.squares[k] = { edge = edge, fill = fill }
  end
  r.more = Kit.Text(r, "GameFontDisableSmall")
  r.more:SetPoint("RIGHT", -(4 + H.MAX_MARKS * (H.MARK + 4)), 0)
  r.hl = r:CreateTexture(nil, "HIGHLIGHT")
  r.hl:SetAllPoints()
  r.hl:SetColorTexture(1, 1, 1, 0.07)
  return r
end

-- marks = { {class, strong, weak}, ... }; note = right-hand text. Lays the
-- name out between the picture and whatever is on the right.
function H.PaintRow(r, name, note, marks, selected)
  local ar, ag, ab = ARLE.Skin:Accent()
  r.name:SetText(name or "")
  marks = marks or {}
  local n = math.min(#marks, H.MAX_MARKS)
  for k = 1, H.MAX_MARKS do
    local sq, mk = r.squares[k], marks[k]
    if mk and k <= n then
      local cr, cg, cb = H.ClassColor(mk.class)
      sq.fill:SetColorTexture(cr, cg, cb, 1)
      sq.fill:SetAlpha(mk.weak and 0.35 or (mk.strong and 1 or 0.6))
      sq.fill:Show()
      sq.edge:SetShown(mk.strong and true or false)
    else
      sq.fill:Hide()
      sq.edge:Hide()
    end
  end
  local extra = #marks - n
  r.more:SetText(extra > 0 and ("+" .. extra) or "")
  local right = 4 + n * (H.MARK + 4) + (extra > 0 and 14 or 0)
  r.note:ClearAllPoints()
  r.note:SetPoint("RIGHT", r, "RIGHT", -right, 0)
  r.note:SetText(note or "")
  r.name:ClearAllPoints()
  r.name:SetPoint("LEFT", r.pic, "RIGHT", 4, 0)
  r.name:SetPoint("RIGHT", r.note, "LEFT", -4, 0)
  r.bar:SetColorTexture(ar, ag, ab, 1)
  r.bar:SetShown(selected and true or false)
  r.bg:SetColorTexture(ar, ag, ab, selected and 0.14 or 0)
end

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

-- A paragraph of text in a pane: y = Para(fs, y, width, text). The width is
-- set outright, so the height is right before the pane is laid out.
function H.Para(fs, y, width, text, gap)
  fs:ClearAllPoints()
  fs:SetPoint("TOPLEFT", 6, -y)
  fs:SetWidth(math.max(width - 12, 20))
  fs:SetWordWrap(true)
  fs:SetText(text or "")
  fs:Show()
  return y + math.max(fs:GetStringHeight() or 12, 12) + (gap or 4)
end
