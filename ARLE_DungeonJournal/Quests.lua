-- Dungeon Helper, Quests tab: the dungeon's quests from DungeonJournal, for
-- the player's faction, grouped by where the player stands with each one:
-- in the quest log (with progress), ready to turn in, level OK (only the
-- level is checked), not yet (level), done. Quests DungeonJournal doesn't
-- count for the character (another class, a missing profession, not in the
-- game, not for this race) are left out. Party members with the addon share theirs, shown as
-- class-coloured squares like the BiS Finder's.
local _, ns = ...
local ARLE = _G.ARLExtensions
local H = ns.H
if not ARLE or not H then
  return
end
local mod = H.mod
local Members, Me, ColorName, TooltipSide = H.Members, H.Me, H.ColorName, H.TooltipSide

local HEAD_H, ROW_H, MARK, MAX_MARKS = 18, 16, 8, 4

local tab = { key = "quests", label = "Quests" }
H.tabs[#H.tabs + 1] = tab

-- State codes, shared in messages too.
--   r ready to turn in, l in the quest log, a level OK (only the level is
--   checked: not the quests before it in a chain), n not yet (level too
--   low), d done
local SECTIONS = {
  { codes = { r = true, l = true }, label = "In your quest log" },
  { codes = { a = true }, label = "Level OK (not in your log)" },
  { codes = { n = true }, label = "Not yet" },
  { codes = { d = true }, label = "Done" },
}
local STATE_TEXT = {
  r = "|cff40ff60ready to turn in|r",
  l = "in the quest log",
  a = "level OK",
  n = "level too low",
  d = "|cff999999done|r",
}
local ICONS = {
  r = "Interface\\GossipFrame\\ActiveQuestIcon",
  l = "Interface\\GossipFrame\\ActiveQuestIcon",
  a = "Interface\\GossipFrame\\AvailableQuestIcon",
  n = "Interface\\GossipFrame\\AvailableQuestIcon",
  d = "Interface\\RaidFrame\\ReadyCheck-Ready",
}

-------------------------------------------------------------------------------
-- Quests and states
-------------------------------------------------------------------------------

local function IsDone(id)
  if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
    return C_QuestLog.IsQuestFlaggedCompleted(id) == true
  end
  return _G.IsQuestFlaggedCompleted and _G.IsQuestFlaggedCompleted(id) == true or false
end

local function InLog(id)
  local index = C_QuestLog and C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(id)
  return index and index > 0
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
-- while in the quest log.
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
  if (UnitLevel("player") or 0) >= (tonumber(q.requires) or 0) then
    return "a"
  end
  return "n"
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

function tab:Reset()
  wipe(party)
  wipe(lastSent)
end

-------------------------------------------------------------------------------
-- View
-------------------------------------------------------------------------------

local child, emptyText
local headers, rows = {}, {}
local FILTERS = {
  { key = "all", label = "All", tip = "Every quest of this dungeon for your faction" },
  { key = "todo", label = "To do", tip = "Quests you haven't done yet" },
  { key = "party", label = "Party", tip = "Quests someone in the party (you too) has in their quest log" },
}

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

local function PartyStates(q)
  local out = {}
  for _, m in ipairs(Members()) do
    if m.unit ~= "player" then
      local p = party[m.name]
      if p and p.dungeon == H.shown then
        out[#out + 1] = { member = m, state = p.states[tonumber(q.id)] }
      end
    end
  end
  return out
end

local function QuestTooltip(row)
  local q = row.quest
  GameTooltip:SetOwner(row, TooltipSide(row))
  GameTooltip:SetText(q.name, DifficultyColor(q.level))
  local lv = {}
  if q.level then
    lv[#lv + 1] = "Level " .. q.level
  end
  if q.requires then
    lv[#lv + 1] = "needs " .. q.requires
  end
  if q.faction and q.faction ~= "Both" then
    lv[#lv + 1] = q.faction
  end
  if #lv > 0 then
    GameTooltip:AddLine(table.concat(lv, "  ·  "), 0.7, 0.7, 0.7)
  end
  if q.objective then
    GameTooltip:AddLine(q.objective, 1, 1, 1, true)
  end
  if row.code == "l" or row.code == "r" then
    for _, o in ipairs(Objectives(tonumber(q.id))) do
      if o.text and o.text ~= "" then
        if o.finished then
          GameTooltip:AddLine("  - " .. o.text, 0.4, 1, 0.45, true)
        else
          GameTooltip:AddLine("  - " .. o.text, 0.85, 0.85, 0.85, true)
        end
      end
    end
  end
  if q.pickup then
    GameTooltip:AddLine("|cffffd100Pick up:|r " .. q.pickup, 0.85, 0.85, 0.85, true)
  end
  if q.turnin then
    GameTooltip:AddLine("|cffffd100Turn in:|r " .. q.turnin, 0.85, 0.85, 0.85, true)
  end
  if q.rewards and q.rewards ~= "" then
    GameTooltip:AddLine("|cffffd100Rewards:|r " .. tostring(q.rewards):gsub("\n", "  ·  "), 0.85, 0.85, 0.85, true)
  end
  if q.note then
    GameTooltip:AddLine(q.note, 0.6, 0.8, 1, true)
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddDoubleLine(ColorName(Members()[1]), STATE_TEXT[row.code] .. (row.progress and (" " .. row.progress) or ""),
    1, 1, 1, 0.85, 0.85, 0.85)
  for _, ps in ipairs(PartyStates(q)) do
    local s = ps.state
    GameTooltip:AddDoubleLine(ColorName(ps.member), s and ((STATE_TEXT[s.code] or s.code)
      .. (s.progress and (" " .. s.progress) or "")) or "?", 1, 1, 1, 0.85, 0.85, 0.85)
  end
  for _, m in ipairs(Members()) do
    local p = party[m.name]
    if m.unit ~= "player" and not (p and p.dungeon == H.shown) then
      GameTooltip:AddDoubleLine(ColorName(m), "no addon", 1, 1, 1, 0.5, 0.5, 0.5)
    end
  end
  if row.code == "l" or row.code == "r" then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Right-click: share with the party.  Shift-click: link it.", 0.6, 0.6, 0.6, true)
  end
  GameTooltip:Show()
end

local function PartyTooltip(owner)
  GameTooltip:SetOwner(owner, TooltipSide(owner))
  GameTooltip:SetText("Party", 1, 1, 1)
  for _, m in ipairs(Members()) do
    local p = party[m.name]
    if m.unit == "player" or (p and p.dungeon == H.shown) then
      GameTooltip:AddDoubleLine(ColorName(m), "shares quests", 1, 1, 1, 0.45, 0.9, 0.5)
    else
      GameTooltip:AddDoubleLine(ColorName(m), "no addon", 1, 1, 1, 0.5, 0.5, 0.5)
    end
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Squares: party members with the addon.", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("Full: has it in the quest log", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("|cffffd100Gold edge|r: ready to turn in", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("Faded: level OK (not in the log)", 0.8, 0.8, 0.8)
  GameTooltip:Show()
end

local function Share(q)
  local fdj = H.FDJ()
  if fdj and fdj.ShareQuestByID then
    pcall(fdj.ShareQuestByID, tonumber(q.id))
    return
  end
  local id = tonumber(q.id)
  if C_QuestLog.SetSelectedQuest then
    pcall(C_QuestLog.SetSelectedQuest, id)
  elseif SelectQuestLogEntry then
    pcall(SelectQuestLogEntry, C_QuestLog.GetLogIndexForQuestID(id))
  end
  if QuestLogPushQuest then
    pcall(QuestLogPushQuest)
  end
end

local function Header(i)
  local h = headers[i]
  if h then
    return h
  end
  h = CreateFrame("Frame", nil, child)
  h:SetHeight(HEAD_H)
  h.bg = h:CreateTexture(nil, "BACKGROUND")
  h.bg:SetAllPoints()
  h.label = ARLE.UIKit.Text(h, "GameFontNormalSmall")
  h.label:SetPoint("LEFT", 6, 0)
  h.count = ARLE.UIKit.Text(h, "GameFontHighlightSmall")
  h.count:SetPoint("RIGHT", -4, 0)
  headers[i] = h
  return h
end

local function Row(i)
  local r = rows[i]
  if r then
    return r
  end
  r = CreateFrame("Button", nil, child)
  r:SetHeight(ROW_H)
  r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  r.icon = r:CreateTexture(nil, "ARTWORK")
  r.icon:SetSize(12, 12)
  r.icon:SetPoint("LEFT", 5, 0)
  r.name = ARLE.UIKit.Text(r, "GameFontHighlightSmall")
  r.name:SetPoint("LEFT", r.icon, "RIGHT", 4, 0)
  r.name:SetWordWrap(false)
  r.progressText = ARLE.UIKit.Text(r, "GameFontHighlightSmall")
  r.progressText:SetJustifyH("RIGHT")
  r.squares = {}
  for k = 1, MAX_MARKS do
    local edge = r:CreateTexture(nil, "ARTWORK")
    edge:SetSize(MARK + 2, MARK + 2)
    edge:SetPoint("RIGHT", -(4 + (k - 1) * (MARK + 4)), 0)
    edge:SetColorTexture(1, 0.82, 0, 1)
    local fill = r:CreateTexture(nil, "OVERLAY")
    fill:SetSize(MARK, MARK)
    fill:SetPoint("CENTER", edge, "CENTER")
    r.squares[k] = { edge = edge, fill = fill }
  end
  r.hl = r:CreateTexture(nil, "HIGHLIGHT")
  r.hl:SetAllPoints()
  r.hl:SetColorTexture(1, 1, 1, 0.07)
  r:SetScript("OnEnter", QuestTooltip)
  r:SetScript("OnLeave", GameTooltip_Hide)
  r:SetScript("OnClick", function(self, button)
    if self.code ~= "l" and self.code ~= "r" then
      return
    end
    if button == "RightButton" then
      Share(self.quest)
    elseif IsModifiedClick and IsModifiedClick("CHATLINK") and GetQuestLink then
      local ok, link = pcall(GetQuestLink, tonumber(self.quest.id))
      if ok and link then
        ChatEdit_InsertLink(link)
      end
    end
  end)
  rows[i] = r
  return r
end

local function PaintRow(r, q, code, progress, states)
  r.quest, r.code, r.progress = q, code, progress
  r.icon:SetTexture(ICONS[code])
  r.icon:SetDesaturated(code == "l" or code == "n")
  r.icon:SetAlpha((code == "n" or code == "d") and 0.5 or 1)
  r.name:SetText((q.level and ("[" .. q.level .. "] ") or "") .. q.name)
  if code == "d" then
    r.name:SetTextColor(0.5, 0.5, 0.5)
  else
    r.name:SetTextColor(DifficultyColor(q.level))
  end
  local marks = {}
  for _, ps in ipairs(states) do
    local s = ps.state and ps.state.code
    if s == "l" or s == "r" or s == "a" then
      marks[#marks + 1] = { member = ps.member, code = s }
    end
  end
  local n = math.min(#marks, MAX_MARKS)
  for k = 1, MAX_MARKS do
    local sq, mk = r.squares[k], marks[k]
    if mk and k <= n then
      local cr, cg, cb = H.ClassColor(mk.member.class)
      sq.fill:SetColorTexture(cr, cg, cb, 1)
      sq.fill:SetAlpha(mk.code == "a" and 0.3 or 1)
      sq.fill:Show()
      sq.edge:SetShown(mk.code == "r")
    else
      sq.fill:Hide()
      sq.edge:Hide()
    end
  end
  local right = 6 + n * (MARK + 4)
  r.progressText:ClearAllPoints()
  r.progressText:SetPoint("RIGHT", r, "RIGHT", -right, 0)
  if code == "r" then
    r.progressText:SetText("|cff40ff60done|r")
  elseif progress then
    r.progressText:SetText(progress)
  else
    r.progressText:SetText("")
  end
  r.name:SetPoint("RIGHT", r.progressText, "LEFT", -4, 0)
end

-- Toolbar: [All][To do][Party]  Party 2/3
function tab:Create(content, bar)
  child = content
  self.filters = H.FilterButtons(bar, FILTERS, Filter, function(key)
    mod.db.questFilter = key
  end)
  self.partyButton = CreateFrame("Button", nil, bar)
  self.partyButton:SetPoint("LEFT", self.filters.last, "RIGHT", 6, 0)
  self.partyButton:SetPoint("RIGHT", 0, 0)
  self.partyButton:SetHeight(20)
  self.partyButton.text = ARLE.UIKit.Text(self.partyButton, "GameFontHighlightSmall")
  self.partyButton.text:SetPoint("LEFT")
  self.partyButton:SetScript("OnEnter", PartyTooltip)
  self.partyButton:SetScript("OnLeave", GameTooltip_Hide)
  emptyText = ARLE.UIKit.Text(child, "GameFontDisableSmall")
  emptyText:SetPoint("TOPLEFT", 6, -8)
  emptyText:SetPoint("RIGHT", -6, 0)
end

function tab:Render()
  local ar, ag, ab = ARLE.Skin:Accent()
  local filter = Filter()
  self.filters.Paint()

  local members = Members()
  local sharing = 1
  for _, m in ipairs(members) do
    local p = party[m.name]
    if m.unit ~= "player" and p and p.dungeon == H.shown then
      sharing = sharing + 1
    end
  end
  self.partyButton.text:SetText("Party " .. sharing .. "/" .. #members)

  -- Sort each quest into its section.
  local quests = Quests(H.shown)
  local bySection = {}
  for _, q in ipairs(quests) do
    local code, progress = MyState(q)
    local states = PartyStates(q)
    local anyLog = code == "l" or code == "r"
    for _, ps in ipairs(states) do
      local s = ps.state and ps.state.code
      anyLog = anyLog or s == "l" or s == "r"
    end
    local keep = filter == "all" or (filter == "todo" and code ~= "d") or (filter == "party" and anyLog)
    if code == "d" and not mod.db.questShowDone then
      keep = false
    end
    if keep then
      for si, sec in ipairs(SECTIONS) do
        if sec.codes[code] then
          bySection[si] = bySection[si] or {}
          table.insert(bySection[si], { q = q, code = code, progress = progress, states = states })
        end
      end
    end
  end

  local y, nh, nr = 0, 0, 0
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
      nh = nh + 1
      local h = Header(nh)
      h:ClearAllPoints()
      h:SetPoint("TOPLEFT", 0, -y)
      h:SetPoint("RIGHT")
      h.bg:SetColorTexture(ar, ag, ab, 0.1)
      h.label:SetText(sec.label)
      h.label:SetTextColor(ar, ag, ab)
      h.count:SetText("|cff888888" .. #list .. "|r")
      h:Show()
      y = y + HEAD_H + 1
      for _, e in ipairs(list) do
        nr = nr + 1
        local r = Row(nr)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", 0, -y)
        r:SetPoint("RIGHT")
        PaintRow(r, e.q, e.code, e.progress, e.states)
        r:Show()
        y = y + ROW_H
      end
      y = y + 2
    end
  end
  for i = nh + 1, #headers do
    headers[i]:Hide()
  end
  for i = nr + 1, #rows do
    rows[i]:Hide()
  end
  emptyText:SetShown(nr == 0)
  if nr == 0 then
    if not H.shown then
      emptyText:SetText("Not in a dungeon. Pick one with the v button.")
    elseif #quests == 0 then
      emptyText:SetText("DungeonJournal lists no quests here for your faction.")
    else
      emptyText:SetText("No quests match. Try All.")
    end
    y = 40
  end
  return y
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
