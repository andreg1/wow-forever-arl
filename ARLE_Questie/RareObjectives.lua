-- Rare Objectives: watches for the rare and named mobs your quests still need
-- while you're in their zone, and alerts and marks them.
-- Based on Questie_RareObjectives by andreg1 (MIT),
-- https://github.com/andreg1/wow-forever-addons
--
-- What gets watched: for every incomplete quest in your log, from QuestieDB
-- (ARLE.Bridge.QuestieDB): kill objectives (objectives[1] creatures, [5] kill
-- credit) and item objectives (objectives[3]) whose item drops from few NPCs
-- (ItemDB npcDrops), where the NPC is "rare": NpcDB rank 2 (rare elite) or 4
-- (rare), or a one-off named target (the log objective needs exactly 1 kill, or
-- 1 item only that NPC drops). The log objective naming the mob / item must
-- still be unfinished. Only mobs whose zone contains your current map are
-- active. Names you add are watched anywhere.
--
-- How it looks (addons can't target or search units by themselves): every
-- interval seconds and on the matching events: nameplates (enemy nameplates
-- must be on), target, mouseover, and minimap vignettes (which also give a
-- map position for the waypoint). A mob alerts once, then again only after it
-- was out of sight for realert seconds. Dead mobs are ignored.
--
-- The scan: markers and pings can't be sent from addon code (SetRaidTarget /
-- pings are Blizzard-UI-only: ADDON_ACTION_FORBIDDEN even out of combat), but
-- a macro run by the player's key press may. So the scan key (the host's
-- secure button ARLE_SecureRareScan, bound in Key Bindings > ARL Extensions)
-- runs /cleartarget, /targetexact each active mob, then for a living hostile
-- living target /tm 0 + /tm <marker> and /ping; nothing found: no target
-- (your old one isn't given back: the user's choice 2026-11-19, the clear and
-- re-select flickered on every press); a corpse found: /cleartarget [dead]
-- drops it. The same text goes into a character macro (QRareScan,
-- made on request, kept up to date, ending with an optional line of yours,
-- e.g. a mount): the button can't be /clicked from inside another macro.
-- Macros hold 255 characters, and so does the button's macrotext (the game
-- cuts it there: 0.10.5's longer closing lines got cut mid "[exists" and the
-- key said "Unknown macro option"). So names that don't fit are left out of
-- both, never the closing lines. Edits wait for combat to end.
local ADDON = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local QDB, Q, Secure, Macro, Alert = ARLE.Bridge.QuestieDB, ARLE.Bridge.Questie, ARLE.Secure, ARLE.Macro, ARLE.UI.Alert
local Lib = ARLE.Lib

local RAID_MARKS = { "Star", "Circle", "Diamond", "Triangle", "Moon", "Square", "Cross", "Skull" }
local MACRO_BASE = "QRareScan"
local MACRO_LIMIT = 255
local PLACEHOLDER = "/arl rare macro"
local OLD_ADDON_MACRO = "QRareScan"        -- Questie_RareObjectives' macro (Import)
local OLD_PLACEHOLDER = "/qrare macro"     -- its placeholder body
-- A living target, hostile or friendly (names added with /arl rare add can
-- be friendly NPCs; the scan clears the target first, so one that exists is
-- a match). /tm acts on the target already; /ping is told explicitly (on a
-- friendly one the contextual ping is "assist" instead of "attack").
local FOUND = "[exists,nodead]"
local FOUND_PING = "[@target,exists,nodead]"

local markerValues = { { value = 0, label = "None" } }
for i, name in ipairs(RAID_MARKS) do
  markerValues[#markerValues + 1] = { value = i, label = name }
end

local F = {
  id = "RareObjectives",
  addon = ADDON,
  title = "Rare Objectives",
  group = "Questie",
  extends = "QuestieDB",
  command = "rare",
  commandHelp = "alerts for rare quest mobs you still need",
  description = "Alerts when a rare mob your quests need shows up. The scan key targets, marks and pings it.",
  pages = {
    { key = "watch", label = "Watching" },
    { key = "alert", label = "Alert" },
    { key = "scan", label = "Scan key", notes = "One press targets, marks and pings a watched mob in view." },
  },
  options = {
    { type = "info", text = function(def) return def:Summary() end },
    { key = "interval", type = "range", label = "Look every (seconds)", min = 1, max = 10, step = 1, default = 1,
      page = "watch" },
    { key = "realert", type = "range", label = "Alert again after (seconds unseen)", min = 10, max = 600,
      step = 10, default = 120, page = "watch" },
    { key = "manual", type = "list", label = "Also watch these names, everywhere", add = "Watch", default = {},
      empty = "(none)", page = "watch" },
    { type = "button", label = "Enemy nameplates on, longer range", desc = "better detection", nocmd = true,
      page = "watch", run = function(def) def:Nameplates() end },
    ARLE.Options.Preset.Alert({ page = "alert" }),
    { key = "waypoint", type = "boolean", label = "Map waypoint when the position is known", default = true,
      page = "alert" },
    { type = "button", label = "Show a test alert", nocmd = true, page = "alert",
      run = function(def) def:Test() end },
    { type = "keybind", binding = Secure:Binding("RareScan"), label = "Scan for rare quest mobs", page = "scan" },
    { key = "marker", type = "select", label = "Marker on a found mob", values = markerValues, default = 8,
      cmd = "mark", page = "scan" },
    { key = "ping", type = "boolean", label = "Ping a found mob", default = true, page = "scan" },
    { key = "pingCooldown", type = "range", label = "Ping at most every (seconds)", min = 0, max = 120, step = 5,
      default = 15, page = "scan", disabled = function(def) return not def.db.ping end },
    { key = "macroExtra", type = "string", label = "Extra macro line", tooltip = "A last line for the QRareScan macro, e.g. /cast your mount, so one press scans and mounts.",
      default = "", cmd = "extra", page = "scan" },
    { type = "button", label = "Create the QRareScan macro", desc = "for your action bar (Character tab of /macro)",
      nocmd = true, page = "scan", run = function(def) def:MakeMacro() end },
  },
}

local watched = {}      -- [npcId] = { name, quests = {[questId] = title}, maps = {[uiMapId] = true} | nil, from }
local zonesLoading = false -- a Rebuild found Questie's zone table still empty: another one follows
local active = {}       -- [npcId] = entry (watched and in your area)
local activeByName = {} -- [lowercase name] = { name, quests } (active + manual)
local lastSeen = {}     -- [guid] = GetTime()
local playerMaps = {}
local macroPending = false
local pingBlockedUntil = 0
local lastDropped = 0

-------------------------------------------------------------------------------
-- Data
-------------------------------------------------------------------------------

local function NpcIdFromGuid(guid)
  if type(guid) ~= "string" or Lib.IsSecret(guid) then
    return
  end
  local kind, _, _, _, _, id = strsplit("-", guid)
  if kind ~= "Creature" and kind ~= "Vehicle" then
    return
  end
  return tonumber(id)
end

local function IsRareRank(npcId)
  local rank = QDB.Npc(npcId, "rank")
  return rank == 2 or rank == 4
end

-- Rare by rank, or a one-off named target: the objective needs exactly one.
-- Spawn counts are no use: QuestieDB records many points for named roamers.
local function IsRareTarget(npcId, needed)
  return needed == 1 or IsRareRank(npcId)
end

local function AreaMaps(areaId)
  local uiMap = type(areaId) == "number" and areaId > 0 and Q.UiMapForArea(areaId)
  return uiMap and { [uiMap] = true } or nil
end

-- Where a watched mob is, best source first, and which source it was:
--   "spawns"  the NPC's spawns and waypoints (ARLE.Lib.QuestPlaces)
--   "npc"     the NPC's own zoneID
--   "quest"   the quest's zone (zoneOrSort)
--   "giver"   where the quest's givers / turn-in stand: many mobs new in
--             Forever have only a name in QuestieDB, and their quests no
--             zone (2026-11-20: Withermaw, Bonesnout, Elder Shaman Bloodmane)
-- nil + why when unknown (then it counts as everywhere): "loading" while
-- Questie's zone table isn't filled yet (Rebuild runs again), "nodata".
local function MapsFor(npcId, questId)
  if not Q.ZoneReady() then
    return nil, "loading"
  end
  local maps = Lib.QuestPlaces.NpcMaps(npcId)
  if maps then
    return maps, "spawns"
  end
  maps = AreaMaps(QDB.Npc(npcId, "zoneID"))
  if maps then
    return maps, "npc"
  end
  maps = AreaMaps(QDB.Quest(questId, "zoneOrSort"))
  if maps then
    return maps, "quest"
  end
  maps = {}
  local any = false
  for _, field in ipairs({ "startedBy", "finishedBy" }) do
    local by = QDB.Quest(questId, field)
    if type(by) == "table" then
      for _, id in ipairs(type(by[1]) == "table" and by[1] or {}) do
        for m in pairs(Lib.QuestPlaces.NpcMaps(id) or AreaMaps(QDB.Npc(id, "zoneID")) or {}) do
          maps[m], any = true, true
        end
      end
      for _, id in ipairs(type(by[2]) == "table" and by[2] or {}) do
        for m in pairs(Lib.QuestPlaces.ObjectMaps(id) or {}) do
          maps[m], any = true, true
        end
      end
    end
  end
  if any then
    return maps, "giver"
  end
  return nil, "nodata"
end

local function ItemName(itemId)
  local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemId)
  return name or QDB.Item(itemId, "name")
end

-- The log objective naming name: finished, numRequired (nil if none names it).
local function LogObjective(objectives, name)
  if not name or not objectives then
    return
  end
  local needle = name:lower()
  for _, o in ipairs(objectives) do
    if type(o.text) == "string" and o.text:lower():find(needle, 1, true) then
      return o.finished, o.numRequired
    end
  end
end

-------------------------------------------------------------------------------
-- Watch list
-------------------------------------------------------------------------------

local function Watch(npcId, questId, title)
  local entry = watched[npcId]
  if not entry then
    entry = { name = QDB.Npc(npcId, "name") or ("NPC " .. npcId), quests = {} }
    watched[npcId] = entry
  end
  -- (a mob in several quests: the first quest that places it)
  if not entry.maps then
    entry.maps, entry.from = MapsFor(npcId, questId)
    if entry.from == "loading" then
      zonesLoading = true
    end
  end
  entry.quests[questId] = title
end

local function ScanQuest(questId, title)
  local objectives = QDB.Quest(questId, "objectives")
  if type(objectives) ~= "table" then
    return
  end
  local logObjectives = C_QuestLog.GetQuestObjectives(questId)
  local function ConsiderNpc(npcId, objectiveName)
    if type(npcId) ~= "number" then
      return
    end
    local name = objectiveName or QDB.Npc(npcId, "name")
    local finished, needed = LogObjective(logObjectives, name)
    if finished then
      return
    end
    if IsRareTarget(npcId, needed) then
      Watch(npcId, questId, title)
    end
  end
  for _, o in ipairs(objectives[1] or {}) do
    ConsiderNpc(o[1])
  end
  for _, o in ipairs(objectives[5] or {}) do
    -- Kill credit: any of o[1] counts; the log names the credit (o[3] or o[2]'s name).
    local creditName = o[3] or QDB.Npc(o[2], "name")
    for _, npcId in ipairs(type(o[1]) == "table" and o[1] or {}) do
      ConsiderNpc(npcId, creditName)
    end
  end
  for _, o in ipairs(objectives[3] or {}) do
    local itemId = o[1]
    local drops = type(itemId) == "number" and QDB.Item(itemId, "npcDrops")
    if type(drops) == "table" and #drops > 0 and #drops <= 3 then
      local finished, needed = LogObjective(logObjectives, ItemName(itemId))
      if not finished then
        -- One item from one mob: that mob is the target. From several: only rares.
        if #drops > 1 and needed == 1 then
          needed = nil
        end
        for _, npcId in ipairs(drops) do
          if IsRareTarget(npcId, needed) then
            Watch(npcId, questId, title)
          end
        end
      end
    end
  end
end

-- Up to zone level, never a continent (shared with Quest Tracker).
local WalkToZone = Lib.QuestPlaces.WalkToZone

-- (values the client may hide in an instance: never tested or indexed)
local Plain = Lib.Plain

local function UpdatePlayerMaps()
  wipe(playerMaps)
  local best = Plain(C_Map.GetBestMapForUnit("player"))
  WalkToZone(type(best) == "number" and best or nil, function(m)
    playerMaps[m] = true
  end)
end

local function InArea(entry)
  if not entry.maps then
    return true
  end
  for uiMap in pairs(entry.maps) do
    if WalkToZone(uiMap, function(m)
      return playerMaps[m]
    end) then
      return true
    end
  end
  return false
end

local UpdateMacro -- below

local function Rebuild()
  wipe(watched)
  zonesLoading = false
  if QDB.Ready() then
    for i = 1, C_QuestLog.GetNumQuestLogEntries() do
      local info = C_QuestLog.GetInfo(i)
      if info and not info.isHeader and info.questID and not C_QuestLog.IsComplete(info.questID) then
        ScanQuest(info.questID, info.title)
      end
    end
  end
  UpdatePlayerMaps()
  wipe(active)
  wipe(activeByName)
  for npcId, entry in pairs(watched) do
    if InArea(entry) then
      active[npcId] = entry
      activeByName[entry.name:lower()] = entry
    end
  end
  for _, name in ipairs(F.db.manual or {}) do
    local key = name:lower()
    if not activeByName[key] then
      activeByName[key] = { name = name, quests = {} }
    end
  end
  UpdateMacro()
  if zonesLoading then
    F:Debug("Questie's zones aren't loaded yet: rebuilding in 5 s")
    F:Debounce("rebuild", 5, Rebuild)
  end
end

-------------------------------------------------------------------------------
-- Alert
-------------------------------------------------------------------------------

local function QuestText(entry)
  local titles = {}
  for _, title in pairs(entry.quests) do
    titles[#titles + 1] = title
  end
  table.sort(titles)
  return #titles > 0 and (" (" .. table.concat(titles, ", ") .. ")") or ""
end

local function SetWaypoint(pos)
  if not (F.db.waypoint and pos and C_Map.SetUserWaypoint and UiMapPoint) then
    return
  end
  pcall(function()
    if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(pos[1]) then
      return
    end
    C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(pos[1], pos[2], pos[3]))
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
      C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    end
  end)
end

local function Announce(entry, unit, pos)
  local where = pos and string.format(" at %.1f, %.1f", pos[2] * 100, pos[3] * 100) or ""
  local tapped = unit and UnitIsTapDenied and UnitIsTapDenied(unit) and " |cffaaaaaa(tapped by someone else)|r" or ""
  local text = "|cffff5050" .. entry.name .. "|r is nearby" .. where .. "!" .. tapped
  local key = Secure:BoundKey("RareScan")
  local hint = key and (" Press " .. key .. " to target, mark and ping it.") or ""
  F:Print(text .. QuestText(entry) .. hint)
  Alert:Nag(F, text)
end

local function Found(entry, guid, unit, pos)
  local now = GetTime()
  local seen = lastSeen[guid]
  lastSeen[guid] = now
  if seen and now - seen < (tonumber(F.db.realert) or 120) then
    return
  end
  Announce(entry, unit, pos)
  SetWaypoint(pos)
end

local function EntryForUnit(unit)
  if not Plain(UnitExists(unit)) or Plain(UnitIsDead(unit)) or Plain(UnitIsPlayer(unit)) then
    return
  end
  local npcId = NpcIdFromGuid(UnitGUID(unit))
  if npcId and active[npcId] then
    return active[npcId]
  end
  local name = UnitName(unit)
  if name and not Lib.IsSecret(name) then
    return activeByName[name:lower()]
  end
end

local function CheckUnit(unit)
  local entry = EntryForUnit(unit)
  if entry then
    Found(entry, UnitGUID(unit), unit, nil)
  end
end

local function CheckVignettes()
  if not (C_VignetteInfo and C_VignetteInfo.GetVignettes) then
    return
  end
  local uiMap = Plain(C_Map.GetBestMapForUnit("player"))
  local list = Plain(C_VignetteInfo.GetVignettes())
  if type(list) ~= "table" then
    return
  end
  for _, vignetteGUID in ipairs(list) do
    local info = Plain(C_VignetteInfo.GetVignetteInfo(vignetteGUID))
    if type(info) ~= "table" then
      info = nil
    end
    local npcId = info and NpcIdFromGuid(Plain(info.objectGUID))
    local name = info and Plain(info.name)
    local entry = npcId and active[npcId] or (type(name) == "string" and activeByName[name:lower()])
    if entry and not Plain(info.isDead) then
      local pos
      if type(uiMap) == "number" and C_VignetteInfo.GetVignettePosition then
        local v = Plain(C_VignetteInfo.GetVignettePosition(vignetteGUID, uiMap))
        local x, y = v and Plain(v.x), v and Plain(v.y)
        if type(x) == "number" and type(y) == "number" then
          pos = { uiMap, x, y }
        end
      end
      Found(entry, Plain(info.objectGUID) or vignetteGUID, nil, pos)
    end
  end
end

local function Scan()
  if next(activeByName) == nil then
    return
  end
  if C_NamePlate and C_NamePlate.GetNamePlates then
    for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
      local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
      if unit then
        CheckUnit(unit)
      end
    end
  end
  CheckUnit("target")
  CheckUnit("mouseover")
  CheckVignettes()
end

-------------------------------------------------------------------------------
-- The scan text: the secure button and the QRareScan macro
-------------------------------------------------------------------------------

-- The scan text for limit characters (nil when there's nothing to scan for),
-- and how many names didn't fit.
local function ScanText(limit, extra)
  -- Names added by hand (/arl rare add) come first, in the order added, so
  -- they're the last to be left out when the 255 characters run short; then
  -- the quest mobs, by name.
  local names, taken = {}, {}
  for _, name in ipairs(F.db.manual or {}) do
    local key = type(name) == "string" and name:lower()
    if key and activeByName[key] and not taken[key] then
      taken[key] = true
      names[#names + 1] = activeByName[key].name
    end
  end
  local rest = {}
  for key, entry in pairs(activeByName) do
    if not taken[key] then
      rest[#rest + 1] = entry.name
    end
  end
  table.sort(rest)
  for _, name in ipairs(rest) do
    names[#names + 1] = name
  end
  local tail = {}
  local marker = tonumber(F.db.marker) or 0
  if #names > 0 then
    if marker >= 1 and marker <= 8 then
      tail[#tail + 1] = "/tm " .. FOUND .. " 0"
      tail[#tail + 1] = "/tm " .. FOUND .. " " .. marker
    end
    if F.db.ping and GetTime() >= pingBlockedUntil then
      -- No ping type: the contextual ping (attack on a hostile mob).
      tail[#tail + 1] = (SLASH_PING1 or "/ping") .. " " .. FOUND_PING
    end
    -- /targetexact can't skip corpses: a dead match is dropped here.
    tail[#tail + 1] = "/cleartarget [dead]"
  end
  if extra and extra ~= "" then
    tail[#tail + 1] = extra
  end
  local tailText = table.concat(tail, "\n")
  if #names == 0 then
    return tailText ~= "" and tailText or nil, 0
  end
  local lines = { "/cleartarget" }
  local length = #lines[1] + 1 + #tailText
  local dropped = 0
  for _, name in ipairs(names) do
    local line = "/targetexact " .. name
    if length + #line + 1 > limit then
      dropped = dropped + 1
    else
      lines[#lines + 1] = line
      length = length + #line + 1
    end
  end
  if #lines == 1 then
    return extra ~= "" and extra or nil, dropped
  end
  return table.concat(lines, "\n") .. "\n" .. tailText, dropped
end

local function TrimEnd(s)
  return (s:gsub("%s+$", ""))
end

-- Ours: the placeholder (ours or the old Questie_RareObjectives' one), scan
-- lines, or, with no watched mob, only the extra line: that one is
-- recognized as the extra line itself, or as the last body written
-- (char.macroBody), which still holds when the extra line was changed since.
local function IsScanBody(body)
  if type(body) ~= "string" then
    return false
  end
  if body == PLACEHOLDER or body == OLD_PLACEHOLDER or body:find("^/cleartarget") ~= nil
      or body:find("/targetexact", 1, true) ~= nil or body:find("^/tm ") ~= nil then
    return true
  end
  local trimmed = TrimEnd(body)
  if trimmed == "" then
    return false
  end
  local extra = F.db and F.db.macroExtra
  if type(extra) == "string" and TrimEnd(extra) == trimmed then
    return true
  end
  local last = F.char and F.char.macroBody
  return type(last) == "string" and TrimEnd(last) == trimmed
end

function UpdateMacro()
  local text, cut = ScanText(MACRO_LIMIT)
  Secure:SetAttributes("RareScan", { macrotext = F._active and text or "" })
  if F._active and (cut or 0) > 0 and cut ~= lastDropped then
    F:Print(string.format("%d watched mob%s didn't fit in the scan (255 characters); they're still watched and "
      .. "alerted on. /arl rare macro shows what the scan runs.", cut, cut == 1 and "" or "s"))
  end
  lastDropped = F._active and cut or 0
  if InCombatLockdown() then
    macroPending = true
    return
  end
  macroPending = false
  local index = Macro:Ours(F.char.macro, IsScanBody)
  if index then
    local body, dropped = ScanText(MACRO_LIMIT, F.db.macroExtra)
    body = body or PLACEHOLDER
    local name, icon, current = GetMacroInfo(index)
    if current ~= body then
      if pcall(EditMacro, index, name, icon, body) then
        F.char.macroBody = body
      end
    else
      F.char.macroBody = body
    end
    if (dropped or 0) > (cut or 0) then
      F:Debug("%d watched mobs didn't fit in %s (its extra line takes room)", dropped, name)
    end
  end
end

function F:MakeMacro()
  if InCombatLockdown() then
    self:Print("macros can't be made in combat.")
    return
  end
  local result, why = Macro:Ensure(self.char, "macro", MACRO_BASE, PLACEHOLDER, true, IsScanBody)
  if not result then
    self:Print("couldn't create the macro: " .. tostring(why) .. ".")
    return
  end
  UpdateMacro()
  if result == "created" then
    self:Print(self.char.macro .. " created: open /macro, Character tab, and drag it to your action bar.")
  else
    self:Print(self.char.macro .. " already exists (Character tab of /macro); it updates itself.")
  end
end

-- The scan button: the template runs the action on one edge only, but
-- callers differ (/click in chat sends the up edge, a key binding both). Out
-- of combat, PreClick points useOnKeyDown at whichever edge arrives first and
-- swallows the other edge of the same press; in combat the last setting stays.
local scanSetup = false
local function SetupScanButton()
  local b = Secure:Button("RareScan")
  if not b or scanSetup then
    return
  end
  scanSetup = true -- (kept here: no fields of ours on a secure button)
  b:SetAttribute("type", "macro")
  b:SetAttribute("useOnKeyDown", false)
  b:RegisterForClicks("AnyUp", "AnyDown")
  local lastPress = 0
  F:Script(b, "PreClick", function(self, _, down)
    if InCombatLockdown() then
      return
    end
    local now = GetTime()
    if now - lastPress < 0.8 then
      self:SetAttribute("type", nil)
    else
      lastPress = now
      self:SetAttribute("type", "macro")
      self:SetAttribute("useOnKeyDown", down and true or false)
    end
  end)
  F:Script(b, "PostClick", function(self)
    if not InCombatLockdown() then
      self:SetAttribute("type", "macro")
    end
  end)
end

-------------------------------------------------------------------------------
-- Panel and chat
-------------------------------------------------------------------------------

function F:Summary()
  if not QDB.Ready() then
    return "|cffff8080QuestieDB's data was not found: only names you add are watched.|r"
  end
  local n, here = 0, 0
  for npcId in pairs(watched) do
    n = n + 1
    if active[npcId] then
      here = here + 1
    end
  end
  return string.format("%d rare quest mob%s in your quests, %d in this zone. Scan key: %s.", n, n == 1 and "" or "s",
    here, Secure:BoundKey("RareScan") or "not bound")
end

function F:Test()
  Announce({ name = "Test Rare", quests = { [0] = "Test Quest" } }, nil, nil)
end

function F:Nameplates()
  if InCombatLockdown() then
    self:Print("not in combat.")
    return
  end
  SetCVar("nameplateShowEnemies", 1)
  -- Only ever raise it; the client clamps to its own max.
  local current = tonumber(GetCVar("nameplateMaxDistance")) or 0
  if current < 60 then
    pcall(SetCVar, "nameplateMaxDistance", 60)
  end
  self:Print(string.format("enemy nameplates on, range %s yards (the game's limit applies).",
    tostring(GetCVar("nameplateMaxDistance"))))
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

local function Queue(self)
  self:Debounce("rebuild", 1, Rebuild)
end

function F:OnEnable()
  if not QDB.Ready() then
    self:Print("QuestieDB's data (QuestDB / NpcDB) was not found; only names you add are watched.")
  end
  self:OutOfCombat(SetupScanButton)
  for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED",
    "ZONE_CHANGED", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED_INDOORS" }) do
    self:On(e, Queue)
  end
  self:On("PLAYER_REGEN_ENABLED", function()
    if macroPending then
      UpdateMacro()
    end
  end)
  self:On("NAME_PLATE_UNIT_ADDED", function(_, _, unit)
    CheckUnit(unit)
  end)
  self:On("UPDATE_MOUSEOVER_UNIT", function()
    CheckUnit("mouseover")
  end)
  self:On("PLAYER_TARGET_CHANGED", function()
    CheckUnit("target")
    -- A watched mob targeted: the scan just pinged it. Start the ping cooldown.
    local cooldown = tonumber(self.db.pingCooldown) or 0
    if self.db.ping and cooldown > 0 and GetTime() >= pingBlockedUntil and EntryForUnit("target") then
      pingBlockedUntil = GetTime() + cooldown
      UpdateMacro()
      self:After(cooldown + 0.1, UpdateMacro)
    end
  end)
  local function Vignettes()
    if next(activeByName) then
      CheckVignettes()
    end
  end
  pcall(self.On, self, "VIGNETTES_UPDATED", Vignettes)
  pcall(self.On, self, "VIGNETTE_MINIMAP_UPDATED", Vignettes)
  self.ticker = self:Ticker(tonumber(self.db.interval) or 1, Scan)
  Queue(self)
end

function F:OnDisable()
  wipe(active)
  wipe(activeByName)
  macroPending = false
  -- Cleanup drops our PLAYER_REGEN_ENABLED handler and self:OutOfCombat is
  -- dropped once off, so a macro edit that has to wait for combat goes
  -- through ARLE.Secure:Run (skipped if the feature is back on by then: its
  -- own rebuild writes the macro).
  Secure:Run(function()
    if not F._active then
      UpdateMacro()
    end
  end)
end

function F:OnOptionChanged(key)
  if key == "interval" then
    if self.ticker then
      self.ticker:Cancel()
    end
    self.ticker = self:Ticker(tonumber(self.db.interval) or 1, Scan)
  end
  Rebuild()
end

function F:GetStatus()
  return "Active · " .. self:Summary()
end

-- Questie_RareObjectives' settings (QuestieRareObjectivesDB, account-wide)
-- replace ours, and its QRareScan character macro becomes ours if its text is
-- still a scan. Called by the host while that addon is loaded.
local function Num(v, lo, hi)
  if type(v) ~= "number" or v ~= v then
    return nil
  end
  return math.max(lo, math.min(hi, v))
end

function F:Import()
  local old = _G.QuestieRareObjectivesDB
  if type(old) ~= "table" then
    return
  end
  local db = self.db
  -- (old.enabled is not copied: db.enabled is the host's feature switch.)
  for _, key in ipairs({ "waypoint", "ping" }) do
    if type(old[key]) == "boolean" then
      db[key] = old[key]
    end
  end
  if type(old.sound) == "boolean" then
    db.alertSound = old.sound
  end
  if type(old.flash) == "boolean" then
    db.alertFlash = old.flash
  end
  local marker = Num(old.marker, 0, 8)
  if marker then
    db.marker = math.floor(marker)
  end
  local cooldown = Num(old.pingCooldown, 0, 120)
  if cooldown then
    db.pingCooldown = math.floor(cooldown)
  end
  local interval = Num(old.interval, 1, 10)
  if interval then
    db.interval = interval
  end
  local realert = Num(old.realert, 10, 600)
  if realert then
    db.realert = realert
  end
  if type(old.macroExtra) == "string" then
    db.macroExtra = old.macroExtra
  end
  -- Its list: [lowercase name] = display name. Ours: an array of names.
  if type(old.manual) == "table" then
    local list, seen = {}, {}
    for key, name in pairs(old.manual) do
      local text = type(name) == "string" and Lib.Trim(name) or (type(key) == "string" and Lib.Trim(key)) or ""
      if text ~= "" and not seen[text:lower()] then
        seen[text:lower()] = true
        list[#list + 1] = text
      end
    end
    table.sort(list)
    db.manual = list
  end
  local index = Macro:Index(OLD_ADDON_MACRO)
  local body = index and Macro:Body(index)
  if type(body) == "string" and IsScanBody(body) then
    self.char.macro = OLD_ADDON_MACRO
    self.char.macroBody = body
  end
end

F.commands = {
  { name = "list", help = "mobs being watched, and whether they're in your zone", run = function(self)
    local any = false
    for npcId, entry in pairs(watched) do
      any = true
      local state
      if not entry.maps then
        state = entry.from == "loading" and "|cffffd100Questie's zones still loading, watched everywhere for now|r"
          or "|cffffd100zone unknown (no location in Questie's data), watched everywhere|r"
      elseif active[npcId] then
        state = "|cff40ff40watching here|r"
      else
        state = "|cffaaaaaanot in this zone|r"
      end
      if entry.from == "giver" then
        state = state .. " |cffaaaaaa(zone of the quest giver)|r"
      end
      print(string.format("   %s (%d)%s - %s", entry.name, npcId, QuestText(entry), state))
    end
    for _, name in ipairs(self.db.manual or {}) do
      any = true
      print("   " .. name .. " - |cff40ff40added by you, watched everywhere|r")
    end
    if not any then
      self:Print("no rare quest mobs to watch for (none in your incomplete quests).")
    end
  end },
  { name = "add", args = "<name>", help = "watches any mob by name, everywhere", run = function(self, _, raw)
    local name = Lib.Trim(raw)
    if name == "" then
      self:Print("usage: /arl rare add <name>")
      return
    end
    local list = { unpack(self.db.manual or {}) }
    list[#list + 1] = name
    ARLE:SetOption(self.id, "manual", list)
    self:Print("watching for " .. name .. " everywhere.")
  end },
  { name = "remove", args = "<name>", help = "stops watching a name you added", run = function(self, rest)
    local list = {}
    for _, v in ipairs(self.db.manual or {}) do
      if v:lower() ~= rest then
        list[#list + 1] = v
      end
    end
    ARLE:SetOption(self.id, "manual", list)
    self:Print("stopped watching for " .. rest .. " (quest mobs are still watched while needed).")
  end },
  { name = "removelast", help = "stops watching the last name you added", run = function(self)
    local list = { unpack(self.db.manual or {}) }
    local name = table.remove(list)
    if not name then
      self:Print("you haven't added any names (/arl rare add <name>).")
      return
    end
    ARLE:SetOption(self.id, "manual", list)
    self:Print("stopped watching for " .. name .. (#list > 0 and (" (" .. #list .. " added name"
      .. (#list == 1 and "" or "s") .. " left)") or "") .. ".")
  end },
  { name = "nameplates", help = "turns enemy nameplates on and raises their range", run = function(self)
    self:Nameplates()
  end },
  { name = "makemacro", help = "creates the QRareScan macro for your action bar", run = function(self)
    self:MakeMacro()
  end },
  { name = "macro", help = "shows what the scan runs", run = function(self)
    local text, cut = ScanText(MACRO_LIMIT)
    text = text or ""
    if text == "" then
      self:Print("the scan has nothing to look for (no watched mob here; /arl rare list).")
    else
      self:Print("the scan runs:")
      for line in text:gmatch("[^\n]+") do
        print("   " .. line)
      end
      if (cut or 0) > 0 then
        print(string.format("   (%d more watched mob%s didn't fit in 255 characters)", cut, cut == 1 and "" or "s"))
      end
    end
    if not Macro:Ours(self.char.macro, IsScanBody) then
      print("   no QRareScan macro yet (/arl rare makemacro).")
    end
    if macroPending then
      print("   (an update is waiting for combat to end)")
    end
  end },
  { name = "test", help = "shows a test alert", run = function(self) self:Test() end },
}

ARLE:RegisterModule(F)
