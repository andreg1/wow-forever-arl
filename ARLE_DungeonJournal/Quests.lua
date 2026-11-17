-- Dungeon Helper, Quests tab: the dungeon's quests (DungeonJournal's list,
-- for the player's faction and character) on the left, grouped by where the
-- player stands with each; the selected quest on the right: what it asks,
-- where it starts and ends, its rewards, the quests that unlock it, the
-- quests that follow it, and the party's progress.
--
-- Chains:
--   Before: DungeonJournal's curated "required to unlock" lists
--     (QUEST_PREREQ_CHAINS: breadcrumbs left out on purpose; QUEST_GUIDE_CHAINS
--     marks lists that are how to do the quest rather than what unlocks it).
--     When it has none, QuestieDB's preQuestGroup (all needed) and
--     preQuestSingle (one of them is enough), walked back to the start.
--   After: QuestieDB's nextQuestInChain, walked forward.
-- QuestieDB is optional: without it, only DungeonJournal's chains show.
--
-- Party members with ARL share their state of each quest ("QS"), shown as
-- class-coloured squares like the loot's.
local _, ns = ...
local ARLE = _G.ARLExtensions
local H = ns.H
if not ARLE or not H then
  return
end
local mod = H.mod
local Kit = ARLE.UI.Kit
local S = H.Script
local Members, Me, ColorName, TooltipSide = H.Members, H.Me, H.ColorName, H.TooltipSide
local QDB = ARLE.Bridge.QuestieDB
local LQ = ARLE.Lib.Quests

local ROW_H, STEP_H = 18, 16
local CHAIN_MAX, WALK_MAX = 25, 15

local tab = { key = "quests", label = "Quests" }
H.tabs[#H.tabs + 1] = tab

-- State codes, shared in messages too.
--   r ready to turn in, l in the quest log, a available (level OK, nothing
--   left before it), c level OK but earlier quests of its chain aren't done,
--   n not yet (level too low), d done
local SECTIONS = {
  { codes = { r = true, l = true }, label = "In your quest log" },
  { codes = { a = true }, label = "Available" },
  { codes = { c = true }, label = "Needs earlier quests" },
  { codes = { n = true }, label = "Level too low" },
  { codes = { d = true }, label = "Done" },
}
local STATE_TEXT = {
  r = "|cff40ff60ready to turn in|r",
  l = "in the quest log",
  a = "available",
  c = "needs earlier quests",
  n = "level too low",
  d = "|cff999999done|r",
}
local ICONS = {
  r = "Interface\\GossipFrame\\ActiveQuestIcon",
  l = "Interface\\GossipFrame\\ActiveQuestIcon",
  a = "Interface\\GossipFrame\\AvailableQuestIcon",
  c = "Interface\\GossipFrame\\AvailableQuestIcon",
  n = "Interface\\GossipFrame\\AvailableQuestIcon",
  d = "Interface\\RaidFrame\\ReadyCheck-Ready",
}
local LOCK = "|TInterface\\PetBattles\\PetBattle-LockIcon:12:12|t"
local DUNGEON_ICON = "|TInterface\\Minimap\\Dungeon:12:12|t"

-------------------------------------------------------------------------------
-- Quests and states
-------------------------------------------------------------------------------

local IsDone = LQ.IsDone

local function InLog(id)
  return (LQ.InLog(id))
end

-- FDJ's helper, pcall'd: ok, result (ok false when it isn't there).
local function FDJCall(name, ...)
  local fdj = H.FDJ()
  local fn = fdj and fdj[name]
  if type(fn) ~= "function" then
    return false
  end
  local ok, res = pcall(fn, ...)
  return ok, res
end

local function PlayerClass()
  if not UnitClass then
    return nil
  end
  local ok, _, token = pcall(UnitClass, "player")
  token = ok and H.Plain(token)
  return type(token) == "string" and token ~= "" and token:upper() or nil
end

-- Whether the quest is for this character, by DungeonJournal's rules
-- (Journal.lua QuestMatchesFaction / QuestCountsForCharacter /
-- IsQuestUnavailable): another class's quest, a profession quest without the
-- profession, one not in the game now or not for this race, are left out.
-- Chain steps DungeonJournal keeps off its list (hideFromMainList) only show
-- while in the quest log: the rest are in the chains of the quests they lead to.
local function ForMe(q, id)
  if q.hideFromMainList and not InLog(id) then
    return false
  end
  local ok, counts = FDJCall("QuestCountsForCharacter", q)
  if ok then
    if not counts then
      return false
    end
  else
    local class = PlayerClass()
    if q.classOnly and class and tostring(q.classOnly):upper() ~= class then
      return false
    end
    if q.profession then
      local okP, has = FDJCall("PlayerHasProfession", q.profession)
      if okP and not has then
        return false
      end
    end
  end
  local okU, unavailable = FDJCall("IsQuestUnavailable", q)
  if okU then
    return not unavailable
  end
  local race = false
  if type(q.unavailableRaces) == "table" then
    local okR, r = FDJCall("IsQuestRaceUnavailable", q)
    race = okR and r or false
  end
  return not ((q.unavailable or race) and not IsDone(id))
end

local function Quests(dungeon)
  local fdj = H.FDJ()
  local d = fdj and dungeon and fdj.DB[dungeon]
  local faction = UnitFactionGroup and UnitFactionGroup("player")
  local list = {}
  for _, q in ipairs(d and d.quests or {}) do
    local id = type(q) == "table" and tonumber(q.id)
    if id and q.name
        and (not q.faction or q.faction == "Both" or q.faction == "Neutral" or not faction or q.faction == faction)
        and ForMe(q, id) then
      list[#list + 1] = q
    end
  end
  return list
end
tab.Quests = Quests

-- Every quest DungeonJournal describes, by ID (any dungeon's list), built once.
local journalByID
local function JournalQuest(id)
  if not journalByID then
    journalByID = {}
    local fdj = H.FDJ()
    for _, d in pairs(fdj and fdj.DB or {}) do
      for _, q in ipairs(type(d) == "table" and d.quests or {}) do
        local qid = type(q) == "table" and tonumber(q.id)
        if qid and not journalByID[qid] then
          journalByID[qid] = q
        end
      end
    end
  end
  return journalByID[id]
end

local function Str(v)
  return type(v) == "string" and v ~= "" and v or nil
end

-- What is known of any quest (a chain step too): id, name, level, requires,
-- objective, pickup, turnin, startsInDungeon. DungeonJournal's entry, its
-- pre-quest details, then QuestieDB, then the game.
local infoCache = {}
local function Info(id, fallbackName)
  id = tonumber(id)
  if not id then
    return nil
  end
  local cached = infoCache[id]
  if cached then
    return cached
  end
  local fdj = H.FDJ() or {}
  local q = JournalQuest(id) or {}
  local det = type(fdj.QUEST_PREREQ_DETAILS) == "table" and fdj.QUEST_PREREQ_DETAILS[id] or {}
  local title = C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(id)
  local info = {
    id = id,
    name = Str(q.name) or Str(QDB.Quest(id, "name")) or Str(title) or Str(fallbackName) or ("Quest " .. id),
    level = tonumber(q.level) or tonumber(det.level) or tonumber(QDB.Quest(id, "questLevel")),
    requires = tonumber(q.requires) or tonumber(det.requires) or tonumber(QDB.Quest(id, "requiredLevel")),
    objective = Str(q.objective) or Str(det.objective),
    pickup = Str(q.pickup) or Str(det.pickup),
    turnin = Str(q.turnin) or Str(det.turnin),
    note = Str(q.note),
    startsInDungeon = (q.startsInDungeon or det.startsInDungeon) and true or false,
  }
  if not info.startsInDungeon and info.pickup then
    local ok, inside = FDJCall("StartsInsideDungeon", info.pickup)
    info.startsInDungeon = ok and inside and true or false
  end
  if not info.objective then
    local text = QDB.Quest(id, "objectivesText")
    if type(text) == "table" then
      local parts = {}
      for _, line in ipairs(text) do
        if Str(line) then
          parts[#parts + 1] = line
        end
      end
      info.objective = #parts > 0 and table.concat(parts, " ") or nil
    end
  end
  infoCache[id] = info
  return info
end

local function Objectives(id)
  local list = C_QuestLog and C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(id)
  return type(list) == "table" and list or {}
end

-- "3/8" summed over the quest's objectives, or nil.
local function Progress(id)
  local have, need = 0, 0
  for _, o in ipairs(Objectives(id)) do
    if tonumber(o.numRequired) and o.numRequired > 0 then
      have = have + math.min(tonumber(o.numFulfilled) or 0, o.numRequired)
      need = need + o.numRequired
    end
  end
  if need > 0 then
    return have .. "/" .. need
  end
end

local function IDs(v)
  if type(v) == "number" then
    return { v }
  end
  return type(v) == "table" and v or {}
end

-- The quests before this one, oldest first: { {id, name, anyOf}, ... } and
-- where they came from ("journal", "guide" or "questie"), or nil. anyOf: one
-- of several alternatives (QuestieDB's preQuestSingle), the others named.
local chainCache = {}
local function Before(id)
  id = tonumber(id)
  if chainCache[id] ~= nil then
    return chainCache[id] or nil, chainCache[id] and chainCache[id].source
  end
  local fdj = H.FDJ() or {}
  local curated = type(fdj.QUEST_PREREQ_CHAINS) == "table" and fdj.QUEST_PREREQ_CHAINS[id]
  local steps
  if type(curated) == "table" and #curated > 0 then
    steps = { source = (type(fdj.QUEST_GUIDE_CHAINS) == "table" and fdj.QUEST_GUIDE_CHAINS[id]) and "guide"
      or "journal" }
    for _, step in ipairs(curated) do
      if type(step) == "table" and tonumber(step.id) and tonumber(step.id) ~= id then
        steps[#steps + 1] = { id = tonumber(step.id), name = step.name }
      end
    end
  elseif QDB.Ready() then
    -- Walk back: every quest of preQuestGroup, and one of preQuestSingle
    -- (one already done if there is, else the first), deepest first.
    steps = { source = "questie" }
    local seen = { [id] = true }
    local function Walk(qid, depth)
      if depth > WALK_MAX or #steps >= CHAIN_MAX then
        return
      end
      for _, pre in ipairs(IDs(QDB.Quest(qid, "preQuestGroup"))) do
        if not seen[pre] then
          seen[pre] = true
          Walk(pre, depth + 1)
          steps[#steps + 1] = { id = pre }
        end
      end
      local single = IDs(QDB.Quest(qid, "preQuestSingle"))
      if #single > 0 then
        local pick = single[1]
        for _, pre in ipairs(single) do
          if IsDone(pre) then
            pick = pre
            break
          end
        end
        if not seen[pick] then
          seen[pick] = true
          Walk(pick, depth + 1)
          local others = {}
          for _, pre in ipairs(single) do
            if pre ~= pick then
              others[#others + 1] = pre
            end
          end
          steps[#steps + 1] = { id = pick, anyOf = #others > 0 and others or nil }
        end
      end
    end
    Walk(id, 1)
  end
  if steps and #steps == 0 then
    steps = nil
  end
  chainCache[id] = steps or false
  return steps, steps and steps.source
end

-- The quests after this one (QuestieDB's nextQuestInChain), in order.
local afterCache = {}
local function After(id)
  id = tonumber(id)
  if afterCache[id] ~= nil then
    return afterCache[id] or nil
  end
  local steps = {}
  local seen = { [id] = true }
  local next = tonumber(QDB.Quest(id, "nextQuestInChain"))
  while next and next > 0 and not seen[next] and #steps < WALK_MAX do
    seen[next] = true
    steps[#steps + 1] = { id = next }
    next = tonumber(QDB.Quest(next, "nextQuestInChain"))
  end
  afterCache[id] = #steps > 0 and steps or false
  return afterCache[id] or nil
end

-- How many of the quests before this one aren't done (a guide chain is
-- how to do it, not what unlocks it: it never blocks).
local function Missing(id)
  local steps, source = Before(id)
  if not steps or source == "guide" then
    return 0
  end
  local n = 0
  for _, step in ipairs(steps) do
    if not IsDone(step.id) then
      local alt = false
      for _, other in ipairs(step.anyOf or {}) do
        alt = alt or IsDone(other)
      end
      if not alt then
        n = n + 1
      end
    end
  end
  return n
end

-- The player's state for a quest: code, progress.
local function MyState(q)
  local id = tonumber(q.id)
  if IsDone(id) then
    return "d"
  end
  if InLog(id) then
    if C_QuestLog.IsComplete and C_QuestLog.IsComplete(id) then
      return "r"
    end
    return "l", Progress(id)
  end
  if (UnitLevel("player") or 0) < (tonumber(q.requires) or 0) then
    return "n"
  end
  if Missing(id) > 0 then
    return "c"
  end
  return "a"
end
tab.MyState = MyState

-- party[name] = { dungeon, states = { [questID] = { code, progress } } }
local party = {}
tab.data = party

-------------------------------------------------------------------------------
-- Comms: "QS <dungeon>~<part>~<total>~id:code[:have/need],..."
-------------------------------------------------------------------------------

local lastSent = {}
function tab:Send(dungeon, channel, force)
  local list = {}
  for _, q in ipairs(Quests(dungeon)) do
    local code, progress = MyState(q)
    list[#list + 1] = q.id .. ":" .. code .. (progress and (":" .. progress) or "")
  end
  local key = table.concat(list, ",")
  if not force and lastSent[dungeon] == key then
    return
  end
  lastSent[dungeon] = key
  H.SendChunks("QS", dungeon, list, ",", channel)
end

ARLE:RegisterComm("QS", function(sender, payload)
  if not mod._active then
    return
  end
  local dungeon, part, list = payload:match("^(.-)~(%d+)~%d+~(.*)$")
  if not dungeon then
    return
  end
  local p = party[sender]
  if not p or p.dungeon ~= dungeon or tonumber(part) == 1 then
    p = { dungeon = dungeon, states = {} }
    party[sender] = p
  end
  for entry in list:gmatch("[^,]+") do
    local id, code, progress = entry:match("^(%d+):(%a)(.*)$")
    if id then
      p.states[tonumber(id)] = { code = code, progress = progress:match("^:(.+)$") }
    end
  end
  H.Render()
end)

function tab:OnQuestChange()
  wipe(chainCache) -- (a preQuestSingle pick follows what's done)
  if H.shown then
    H.QueueSend(H.shown, "quests")
  end
  H.Render()
end

function tab:Prune(keep)
  for name in pairs(party) do
    if not keep[name] then
      party[name] = nil
    end
  end
end

-------------------------------------------------------------------------------
-- View
-------------------------------------------------------------------------------

local selected = {} -- dungeon -> quest ID
local listPool, sectionPool, listEmpty
local detail = {}

local function Filter()
  return mod.db.questFilter or "all"
end

local function DifficultyColor(level)
  if GetQuestDifficultyColor and tonumber(level) then
    local c = GetQuestDifficultyColor(tonumber(level))
    if type(c) == "table" and c.r then
      return c.r, c.g, c.b
    end
  end
  return 1, 0.82, 0
end

local function Hex(r, g, b)
  return string.format("|cff%02x%02x%02x", r * 255, g * 255, b * 255)
end

local function PartyStates(id)
  local out = {}
  for _, m in ipairs(Members()) do
    if m.unit ~= "player" then
      local p = party[m.name]
      if p and p.dungeon == H.shown then
        out[#out + 1] = { member = m, state = p.states[tonumber(id)] }
      end
    end
  end
  return out
end

local function Share(id)
  local fdj = H.FDJ()
  if fdj and fdj.ShareQuestByID then
    pcall(fdj.ShareQuestByID, tonumber(id))
    return
  end
  if C_QuestLog.SetSelectedQuest then
    pcall(C_QuestLog.SetSelectedQuest, id)
  elseif SelectQuestLogEntry then
    pcall(SelectQuestLogEntry, C_QuestLog.GetLogIndexForQuestID(id))
  end
  if QuestLogPushQuest then
    pcall(QuestLogPushQuest)
  end
end

local function Link(id, name, level)
  LQ.InsertLink(tonumber(id), name, tonumber(level))
end

local function PartyTooltip(owner)
  GameTooltip:SetOwner(owner, TooltipSide(owner))
  GameTooltip:SetText("Party", 1, 1, 1)
  for _, m in ipairs(Members()) do
    local p = party[m.name]
    if m.unit == "player" or (p and p.dungeon == H.shown) then
      GameTooltip:AddDoubleLine(ColorName(m), "shares quests", 1, 1, 1, 0.45, 0.9, 0.5)
    else
      GameTooltip:AddDoubleLine(ColorName(m), "no ARL", 1, 1, 1, 0.5, 0.5, 0.5)
    end
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Squares: ARL members in the party.", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("Full: has it in the quest log", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("|cffffd100Gold edge|r: ready to turn in", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("Faded: can pick it up", 0.8, 0.8, 0.8)
  GameTooltip:Show()
end

-- A chain step's hover: what is known of it.
local function StepTooltip(row)
  local info = Info(row.id, row.stepName)
  GameTooltip:SetOwner(row, TooltipSide(row))
  GameTooltip:SetText(info.name, DifficultyColor(info.level))
  local lv = {}
  if info.level then
    lv[#lv + 1] = "Level " .. info.level
  end
  if info.requires then
    lv[#lv + 1] = "needs " .. info.requires
  end
  if #lv > 0 then
    GameTooltip:AddLine(table.concat(lv, "  ·  "), 0.7, 0.7, 0.7)
  end
  if info.objective then
    GameTooltip:AddLine(info.objective, 1, 1, 1, true)
  end
  if info.pickup then
    GameTooltip:AddLine("|cffffd100Pick up:|r " .. info.pickup, 0.85, 0.85, 0.85, true)
  end
  if info.turnin then
    GameTooltip:AddLine("|cffffd100Turn in:|r " .. info.turnin, 0.85, 0.85, 0.85, true)
  end
  if row.anyOf then
    local names = {}
    for _, other in ipairs(row.anyOf) do
      names[#names + 1] = Info(other).name
    end
    GameTooltip:AddLine("Or instead: " .. table.concat(names, ", "), 0.6, 0.8, 1, true)
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Shift-click: link it.", 0.6, 0.6, 0.6)
  GameTooltip:Show()
end

local function Select(id)
  if H.shown and selected[H.shown] ~= id then
    selected[H.shown] = id
    H.DetailToTop()
  end
  H.Render()
end

function tab:Create(bar, list, detailFrame)
  self.filters = H.FilterButtons(bar, {
    { key = "all", label = "All", tip = "Every quest of this dungeon for your character" },
    { key = "todo", label = "To do", tip = "Quests you haven't done yet" },
    { key = "party", label = "Party", tip = "Quests someone in the party (you too) has in their quest log" },
  }, Filter, function(key)
    mod.db.questFilter = key
  end)
  self.partyButton = CreateFrame("Button", nil, bar)
  self.partyButton:SetPoint("LEFT", self.filters.last, "RIGHT", 8, 0)
  self.partyButton:SetSize(160, 18)
  self.partyButton.text = Kit.Text(self.partyButton, "GameFontHighlightSmall")
  self.partyButton.text:SetPoint("LEFT")
  S(self.partyButton, "OnEnter", PartyTooltip)
  S(self.partyButton, "OnLeave", GameTooltip_Hide)

  listPool = H.Pool(function()
    local r = H.Row(list, ROW_H, 12)
    S(r, "OnClick", function(row, button)
      if IsModifiedClick and IsModifiedClick("CHATLINK") then
        Link(row.id, row.quest.name, row.quest.level)
      elseif button == "RightButton" and (row.code == "l" or row.code == "r") then
        Share(row.id)
      else
        Select(row.id)
      end
    end)
    H.Tip(r, function(row)
      return row.quest.name
    end, function(row)
      return STATE_TEXT[row.code] .. ((row.code == "l" or row.code == "r") and "\nRight-click: share it with "
        .. "the party." or "") .. "\nShift-click: link it."
    end)
    return r
  end)
  sectionPool = H.Pool(function()
    return H.Section(list)
  end)
  listEmpty = Kit.Text(list, "GameFontDisableSmall")

  -- Details: the title, its facts and text, then the chain and the party.
  detail.frame = detailFrame
  detail.title = Kit.Text(detailFrame, "GameFontNormal")
  detail.title:SetWordWrap(true)
  detail.share = H.SmallButton(detailFrame, "Share", 44)
  detail.share:SetPoint("TOPRIGHT", -2, -2)
  S(detail.share, "OnClick", function()
    Share(detail.id)
  end)
  H.Tip(detail.share, "Share", "Offers the quest to the party (it must be in your quest log).")
  detail.link = H.SmallButton(detailFrame, "Link", 36)
  detail.link:SetPoint("RIGHT", detail.share, "LEFT", -2, 0)
  S(detail.link, "OnClick", function()
    local info = Info(detail.id)
    if info then
      Link(info.id, info.name, info.level)
    end
  end)
  H.Tip(detail.link, "Link", "Puts the quest's link in the chat box.")
  detail.paras = H.Pool(function()
    local fs = Kit.Text(detailFrame, "GameFontHighlightSmall")
    return fs
  end)
  detail.sections = H.Pool(function()
    return H.Section(detailFrame)
  end)
  detail.steps = H.Pool(function()
    local r = H.Row(detailFrame, STEP_H, 12)
    S(r, "OnEnter", StepTooltip)
    S(r, "OnLeave", GameTooltip_Hide)
    S(r, "OnClick", function(row)
      if IsModifiedClick and IsModifiedClick("CHATLINK") then
        local info = Info(row.id, row.stepName)
        Link(info.id, info.name, info.level)
      end
    end)
    return r
  end)
  detail.rewards = H.Pool(function()
    local r = H.Row(detailFrame, STEP_H, STEP_H - 2)
    r.pic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    S(r, "OnEnter", function(row)
      GameTooltip:SetOwner(row, TooltipSide(row))
      GameTooltip:SetItemByID(row.itemID)
      GameTooltip:Show()
    end)
    S(r, "OnLeave", GameTooltip_Hide)
    S(r, "OnClick", function(row)
      if IsModifiedClick and IsModifiedClick("CHATLINK") then
        local _, link = H.GetItemInfo(row.itemID)
        if link and ChatEdit_InsertLink then
          ChatEdit_InsertLink(link)
        end
      end
    end)
    return r
  end)
end

-- One quest's entry for the list and the details.
local function Entry(q)
  local code, progress = MyState(q)
  return { q = q, id = tonumber(q.id), code = code, progress = progress, states = PartyStates(q.id),
    missing = code == "c" and Missing(q.id) or 0 }
end

local function Marks(states)
  local marks = {}
  for _, ps in ipairs(states) do
    local s = ps.state and ps.state.code
    if s == "l" or s == "r" or s == "a" then
      marks[#marks + 1] = { class = ps.member.class, strong = s == "r", weak = s == "a" }
    end
  end
  return marks
end

local view
function tab:RenderList(width)
  self.filters.Paint()
  local filter = Filter()
  local members = Members()
  local sharing = 1
  for _, m in ipairs(members) do
    local p = party[m.name]
    if m.unit ~= "player" and p and p.dungeon == H.shown then
      sharing = sharing + 1
    end
  end
  self.partyButton.text:SetText("Party: " .. sharing .. "/" .. #members .. " with ARL")

  local quests = Quests(H.shown)
  local bySection, byID, first = {}, {}, nil
  for _, q in ipairs(quests) do
    local e = Entry(q)
    local anyLog = e.code == "l" or e.code == "r"
    for _, ps in ipairs(e.states) do
      local s = ps.state and ps.state.code
      anyLog = anyLog or s == "l" or s == "r"
    end
    local keep = filter == "all" or (filter == "todo" and e.code ~= "d") or (filter == "party" and anyLog)
    if e.code == "d" and not mod.db.questShowDone then
      keep = false
    end
    if keep then
      for si, sec in ipairs(SECTIONS) do
        if sec.codes[e.code] then
          bySection[si] = bySection[si] or {}
          table.insert(bySection[si], e)
        end
      end
      byID[e.id] = e
    end
  end

  local y = 0
  for si, sec in ipairs(SECTIONS) do
    local list = bySection[si]
    if list then
      table.sort(list, function(a, b)
        if a.code ~= b.code then
          return a.code == "r" -- ready before in progress
        end
        local la, lb = tonumber(a.q.level) or 0, tonumber(b.q.level) or 0
        if la ~= lb then
          return la < lb
        end
        return a.q.name < b.q.name
      end)
      local h = sectionPool:Get()
      H.PaintSection(h, sec.label, "|cff888888" .. #list .. "|r")
      y = H.Place(h, y + (y > 0 and 4 or 0), 18)
      for _, e in ipairs(list) do
        first = first or e.id
        local r = listPool:Get()
        r.id, r.quest, r.code = e.id, e.q, e.code
        r.pic:SetTexture(ICONS[e.code])
        r.pic:SetDesaturated(e.code == "l" or e.code == "n" or e.code == "c")
        r.pic:SetAlpha((e.code == "n" or e.code == "d" or e.code == "c") and 0.5 or 1)
        local note
        if e.code == "r" then
          note = "|cff40ff60done|r"
        elseif e.progress then
          note = e.progress
        elseif e.code == "c" then
          note = LOCK .. "|cff999999" .. e.missing .. "|r"
        end
        local name = (e.q.level and ("[" .. e.q.level .. "] ") or "") .. e.q.name
        H.PaintRow(r, name, note, Marks(e.states), e.id == (selected[H.shown or ""] or nil))
        if e.code == "d" then
          r.name:SetTextColor(0.5, 0.5, 0.5)
        else
          r.name:SetTextColor(DifficultyColor(e.q.level))
        end
        y = H.Place(r, y, ROW_H)
      end
    end
  end
  listPool:Done()
  sectionPool:Done()

  -- The selection: kept while it's listed, else the first quest.
  if H.shown and not byID[selected[H.shown]] then
    selected[H.shown] = first
    -- (the rows just drawn showed no selection: the next render does)
    if first then
      H.Render()
    end
  end
  view = { byID = byID }

  listEmpty:SetShown(y == 0)
  if y == 0 then
    local text
    if not H.shown then
      text = "Not in a dungeon. Pick one with the v button."
    elseif #quests == 0 then
      text = "DungeonJournal lists no quests here for your character."
    else
      text = "No quests match. Try All."
    end
    y = H.Para(listEmpty, 6, width, text)
  end
  return y
end

-- A chain step's state for the player: icon code, note.
local function StepState(id, nextUp)
  if IsDone(id) then
    return "d", "|cff999999done|r"
  end
  if InLog(id) then
    if C_QuestLog.IsComplete and C_QuestLog.IsComplete(id) then
      return "r", "|cff40ff60ready|r"
    end
    return "l", Progress(id) or "in your log"
  end
  if nextUp then
    return "a", "|cffffd100next|r"
  end
  return "n", ""
end

function tab:RenderDetail(width)
  local e = view and H.shown and view.byID[selected[H.shown]]
  detail.paras:Done()
  detail.sections:Done()
  detail.steps:Done()
  detail.rewards:Done()
  if not e then
    detail.title:Hide()
    detail.share:Hide()
    detail.link:Hide()
    return 1
  end
  local q, id = e.q, e.id
  detail.id = id
  local info = Info(id)
  detail.title:Show()
  detail.link:Show()
  detail.share:Show()
  detail.share:SetEnabled(e.code == "l" or e.code == "r")
  detail.title:ClearAllPoints()
  detail.title:SetPoint("TOPLEFT", 6, -4)
  detail.title:SetWidth(width - 100)
  detail.title:SetText((info.startsInDungeon and (DUNGEON_ICON .. " ") or "") .. q.name)
  detail.title:SetTextColor(DifficultyColor(q.level))
  local y = 4 + math.max(detail.title:GetStringHeight() or 14, 14) + 4

  local function Para(text, r, g, b)
    if not text then
      return
    end
    local fs = detail.paras:Get()
    fs:SetTextColor(r or 0.85, g or 0.85, b or 0.85)
    y = H.Para(fs, y, width, text, 3)
  end
  local function Section(label, note)
    local h = detail.sections:Get()
    H.PaintSection(h, label, note)
    y = H.Place(h, y + 4, 18)
  end

  local facts = {}
  if q.level then
    facts[#facts + 1] = "Level " .. q.level
  end
  if q.requires then
    facts[#facts + 1] = "needs " .. q.requires
  end
  if q.faction and q.faction ~= "Both" and q.faction ~= "Neutral" then
    facts[#facts + 1] = q.faction
  end
  facts[#facts + 1] = STATE_TEXT[e.code] .. (e.progress and (" " .. e.progress) or "")
  Para(table.concat(facts, "  ·  "), 0.7, 0.7, 0.7)
  if info.startsInDungeon then
    Para(DUNGEON_ICON .. " Starts inside the dungeon.", 0.6, 0.8, 1)
  end
  Para(info.objective, 1, 1, 1)
  if e.code == "l" or e.code == "r" then
    for _, o in ipairs(Objectives(id)) do
      if o.text and o.text ~= "" then
        if o.finished then
          Para("  - " .. o.text, 0.4, 1, 0.45)
        else
          Para("  - " .. o.text, 0.85, 0.85, 0.85)
        end
      end
    end
  end
  if info.pickup then
    Para("|cffffd100Pick up:|r " .. info.pickup)
  end
  if info.turnin then
    Para("|cffffd100Turn in:|r " .. info.turnin)
  end
  if info.note then
    Para(info.note, 0.6, 0.8, 1)
  end

  -- Rewards: the items, each marked when it's an upgrade for you.
  local items = type(q.rewardItems) == "table" and q.rewardItems or {}
  if #items > 0 or Str(q.rewards) or Str(q.rewardSummary) then
    Section("Rewards", q.rewardChoice and "|cff888888pick one|r" or nil)
    local flb = H.FLB()
    for _, item in ipairs(items) do
      local itemID = type(item) == "table" and tonumber(item[1])
      if itemID then
        local r = detail.rewards:Get()
        r.itemID = itemID
        r.pic:SetTexture(H.GetItemIcon(itemID) or 134400)
        local note = ""
        if flb and flb.GetGain then
          local ok, gain = pcall(flb.GetGain, itemID)
          if ok and type(gain) == "number" and gain > 0 then
            note = string.format("|cff66ff66+%.1f|r", gain)
          end
        end
        H.PaintRow(r, (H.GetItemInfo(itemID)) or item[2] or ("item " .. itemID), note, nil, false)
        r.name:SetTextColor(H.QualityColor(tonumber(item[3]) or 1))
        y = H.Place(r, y, STEP_H, 0)
      end
    end
    if #items == 0 then
      local text = (Str(q.rewards) or q.rewardSummary):gsub("\n", "  ·  ")
      Para(text)
    end
  end

  -- The chain: what comes before (to unlock it), and what follows.
  local before, source = Before(id)
  local function Steps(list)
    local nextShown = false
    for _, step in ipairs(list) do
      local r = detail.steps:Get()
      local sInfo = Info(step.id, step.name)
      r.id, r.stepName, r.anyOf = step.id, step.name, step.anyOf
      local done = IsDone(step.id)
      for _, other in ipairs(step.anyOf or {}) do
        done = done or IsDone(other)
      end
      local code, note = StepState(step.id, not done and not nextShown)
      if done and code ~= "d" then
        code, note = "d", "|cff999999done (another)|r"
      end
      nextShown = nextShown or not done
      r.pic:SetTexture(ICONS[code])
      r.pic:SetDesaturated(code == "n")
      r.pic:SetAlpha(code == "n" and 0.5 or 1)
      local name = (sInfo.level and ("[" .. sInfo.level .. "] ") or "") .. sInfo.name
        .. (step.anyOf and " |cff888888(or " .. #step.anyOf .. " other)|r" or "")
        .. (sInfo.startsInDungeon and (" " .. DUNGEON_ICON) or "")
      H.PaintRow(r, name, note, nil, false)
      if code == "d" then
        r.name:SetTextColor(0.5, 0.5, 0.5)
      else
        r.name:SetTextColor(DifficultyColor(sInfo.level))
      end
      y = H.Place(r, y, STEP_H, 0)
    end
  end
  if before then
    local left = Missing(id)
    if source == "guide" then
      Section("How to do it", "|cff888888" .. #before .. " steps|r")
    else
      Section("Before this quest", left > 0 and (LOCK .. " " .. left .. " left") or "|cff40ff60all done|r")
    end
    Steps(before)
    if source == "questie" then
      Para("From QuestieDB.", 0.5, 0.5, 0.5)
    end
  end
  local after = After(id)
  if after then
    Section("After this quest", "|cff888888" .. #after .. " more|r")
    Steps(after)
  end
  if not before and not after then
    Para(QDB.Ready() and "Not part of a chain." or "Not part of a chain DungeonJournal knows (QuestieDB would "
      .. "know more).", 0.5, 0.5, 0.5)
  end

  -- The party.
  local states = e.states
  if #Members() > 1 then
    Section("Party")
    for _, m in ipairs(Members()) do
      local text
      if m.unit == "player" then
        text = STATE_TEXT[e.code] .. (e.progress and (" " .. e.progress) or "")
      else
        local found
        for _, ps in ipairs(states) do
          if ps.member.name == m.name then
            found = ps
          end
        end
        local s = found and found.state
        text = found and (s and ((STATE_TEXT[s.code] or s.code) .. (s.progress and (" " .. s.progress) or "")) or "?")
          or "|cff888888no ARL|r"
      end
      local cr, cg, cb = H.ClassColor(m.class)
      Para(Hex(cr, cg, cb) .. m.name .. "|r  " .. text)
    end
  end
  return y + 4
end

function tab:Status()
  local open = 0
  for _, q in ipairs(Quests(H.shown)) do
    local code = MyState(q)
    if code == "l" or code == "r" then
      open = open + 1
    end
  end
  return open .. " quest(s) in your log"
end
