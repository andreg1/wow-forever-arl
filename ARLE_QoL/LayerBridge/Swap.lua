-- Layer Bridge: the swap (asking -> invited -> joining -> joined -> moved),
-- hosting, the layers we've been on, the game's hourly limit and the numbers
-- the Network drawer shows. See Core.lua for the design.
local _, ns = ...
local LB = ns.LayerBridge
if not LB then
  return
end
local ARLE = _G.ARLExtensions
local F = LB.F
local Lib = ARLE.Lib
local Plain, Str = Lib.Plain, Lib.Str

local HOUR = 3600
-- the swap
local ASK_WINDOW, RETRY_WINDOW, MORE_WINDOW, FALLBACK_AFTER = 25, 10, 20, 8
local JOIN_WAIT, VERDICT_AFTER, LEAVE_AFTER, MOVED_BACK_WATCH = 10, 3, 3, 6
local NOTE_FOR, LATE_FOR, SYSTEM_FRESH, FLASH_FOR = 6, 90, 3, 10
local RESULT_AFTER = 25
-- the game's limit: LayerSwap's rules (r3) promise at most 16 joins an hour
local SWAP_CAP, MIN_WINDOW, MOVES_MAX, LOCKOUTS_MAX = 16, 300, 200, 50
-- moves that aren't ours
local BORDER_BEFORE, BORDER_AFTER, TRANSFER_SETTLE = 10, 2, 2
-- hosting
local HOST_RECENT, INVITE_WAIT, MOVE_WAIT, RELEASE_AFTER, GROUP_MAX = 60, 60, 60, 30, 5
-- history
local HISTORY_TTL, HISTORY_MAX = 6 * HOUR, 12
-- stats
local EVENTS_MAX, KEYS_MAX = 500, 1000

-------------------------------------------------------------------------------
-- The game's hourly limit, learned from its refusals (per character):
--   char.limit = { moves = { time() ... }, lockouts = { ... },
--                  learned = { count, window }, hold = { untilAt, lastMove, count } }
-------------------------------------------------------------------------------

local Limit = {}
LB.Limit = Limit

local function L()
  local c = F.char.limit
  if type(c) ~= "table" then
    c = {}
    F.char.limit = c
  end
  c.moves = type(c.moves) == "table" and c.moves or {}
  c.lockouts = type(c.lockouts) == "table" and c.lockouts or {}
  c.learned = type(c.learned) == "table" and c.learned or { window = HOUR }
  return c
end

local function MovesWithin(c, now, span)
  local n = 0
  for i = #c.moves, 1, -1 do
    if now - c.moves[i] > span then
      break
    end
    n = n + 1
  end
  return n
end

function Limit.Moved()
  local c, now = L(), time()
  local hold = c.hold
  if hold then
    local last = c.lockouts[#c.lockouts]
    if last and not last.resumedAt then
      last.resumedAt = now
    end
    -- Moved again before the hold we guessed ran out: the window is shorter.
    if now < hold.untilAt and hold.lastMove then
      c.learned.window = math.max(MIN_WINDOW, now - hold.lastMove)
    end
    c.hold = nil
  end
  c.moves[#c.moves + 1] = now
  if #c.moves > MOVES_MAX then
    table.remove(c.moves, 1)
  end
end

-- The game kept us on our layer although the host is on another one.
function Limit.Refused()
  local c, now = L(), time()
  local n, lastMove = MovesWithin(c, now, HOUR), c.moves[#c.moves]
  if n > 0 then
    c.learned.count = n
  end
  c.hold = { untilAt = (lastMove or now) + (c.learned.window or HOUR), lastMove = lastMove, count = n }
  c.lockouts[#c.lockouts + 1] = { at = now, count = n, lastMove = lastMove, window = c.learned.window }
  if #c.lockouts > LOCKOUTS_MAX then
    table.remove(c.lockouts, 1)
  end
  LB.Log("refused", n, "learned", c.learned.count, "window", c.learned.window)
  return n
end

function Limit.Likely()
  local c = L()
  return c.learned.count ~= nil and MovesWithin(c, time(), HOUR) >= c.learned.count
end

-- Swaps this hour, and the limit (learned, else LayerSwap's 16).
function Limit.ThisHour()
  local c = L()
  return MovesWithin(c, time(), HOUR), c.learned.count or SWAP_CAP
end

-- Seconds until the game lets us move again, or nil.
function Limit.Left()
  local c = L()
  local now = time()
  local left
  if c.hold then
    left = c.hold.untilAt - now
    if left <= 0 then
      c.hold, left = nil, nil
    end
  end
  -- Our own promise (LayerSwap's r3 mark): at most SWAP_CAP an hour.
  if #c.moves >= SWAP_CAP then
    local cap = c.moves[#c.moves - SWAP_CAP + 1] + HOUR - now
    if cap > 0 and (not left or cap > left) then
      left = cap
    end
  end
  return left
end

-------------------------------------------------------------------------------
-- The layers we've been on (per character), newest first:
--   char.history[i] = { epoch, id = LayerSwap id (once known), zone, host, at }
-------------------------------------------------------------------------------

local History = {}
LB.History = History

function History.List()
  local list = type(F.char.history) == "table" and F.char.history or {}
  F.char.history = list
  local now, epoch = time(), LB.Epoch()
  for i = #list, 1, -1 do
    local e = list[i]
    if type(e) ~= "table" or type(e.epoch) ~= "number" then
      table.remove(list, i) -- (also the GUID-based entries from before 0.14.0)
    else
      if e.epoch == epoch then
        e.at = now
      end
      if type(e.at) ~= "number" or now - e.at > HISTORY_TTL then
        table.remove(list, i)
      end
    end
  end
  return list
end

function History.Current()
  local epoch = LB.Epoch()
  for _, e in ipairs(History.List()) do
    if e.epoch == epoch then
      return e
    end
  end
end

function History.Note(host)
  local list = History.List()
  local e = { epoch = LB.Epoch(), zone = LB.Zone(), at = time(), host = host }
  table.insert(list, 1, e)
  for i = #list, HISTORY_MAX + 1, -1 do
    list[i] = nil
  end
end

-- A network learned the id others know our current layer by.
function History.SetId(id, host)
  local e = History.Current()
  if not e then
    History.Note(host)
    e = History.Current()
  end
  if e then
    e.id = id
    e.host = e.host or host
  end
end

-- LayerSwap ids of the layers to stay away from (not the current one).
function History.Avoid()
  local out, epoch = {}, LB.Epoch()
  if F.db.avoidVisited == false then
    return out
  end
  for _, e in ipairs(History.List()) do
    if e.epoch ~= epoch and type(e.id) == "string" then
      out[#out + 1] = e.id
    end
  end
  return out
end

function History.Clear()
  F.char.history = {}
  History.Note(nil)
end

-------------------------------------------------------------------------------
-- Numbers for the Network drawer (per character, char.stats): the last hour
-- or this session.
-------------------------------------------------------------------------------

local Stats = {}
LB.Stats = Stats
local s

function Stats.Load(newSession)
  local c = F.char
  c.stats = type(c.stats) == "table" and c.stats or {}
  s = c.stats
  s.recent = type(s.recent) == "table" and s.recent or {}
  s.session = type(s.session) == "table" and s.session or {}
  s.talking = type(s.talking) == "table" and s.talking or {}
  s.hosts = type(s.hosts) == "table" and s.hosts or {}
  if newSession or not s.since then
    s.since = time()
    wipe(s.session)
  end
end

local function SessionWindow()
  return F.char.statsWindow == "session"
end

local function Trim(list, from)
  local drop = 0
  while list[drop + 1] and list[drop + 1].at < from do
    drop = drop + 1
  end
  if drop > 0 then
    for i = 1, #list do
      list[i] = list[i + drop]
    end
  end
end

local function See(group, netId, key)
  if not (s and netId and key) or key == LB.MyKey() then
    return
  end
  local set = group[netId] or {}
  group[netId] = set
  local now = time()
  if not set[key] then
    local n, oldest, oldestAt = 0, nil, nil
    for k, at in pairs(set) do
      if at < math.min(s.since, now - HOUR) then
        set[k] = nil
      else
        n = n + 1
        if not oldestAt or at < oldestAt then
          oldest, oldestAt = k, at
        end
      end
    end
    if n >= KEYS_MAX and oldest then
      set[oldest] = nil
    end
  end
  set[key] = now
end

function Stats.Heard(netId, key)
  See(s and s.talking, netId, key)
end

function Stats.Offered(netId, key)
  See(s and s.hosts, netId, key)
end

function Stats.Note(kind, value)
  if not s then
    return
  end
  local now = time()
  for k, list in pairs(s.recent) do
    Trim(list, now - HOUR)
    if not list[1] then
      s.recent[k] = nil
    end
  end
  local list = s.recent[kind] or {}
  s.recent[kind] = list
  if #list >= EVENTS_MAX then
    table.remove(list, 1)
  end
  list[#list + 1] = { at = now, value = value }
  local e = s.session[kind] or { n = 0, sum = 0 }
  s.session[kind] = e
  e.n = e.n + 1
  if value then
    e.sum, e.best = e.sum + value, math.min(e.best or value, value)
  end
end

local function Total(kind)
  if not s then
    return 0, 0, nil
  end
  if SessionWindow() then
    local e = s.session[kind] or {}
    return e.n or 0, e.sum or 0, e.best
  end
  local n, sum, best, from = 0, 0, nil, time() - HOUR
  local list = s.recent[kind] or {}
  for i = #list, 1, -1 do
    local e = list[i]
    if e.at < from then
      break
    end
    n = n + 1
    if e.value then
      sum, best = sum + e.value, math.min(best or e.value, e.value)
    end
  end
  return n, sum, best
end

local function Count(kind)
  return (Total(kind))
end

local function Distinct(set)
  local from = SessionWindow() and (s and s.since or 0) or time() - HOUR
  local n = 0
  for _, at in pairs(set or {}) do
    if at >= from then
      n = n + 1
    end
  end
  return n
end

-- seen (in its channel or heard), talking, hosts (nil: the network can't tell)
function Stats.Net(net)
  local talking = Distinct(s and s.talking[net.id])
  local hosts = net.offers ~= false and Distinct(s and s.hosts[net.id]) or nil
  local seen = LB.NetOn(net) and LB.CallNet(net, "Seen") or 0
  return math.max(tonumber(seen) or 0, talking), talking, hosts
end

function Stats.View()
  local v = {}
  local swaps, sum, best = Total("swap")
  v.swaps, v.avg, v.best = swaps, swaps > 0 and sum / swaps or nil, best
  v.taken, v.same, v.late = Count("invite"), Count("declined same layer"), Count("declined late")
  v.thisHour, v.limit = Limit.ThisHour()
  v.ground = { asked = Count("asked"), invited = Count("host.invited"), moved = Count("host.moved"),
    failed = Count("host.stuck") + Count("host.noshow") }
  v.flying = { invited = Count("fly.invited"), moved = Count("fly.moved"),
    failed = Count("fly.stuck") + Count("fly.noshow") }
  return v
end

-------------------------------------------------------------------------------
-- Flash: a short message in the box (a failure, a refusal)
-------------------------------------------------------------------------------

local flash = { untilAt = 0 }

function LB.Flash(text, notice, seconds)
  flash.text, flash.untilAt = text, GetTime() + (seconds or FLASH_FOR)
  flash.notice = notice and { text = notice, tone = "warn" } or nil
  LB.Refresh()
end

-------------------------------------------------------------------------------
-- Moves: an epoch per layer
-------------------------------------------------------------------------------

function LB.Moved(why, host)
  F.char.epoch = LB.Epoch() + 1
  History.Note(host)
  LB.Log("moved", why, LB.Label())
  if F.db.sound then
    pcall(PlaySound, SOUNDKIT and SOUNDKIT.READY_CHECK or 8960)
  end
  LB.Refresh()
end

-------------------------------------------------------------------------------
-- The swap
-------------------------------------------------------------------------------

local Swap = {}
LB.Swap = Swap

local cur, nextId = nil, 0
local lastAsk, lateUntil = nil, 0
local abandonedAt
local systemText, systemAt

local function Now()
  return GetTime()
end

local function SetPhase(a, phase)
  a.phase, a.phaseAt = phase, Now()
  LB.Step("phase: %s", phase)
end

local function Leave(a, why)
  a.leaving = true
  LB.LeaveGroup(why)
end

local function HidePopup()
  if type(StaticPopup_Hide) == "function" then
    pcall(StaticPopup_Hide, "PARTY_INVITE")
  end
end

local function Decline(name, why)
  pcall(DeclineGroup)
  HidePopup()
  LB.Log("decline", name, why)
  LB.Step("declined %s's invite (%s)", tostring(name), why)
  Stats.Note("declined " .. why)
end

local function NoteShown(a)
  return a.note ~= nil and Now() < a.noteUntil
end

-- sent, total, more (a network could ask more players), busy (still sending)
local function Tally(a)
  local sent, total, more, busy = 0, 0, false, false
  for _, p in pairs(a.progress) do
    sent, total = sent + p.sent, total + p.total
    if p.sent < p.total then
      busy = true
    end
    if p.more then
      more = true
    end
  end
  return sent, total, more and not busy, busy
end

local function Summary(a)
  local sent, total = Tally(a)
  local nets = {}
  for id, p in pairs(a.progress) do
    nets[#nets + 1] = string.format("%s %d/%d", (LB.Net(id) or {}).name or id, p.sent, p.total)
  end
  table.sort(nets)
  local parts = { a.result or "?" }
  parts[#parts + 1] = string.format("asked %d of %d players", sent, total)
  if #nets > 0 then
    parts[#parts + 1] = table.concat(nets, ", ")
  end
  parts[#parts + 1] = string.format("%d hosts offered", a.found)
  if a.host then
    parts[#parts + 1] = "host " .. a.host
  end
  if a.prefilled then
    parts[#parts + 1] = "AutoLayer line put in the chat box"
  end
  return table.concat(parts, "; ")
end

local function Finish(result, flashText, notice)
  local a = cur
  if not a then
    return
  end
  a.active, cur = false, nil
  a.result = result
  lastAsk, lateUntil = a, Now() + LATE_FOR
  LB.Each("StopAsk", a)
  LB.Each("OnSwapResult", a, result, a.host)
  LB.ClearPrefill()
  LB.Log("swap", result, a.host)
  LB.Step("result: %s", result)
  if result == "moved" then
    Stats.Note("swap", a.phaseAt - a.started)
  end
  if result ~= "moved" and result ~= "stopped" then
    F:Print("Swap: " .. Summary(a) .. ". Details: /arl layer last")
  end
  if flashText then
    LB.Flash(flashText, notice)
  else
    LB.Refresh()
  end
end

local ArmDeadline

local function CheckDeadline(a)
  if cur ~= a or a.phase ~= "asking" then
    return
  end
  if a.deadline > Now() then
    return ArmDeadline(a)
  end
  Finish("no host", "No host found")
end

ArmDeadline = function(a)
  if a.deadlineTimer then
    a.deadlineTimer.Cancel()
  end
  a.deadlineTimer = LB.After(a.deadline - Now(), CheckDeadline, a)
end

local function TryFallback(a, due)
  if cur ~= a or a.fallbackTried or a.phase ~= "asking" or a.found > 0 or a.want then
    return
  end
  if (not due and Now() - a.started < FALLBACK_AFTER) or F.db.askAutoLayer == false then
    return
  end
  a.fallbackTried = true
  if LB.Each("Fallback", a) == "prefilled" then
    a.prefilled = true
    LB.Step("no host yet: AutoLayer's line put in the chat box (press Enter)")
    LB.Refresh()
  end
end

local function Retry(why, note)
  local a = cur
  if not a then
    return
  end
  if a.hostKey then
    a.refused[a.hostKey] = true
    LB.Each("OnHostFailed", a, why, a.host)
  end
  SetPhase(a, "asking")
  a.host, a.hostKey, a.leaving = nil, nil, nil
  a.deadline = math.max(a.deadline, Now() + RETRY_WINDOW)
  a.note, a.noteUntil = note, Now() + NOTE_FOR
  ArmDeadline(a)
  TryFallback(a)
  LB.Refresh()
end

local function NewAsk(via, target)
  nextId = nextId + 1
  local t = Now()
  local a = { id = nextId, via = via, active = true, phase = "asking", started = t, deadline = t + ASK_WINDOW,
    phaseAt = t, zone = LB.Zone(), asked = {}, offers = {}, refused = {}, found = 0, joins = 0, progress = {},
    want = target and target.id or nil, wantHost = target and target.host or nil, epoch = LB.Epoch() }
  function a.Asked(name)
    local key = LB.Key(name)
    if key then
      a.asked[key] = true
    end
  end
  function a.Offer(name, netId)
    local key = LB.Key(name)
    if not key or a.offers[key] or a.refused[key] then
      return
    end
    a.offers[key] = netId or true
    a.found = a.found + 1
    Stats.Offered(netId, key)
    LB.Step("%s (%s) offers to host", tostring(name), tostring(netId))
    LB.Refresh()
  end
  function a.Refuse(name)
    local key = LB.Key(name)
    if key then
      a.refused[key] = true
    end
  end
  function a.Progress(netId, sent, total, more)
    local p = a.progress[netId] or {}
    a.progress[netId] = p
    p.sent, p.total, p.more = sent, total, more and true or false
    LB.Refresh()
  end
  -- Invites from anyone count for a while (AutoLayer hosts we never named).
  function a.AllowAny(seconds)
    a.anyUntil = Now() + seconds
    a.deadline = math.max(a.deadline, a.anyUntil)
  end
  return a
end

function Swap.Start(via, target)
  local a = NewAsk(via, target)
  cur = a
  LB.steps = { at = GetTime(), via = via, lines = {} }
  LB.Step("press (%s): zone %s (%s), %s, networks: %s%s", tostring(via), tostring(a.zone),
    tostring(LB.ZoneName(a.zone)), LB.Label(), Swap.NetList(), target and (", asking for " .. tostring(target.id))
      or "")
  LB.Each("Ask", a)
  ArmDeadline(a)
  LB.After(FALLBACK_AFTER, TryFallback, a, true)
  LB.After(RESULT_AFTER, function()
    if cur == a and a.phase == "asking" then
      LB.Step("still asking after %d s", RESULT_AFTER)
    end
  end)
  LB.Refresh()
end

function Swap.NetList()
  local out = {}
  for _, net in ipairs(LB.nets) do
    local native = LB.Native(net)
    out[#out + 1] = net.name .. (native and " (own addon)" or (LB.NetOn(net) and "" or " (off)"))
  end
  return table.concat(out, ", ")
end

function Swap.Stop()
  local a = cur
  if not a then
    return
  end
  local phase = a.phase
  if phase == "invited" then
    Decline(a.host, "stopped")
  elseif phase == "joining" and not IsInGroup() then
    abandonedAt = Now()
  elseif phase ~= "asking" and IsInGroup() then
    Leave(a, "stopped")
  end
  Finish(phase == "moved" and "moved" or "stopped")
end

function Swap.More()
  local a = cur
  a.deadline = math.max(a.deadline, Now() + MORE_WINDOW)
  LB.Step("ask more")
  LB.Each("More", a)
  ArmDeadline(a)
  LB.Refresh()
end

local function CanAskMore(a)
  return a.phase == "asking" and not NoteShown(a) and select(3, Tally(a))
end

-- Why a swap can't start now, or nil.
function Swap.Blocked()
  if F._conflict then
    return "Off: " .. tostring(F._conflict) .. " loaded"
  end
  if IsInGroup() then
    return "In a group"
  end
  if LB.InInstance() then
    return "In an instance"
  end
  if UnitIsDeadOrGhost("player") then
    return "Dead"
  end
  if LB.Host.Pending() then
    return "Inviting a player"
  end
  local any = false
  for _, net in ipairs(LB.nets) do
    any = any or LB.NetOn(net)
  end
  if not any then
    return "No network on"
  end
end

-- The Swap button / key / command. via: "button", "key", "command", "panel",
-- "AutoLayer"; target: a History entry ({ id, host }).
function Swap.Click(via, target)
  if cur then
    if target then
      return
    end
    if CanAskMore(cur) then
      return Swap.More()
    end
    return Swap.Stop()
  end
  local why = Swap.Blocked()
  if why then
    return LB.Flash(why, nil, 4)
  end
  local left = Limit.Left()
  if left then
    return LB.Flash("Swap limit reached", "Reset in " .. LB.Countdown(left), 4)
  end
  Swap.Start(via, target)
end

function Swap.Busy()
  return cur ~= nil
end

function Swap.Current()
  return cur
end

function Swap.Last()
  return lastAsk
end

function Swap.ClaimsTransfer()
  return cur ~= nil and (cur.phase == "joined" or cur.phase == "moved" or cur.leftAt ~= nil)
end

local function AskingStatus(a, v)
  if NoteShown(a) then
    v.status, v.tone, v.border = a.note, "fail", "fail"
    return LB.WakeIn(a.noteUntil - Now())
  end
  if a.prefilled then
    v.status, v.tone, v.border = "Press Enter to ask AutoLayer", "warn", "fail"
    return
  end
  local sent, total, more, busy = Tally(a)
  if busy then
    v.status = "Asking " .. sent .. "/" .. total .. " · " .. a.found .. " found"
    return
  end
  v.status = "Searching (" .. a.found .. " found)"
  if more then
    v.swapText = "Ask more"
  end
end

local function MovedStatus(a)
  if not (F.db.auto ~= false and a.leaveAt and not a.leftAt) then
    return "Moved"
  end
  local wait = a.leaveAt - Now()
  local shown = math.max(0, math.ceil(wait))
  if shown > 0 then
    LB.WakeIn(wait - (shown - 1))
  end
  return "Moved · leaving in " .. shown .. "s"
end

function Swap.View(v)
  local a = cur
  if not a then
    return false
  end
  v.tone, v.border, v.swapText = "swap", "swap", "Stop"
  local phase = a.phase
  if phase == "asking" then
    AskingStatus(a, v)
  elseif phase == "invited" then
    v.status, v.swapText = "Invite from " .. (a.host or "?"), "Decline"
    v.notice = { text = "", tone = "swap", button = { text = "Accept", onClick = Swap.Accept } }
  elseif phase == "joining" then
    v.status = "Joining " .. (a.host or "the host")
  elseif phase == "joined" then
    v.status, v.swapText = "In " .. (a.host or "the host") .. "'s group", "Leave"
  else
    v.status, v.swapText = MovedStatus(a), "Leave"
  end
  return true
end

local function Verdict(a, join)
  if cur ~= a or a.phase ~= "joined" or a.joins ~= join then
    return
  end
  local unit = LB.LeaderUnit()
  local phase = unit and LB.PhaseOf(unit)
  local hostMap = unit and (Lib.Call(C_Map.GetBestMapForUnit, unit))
  local sameZone = not hostMap or hostMap == LB.RawMap()
  LB.Step("no move %d s after joining: leader phase %s, same map %s", VERDICT_AFTER, tostring(phase),
    tostring(sameZone))
  Leave(a, "verdict")
  if (phase == LB.SHARDING and sameZone) or Limit.Likely() then
    local n = Limit.Refused()
    local left = Limit.Left() or HOUR
    Finish("refused by the game (" .. n .. " swaps this hour)", "Refused · " .. n .. " this hour",
      "Reset in " .. LB.Countdown(left))
  else
    Retry("same", "Same layer · retrying")
  end
end

local function CheckJoin(a, phaseAt)
  if cur ~= a or a.phaseAt ~= phaseAt then
    return
  end
  if a.phase == "joining" or a.phase == "invited" then
    Retry("ended", "Invite ended · retrying")
  end
end

local function IsLate(key)
  return lastAsk and Now() < lateUntil and (lastAsk.asked[key] or lastAsk.offers[key])
end

local function Wanted(a, key)
  return a.offers[key] or a.asked[key] or (a.anyUntil and Now() < a.anyUntil)
end

function Swap.Accept()
  local a = cur
  if not a or a.phase ~= "invited" then
    return
  end
  pcall(AcceptGroup)
  SetPhase(a, "joining")
  LB.After(JOIN_WAIT, CheckJoin, a, a.phaseAt)
  LB.Refresh()
end

-- PARTY_INVITE_REQUEST: inviter, roles..., isCrossShard (6th)
local function OnInvite(_, name, _, _, _, _, isCrossShard)
  name = Str(Plain(name))
  local key = LB.Key(name)
  if not key then
    return
  end
  local a = cur
  if not a or a.phase ~= "asking" then
    if (a and (a.asked[key] or a.offers[key])) or IsLate(key) then
      Decline(name, "late")
    end
    return
  end
  if not Wanted(a, key) then
    LB.Step("invite from %s, who we didn't ask: left to you", name)
    return
  end
  if Plain(isCrossShard) == false or a.refused[key] then
    Decline(name, "same layer")
    a.refused[key] = true
    LB.Each("OnHostFailed", a, "same", name)
    return
  end
  a.host, a.hostKey = name, key
  F.char.invitedAt = GetTime()
  Stats.Note("invite")
  LB.Step("invite from %s (cross-layer: %s)", name, tostring(Plain(isCrossShard)))
  if F.db.auto ~= false then
    SetPhase(a, "invited")
    Swap.Accept()
  else
    SetPhase(a, "invited")
    LB.After(JOIN_WAIT * 6, CheckJoin, a, a.phaseAt)
  end
  LB.Refresh()
end

local function OnJoined()
  local a = cur
  if not a then
    if abandonedAt and Now() - abandonedAt < JOIN_WAIT then
      LB.LeaveGroup("stopped")
    end
    abandonedAt = nil
    return
  end
  if not (a.phase == "joining" or a.phase == "invited") or not IsInGroup() then
    return
  end
  HidePopup()
  SetPhase(a, "joined")
  a.leaving = false
  a.joins = a.joins + 1
  LB.After(VERDICT_AFTER, Verdict, a, a.joins)
  LB.Refresh()
end

local function FinishMoved(a)
  if cur == a then
    Finish("moved")
  end
end

local function LeaveAfterMove(a)
  if cur ~= a or a.phase ~= "moved" or a.leftAt or not IsInGroup() then
    return
  end
  a.leftAt = Now()
  Leave(a, "moved")
  LB.After(MOVED_BACK_WATCH, FinishMoved, a)
end

local function OnSwapTransfer()
  local a = cur
  if not a then
    return
  end
  if a.phase == "joined" then
    SetPhase(a, "moved")
    Limit.Moved()
    LB.Moved("swap", a.host)
    if F.db.auto ~= false then
      a.leaveAt = Now() + LEAVE_AFTER
      LB.After(LEAVE_AFTER, LeaveAfterMove, a)
    end
    LB.Refresh()
  elseif a.leftAt and Now() - a.leftAt <= MOVED_BACK_WATCH then
    LB.Moved("moved back")
    Finish("moved back", "Moved back · try again")
  end
end

local function RemovedByHost()
  return systemAt ~= nil and Now() - systemAt < SYSTEM_FRESH and systemText ~= nil
    and systemText == Str(rawget(_G, "ERR_UNINVITE_YOU"))
end

local function OnLeft()
  local a = cur
  if not a then
    return
  end
  if a.phase == "moved" then
    if not a.leftAt then
      a.leftAt = Now()
      LB.After(MOVED_BACK_WATCH, FinishMoved, a)
    end
    return
  end
  if a.phase ~= "joined" or a.leaving then
    return
  end
  if RemovedByHost() then
    Retry("removed", "Removed by " .. (a.host or "host") .. " · retrying")
  else
    Retry("ended", "Group ended · retrying")
  end
end

local function OnRoster()
  LB.PartyChanged()
  if cur and (cur.phase == "joining" or cur.phase == "invited") and IsInGroup() then
    OnJoined()
  end
end

local function OnSystem(_, text)
  if cur then
    systemText, systemAt = Str(Plain(text)), Now()
    LB.Step("game says: %s", tostring(systemText))
  end
end

-------------------------------------------------------------------------------
-- Moves that aren't ours: a world refresh, a transfer away from a border
-------------------------------------------------------------------------------

local lastZoneAt, refreshAt = 0, nil

local function ZoneChanged()
  lastZoneAt = GetTime()
  LB.MapsChanged()
  LB.Refresh()
end

local function OnTransferImminent()
  refreshAt = GetTime() + (tonumber(Plain(type(GetEvictionTimeRemaining) == "function"
    and GetEvictionTimeRemaining() or 0)) or 0)
  LB.Refresh()
end

local function OnTransferCancelled()
  refreshAt = nil
  LB.Refresh()
end

local function JudgeTransfer(at, wasRefresh)
  local since = at - lastZoneAt
  local border = (since >= 0 and since <= BORDER_BEFORE) or (since < 0 and -since <= BORDER_AFTER)
  if border and not wasRefresh then
    return
  end
  LB.Moved(wasRefresh and "world refresh" or "transfer")
end

local function OnTransfer()
  local wasRefresh = refreshAt ~= nil
  refreshAt = nil
  if Swap.ClaimsTransfer() then
    return OnSwapTransfer()
  end
  -- (a border crossing's zone change can come after its transfer)
  LB.After(TRANSFER_SETTLE, JudgeTransfer, GetTime(), wasRefresh)
end

local function ConfirmRefresh()
  local m = C_PlayerInteractionManager
  if m and type(m.ShardTransferConfirm) == "function" then
    pcall(m.ShardTransferConfirm)
  end
end

local function Clock(sec)
  sec = math.max(0, math.floor(sec + 0.5))
  return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

-------------------------------------------------------------------------------
-- Hosting: one gate for every network
-------------------------------------------------------------------------------

local Host = { guests = {}, sent = {} }
LB.Host = Host
local hostWake

function Host.Recent(sec)
  local n, now = 0, GetTime()
  for i = #Host.sent, 1, -1 do
    if now - Host.sent[i] >= sec then
      break
    end
    n = n + 1
  end
  return n
end

local function RecordInvite(now)
  local kept = {}
  for _, at in ipairs(Host.sent) do
    if now - at < HOUR then
      kept[#kept + 1] = at
    end
  end
  kept[#kept + 1] = now
  Host.sent = kept
end

local function LimitReached()
  local limit = tonumber(F.db.invitesPerHour) or 0
  return limit > 0 and Host.Recent(HOUR) >= limit
end

-- Solo, or leading a party of nobody but our guests.
local function GroupIsOurs()
  if not IsInGroup() then
    return true
  end
  if IsInRaid() or not UnitIsGroupLeader("player") then
    return false
  end
  for key in pairs(LB.Party()) do
    if not Host.guests[key] then
      return false
    end
  end
  return true
end

-- When every guest still in the group has moved: the last move.
local function LastMove()
  local last
  for key, g in pairs(Host.guests) do
    if LB.UnitFor(key) then
      if not g.movedAt then
        return nil
      end
      last = math.max(last or 0, g.movedAt)
    end
  end
  return last
end

local function Blocked()
  if not F.db.host then
    return "off"
  end
  if LB.InInstance() then
    return "instance"
  end
  if UnitOnTaxi("player") and F.db.hostWhileFlying == false then
    return "flying"
  end
  if Swap.Busy() then
    return "swapping"
  end
  if not GroupIsOurs() then
    return "in group"
  end
  if LimitReached() then
    return "invite limit"
  end
end
Host.Blocked = Blocked

local function GroupFull()
  return IsInGroup() and (GetNumGroupMembers() or 0) >= GROUP_MAX
end

local function Check(asker, askerZone)
  local why = Blocked()
  if why then
    return false, why
  end
  if asker == nil then
    return true
  end
  local key = LB.Key(asker)
  if not key or key == LB.MyKey() then
    return false, "self"
  end
  local zone = LB.Zone()
  if askerZone and zone and tonumber(askerZone) ~= zone then
    return false, "zone"
  end
  if not LB.Gate("invite", key, HOST_RECENT, true) then
    return false, "recent"
  end
  if GroupFull() and not LastMove() then
    return false, "full"
  end
  return true
end

local askedGate = {}
-- Whether we'd invite asker now (and why not). asker nil: hosting at all.
function Host.Can(asker, askerZone)
  local ok, why = Check(asker, askerZone)
  local key = asker and LB.Key(asker)
  if key and key ~= LB.MyKey() and LB.Gate("stats asked", key, 60) then
    Stats.Note("asked")
    askedGate[key] = why
    F:Debug("host: %s asks (zone %s): %s", tostring(asker), tostring(askerZone), ok and "yes" or tostring(why))
  end
  return ok, why
end

local function WakeHost(at)
  if hostWake then
    hostWake.Cancel()
  end
  hostWake = at and LB.After(math.max(0, at - GetTime()), Host.Check) or nil
end

local function TallyKey(g, event)
  return (g.flying and "fly." or "host.") .. event
end

local function Track(key, g, now)
  local unit = LB.UnitFor(key)
  if not unit then
    if not g.joinedAt and now - g.invitedAt < INVITE_WAIT then
      return g.invitedAt + INVITE_WAIT
    end
    if not g.joinedAt then
      Stats.Note(TallyKey(g, "noshow"))
    end
    Host.guests[key] = nil
    return nil
  end
  if not g.joinedAt then
    g.joinedAt = now
    LB.CallNet(LB.Net(g.net), "OnGuestJoined", g.name)
  end
  if g.movedAt then
    return nil
  end
  if LB.PhaseOf(unit) == nil then
    g.movedAt = now
    Stats.Note(TallyKey(g, "moved"))
    LB.Log("guest-moved", g.name)
  elseif now - g.joinedAt >= MOVE_WAIT then
    g.movedAt = now
    Stats.Note(TallyKey(g, "stuck"))
    LB.Log("guest-stuck", g.name)
  else
    return g.joinedAt + MOVE_WAIT
  end
end

function Host.Check()
  local now, due = GetTime(), nil
  for key, g in pairs(Host.guests) do
    local at = Track(key, g, now)
    if at and (not due or at < due) then
      due = at
    end
  end
  local last = LastMove()
  if last and now - last >= RELEASE_AFTER then
    LB.LeaveGroup("guests moved")
    wipe(Host.guests)
  elseif last then
    due = math.min(due or math.huge, last + RELEASE_AFTER)
  end
  WakeHost(due)
  LB.Refresh()
end

function Host.Invite(name, netId)
  local ok, why = Check(name)
  if not ok then
    LB.Log("host-skip", netId, name, why)
    return false
  end
  if GroupFull() then
    LB.LeaveGroup("group full")
    wipe(Host.guests)
  end
  local invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or rawget(_G, "InviteUnit")
  local sent, err = pcall(invite, name)
  if not sent then
    LB.Log("invite-error", name, err)
    return false
  end
  local now, key = GetTime(), LB.Key(name)
  LB.Gate("invite", key, 0)
  RecordInvite(now)
  local g = { name = name, net = netId, invitedAt = now, flying = UnitOnTaxi("player") and true or false }
  Host.guests[key] = g
  Stats.Note(TallyKey(g, "invited"))
  LB.Log("invite", netId, name)
  Host.Check()
  return true
end

function Host.Pending()
  for _, g in pairs(Host.guests) do
    if not g.movedAt then
      return true
    end
  end
  return false
end

function Host.View(v)
  for _, g in pairs(Host.guests) do
    if not g.movedAt then
      v.status, v.tone, v.border = "Inviting " .. g.name, "host", "host"
      return
    end
  end
  local why = Blocked()
  if why == "off" then
    v.status, v.tone = "Host off", "off"
  elseif why then
    v.status, v.tone = "Hosting paused (" .. why .. ")", "warn"
  else
    v.status, v.tone = "Hosting", "host"
  end
end

local function OnGroupLeft()
  for key, g in pairs(Host.guests) do
    if g.joinedAt then
      Host.guests[key] = nil
    end
  end
  Host.Check()
end

-------------------------------------------------------------------------------
-- What the box shows
-------------------------------------------------------------------------------

local REFRESH_NOTICE = { text = "", tone = "warn", button = { text = "Refresh now", onClick = ConfirmRefresh } }

local function IdleView(v, now)
  if now < flash.untilAt then
    v.status, v.tone, v.border, v.notice = flash.text, "fail", "fail", flash.notice
    return LB.WakeIn(flash.untilAt - now)
  end
  local left = Limit.Left()
  if left then
    local text, nextIn = LB.Countdown(left)
    v.status, v.tone = "Swaps reset in " .. text, "warn"
    return LB.WakeIn(nextIn)
  end
  if refreshAt and refreshAt > now then
    local remaining = refreshAt - now
    v.status, v.tone, v.border, v.notice = "World refresh in " .. Clock(remaining), "warn", "fail", REFRESH_NOTICE
    return LB.WakeIn((remaining + 0.5) % 1 + 0.01)
  end
  refreshAt = nil
  Host.View(v)
end

function LB.View()
  local v = { label = LB.Label(), host = F.db.host and true or false, status = nil, tone = "idle",
    border = "neutral", notice = nil, swapText = "Swap", swapEnabled = true }
  if F._conflict then
    v.status, v.tone, v.swapEnabled = "Off · " .. tostring(F._conflict) .. " loaded", "off", false
  elseif not Swap.View(v) then
    IdleView(v, GetTime())
  end
  return v
end

-------------------------------------------------------------------------------
-- Start / stop
-------------------------------------------------------------------------------

function Swap.Init()
  cur, lastAsk, lateUntil, abandonedAt, systemText, systemAt = nil, nil, 0, nil, nil, nil
  refreshAt, flash.untilAt = nil, 0
  wipe(Host.guests)
  Stats.Load(false)
  LB.On("PARTY_INVITE_REQUEST", OnInvite)
  LB.On("GROUP_JOINED", OnJoined)
  LB.On("GROUP_ROSTER_UPDATE", OnRoster)
  LB.On("PARTY_LEADER_CHANGED", LB.PartyChanged)
  LB.On("GROUP_LEFT", function()
    OnLeft()
    OnGroupLeft()
  end)
  LB.On("CHAT_MSG_SYSTEM", OnSystem)
  LB.On("ZONE_CHANGED_NEW_AREA", ZoneChanged)
  LB.On("ZONE_CHANGED", LB.MapsChanged)
  LB.On("ZONE_CHANGED_INDOORS", LB.MapsChanged)
  LB.On("PLAYER_ENTERING_WORLD", function(_, isLogin)
    if Plain(isLogin) then
      Stats.Load(true)
    end
    ZoneChanged()
  end)
  LB.On("SHARD_TRANSFER_IMMINENT", OnTransferImminent)
  LB.On("SHARD_TRANSFER_CANCELLED", OnTransferCancelled)
  LB.On("SHARD_TRANSFER", OnTransfer)
  LB.On("UNIT_PHASE", function()
    if next(Host.guests) then
      Host.Check()
    end
  end)
  LB.On("PLAYER_CONTROL_LOST", LB.Refresh)
  LB.On("PLAYER_CONTROL_GAINED", function()
    LB.Refresh()
    -- (the taxi flag clears a moment after control comes back)
    LB.After(1, LB.Refresh)
    LB.After(3, LB.Refresh)
  end)
  if not History.Current() then
    History.Note(nil)
  end
end

-- The feature goes off mid-swap: put the group back as it was.
function Swap.Shutdown()
  local a = cur
  if a then
    if a.phase == "invited" then
      Decline(a.host, "stopped")
    elseif (a.phase == "joined" or a.phase == "moved") and IsInGroup() then
      LB.LeaveGroup("feature off")
    end
    a.active, cur = false, nil
  end
  LB.ClearPrefill()
end
