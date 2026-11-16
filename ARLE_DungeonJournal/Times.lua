-- Dungeon Helper, Clear Times tab: a run timer with a split per boss, like a
-- speedrun timer. Each boss row has the boss's portrait, its split in this
-- run (time from the start of the run to the kill) and the difference with
-- the player's best split. Hovering a split shows the records for that boss
-- (best split, best fight) and those of party members with the addon.
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
local _, ns = ...
local ARLE = _G.ARLExtensions
local H = ns.H
if not ARLE or not H then
  return
end
local mod = H.mod
local Bosses, Members, ColorName, TooltipSide = H.Bosses, H.Members, H.ColorName, H.TooltipSide
local FormatTime, FormatDelta, Now = H.FormatTime, H.FormatDelta, H.Now

local ROW_H, PORTRAIT = 22, 20
local RESUME = 45 * 60 -- an unfinished run older than this starts over

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
    ARLE:Print("Clear Times: this is a new copy of " .. tostring(run.dungeon) .. " (reset): the run starts over.")
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
    ARLE:Print(text)
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
  H.Render()
end

-------------------------------------------------------------------------------
-- Comms: "BT <dungeon>~<best total>~<clears>~<part>~<count>~boss=split/fight;..."
-------------------------------------------------------------------------------

local party = {} -- name -> { dungeon, total, clears, bosses = { [boss] = {split, fight} } }
tab.data = party

function tab:Send(dungeon, channel)
  local rec = Records(dungeon) or { bosses = {} }
  local list = {}
  for boss, r in pairs(rec.bosses) do
    if r.split or r.fight then
      list[#list + 1] = boss .. "=" .. (r.split or "") .. "/" .. (r.fight or "")
    end
  end
  table.sort(list)
  H.SendChunks("BT", dungeon .. "~" .. (rec.total or "") .. "~" .. (rec.clears or 0), list, ";", channel)
end

ARLE:RegisterComm("BT", function(sender, payload)
  if not mod._active then
    return
  end
  local dungeon, total, clears, part, list = payload:match("^(.-)~(%d*)~(%d*)~(%d+)~%d+~(.*)$")
  if not dungeon then
    return
  end
  local p = party[sender]
  if not p or p.dungeon ~= dungeon or tonumber(part) == 1 then
    p = { dungeon = dungeon, bosses = {} }
    party[sender] = p
  end
  p.total, p.clears = tonumber(total), tonumber(clears) or 0
  for entry in list:gmatch("[^;]+") do
    local boss, split, fight = entry:match("^(.-)=(%d*)/(%d*)$")
    if boss then
      p.bosses[boss] = { split = tonumber(split), fight = tonumber(fight) }
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

-------------------------------------------------------------------------------
-- View: [12:34] running ............ [Reset]
--       (portrait) Boss name ........ -0:12  4:05
--       ...
--       Clear ......................... 23:41
-------------------------------------------------------------------------------

local child, emptyText, footer
local rows = {}

local function DateText(t)
  return t and date and date("%Y-%m-%d", t) or ""
end


-- Party members' records as { member, value, text } (value nil: no record;
-- none: no addon), with the fastest value among them and mine.
local function PartyEntries(dungeon, get, mine)
  local entries, fastest = {}, mine
  for _, m in ipairs(Members()) do
    if m.unit ~= "player" then
      local p = party[m.name]
      local e = { member = m, none = not (p and p.dungeon == dungeon) }
      if not e.none then
        e.value, e.text = get(p)
        if e.value and (not fastest or e.value < fastest) then
          fastest = e.value
        end
      end
      entries[#entries + 1] = e
    end
  end
  return entries, fastest
end

local function AddPartyLines(entries, fastest)
  if #entries == 0 then
    return
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Party records", 1, 0.82, 0)
  for _, e in ipairs(entries) do
    if e.none then
      GameTooltip:AddDoubleLine(ColorName(e.member), "no addon", 1, 1, 1, 0.5, 0.5, 0.5)
    elseif e.value then
      GameTooltip:AddDoubleLine(ColorName(e.member), (e.value == fastest and "|cffffd100" or "|cffffffff") .. e.text .. "|r",
        1, 1, 1, 1, 1, 1)
    else
      GameTooltip:AddDoubleLine(ColorName(e.member), "none yet", 1, 1, 1, 0.6, 0.6, 0.6)
    end
  end
end

local function RecordLine(label, value, at)
  GameTooltip:AddDoubleLine(label, value and (FormatTime(value) .. "  |cff888888" .. DateText(at) .. "|r") or "none yet",
    0.8, 0.8, 0.8, 1, 1, 1)
end

local function SplitTooltip(row)
  local boss, dungeon = row.boss, H.shown
  local run = Run()
  local rec = Records(dungeon) or { bosses = {} }
  local best = rec.bosses[boss.name] or {}
  GameTooltip:SetOwner(row, TooltipSide(row))
  GameTooltip:SetText(boss.name .. (boss.rare and "  |cffaaaaaa(rare)|r" or (boss.optional and "  |cffaaaaaa(optional)|r")
    or ""), 1, 1, 1)
  if run and run.dungeon == dungeon then
    local split = run.splits[boss.name]
    if split then
      local prev = run.prev and run.prev[boss.name]
      GameTooltip:AddDoubleLine("This run", FormatTime(split) .. (prev and ("  " .. FormatDelta(split - prev)) or ""),
        0.8, 0.8, 0.8, 1, 1, 1)
      if run.fights[boss.name] then
        GameTooltip:AddDoubleLine("   fight", FormatTime(run.fights[boss.name]), 0.6, 0.6, 0.6, 0.8, 0.8, 0.8)
      end
    else
      GameTooltip:AddLine("Not killed in this run yet", 0.6, 0.6, 0.6)
    end
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Your records", 1, 0.82, 0)
  RecordLine("Best split", best.split, best.splitAt)
  RecordLine("Best fight", best.fight, best.fightAt)
  AddPartyLines(PartyEntries(dungeon, function(p)
    local b = p.bosses[boss.name]
    if b and b.split then
      return b.split, FormatTime(b.split) .. (b.fight and ("  |cff888888fight " .. FormatTime(b.fight) .. "|r") or "")
    end
  end, best.split))
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Split: from the start of the run to the kill. Fight: from the pull to the kill. "
    .. "Gold: the party's fastest.", 0.6, 0.6, 0.6, true)
  GameTooltip:Show()
end

local function ClearTooltip(owner)
  local dungeon = H.shown
  local run = Run()
  local rec = Records(dungeon) or {}
  GameTooltip:SetOwner(owner, TooltipSide(owner))
  GameTooltip:SetText(dungeon or "Clear", 1, 1, 1)
  if run and run.dungeon == dungeon and run.start then
    local required, killed = Required(dungeon), 0
    for _, name in ipairs(required) do
      if run.splits[name] then
        killed = killed + 1
      end
    end
    GameTooltip:AddDoubleLine(run.done and "This run (cleared)" or "This run", FormatTime(Elapsed(run))
      .. ((run.done and run.prevTotal) and ("  " .. FormatDelta(run.total - run.prevTotal)) or ""), 0.8, 0.8, 0.8, 1, 1, 1)
    GameTooltip:AddDoubleLine("   bosses", killed .. "/" .. #required, 0.6, 0.6, 0.6, 0.8, 0.8, 0.8)
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Your records", 1, 0.82, 0)
  RecordLine("Best clear", rec.total, rec.totalAt)
  GameTooltip:AddDoubleLine("Clears", tostring(rec.clears or 0), 0.8, 0.8, 0.8, 1, 1, 1)
  AddPartyLines(PartyEntries(dungeon, function(p)
    if p.total then
      return p.total, FormatTime(p.total) .. "  |cff888888" .. (p.clears or 0) .. " clears|r"
    end
  end, rec.total))
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("A clear needs every boss but the rares and the optional ones (summoned, or brought by a "
    .. "quest).", 0.6, 0.6, 0.6, true)
  GameTooltip:Show()
end

local function Row(i)
  local r = rows[i]
  if r then
    return r
  end
  r = CreateFrame("Button", nil, child)
  r:SetHeight(ROW_H)
  r.bg = r:CreateTexture(nil, "BACKGROUND")
  r.bg:SetAllPoints()
  r.portrait = r:CreateTexture(nil, "ARTWORK")
  r.portrait:SetSize(PORTRAIT, PORTRAIT)
  r.portrait:SetPoint("LEFT", 3, 0)
  r.time = ARLE.UIKit.Text(r, "GameFontHighlightSmall")
  r.time:SetPoint("RIGHT", -4, 0)
  r.time:SetJustifyH("RIGHT")
  r.name = ARLE.UIKit.Text(r, "GameFontHighlightSmall")
  r.name:SetPoint("LEFT", r.portrait, "RIGHT", 5, 0)
  r.name:SetPoint("RIGHT", r.time, "LEFT", -4, 0)
  r.name:SetWordWrap(false)
  r.hl = r:CreateTexture(nil, "HIGHLIGHT")
  r.hl:SetAllPoints()
  r.hl:SetColorTexture(1, 1, 1, 0.07)
  r:SetScript("OnEnter", SplitTooltip)
  r:SetScript("OnLeave", GameTooltip_Hide)
  rows[i] = r
  return r
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
  C_Timer.After(3, function()
    if self.armed and GetTime() - self.armed >= 2.9 then
      self.armed = nil
      self:SetText("Reset")
    end
  end)
end

-- Toolbar: 12:34  2/4 bosses ............ [Reset]
function tab:Create(content, bar)
  child = content
  local kit = ARLE.UIKit
  self.clock = kit.Text(bar, "GameFontNormal")
  self.clock:SetPoint("LEFT", 2, 0)
  self.reset = H.SmallButton(bar, "Reset", 48)
  self.reset:SetPoint("RIGHT", 0, 0)
  self.reset:SetScript("OnClick", ResetClick)
  self.reset:SetScript("OnEnter", function(b)
    H.SimpleTooltip(b, "Start over", "Throws away this run and waits for the next pull. Records are kept. "
      .. "Click twice to confirm.")
  end)
  self.reset:SetScript("OnLeave", GameTooltip_Hide)
  self.status = kit.Text(bar, "GameFontDisableSmall")
  self.status:SetPoint("LEFT", self.clock, "RIGHT", 6, 0)
  self.status:SetPoint("RIGHT", self.reset, "LEFT", -4, 0)
  self.status:SetWordWrap(false)

  footer = CreateFrame("Button", nil, child)
  footer:SetHeight(32)
  footer.bg = footer:CreateTexture(nil, "BACKGROUND")
  footer.bg:SetAllPoints()
  footer.label = kit.Text(footer, "GameFontNormalSmall")
  footer.label:SetPoint("TOPLEFT", 6, -4)
  footer.label:SetText("Clear")
  footer.time = kit.Text(footer, "GameFontHighlight")
  footer.time:SetPoint("TOPRIGHT", -4, -3)
  footer.time:SetJustifyH("RIGHT")
  footer.best = kit.Text(footer, "GameFontDisableSmall")
  footer.best:SetPoint("BOTTOMLEFT", 6, 4)
  footer.best:SetPoint("BOTTOMRIGHT", -4, 4)
  footer:SetScript("OnEnter", ClearTooltip)
  footer:SetScript("OnLeave", GameTooltip_Hide)
  self.footer = footer

  emptyText = kit.Text(child, "GameFontDisableSmall")
  emptyText:SetPoint("TOPLEFT", 6, -8)
  emptyText:SetPoint("RIGHT", -6, 0)
end

-- The running parts: clock, status and the clear time.
function tab:Tick()
  if not self.clock then
    return
  end
  local ar, ag, ab = ARLE.Skin:Accent()
  local dungeon = H.shown
  local run = Run()
  local live = run and dungeon and run.dungeon == dungeon
  local rec = dungeon and Records(dungeon) or {}
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

  if live and run.start then
    local text = FormatTime(Elapsed(run))
    if run.done and run.prevTotal then
      text = FormatDelta(run.total - run.prevTotal) .. "  " .. text
    end
    footer.time:SetText(text)
  else
    footer.time:SetText("|cff888888" .. FormatTime(rec.total) .. "|r")
  end
  footer.label:SetTextColor(ar, ag, ab)
  if rec.total then
    footer.best:SetText("Best " .. FormatTime(rec.total) .. "  ·  " .. (rec.clears or 0) .. " clear(s)")
  else
    footer.best:SetText("No clear yet")
  end
end

-- The rares' section header: they may not spawn, and a clear doesn't need them.
local rareHeader
local function RareHeader()
  if rareHeader then
    return rareHeader
  end
  local h = CreateFrame("Button", nil, child)
  h:SetHeight(18)
  h.bg = h:CreateTexture(nil, "BACKGROUND")
  h.bg:SetAllPoints()
  h.icon = h:CreateTexture(nil, "ARTWORK")
  h.icon:SetSize(14, 14)
  h.icon:SetPoint("LEFT", 4, 0)
  if not (h.icon.SetAtlas and pcall(h.icon.SetAtlas, h.icon, "nameplates-icon-elite-silver")) then
    h.icon:SetTexture("Interface\\Tooltips\\EliteNameplateIcon")
    h.icon:SetDesaturated(true)
  end
  h.label = ARLE.UIKit.Text(h, "GameFontNormalSmall")
  h.label:SetPoint("LEFT", h.icon, "RIGHT", 3, 0)
  h.label:SetText("Rares")
  h.count = ARLE.UIKit.Text(h, "GameFontDisableSmall")
  h.count:SetPoint("RIGHT", -4, 0)
  h.count:SetJustifyH("RIGHT")
  h:SetScript("OnEnter", function(self)
    H.SimpleTooltip(self, self.label:GetText() or "Rares", "Rare mobs may not spawn in every run, and some bosses "
      .. "only come with a quest or a summoning item, so they are kept apart and a clear doesn't need them. When "
      .. "one is killed it still gets a split and records.")
  end)
  h:SetScript("OnLeave", GameTooltip_Hide)
  rareHeader = h
  tab.rareHeader = h
  return h
end

local function PaintRow(r, boss, run, live, rec, ar, ag, ab)
  r.boss = boss
  if r.portraitOf ~= boss then
    r.portraitOf = boss
    H.SetPortrait(r.portrait, boss)
  end
  local split = live and run.splits[boss.name]
  local best = rec.bosses[boss.name]
  r.name:SetText(boss.name)
  if split then
    local prev = run.prev and run.prev[boss.name]
    r.name:SetTextColor(1, 1, 1)
    r.time:SetText((prev and (FormatDelta(split - prev) .. "  ") or "") .. FormatTime(split))
    r.bg:SetColorTexture(ar, ag, ab, 0.12)
    r.portrait:SetAlpha(1)
  else
    r.name:SetTextColor(0.7, 0.7, 0.7)
    r.time:SetText("|cff777777" .. FormatTime(best and best.split) .. "|r")
    r.bg:SetColorTexture(0, 0, 0, 0)
    r.portrait:SetAlpha(live and 0.6 or 1)
  end
end

-- Bosses, then the clear, then the rares in a section of their own.
function tab:Render()
  local ar, ag, ab = ARLE.Skin:Accent()
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
  local y, n = 0, 0
  local function Place(boss)
    n = n + 1
    local r = Row(n)
    PaintRow(r, boss, run, live, rec, ar, ag, ab)
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", 0, -y)
    r:SetPoint("RIGHT")
    r:Show()
    y = y + ROW_H + 1
  end
  for _, boss in ipairs(bosses) do
    Place(boss)
  end
  footer:SetShown(#bosses > 0)
  if #bosses > 0 then
    footer:ClearAllPoints()
    footer:SetPoint("TOPLEFT", 0, -(y + 2))
    footer:SetPoint("RIGHT")
    footer.bg:SetColorTexture(ar, ag, ab, 0.1)
    y = y + 2 + 32
  end
  if #rares > 0 then
    local h = RareHeader()
    local killed = 0
    for _, boss in ipairs(rares) do
      if live and run.splits[boss.name] then
        killed = killed + 1
      end
    end
    y = y + 6
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", 0, -y)
    h:SetPoint("RIGHT")
    h.bg:SetColorTexture(ar, ag, ab, 0.1)
    h.label:SetTextColor(ar, ag, ab)
    h.label:SetText(allRare and "Rares" or "Rares & optional")
    h.count:SetText(live and (killed .. "/" .. #rares .. " killed") or "may not spawn")
    h:Show()
    y = y + 18 + 1
    for _, boss in ipairs(rares) do
      Place(boss)
    end
  elseif rareHeader then
    rareHeader:Hide()
  end
  for i = n + 1, #rows do
    rows[i]:Hide()
  end
  emptyText:SetShown(n == 0)
  self:Tick()
  if n == 0 then
    emptyText:SetText(dungeon and "DungeonJournal lists no bosses here." or "Not in a dungeon. Pick one with the v button.")
    return 40
  end
  return y
end

function tab:Status()
  local run = Run()
  if run and run.start and run.inside then
    return (run.done and "cleared in " or "run ") .. FormatTime(Elapsed(run))
  end
end
