-- Dungeon Helper, Clear Times tab: a run timer with a split per boss, like a
-- speedrun timer. The list has each boss with its portrait, its split in
-- this run (time from the start of the run to the kill) and the difference
-- with the player's best split, then the clear, then the rares. The details
-- of the selected boss (or the clear): this run, the player's records, the
-- party's, and the guild leaderboard.
--
-- A run starts on the first pull inside the dungeon (or on entering, per the
-- "Start the timer" setting) and is cleared when every required boss is dead
-- (DungeonJournal's rules: not the rares, nor bosses that need a quest or a
-- summoning item, nor optional ones; a fight like the Ring of Law counts
-- once, whichever boss shows up). Leaving and coming back (a corpse run)
-- resumes it; a finished run stays on screen until the next time you enter.
-- A new run starts instead when it's another copy of the dungeon (a reset:
-- told by the instance part of creature GUIDs, or the reset message), or
-- another group. Moving to another wing of the same instance (Lower/Upper
-- Spire, Dire Maul, Stratholme) parks the run, and coming back resumes it.
-- The run in progress is this character's (self.char.run); records are
-- kept per character too: db.records["Name-Realm"][dungeon].
--
-- Sharing (ARL members only, through ARL's addon messages):
--   party  "BT" with each member's records for the shown dungeon (as before)
--   guild  the same "BT" on the guild channel, for the leaderboard: sent when
--          the player sets a record, and in answer to "BR <dungeon>", which
--          the Clear Times tab sends (once per dungeon per 15 min) when it
--          shows a dungeon. Answers wait a random 1-6 s, and one per dungeon
--          per minute at most. What comes in is kept account-wide
--          (shared.board[dungeon][name]), 120 days. The "Share my records
--          with the guild leaderboard" setting stops our own sends only.
local _, ns = ...
local ARLE = _G.ARLExtensions
local H = ns.H
if not ARLE or not H then
  return
end
local mod = H.mod
local Kit = ARLE.UI.Kit
local S = H.Script
local Bosses, Members, ColorName = H.Bosses, H.Members, H.ColorName
local FormatTime, FormatDelta, Now = H.FormatTime, H.FormatDelta, H.Now

local ROW_H, PORTRAIT, BIG, LINE_H = 22, 20, 36, 15
local RESUME = 45 * 60 -- an unfinished run older than this starts over
local CLEAR = "@clear" -- the clear's entry in the list
local BOARD_TOP = 10
local BOARD_KEEP = 120 * 86400
local ASK_EVERY, ANSWER_EVERY = 15 * 60, 60

local tab = { key = "times", label = "Clear Times" }
H.tabs[#H.tabs + 1] = tab

-------------------------------------------------------------------------------
-- Runs and records
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- Runs and records
-------------------------------------------------------------------------------

local pulls = {} -- boss -> server time of its pull

local function CharKey()
  local realm = GetRealmName and GetRealmName() or ""
  return UnitName("player") .. (realm ~= "" and ("-" .. realm:gsub("%s", "")) or "")
end

local function Records(dungeon, create)
  local db = mod.db
  if type(db.records) ~= "table" then
    db.records = {}
  end
  local mine = db.records[CharKey()]
  if not mine and create then
    mine = {}
    db.records[CharKey()] = mine
  end
  local rec = mine and mine[dungeon]
  if not rec and create then
    rec = { bosses = {}, clears = 0 }
    mine[dungeon] = rec
  end
  return rec
end
tab.Records = Records

function tab:AllRecords()
  local db = mod.db
  return type(db.records) == "table" and db.records[CharKey()] or {}
end

function tab:ClearRecords()
  if type(mod.db.records) == "table" then
    mod.db.records[CharKey()] = nil
  end
  H.QueueSend(H.shown, "times", true)
  H.Render()
end

-- The run in progress belongs to this character (mod.char): another
-- character entering the same dungeon must not carry it on.
local function CharData()
  return mod.char or {}
end

local function Run()
  local run = CharData().run
  return type(run) == "table" and run or nil
end
tab.Run = Run

local function SetRun(run)
  CharData().run = run
end

-- Runs left for another wing of the same instance: parked[dungeon] = run.
local function Parked()
  local c = CharData()
  if type(c.parked) ~= "table" then
    c.parked = {}
  end
  return c.parked
end

-- The rows of the window: one per boss, one per fight (the Ring of Law's
-- challengers fold into "Ring of Law"). { name, raw, rare, optional }.
local entryCache = setmetatable({}, { __mode = "k" })
local function Entries(dungeon)
  local list = Bosses(dungeon)
  if entryCache[list] then
    return entryCache[list]
  end
  local entries, byGroup = {}, {}
  for _, boss in ipairs(list) do
    if boss.group then
      local e = byGroup[boss.group]
      if not e then
        e = { name = boss.group, aliases = {}, raw = boss.raw, rare = boss.rare, optional = boss.optional, items = {} }
        byGroup[boss.group] = e
        entries[#entries + 1] = e
      else
        -- The fight is optional (or rare) only if each of its bosses is.
        e.optional = e.optional and boss.optional
        e.rare = e.rare and boss.rare
      end
    else
      entries[#entries + 1] = boss
    end
  end
  entryCache[list] = entries
  return entries
end

-- Bosses a clear needs: DungeonJournal's rules (RunLog.lua AllBossesDown).
local function Required(dungeon)
  local list = {}
  for _, e in ipairs(Entries(dungeon)) do
    if not e.optional then
      list[#list + 1] = e.name
    end
  end
  return list
end

local function InstanceMap()
  local id = GetInstanceInfo and select(8, GetInstanceInfo())
  return tonumber(H.Plain(id))
end

-- The other members' names, sorted.
local function OtherNames()
  local list = {}
  for _, m in ipairs(Members()) do
    if m.unit ~= "player" and m.name then
      list[#list + 1] = m.name
    end
  end
  table.sort(list)
  return list
end

-- Another group: nobody of the run's group is still here (solo counts as a
-- group of one: solo then grouped, or the other way, is another group). One
-- member swapped out keeps the run.
local function SameGroup(run)
  if type(run.group) ~= "table" then
    return true
  end
  local now = OtherNames()
  if #now == 0 and #run.group == 0 then
    return true
  end
  local here = {}
  for _, name in ipairs(now) do
    here[name] = true
  end
  for _, name in ipairs(run.group) do
    if here[name] then
      return true
    end
  end
  return false
end

local function NewRun(dungeon, start)
  local now = Now()
  SetRun({
    dungeon = dungeon, created = now, last = now, inside = true, splits = {}, fights = {},
    start = start or (mod.db.timerStart == "enter" and now or nil),
    entered = now, map = InstanceMap(), group = OtherNames(),
  })
  Parked()[dungeon] = nil
  wipe(pulls)
end

local function Fresh(run, now)
  return now - (run.last or 0) < RESUME
end

-- Leaves the current run for another wing of the same instance. A run that
-- never started is just dropped.
local function Park(run)
  run.inside = false
  if run.start then
    run.last = Now()
    Parked()[run.dungeon] = run
  end
  SetRun(nil)
end

-- The parked run of a wing, if it can carry on here.
local function Unpark(dungeon, map, now)
  local parked = Parked()
  local run = parked[dungeon]
  parked[dungeon] = nil
  if type(run) == "table" and not run.reset and Fresh(run, now) and (not run.map or not map or run.map == map) then
    run.inside = true
    SetRun(run)
    return run
  end
end

-- The instance copy, from a creature GUID seen inside: another copy than the
-- run's means the dungeon was reset, so the run starts over.
function tab:OnInstanceGUID(zone, map)
  local run = Run()
  if not run or not run.inside or not zone then
    return
  end
  local here = InstanceMap()
  if map and here and map ~= here then
    return
  end
  if not run.zone then
    run.zone = zone
  elseif run.zone ~= zone then
    mod:Print("Clear Times: this is a new copy of " .. tostring(run.dungeon) .. " (reset): the run starts over.")
    NewRun(run.dungeon, mod.db.timerStart == "enter" and Now() or nil)
    Run().zone = zone
    H.Render()
  end
end

-- "<Instance> has been reset." (the leader only gets it): the run of that
-- dungeon, while outside it, can't be resumed.
local resetPattern
function tab:OnSystemMessage(text)
  text = H.Plain(text)
  if type(text) ~= "string" then
    return
  end
  if resetPattern == nil then
    local fmt = type(_G.INSTANCE_RESET_SUCCESS) == "string" and _G.INSTANCE_RESET_SUCCESS or "%s has been reset."
    local escaped = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    resetPattern = "^" .. escaped:gsub("%%s", "(.+)") .. "$"
  end
  local name = text:match(resetPattern)
  if not name then
    return
  end
  local function Loose(s)
    return (tostring(s):lower():gsub("^the ", ""))
  end
  local wanted = Loose(name)
  local function Matches(dungeon)
    local d = Loose(dungeon)
    return d:find(wanted, 1, true) ~= nil or wanted:find(d, 1, true) ~= nil
  end
  local run = Run()
  if run and not run.inside and Matches(run.dungeon) then
    run.reset = true
  end
  local parked = Parked()
  for dungeon in pairs(parked) do
    if Matches(dungeon) then
      parked[dungeon] = nil
    end
  end
end

-- Seconds the current run has been going, or nil.
local function Elapsed(run)
  if not run or not run.start then
    return nil
  end
  if run.done then
    return run.total
  end
  return Now() - run.start
end
tab.Elapsed = Elapsed

-- The running time for the title bar, while a run is going in the shown
-- dungeon (or any run when nothing else is shown).
function tab:Clock()
  local run = Run()
  if run and run.start and run.inside then
    return FormatTime(Elapsed(run)), run.done
  end
end

-- Zone changes: start, resume or keep a run.
function tab:OnZone(current)
  local run = Run()
  local inside = current and IsInInstance and IsInInstance()
  if inside then
    local now = Now()
    local map = InstanceMap()
    if run and run.dungeon ~= current then
      if run.map and map and run.map == map then
        Park(run) -- another wing of the same instance (or its entrance side)
      end
      run = Unpark(current, map, now) or run
    end
    if run and run.dungeon == current and not run.reset and (not run.map or not map or run.map == map)
        and SameGroup(run) then
      local fresh = Fresh(run, now)
      if run.done and run.inside and fresh then
        return -- a reload after the clear: keep the result up
      elseif not run.done and fresh then
        run.inside = true -- back from a corpse run
        return
      end
    end
    NewRun(current)
  elseif run then
    run.inside = false
    if not run.start then
      SetRun(nil)
    end
  end
end

-- A kill in a parked wing (the room said one wing, the boss another): that
-- wing's run comes back. True when the run is now the dungeon's.
local function SwitchTo(dungeon)
  local run = Run()
  if run and run.dungeon == dungeon then
    return true
  end
  local now, map = Now(), InstanceMap()
  local parked = Parked()[dungeon]
  if type(parked) ~= "table" or not map or parked.map ~= map then
    return false
  end
  if run then
    if run.map ~= map then
      return false
    end
    Park(run)
  end
  return Unpark(dungeon, map, now) ~= nil
end

function tab:Reset()
  local current = H.CurrentDungeon()
  if current and IsInInstance and IsInInstance() then
    NewRun(current)
  else
    SetRun(nil)
  end
  H.Render()
end

local function StartIfWaiting(at)
  local run = Run()
  if run and run.inside and not run.start and not run.done then
    run.start = at or Now()
    run.last = run.start
    H.Render()
  end
end

function tab:OnCombat()
  StartIfWaiting()
  local run = Run()
  if run and run.inside and run.start and not run.done then
    run.last = Now() -- still going: a long run isn't mistaken for an old one
  end
end

function tab:OnPull(dungeon, boss)
  pulls[boss] = Now()
  if SwitchTo(dungeon) then
    StartIfWaiting(pulls[boss])
  end
end

local function Announce(text)
  if mod.db.announceRecords then
    mod:Print(text)
  end
end

-- After the clear, kills still get splits and records (a rare found after
-- the last boss); only the clear itself isn't counted again.
function tab:OnKill(dungeon, boss)
  SwitchTo(dungeon)
  local run = Run()
  if not run or run.dungeon ~= dungeon or not run.inside then
    return
  end
  local now = Now()
  if not run.start then
    run.start = pulls[boss] or now
  end
  if run.splits[boss] then
    return
  end
  local split = now - run.start
  local fight = pulls[boss] and (now - pulls[boss]) or nil
  run.splits[boss], run.fights[boss], run.last = split, fight, now
  pulls[boss] = nil

  local rec = Records(dungeon, true)
  local best = rec.bosses[boss] or {}
  rec.bosses[boss] = best
  run.prev = run.prev or {}
  run.prev[boss] = best.split -- what this kill is compared with
  local improved = false
  if not best.split or split < best.split then
    if best.split then
      Announce(string.format("New record: %s at %s (%s).", boss, FormatTime(split), FormatDelta(split - best.split)))
    end
    best.split, best.splitAt, improved = split, now, true
  end
  if fight and (not best.fight or fight < best.fight) then
    best.fight, best.fightAt, improved = fight, now, true
  end

  local all = false
  if not run.done then
    local required = Required(dungeon)
    all = #required > 0
    for _, name in ipairs(required) do
      if not run.splits[name] then
        all = false
      end
    end
  end
  if all then
    run.done, run.total, run.prevTotal = true, split, rec.total
    rec.clears = (rec.clears or 0) + 1
    if not rec.total or split < rec.total then
      if rec.total then
        Announce(string.format("New record: %s cleared in %s (%s).", dungeon, FormatTime(split),
          FormatDelta(split - rec.total)))
      else
        Announce(string.format("%s cleared in %s.", dungeon, FormatTime(split)))
      end
      rec.total, rec.totalAt, improved = split, now, true
    else
      Announce(string.format("%s cleared in %s (record %s).", dungeon, FormatTime(split), FormatTime(rec.total)))
    end
  end
  if improved or all then
    H.QueueSend(dungeon, "times", true)
  end
  if improved then
    tab:ShareGuild(dungeon)
  end
  H.Render()
end

-------------------------------------------------------------------------------
-- Comms: "BT <dungeon>~<best total>~<clears>~<part>~<count>~boss=split/fight;..."
-- on the party channel (the party's records) and the guild channel (the
-- leaderboard); "BR <dungeon>" asks the guild for theirs.
-------------------------------------------------------------------------------

local party = {} -- name -> { dungeon, total, clears, bosses = { [boss] = {split, fight} } }
tab.data = party

local function Payload(dungeon)
  local rec = Records(dungeon)
  if not rec then
    return nil
  end
  local list = {}
  for boss, r in pairs(rec.bosses or {}) do
    if r.split or r.fight then
      list[#list + 1] = boss .. "=" .. (r.split and math.floor(r.split + 0.5) or "") .. "/"
        .. (r.fight and math.floor(r.fight + 0.5) or "")
    end
  end
  if #list == 0 and not rec.total then
    return nil
  end
  table.sort(list)
  return dungeon .. "~" .. (rec.total and math.floor(rec.total + 0.5) or "") .. "~" .. (rec.clears or 0), list
end

function tab:Send(dungeon, channel)
  local head, list = Payload(dungeon)
  if not head then
    head, list = dungeon .. "~~0", {}
  end
  H.SendChunks("BT", head, list, ";", channel)
end

-- The leaderboard, account-wide: board[dungeon][name] = { total, clears,
-- at, bosses = { [boss] = split } }.
local function Board(dungeon)
  local shared = mod.shared
  if not shared then
    return {}
  end
  if type(shared.board) ~= "table" then
    shared.board = {}
  end
  if dungeon == nil then
    return shared.board
  end
  shared.board[dungeon] = type(shared.board[dungeon]) == "table" and shared.board[dungeon] or {}
  return shared.board[dungeon]
end

local guildSent = {} -- dungeon -> GetTime() of our last guild send
local function SendGuild(dungeon)
  if not mod._active or not mod.db.guildBoard or not (IsInGuild and IsInGuild()) then
    return
  end
  local head, list = Payload(dungeon)
  if head then
    guildSent[dungeon] = GetTime()
    H.SendChunks("BT", head, list, ";", "GUILD")
    mod:Debug("leaderboard: sent %s to the guild", dungeon)
  end
end

-- After a record (several can come in one kill: once, a moment later).
function tab:ShareGuild(dungeon)
  if mod.db.guildBoard then
    mod:Debounce("board:" .. dungeon, 5, function()
      SendGuild(dungeon)
    end)
  end
end

-- The setting turned on: the shown dungeon's records go out now.
function tab:ShareAll()
  if H.shown then
    SendGuild(H.shown)
  end
end

local asked = {} -- dungeon -> GetTime() we last asked the guild
local function AskGuild(dungeon)
  if not dungeon or not (IsInGuild and IsInGuild()) then
    return
  end
  if asked[dungeon] and GetTime() - asked[dungeon] < ASK_EVERY then
    return
  end
  asked[dungeon] = GetTime()
  ARLE:Send("BR", dungeon, "GUILD")
  mod:Debug("leaderboard: asked the guild about %s", dungeon)
end

ARLE:RegisterComm("BR", function(sender, dungeon, channel)
  if not mod._active or channel ~= "GUILD" or not mod.db.guildBoard then
    return
  end
  if not (H.FDJ() and H.FDJ().DB[dungeon]) or not Records(dungeon) then
    return
  end
  if guildSent[dungeon] and GetTime() - guildSent[dungeon] < ANSWER_EVERY then
    return
  end
  guildSent[dungeon] = GetTime() -- (claimed now: a second ask in the wait isn't answered twice)
  mod:After(1 + math.random() * 5, function()
    local head, list = Payload(dungeon)
    if head then
      H.SendChunks("BT", head, list, ";", "GUILD")
    end
  end)
end)

ARLE:RegisterComm("BT", function(sender, payload, channel)
  if not mod._active then
    return
  end
  local dungeon, total, clears, part, list = payload:match("^(.-)~(%d*)~(%d*)~(%d+)~%d+~(.*)$")
  if not dungeon then
    return
  end
  local bosses = {}
  for entry in list:gmatch("[^;]+") do
    local boss, split, fight = entry:match("^(.-)=(%d*)/(%d*)$")
    if boss then
      bosses[boss] = { split = tonumber(split), fight = tonumber(fight) }
    end
  end
  -- The party's records for the shown dungeon.
  if channel ~= "GUILD" then
    local p = party[sender]
    if not p or p.dungeon ~= dungeon or tonumber(part) == 1 then
      p = { dungeon = dungeon, bosses = {} }
      party[sender] = p
    end
    p.total, p.clears = tonumber(total), tonumber(clears) or 0
    for boss, b in pairs(bosses) do
      p.bosses[boss] = b
    end
  end
  -- The leaderboard: guildmates only (the guild channel, or a party member
  -- in the guild roster).
  if (channel == "GUILD" or ARLE:IsGuildmate(sender)) and (tonumber(total) or next(bosses)) then
    local board = Board(dungeon)
    local e = board[sender]
    if not e or tonumber(part) == 1 then
      e = { bosses = {} }
      board[sender] = e
    end
    e.total, e.clears, e.at = tonumber(total), tonumber(clears) or 0, Now()
    for boss, b in pairs(bosses) do
      e.bosses[boss] = b.split
    end
  end
  H.Render()
end)

function tab:Prune(keep)
  for name in pairs(party) do
    if not keep[name] then
      party[name] = nil
    end
  end
end

function tab:OnEnable()
  local cutoff = Now() - BOARD_KEEP
  for _, entries in pairs(Board()) do
    if type(entries) == "table" then
      for name, e in pairs(entries) do
        if type(e) ~= "table" or (e.at or 0) < cutoff then
          entries[name] = nil
        end
      end
    end
  end
end

function tab:OnDungeon(dungeon)
  if dungeon and mod.db.tab == "times" then
    AskGuild(dungeon)
  end
end

-------------------------------------------------------------------------------
-- Leaderboards: { {name, value, extra, at, me}, ... }, fastest first.
-------------------------------------------------------------------------------

local function Leaders(dungeon, boss)
  local list = {}
  local me = H.Me()
  for name, e in pairs(Board(dungeon)) do
    local value = boss and e.bosses and e.bosses[boss] or (not boss and e.total)
    if name ~= me and value then
      list[#list + 1] = { name = name, value = value, clears = e.clears, at = e.at }
    end
  end
  local rec = Records(dungeon)
  local mine = rec and (boss and rec.bosses[boss] and rec.bosses[boss].split or (not boss and rec.total))
  if mine then
    list[#list + 1] = { name = me, value = mine, clears = rec.clears, me = true,
      at = boss and rec.bosses[boss].splitAt or rec.totalAt }
  end
  table.sort(list, function(a, b)
    if a.value ~= b.value then
      return a.value < b.value
    end
    return a.name < b.name
  end)
  return list
end

-------------------------------------------------------------------------------
-- View
--   list:    (portrait) Boss name ........ -0:12  4:05    (one per boss)
--            Clear .......................... 23:41
--            Rares: (portrait) Rare ......... --:--
--   details: the selected entry: this run, your records, the party's, the
--            guild leaderboard
-------------------------------------------------------------------------------

local selected = {} -- dungeon -> boss name or CLEAR
local listPool, sectionPool, listEmpty
local detail = {}

local function DateText(t)
  return t and date and date("%Y-%m-%d", t) or ""
end

local function Select(key)
  if H.shown and selected[H.shown] ~= key then
    selected[H.shown] = key
    H.DetailToTop()
  end
  H.Render()
end

local function ResetClick(self)
  if self.armed and GetTime() - self.armed < 3 then
    self.armed = nil
    self:SetText("Reset")
    tab:Reset()
    return
  end
  self.armed = GetTime()
  self:SetText("Sure?")
  mod:After(3, function()
    if self.armed and GetTime() - self.armed >= 2.9 then
      self.armed = nil
      self:SetText("Reset")
    end
  end)
end

-- A line of the details: label on the left, value on the right.
local function MakeLine(parent)
  local f = CreateFrame("Frame", nil, parent)
  f:SetHeight(LINE_H)
  f.left = Kit.Text(f, "GameFontHighlightSmall")
  f.left:SetPoint("LEFT", 6, 0)
  f.left:SetWordWrap(false)
  f.right = Kit.Text(f, "GameFontHighlightSmall")
  f.right:SetPoint("RIGHT", -4, 0)
  f.right:SetJustifyH("RIGHT")
  f.left:SetPoint("RIGHT", f.right, "LEFT", -6, 0)
  f.bg = f:CreateTexture(nil, "BACKGROUND")
  f.bg:SetAllPoints()
  return f
end

function tab:Create(bar, list, detailFrame)
  self.clock = Kit.Text(bar, "GameFontNormal")
  self.clock:SetPoint("LEFT", 2, 0)
  self.reset = H.SmallButton(bar, "Reset", 48)
  self.reset:SetPoint("RIGHT", 0, 0)
  S(self.reset, "OnClick", ResetClick)
  H.Tip(self.reset, "Start over", "Throws away this run and waits for the next pull. Records are kept. "
    .. "Click twice to confirm.")
  self.status = Kit.Text(bar, "GameFontDisableSmall")
  self.status:SetPoint("LEFT", self.clock, "RIGHT", 8, 0)
  self.status:SetPoint("RIGHT", self.reset, "LEFT", -4, 0)
  self.status:SetWordWrap(false)

  listPool = H.Pool(function()
    local r = H.Row(list, ROW_H, PORTRAIT)
    S(r, "OnClick", function(row)
      Select(row.key)
    end)
    return r
  end)
  sectionPool = H.Pool(function()
    local h = H.Section(list)
    H.Tip(h, function(self)
      return self.label:GetText() or "Rares"
    end, "Rare mobs may not spawn in every run, and some bosses only come with a quest or a summoning item, so "
      .. "they are kept apart and a clear doesn't need them. When one is killed it still gets a split and records.")
    return h
  end)
  listEmpty = Kit.Text(list, "GameFontDisableSmall")

  detail.portrait = detailFrame:CreateTexture(nil, "ARTWORK")
  detail.portrait:SetSize(BIG, BIG)
  detail.portrait:SetPoint("TOPLEFT", 4, -4)
  detail.title = Kit.Text(detailFrame, "GameFontNormal")
  detail.title:SetPoint("TOPLEFT", detail.portrait, "TOPRIGHT", 8, -2)
  detail.title:SetPoint("RIGHT", -4, 0)
  detail.title:SetWordWrap(false)
  detail.sub = Kit.Text(detailFrame, "GameFontDisableSmall")
  detail.sub:SetPoint("TOPLEFT", detail.title, "BOTTOMLEFT", 0, -3)
  detail.sub:SetPoint("RIGHT", -4, 0)
  detail.sub:SetWordWrap(false)
  detail.sections = H.Pool(function()
    return H.Section(detailFrame)
  end)
  detail.lines = H.Pool(function()
    return MakeLine(detailFrame)
  end)
  detail.paras = H.Pool(function()
    return Kit.Text(detailFrame, "GameFontDisableSmall")
  end)
end

-- The running parts: clock, status and the times in the list.
function tab:Tick()
  if not self.clock then
    return
  end
  local dungeon = H.shown
  local run = Run()
  local live = run and dungeon and run.dungeon == dungeon
  if live and run.start then
    self.clock:SetText(FormatTime(Elapsed(run)))
    if run.done then
      self.clock:SetTextColor(1, 0.82, 0)
    else
      self.clock:SetTextColor(1, 1, 1)
    end
  else
    self.clock:SetText(FormatTime(nil))
    self.clock:SetTextColor(0.6, 0.6, 0.6)
  end
  local status
  if not dungeon then
    status = ""
  elseif not live then
    status = "records only (not this run)"
  elseif run.done then
    status = "|cffffd100cleared!|r"
  elseif not run.start then
    status = mod.db.timerStart == "enter" and "starting" or "starts on the first pull"
  else
    local required, killed = Required(dungeon), 0
    for _, name in ipairs(required) do
      if run.splits[name] then
        killed = killed + 1
      end
    end
    status = killed .. "/" .. #required .. " bosses"
  end
  self.status:SetText(status)
  -- The clear's running time.
  if self.clearRow and self.clearRow:IsShown() and live and run.start then
    local text = FormatTime(Elapsed(run))
    if run.done and run.prevTotal then
      text = FormatDelta(run.total - run.prevTotal) .. "  " .. text
    end
    self.clearRow.note:SetText(text)
  end
end

local function SplitNote(boss, run, live, rec)
  local split = live and run.splits[boss.name]
  local best = rec.bosses[boss.name]
  if split then
    local prev = run.prev and run.prev[boss.name]
    return (prev and (FormatDelta(split - prev) .. "  ") or "") .. FormatTime(split), true
  end
  return "|cff777777" .. FormatTime(best and best.split) .. "|r", false
end

function tab:RenderList(width)
  local dungeon = H.shown
  local run = Run()
  local live = run and dungeon and run.dungeon == dungeon
  local rec = dungeon and Records(dungeon) or { bosses = {} }
  local bosses, rares = {}, {}
  local allRare = true
  for _, boss in ipairs(dungeon and Entries(dungeon) or {}) do
    if boss.optional then
      rares[#rares + 1] = boss
      allRare = allRare and boss.rare
    else
      bosses[#bosses + 1] = boss
    end
  end
  local sel = dungeon and selected[dungeon]
  local valid = sel == CLEAR
  for _, group in ipairs({ bosses, rares }) do
    for _, boss in ipairs(group) do
      valid = valid or boss.name == sel
    end
  end
  if dungeon and not valid then
    sel = #bosses > 0 and CLEAR or (rares[1] and rares[1].name)
    selected[dungeon] = sel
  end

  local y = 0
  local function Place(boss)
    local r = listPool:Get()
    r.key = boss.name
    if r.portraitOf ~= boss then
      r.portraitOf = boss
      H.SetPortrait(r.pic, boss)
    end
    local note, killed = SplitNote(boss, run, live, rec)
    H.PaintRow(r, boss.name, note, nil, sel == boss.name)
    r.name:SetTextColor(killed and 1 or 0.7, killed and 1 or 0.7, killed and 1 or 0.7)
    r.pic:SetAlpha((killed or not live) and 1 or 0.6)
    if killed and sel ~= boss.name then
      local ar, ag, ab = ARLE.Skin:Accent()
      r.bg:SetColorTexture(ar, ag, ab, 0.07)
    end
    y = H.Place(r, y, ROW_H)
  end
  for _, boss in ipairs(bosses) do
    Place(boss)
  end
  self.clearRow = nil
  if #bosses > 0 then
    local r = listPool:Get()
    r.key, r.portraitOf = CLEAR, nil
    r.pic:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
    r.pic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.pic:SetAlpha(1)
    local note = live and run.start and FormatTime(Elapsed(run)) or ("|cff777777" .. FormatTime(rec.total) .. "|r")
    H.PaintRow(r, "Clear", note, nil, sel == CLEAR)
    local ar, ag, ab = ARLE.Skin:Accent()
    r.name:SetTextColor(ar, ag, ab)
    if sel ~= CLEAR then
      r.bg:SetColorTexture(ar, ag, ab, 0.1)
    end
    self.clearRow = r
    y = H.Place(r, y + 2, ROW_H)
  end
  if #rares > 0 then
    local h = sectionPool:Get()
    local killed = 0
    for _, boss in ipairs(rares) do
      if live and run.splits[boss.name] then
        killed = killed + 1
      end
    end
    H.PaintSection(h, allRare and "Rares" or "Rares & optional",
      "|cff888888" .. (live and (killed .. "/" .. #rares) or "may not spawn") .. "|r",
      "atlas:nameplates-icon-elite-silver")
    y = H.Place(h, y + 6, 18)
    for _, boss in ipairs(rares) do
      Place(boss)
    end
  end
  listPool:Done()
  sectionPool:Done()
  self:Tick()

  listEmpty:SetShown(y == 0)
  if y == 0 then
    y = H.Para(listEmpty, 6, width, dungeon and "DungeonJournal lists no bosses here."
      or "Not in a dungeon. Pick one with the v button.")
  end
  return y
end

-- The selected entry's boss (nil for the clear).
local function SelectedBoss(dungeon)
  local sel = selected[dungeon]
  if sel == CLEAR then
    return nil
  end
  for _, boss in ipairs(Entries(dungeon)) do
    if boss.name == sel then
      return boss
    end
  end
end

function tab:RenderDetail(width)
  detail.sections:Done()
  detail.lines:Done()
  detail.paras:Done()
  local dungeon = H.shown
  if not dungeon or not selected[dungeon] then
    detail.portrait:Hide()
    detail.title:Hide()
    detail.sub:Hide()
    return 1
  end
  AskGuild(dungeon)
  local run = Run()
  local live = run and run.dungeon == dungeon
  local rec = Records(dungeon) or { bosses = {} }
  local boss = SelectedBoss(dungeon)
  local ar, ag, ab = ARLE.Skin:Accent()

  detail.portrait:Show()
  detail.title:Show()
  detail.sub:Show()
  if boss then
    H.SetPortrait(detail.portrait, boss)
    detail.title:SetText(boss.name)
    detail.sub:SetText(boss.rare and "Rare: may not spawn" or (boss.optional and "Optional: not needed for a clear")
      or "Needed for a clear")
  else
    detail.portrait:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
    detail.portrait:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    detail.title:SetText(dungeon .. ": clear")
    local required = Required(dungeon)
    detail.sub:SetText("Every boss but the rares and the optional ones: " .. #required .. " bosses")
  end
  detail.title:SetTextColor(ar, ag, ab)

  local y = BIG + 10
  local function Section(label, note)
    local h = detail.sections:Get()
    H.PaintSection(h, label, note)
    y = H.Place(h, y + 4, 18)
  end
  local function Line(left, right, highlight)
    local f = detail.lines:Get()
    f.left:SetText(left)
    f.right:SetText(right or "")
    f.bg:SetColorTexture(ar, ag, ab, highlight and 0.12 or 0)
    y = H.Place(f, y, LINE_H, 0)
  end
  local function Para(text)
    local fs = detail.paras:Get()
    y = H.Para(fs, y + 2, width, text, 2)
  end

  -- This run.
  if live and run.start then
    Section("This run", run.done and "|cffffd100cleared|r" or nil)
    if boss then
      local split = run.splits[boss.name]
      if split then
        local prev = run.prev and run.prev[boss.name]
        Line("Split", FormatTime(split) .. (prev and ("  " .. FormatDelta(split - prev)) or ""))
        if run.fights[boss.name] then
          Line("Fight", FormatTime(run.fights[boss.name]))
        end
      else
        Line("|cff888888Not killed yet|r")
      end
    else
      local required, killed = Required(dungeon), 0
      for _, name in ipairs(required) do
        if run.splits[name] then
          killed = killed + 1
        end
      end
      Line(run.done and "Cleared in" or "Running", FormatTime(Elapsed(run))
        .. ((run.done and run.prevTotal) and ("  " .. FormatDelta(run.total - run.prevTotal)) or ""))
      Line("Bosses", killed .. "/" .. #required)
    end
  end

  -- Your records.
  Section("Your records")
  local function Rec(label, value, at)
    Line(label, value and (FormatTime(value) .. "  |cff888888" .. DateText(at) .. "|r") or "|cff888888none yet|r")
  end
  if boss then
    local best = rec.bosses[boss.name] or {}
    Rec("Best split", best.split, best.splitAt)
    Rec("Best fight", best.fight, best.fightAt)
  else
    Rec("Best clear", rec.total, rec.totalAt)
    Line("Clears", tostring(rec.clears or 0))
  end

  -- The party's.
  local others = {}
  for _, m in ipairs(Members()) do
    if m.unit ~= "player" then
      others[#others + 1] = m
    end
  end
  if #others > 0 then
    Section("Party")
    for _, m in ipairs(others) do
      local p = party[m.name]
      local text
      if not (p and p.dungeon == dungeon) then
        text = "|cff888888no ARL|r"
      elseif boss then
        local b = p.bosses[boss.name]
        text = b and b.split and (FormatTime(b.split) .. (b.fight and ("  |cff888888fight " .. FormatTime(b.fight)
          .. "|r") or "")) or "|cff888888none yet|r"
      else
        text = p.total and (FormatTime(p.total) .. "  |cff888888" .. (p.clears or 0) .. " clears|r")
          or "|cff888888no clear yet|r"
      end
      Line(ColorName(m), text)
    end
  end

  -- The guild leaderboard.
  local leaders = Leaders(dungeon, boss and boss.name)
  Section("Guild leaderboard", "|cff888888" .. (boss and "best split" or "best clear") .. "|r")
  if #leaders == 0 then
    Para("No ARL member of the guild has shared a record here yet.")
  end
  local meShown = false
  for i, e in ipairs(leaders) do
    if i <= BOARD_TOP or (e.me and not meShown) then
      local medal = i == 1 and "|cffffd100" or (i == 2 and "|cffc0c0c0" or (i == 3 and "|cffcd7f32" or "|cffaaaaaa"))
      local name = e.me and ("|cff66ff66" .. e.name .. "|r") or e.name
      local extra = (not boss and e.clears) and ("  |cff888888" .. e.clears .. " clears|r") or ""
      Line(medal .. i .. ".|r " .. name, FormatTime(e.value) .. extra, e.me)
      meShown = meShown or e.me
    end
  end
  Para(mod.db.guildBoard and "Records of the guild's ARL members, shared when they set one and when someone "
    .. "looks here." or "|cffff9933You don't share yours|r (Clear Times settings); you still see the others'.")
  return y + 4
end

function tab:Status()
  local run = Run()
  if run and run.start and run.inside then
    return (run.done and "cleared in " or "run ") .. FormatTime(Elapsed(run))
  end
end
