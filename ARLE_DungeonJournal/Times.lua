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

local ROW_H, PORTRAIT, BIG, LINE_H = 38, 32, 50, 26
local RESUME = 45 * 60 -- an unfinished run older than this starts over
local CLEAR = "@clear" -- the clear's entry in the list
local BOARD_TOP = 10
local BOARD_KEEP = 120 * 86400
local MIN_SPLIT = 10 -- a boss or clear time under this isn't real (the clock started at the kill)
local MIN_FIGHT = 1
local ASK_EVERY, ANSWER_EVERY = 15 * 60, 60

local tab = { key = "times", label = "Clear Times" }
H.tabs[#H.tabs + 1] = tab

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
  local had = {}
  if type(mod.db.records) == "table" then
    for dungeon in pairs(mod.db.records[CharKey()] or {}) do
      had[#had + 1] = dungeon
    end
    mod.db.records[CharKey()] = nil
  end
  -- (an empty list on the guild channel takes us off guildmates' leaderboards)
  if IsInGuild and IsInGuild() then
    for i, dungeon in ipairs(had) do
      mod:After(i * 1.5, function()
        tab:Send(dungeon, "GUILD")
      end)
    end
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
  if run and run.start and run.inside and (not H.shown or H.shown == run.dungeon) then
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
    if pulls[boss] then
      run.start = pulls[boss]
    else
      -- The pull wasn't seen (the run was reset mid-fight, or a reload): the
      -- clock starts at the kill, so this run's times aren't records.
      run.start, run.noRecord = now, true
      mod:Debug("%s: the pull wasn't seen, this run makes no time records", boss)
    end
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
  local real = not run.noRecord and split >= MIN_SPLIT
  if real and (not best.split or split < best.split) then
    if best.split then
      Announce(string.format("New record: %s at %s (%s).", boss, FormatTime(split), FormatDelta(split - best.split)))
    end
    best.split, best.splitAt, improved = split, now, true
  end
  if fight and fight >= MIN_FIGHT and (not best.fight or fight < best.fight) then
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
    if run.noRecord then
      Announce(string.format("%s cleared (the start wasn't seen: no time record).", dungeon))
    elseif not rec.total or split < rec.total then
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

H.Comm("BR", function(sender, dungeon, channel)
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

H.Comm("BT", function(sender, payload, channel)
  if not mod._active then
    return
  end
  local dungeon, total, clears, part, list = payload:match("^(.-)~(%d*)~(%d*)~(%d+)~%d+~(.*)$")
  if not dungeon then
    return
  end
  if channel == "GUILD" and total == "" and list == "" and tonumber(part) == 1 then
    -- They cleared their records.
    local board = Board(dungeon)
    if board[sender] then
      board[sender] = nil
      H.Render()
    end
    return
  end
  -- (only times that can be real: a 0:00 or a day-long "record" is dropped)
  local function Time(v, least)
    v = tonumber(v)
    return v and v >= least and v < 86400 and v or nil
  end
  total = Time(total, MIN_SPLIT)
  local bosses = {}
  local n = 0
  for entry in list:gmatch("[^;]+") do
    local boss, split, fight = entry:match("^(.-)=(%d*)/(%d*)$")
    split, fight = Time(split, MIN_SPLIT), Time(fight, MIN_FIGHT)
    if boss and boss ~= "" and #boss <= 80 and (split or fight) and n < 60 then
      n = n + 1
      bosses[boss] = { split = split, fight = fight }
    end
  end
  -- The party's records for the shown dungeon.
  if channel ~= "GUILD" then
    local p = party[sender]
    if not p or p.dungeon ~= dungeon or tonumber(part) == 1 then
      p = { dungeon = dungeon, bosses = {} }
      party[sender] = p
    end
    p.total, p.clears = total, tonumber(clears) or 0
    for boss, b in pairs(bosses) do
      p.bosses[boss] = b
    end
  end
  -- The leaderboard: from the guild channel only. A party member's records
  -- stay in the party view: someone who turned "Share my records" off still
  -- sends them to the party, and they mustn't reach the board that way.
  if channel == "GUILD" and (total or next(bosses)) and #dungeon <= 80
    and H.FDJ() and type(H.FDJ().DB) == "table" and H.FDJ().DB[dungeon] then
    local board = Board(dungeon)
    local e = board[sender]
    if not e or tonumber(part) == 1 then
      e = { bosses = {} }
      board[sender] = e
    end
    e.total, e.clears, e.at = total, tonumber(clears) or 0, Now()
    for boss, b in pairs(bosses) do
      if b.split then
        e.bosses[boss] = b.split
      end
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
--   list:    [face] Boss name            4:05     (this run's split)
--                   best 4:17           -0:12     (against your best)
--            [watch] Full clear         23:41
--            Rares: [face] Rare ...
--   details: the selected entry: a banner, this run and your records as
--            stat tiles, the party, the guild leaderboard (gold, silver and
--            copper coins for the top three)
-------------------------------------------------------------------------------

local selected = {} -- dungeon -> boss name or CLEAR
local listPool, sectionPool, listEmpty
local detail = {}
local COINS = {
  "Interface\\MoneyFrame\\UI-GoldIcon",
  "Interface\\MoneyFrame\\UI-SilverIcon",
  "Interface\\MoneyFrame\\UI-CopperIcon",
}

local function DateText(t)
  return t and date and date("%d %b %Y", t) or ""
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

-- Killed in the run in progress (the other tabs mark it too).
function tab:IsKilled(dungeon, name)
  local run = Run()
  return run ~= nil and run.dungeon == dungeon and type(run.splits) == "table" and run.splits[name] ~= nil
end

local function Killed(run, dungeon)
  local required, killed = Required(dungeon), 0
  for _, name in ipairs(required) do
    if run.splits[name] then
      killed = killed + 1
    end
  end
  return killed, #required
end

-- "3/7 bosses" under the banner's clock, while a run is going here.
function tab:Progress()
  local run, dungeon = Run(), H.shown
  if not (run and dungeon and run.dungeon == dungeon and run.start) then
    return nil
  end
  if run.done then
    return "|cffffd100cleared|r"
  end
  local killed, total = Killed(run, dungeon)
  return killed .. "/" .. total .. " bosses"
end

function tab:Create(bar, list, detailFrame)
  self.statusIcon = bar:CreateTexture(nil, "ARTWORK")
  self.statusIcon:SetSize(16, 16)
  self.statusIcon:SetPoint("LEFT", 2, 0)
  self.statusIcon:SetTexture(H.ICON.watch)
  self.statusIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  self.reset = H.SmallButton(bar, "Reset", 52)
  self.reset:SetPoint("RIGHT", 0, 0)
  S(self.reset, "OnClick", ResetClick)
  H.Tip(self.reset, "Start over", "Throws away this run and waits for the next pull. Records are kept. "
    .. "Click twice to confirm.")
  self.status = Kit.Text(bar, "GameFontHighlight")
  self.status:SetPoint("LEFT", self.statusIcon, "RIGHT", 6, 0)
  self.status:SetPoint("RIGHT", self.reset, "LEFT", -6, 0)
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
  listEmpty = H.Empty(list)

  detail.banner = H.Banner(detailFrame, BIG)
  detail.sections = H.Pool(function()
    return H.Section(detailFrame)
  end)
  detail.tiles = H.Pool(function()
    return H.Tile(detailFrame)
  end)
  detail.rows = H.Pool(function()
    return H.Row(detailFrame, LINE_H, LINE_H - 6)
  end)
  detail.paras = H.Pool(function()
    return Kit.Text(detailFrame, "GameFontDisableSmall")
  end)
  detail.empty = H.Empty(detailFrame)
end

-- The running parts: the status line and the clear's time in the list.
function tab:Tick()
  if not self.status then
    return
  end
  local dungeon = H.shown
  local run = Run()
  local live = run and dungeon and run.dungeon == dungeon
  local status
  if not dungeon then
    status = "|cff888888No dungeon|r"
  elseif not live then
    status = "|cff888888No run here: your records|r"
  elseif run.done then
    status = "|cffffd100Cleared in " .. FormatTime(Elapsed(run)) .. "|r"
  elseif not run.start then
    status = mod.db.timerStart == "enter" and "Starting..." or "|cff888888Starts on the first pull|r"
  else
    local killed, total = Killed(run, dungeon)
    status = "Run going  ·  " .. killed .. "/" .. total .. " bosses"
  end
  self.status:SetText(status)
  self.statusIcon:SetDesaturated(not (live and run.start and not run.done))
  -- The clear's running time.
  if self.clearRow and self.clearRow:IsShown() and live and run.start then
    self.clearRow.note:SetText(FormatTime(Elapsed(run)))
  end
end

-- A boss row's right side: this run's split (and how it compares), or the
-- best one, faded.
local function SplitTexts(boss, run, live, rec)
  local split = live and run.splits[boss.name]
  local best = rec.bosses[boss.name]
  local bestText = best and best.split and ("best " .. FormatTime(best.split)) or "no record yet"
  if split then
    local prev = run.prev and run.prev[boss.name]
    return FormatTime(split), prev and FormatDelta(split - prev) or "|cffffd100first!|r", bestText, true
  end
  return "|cff777777--:--|r", nil, bestText, false
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
  local ar, ag, ab = ARLE.Skin:Accent()

  local y = 2
  local function Place(boss)
    local r = listPool:Get()
    r.key = boss.name
    if r.portraitOf ~= boss then
      r.portraitOf = boss
      r.pic.tex:SetDesaturated(false)
      H.SetPortrait(r.pic.tex, boss)
    end
    local note, noteSub, bestText, killed = SplitTexts(boss, run, live, rec)
    H.PaintRow(r, {
      name = boss.name,
      sub = bestText,
      note = note,
      noteSub = noteSub,
      selected = sel == boss.name,
      dim = live and not killed,
      tint = killed and { 0.35, 1, 0.45, 0.06 } or nil,
    })
    H.SetEdge(r.pic, ar, ag, ab, sel == boss.name and 0.9 or 0.3)
    H.SetCorner(r.pic, killed and H.ICON.ready or nil)
    y = H.Place(r, y, ROW_H)
  end
  for _, boss in ipairs(bosses) do
    Place(boss)
  end
  self.clearRow = nil
  if #bosses > 0 then
    local r = listPool:Get()
    r.key, r.portraitOf = CLEAR, nil
    H.SetIcon(r.pic, H.ICON.watch)
    local note, noteSub, sub
    if live and run.start then
      local killed, total = Killed(run, dungeon)
      note = FormatTime(Elapsed(run))
      noteSub = (run.done and run.prevTotal) and FormatDelta(run.total - run.prevTotal) or nil
      sub = run.done and "|cffffd100cleared|r" or (killed .. "/" .. total .. " bosses")
    else
      note = "|cff777777" .. FormatTime(rec.total) .. "|r"
      sub = rec.total and ("best  ·  " .. (rec.clears or 0) .. " clears") or "no clear yet"
    end
    H.PaintRow(r, {
      name = "Full clear",
      sub = sub,
      note = note,
      noteSub = noteSub,
      color = { ar, ag, ab },
      selected = sel == CLEAR,
      tint = { ar, ag, ab, 0.08 },
    })
    H.SetEdge(r.pic, ar, ag, ab, 0.8)
    H.SetCorner(r.pic, (live and run.done) and H.ICON.ready or nil)
    self.clearRow = r
    y = H.Place(r, y + 4, ROW_H)
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
      "|cff888888" .. (live and (killed .. "/" .. #rares) or "") .. "|r", "atlas:nameplates-icon-elite-silver")
    y = H.Place(h, y + 8, 20, 2)
    for _, boss in ipairs(rares) do
      Place(boss)
    end
  end
  listPool:Done()
  sectionPool:Done()
  self:Tick()

  if y <= 2 then
    y = H.ShowEmpty(listEmpty, 8, width, dungeon and "No bosses listed here" or "Not in a dungeon", H.ICON.watch)
  else
    listEmpty:Hide()
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

-- A delta as a tile's value: "-0:12" green, "+0:08" red.
local function DeltaTile(delta, label)
  if not delta then
    return { value = "--", label = label, color = H.GREY }
  end
  local color = delta < 0 and H.GREEN or (delta > 0 and { 1, 0.35, 0.25 } or H.GREY)
  return { value = (delta < 0 and "-" or "+") .. FormatTime(math.abs(delta)), label = label, color = color }
end

function tab:RenderDetail(width)
  -- Pools are finished at the end: Done hides what this render didn't use.
  local function Finish(y)
    detail.sections:Done()
    detail.tiles:Done()
    detail.rows:Done()
    detail.paras:Done()
    return y
  end
  local dungeon = H.shown
  if not dungeon or not selected[dungeon] then
    detail.banner:Hide()
    detail.empty:Hide()
    return Finish(1)
  end
  detail.empty:Hide()
  AskGuild(dungeon)
  local run = Run()
  local live = run and run.dungeon == dungeon and run.start
  local rec = Records(dungeon) or { bosses = {} }
  local boss = SelectedBoss(dungeon)
  local ar, ag, ab = ARLE.Skin:Accent()

  -- Banner.
  local b = detail.banner
  b:ClearAllPoints()
  b:SetPoint("TOPLEFT", 0, 0)
  b:SetWidth(width)
  local tags = {}
  if boss then
    b.pic.tex:SetDesaturated(false)
    H.SetPortrait(b.pic.tex, boss)
    if live and run.splits[boss.name] then
      tags[#tags + 1] = { text = "Killed", color = H.GREEN, icon = H.ICON.ready }
    end
    if boss.rare then
      tags[#tags + 1] = { text = "Rare", color = { 0.75, 0.8, 0.9 }, tip = { "Rare", "May not spawn in every run." } }
    elseif boss.optional then
      tags[#tags + 1] = { text = "Optional", color = { 0.75, 0.8, 0.9 },
        tip = { "Optional", "Summoned, or brought by a quest: a clear doesn't need it." } }
    else
      tags[#tags + 1] = { text = "Needed for a clear", color = H.GREY }
    end
  else
    H.SetIcon(b.pic, H.ICON.watch)
    if live and run.done then
      tags[#tags + 1] = { text = "Cleared", color = H.GOLD, icon = H.ICON.ready }
    end
    tags[#tags + 1] = { text = #Required(dungeon) .. " bosses", color = H.GREY,
      tip = { "A full clear", "Every boss but the rares and the optional ones." } }
  end
  H.SetEdge(b.pic, ar, ag, ab, 0.8)
  H.PaintBanner(b, boss and boss.name or "Full clear", nil, tags)
  local y = H.BANNER_H + 4

  local function Section(label, note)
    local h = detail.sections:Get()
    H.PaintSection(h, label, note)
    y = H.Place(h, y + 6, 20, 4)
  end

  -- This run, as tiles.
  if live then
    Section("This run")
    if boss then
      local split = run.splits[boss.name]
      local prev = run.prev and run.prev[boss.name]
      y = H.Tiles(detail.tiles, y, width, {
        { value = FormatTime(split), label = "split", color = split and nil or H.GREY, strong = split ~= nil },
        { value = FormatTime(run.fights[boss.name]), label = "fight", color = run.fights[boss.name] and nil or H.GREY },
        DeltaTile(split and prev and (split - prev), "vs your best"),
      })
    else
      local killed, total = Killed(run, dungeon)
      y = H.Tiles(detail.tiles, y, width, {
        { value = FormatTime(Elapsed(run)), label = run.done and "cleared in" or "running", strong = true,
          color = run.done and H.GOLD or nil },
        { value = killed .. "/" .. total, label = "bosses" },
        DeltaTile(run.done and run.prevTotal and (run.total - run.prevTotal), "vs your best"),
      })
    end
  end

  -- Your records.
  Section("Your records")
  if boss then
    local best = rec.bosses[boss.name] or {}
    y = H.Tiles(detail.tiles, y, width, {
      { value = FormatTime(best.split), label = best.split and ("best split · " .. DateText(best.splitAt)) or "best split",
        color = best.split and H.GOLD or H.GREY },
      { value = FormatTime(best.fight), label = best.fight and ("best fight · " .. DateText(best.fightAt)) or "best fight",
        color = best.fight and nil or H.GREY },
    })
  else
    y = H.Tiles(detail.tiles, y, width, {
      { value = FormatTime(rec.total), label = rec.total and ("best clear · " .. DateText(rec.totalAt)) or "best clear",
        color = rec.total and H.GOLD or H.GREY },
      { value = tostring(rec.clears or 0), label = "clears" },
    })
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
      local note, noteSub
      local has = p and p.dungeon == dungeon
      if not has then
        note = "|cff888888" .. H.Quiet(m) .. "|r"
      elseif boss then
        local bb = p.bosses[boss.name]
        note = bb and bb.split and FormatTime(bb.split) or "|cff888888--:--|r"
        noteSub = bb and bb.fight and ("fight " .. FormatTime(bb.fight)) or nil
      else
        note = p.total and FormatTime(p.total) or "|cff888888--:--|r"
        noteSub = p.total and ((p.clears or 0) .. " clears") or nil
      end
      local r = detail.rows:Get()
      H.SetClassIcon(r.pic.tex, m.class)
      H.SetEdge(r.pic, 0, 0, 0, 1)
      H.SetCorner(r.pic, nil)
      r.pic.label:SetText("")
      r.pic.back:SetColorTexture(0, 0, 0, 0.6)
      local cr, cg, cb = H.ClassColor(m.class)
      H.PaintRow(r, { name = m.name, note = note, noteSub = noteSub, color = { cr, cg, cb }, dim = not has })
      y = H.Place(r, y, LINE_H, 1)
    end
  end

  -- The guild leaderboard.
  local leaders = Leaders(dungeon, boss and boss.name)
  Section("Guild leaderboard", "|cff888888" .. (boss and "best split" or "best clear") .. "|r")
  if #leaders == 0 then
    y = H.ShowEmpty(detail.empty, y, width, "No records shared yet", COINS[1])
  end
  local meShown = false
  for i, e in ipairs(leaders) do
    if i <= BOARD_TOP or (e.me and not meShown) then
      local r = detail.rows:Get()
      if COINS[i] then
        H.SetIcon(r.pic, COINS[i], false)
        H.SetEdge(r.pic, 0, 0, 0, 0)
        r.pic.back:SetColorTexture(0, 0, 0, 0)
        r.pic.label:SetText("")
      else
        r.pic.tex:SetTexture(nil)
        r.pic.tex:SetColorTexture(1, 1, 1, 0.06)
        H.SetEdge(r.pic, 1, 1, 1, 0.15)
        r.pic.label:SetText("|cffbbbbbb" .. i .. "|r")
      end
      H.SetCorner(r.pic, nil)
      H.PaintRow(r, {
        name = e.me and ("|cff66ff66" .. e.name .. "|r") or e.name,
        note = (i == 1 and "|cffffd100" or "") .. FormatTime(e.value) .. (i == 1 and "|r" or ""),
        noteSub = (not boss and e.clears) and (e.clears .. " clears") or nil,
        tint = e.me and { 0.4, 1, 0.45, 0.08 } or (i <= 3 and { ar, ag, ab, 0.05 } or nil),
      })
      r.pic.back:SetColorTexture(0, 0, 0, COINS[i] and 0 or 0.6)
      y = H.Place(r, y, LINE_H, 1)
      meShown = meShown or e.me
    end
  end
  if not mod.db.guildBoard then
    local fs = detail.paras:Get()
    y = H.Para(fs, y + 4, width, "|cffff9933You don't share yours|r (Clear Times settings)")
  end
  return Finish(y + 6)
end

function tab:Status()
  local run = Run()
  if run and run.start and run.inside then
    return (run.done and "cleared in " or "run ") .. FormatTime(Elapsed(run))
  end
end
