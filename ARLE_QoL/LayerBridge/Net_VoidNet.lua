-- Layer Bridge network: VoidNet (the Void* addons' shared layer network; no
-- license we could reuse code under, so only its message format is spoken).
--
-- Members meet in a private channel that changes every hour: its name and
-- password come from the hour, the faction and a slot (0-3; members move to
-- the next slot when a channel refuses them, or when two of them vote "M").
-- The channel's roster is who to ask. All talk is hidden addon whispers:
--   Q:1:<ttl>:<zone>:<nonce>:<asker>  who hosts in <zone>? (ttl 1 = relay once)
--   A:1:<zone>:<pair>:<0|1>           an answer: my layer pair, hosting or not
--   HR:1:<zone>:<pair>:<nonce>        invite me to your layer <pair>
--   HA:1:<nonce>:ok | HA:1:<nonce>:no:<why>, HP:1:<nonce>:<pair>
--   (prefix VOIDNET) O:<n> -> "o" a ping; M:<slot>:<hour> a slot vote
-- A pair is "<token>-0", our random number for the layer (see Core.lua).
local _, ns = ...
local LB = ns.LayerBridge
if not LB then
  return
end
local ARLE = _G.ARLExtensions
local F = LB.F
local Lib = ARLE.Lib
local Plain, Str = Lib.Plain, Lib.Str

local VL, VN = "VLAYER", "VOIDNET"
local ALPHA, MOD = "bcdfghjkmnpqrstvwxz23456789", 2147483629
local TAG, SALT, SLOTS, NAME_LEN, PW_LEN = "Vn", 52817, 3, 6, 8
local CODE_PRIME, SALT_PRIME, PW_PRIME, HASH_MUL = 7919, 97, 104729, 31
local HORDE, ALLIANCE, NEUTRAL, HOUR = 1, 2, 3, 3600
local JITTER_MIN, JITTER_MAX, JOIN_DEBOUNCE, REJOIN_AFTER, REJOIN_TRIES = 20, 40, 10, 10, 3
local ROSTER_FRESH, ROSTER_MAX, ROSTER_WAIT, ROSTER_SETTLE = 300, 300, 8, 2
local FANOUT, RELAY, WAVES, WAVE_GAP, KNOWN_FIRST, RELAY_QUEUE_MAX = 10, 4, 3, 8, 3, 20
local HR_WAIT, OK_WAIT, A_WINDOW, ANSWER_GAP, Q_GAP = 12, 30, 60, 60, 60
local CENSUS_HOST, CENSUS_KEEP, HEARD_KEEP, REACH, PING_GAP = 300, 600, 7200, 3600, 10
local IN_MAX, IN_WINDOW, QUEUE_MAX, BURST, REFILL = 20, 60, 60, 8, 1.1
local Q_TTL, RELAY_TTL, A_TTL, H_TTL = 15, 6, 6, 10
local NAME_MAX, PAIR_MAX, TEXT_MAX, VOTES_NEEDED = 48, 20, 255, 2
local NONCE_MIN, NONCE_MAX = 100000, 999999
local REFUSALS = { WRONG_PASSWORD = true, BANNED = true, password = true }
local HR_REPLY = { off = "off", zone = "layer" }

local NET = {
  id = "voidnet", name = "VoidNet", key = "voidnet", prefixes = { VL, VN },
  addons = { "VoidLayer", "VoidSweep", "VoidQuest", "VoidGather", "VoidBounty", "VoidDungeon" },
  desc = "Joins VoidNet's hourly private channel (out of your chat windows) and asks its members out of sight; "
    .. "with Host on, answers their asks.",
}

local db, book
local faction, chan
local started, waiting, joinTries = false, false, 0
local roster = { names = {}, ks = {}, keys = {}, at = 0 }
local reading
local heard, census, seenQ, inbound, votes = {}, {}, {}, {}, {}
local asking
local queue, tokens, filled, pumping, held = {}, BURST, 0, false, false
local Join, Refused, Check, ScheduleHour

local function Now()
  return GetTime()
end

local function Nonce()
  return tostring(math.random(NONCE_MIN, NONCE_MAX))
end

local function ValidName(n)
  return type(n) == "string" and #n >= 1 and #n <= NAME_MAX and not n:find("[|:]")
end

local function Shuffle(t)
  for i = #t, 2, -1 do
    local j = math.random(1, i)
    t[i], t[j] = t[j], t[i]
  end
  return t
end

-------------------------------------------------------------------------------
-- The hour's channel: name and password
-------------------------------------------------------------------------------

local function Mix(h, n)
  return (h * HASH_MUL + n) % MOD
end

local function Code(seed, len)
  local h, out = seed, {}
  for i = 1, len do
    h = Mix(Mix(h, i), CODE_PRIME)
    local c = h % #ALPHA + 1
    out[i] = ALPHA:sub(c, c)
  end
  return table.concat(out)
end

local function Derive(slot, hour, side)
  local salt = SALT + slot
  local seed = Mix(Mix(Mix(salt, hour), salt % SALT_PRIME), side)
  return TAG .. Code(seed, NAME_LEN), Code(Mix(seed, PW_PRIME), PW_LEN)
end

local function HourNow()
  return math.floor(GetServerTime() / HOUR)
end

local function Side()
  if not faction then
    local f = Plain(UnitFactionGroup("player"))
    faction = (f == "Horde" and HORDE) or (f == "Alliance" and ALLIANCE) or nil
  end
  return faction or NEUTRAL
end

local function Pair()
  return LB.Token(NET.id) .. "-0"
end

local function Canon(p)
  return p and p:match("^(%d+)%-%d+$")
end

local function Locked()
  return InCombatLockdown() or LB.ChatLocked()
end

-------------------------------------------------------------------------------
-- Sending: a small queue (8 at once, then one per 1.1 s; urgent ones first)
-------------------------------------------------------------------------------

local Pump

local function Refill()
  pumping = false
  Pump()
end

Pump = function()
  if held then
    return
  end
  local t = Now()
  tokens = math.min(BURST, tokens + (t - filled) / REFILL)
  filled = t
  local lockdown = LB.RESULT.AddOnMessageLockdown
  while tokens >= 1 and queue[1] do
    local m = table.remove(queue, 1)
    if not m.exp or m.exp > t then
      local result = LB.SendAddon(m.prefix, m.text, "WHISPER", m.to)
      if result == LB.THROTTLED or (lockdown and result == lockdown) then
        table.insert(queue, 1, m)
        held = lockdown ~= nil and result == lockdown
        tokens = 0
        break
      end
      tokens = tokens - 1
    end
  end
  if queue[1] and not pumping and not held then
    pumping = true
    LB.After(REFILL, Refill)
  end
end

local function Send(prefix, text, to, urgent, life)
  if not to then
    return
  end
  if held and not Locked() then
    held = false
  end
  if #queue >= QUEUE_MAX then
    if not urgent then
      return
    end
    table.remove(queue)
  end
  local m = { prefix = prefix, text = text, to = to, urgent = urgent, exp = life and (Now() + life) or nil }
  if urgent then
    local i = 1
    while queue[i] and queue[i].urgent do
      i = i + 1
    end
    table.insert(queue, i, m)
  else
    queue[#queue + 1] = m
  end
  Pump()
end

-------------------------------------------------------------------------------
-- Who to ask: hosts we know, members we've heard, then the roster
-------------------------------------------------------------------------------

local function Reachable(k, t)
  if LB.Offline(k) then
    return false
  end
  local h = heard[k]
  return roster.keys[k] ~= nil or (h ~= nil and t - h.t < REACH)
end

local function Pick(n, exclude)
  local t, me = Now(), LB.MyKey()
  local used, hosts, known, strangers = {}, {}, {}, {}
  local function Usable(k)
    if not k or k == me or used[k] or exclude[k] then
      return false
    end
    if not LB.Gate("voidnet ask", k, Q_GAP, true) or not Reachable(k, t) then
      return false
    end
    used[k] = true
    return true
  end
  for k, e in pairs(book.entries) do
    if Usable(k) then
      hosts[#hosts + 1] = roster.keys[k] or e.name
    end
  end
  for k, h in pairs(heard) do
    if Usable(k) then
      known[#known + 1] = h.name
    end
  end
  for i, name in ipairs(roster.names) do
    if Usable(roster.ks[i]) then
      strangers[#strangers + 1] = name
    end
  end
  Shuffle(hosts)
  Shuffle(known)
  Shuffle(strangers)
  for _, name in ipairs(known) do
    hosts[#hosts + 1] = name
  end
  -- a few strangers in every wave, so new hosts get found too
  local out = {}
  local room = n - math.min(KNOWN_FIRST, #strangers)
  for i = 1, math.min(room, #hosts) do
    out[#out + 1] = hosts[i]
  end
  for i = 1, #strangers do
    if #out >= n then
      break
    end
    out[#out + 1] = strangers[i]
  end
  for i = room + 1, #hosts do
    if #out >= n then
      break
    end
    out[#out + 1] = hosts[i]
  end
  return out
end

local function PickRandom(n, exclude)
  local out, used, me, list = {}, {}, LB.MyKey(), roster.names
  if #list == 0 then
    return out
  end
  for _ = 1, n * 3 do
    if #out >= n then
      break
    end
    local i = math.random(1, #list)
    local k = roster.ks[i]
    if k and k ~= me and not used[k] and not exclude[k] then
      used[k] = true
      out[#out + 1] = list[i]
    end
  end
  return out
end

-------------------------------------------------------------------------------
-- The channel's roster (the game lists it for the selected channel)
-------------------------------------------------------------------------------

local function ChannelFrameOpen()
  local f = rawget(_G, "ChannelFrame")
  return type(f) == "table" and f.IsShown and f:IsShown()
end

local function DisplayIndex(name)
  local n = Plain(GetNumDisplayChannels and GetNumDisplayChannels()) or 0
  for i = 1, n do
    local cname, header, _, _, count, active = GetChannelDisplayInfo(i)
    if not Plain(header) and Plain(cname) == name then
      return i, Plain(count), Plain(active)
    end
  end
end

local function SelectedIndex()
  local i = type(GetSelectedDisplayChannel) == "function" and (Lib.Call(GetSelectedDisplayChannel)) or nil
  return i
end

local function ReadNow(idx, count)
  count = tonumber(count) or 0
  local list, ks, keys, owner = {}, {}, {}, nil
  local first = count > ROSTER_MAX and math.random(1, count) or 1
  for j = 0, math.min(count, ROSTER_MAX) - 1 do
    local ok, name, isOwner = pcall(C_ChatInfo.GetChannelRosterInfo, idx, (first + j - 1) % count + 1)
    name = ok and Str(Plain(name)) or nil
    local k = LB.Key(name)
    if k and not keys[k] then
      keys[k] = name
      list[#list + 1] = name
      ks[#ks + 1] = k
      if Plain(isOwner) then
        owner = name
      end
    end
  end
  if #list == 0 then
    return false
  end
  roster.names, roster.ks, roster.keys, roster.owner, roster.at = list, ks, keys, owner, Now()
  return true
end

local function FinishRead(ok)
  local r = reading
  if not r then
    return
  end
  reading = nil
  if r.prev and r.prev ~= r.idx and not ChannelFrameOpen() and type(SetSelectedDisplayChannel) == "function" then
    pcall(SetSelectedDisplayChannel, r.prev)
  end
  for _, cb in ipairs(r.callbacks) do
    ARLE.Debug.Call(F, cb, ok)
  end
end

local function OnRoster(_, idx, count)
  local r = reading
  idx, count = Plain(idx), Plain(count)
  if r and idx == r.idx and ReadNow(idx, count) then
    FinishRead(true)
  end
end

local function ReadRoster(cb)
  cb = cb or function() end
  if reading then
    reading.callbacks[#reading.callbacks + 1] = cb
    return
  end
  if not chan or ChannelFrameOpen() or type(SetSelectedDisplayChannel) ~= "function" then
    return cb(false)
  end
  local idx, _, active = DisplayIndex(chan.name)
  if not idx then
    if joinTries < REJOIN_TRIES and not LB.ChannelId(chan.name) then
      LB.After(REJOIN_AFTER, Join)
    end
    return cb(false)
  end
  if active == false then
    Refused(chan.name, "disabled")
    return cb(false)
  end
  local r = { idx = idx, prev = SelectedIndex(), callbacks = { cb } }
  reading = r
  pcall(SetSelectedDisplayChannel, idx)
  if r.prev == idx and ReadNow(idx, select(5, GetChannelDisplayInfo(idx))) then
    return FinishRead(true)
  end
  LB.After(ROSTER_WAIT, function()
    if reading == r then
      FinishRead(ReadNow(r.idx, Plain(select(5, GetChannelDisplayInfo(r.idx)))))
    end
  end)
end

-------------------------------------------------------------------------------
-- Joining the hour's channel
-------------------------------------------------------------------------------

local function SlotFor(hour)
  local slot = db.slots[Side()]
  return type(slot) == "table" and slot.hour == hour and tonumber(slot.slot) or 0
end

local function OnJoined(name, id, why)
  if not chan or chan.name ~= name then
    return
  end
  if not id and REFUSALS[why] then
    return Refused(name, why)
  end
  if id then
    LB.After(ROSTER_SETTLE, ReadRoster)
  end
end

Join = function()
  if not started or not LB.NetOn(NET) then
    return
  end
  if Locked() then
    waiting = true
    return
  end
  waiting = false
  local hour = HourNow()
  local slot = SlotFor(hour)
  local name, pw = Derive(slot, hour, Side())
  if chan and chan.name == name and Now() - chan.at < JOIN_DEBOUNCE then
    return
  end
  chan = { name = name, hour = hour, slot = slot, at = Now() }
  LB.LeaveChannels(NET.id, { [name] = true })
  if not LB.ChannelId(name) then
    joinTries = joinTries + 1
  end
  LB.JoinChannel(NET.id, name, pw, OnJoined)
end

local function MoveToSlot(hour, slot, why)
  LB.Log("voidnet-slot", slot, why)
  db.slots[Side()] = { hour = hour, slot = slot }
  chan.at = 0
  Join()
end

Refused = function(name, why)
  if not chan or name ~= chan.name or chan.slot >= SLOTS then
    return
  end
  MoveToSlot(chan.hour, chan.slot + 1, why)
end

local function Sweep(t)
  wipe(seenQ)
  wipe(inbound)
  wipe(votes)
  for k, c in pairs(census) do
    if t - c.t > CENSUS_KEEP then
      census[k] = nil
    end
  end
  for k, h in pairs(heard) do
    if t - h.t > HEARD_KEEP then
      heard[k] = nil
    end
  end
end

local function OnHour()
  if not (chan and HourNow() == chan.hour) then
    Sweep(Now())
    joinTries = 0
    Join()
  end
  ScheduleHour()
end

ScheduleHour = function()
  LB.After(HOUR - GetServerTime() % HOUR + math.random(JITTER_MIN, JITTER_MAX), OnHour)
end

local function Unlocked()
  if held then
    held = false
    Pump()
  end
  if waiting then
    Join()
  end
end

-------------------------------------------------------------------------------
-- Asking
-------------------------------------------------------------------------------

local function Enqueue(a, k)
  if a.tried[k] or a.queued[k] then
    return
  end
  a.queued[k] = true
  a.queue[#a.queue + 1] = k
end

local function FreshHost(a, k, t)
  local c = census[k]
  return not a.tried[k] and c ~= nil and c.zone == a.zone and t - c.t <= CENSUS_HOST
end

-- One host at a time: ask it for its layer, wait for its answer and invite.
local function TryNext()
  local a = asking
  if not a or not a.ask.active or a.cur or IsInGroup() then
    return
  end
  local t = Now()
  while a.queue[1] do
    local k = table.remove(a.queue, 1)
    if FreshHost(a, k, t) then
      local c = census[k]
      local try = { k = k, name = c.name, nonce = Nonce(), at = t }
      a.tried[k], a.cur, a.nonces[try.nonce] = true, try, k
      a.ask.Asked(c.name)
      LB.Step("VoidNet: asking %s to invite (layer %s)", c.name, c.pair)
      Send(VL, ("HR:1:%d:%s:%s"):format(a.zone, c.pair, try.nonce), c.name, true, HR_WAIT)
      LB.After(HR_WAIT, Check, a, try)
      return
    end
  end
end

Check = function(a, try)
  if asking ~= a or a.cur ~= try or not a.ask.active then
    return
  end
  if IsInGroup() then
    try.grouped = true
    return
  end
  if try.ok and not try.grouped and Now() - try.at < OK_WAIT then
    LB.After(try.at + OK_WAIT - Now(), Check, a, try)
    return
  end
  a.cur = nil
  if not try.ok then
    census[try.k] = nil
  end
  TryNext()
end

local function Wave(a, first)
  if asking ~= a or not a.ask.active or a.waves >= WAVES then
    return
  end
  if not first and a.ask.found > 0 then
    return
  end
  local me = LB.Me()
  if not ValidName(me) then
    return
  end
  local targets = Pick(FANOUT, a.asked)
  if #targets == 0 then
    return
  end
  a.waves, a.lastQ = a.waves + 1, Now()
  local text = ("Q:1:1:%d:%s:%s"):format(a.zone, a.nonce, me)
  for _, name in ipairs(targets) do
    local k = LB.Key(name)
    if k then
      a.asked[k] = true
      LB.Gate("voidnet ask", k, 0)
      a.ask.Asked(name)
      Send(VL, text, name, false, Q_TTL)
    end
  end
  a.sent = a.sent + #targets
  a.ask.Progress(NET.id, a.sent, a.sent, false)
  LB.Step("VoidNet: wave %d asked %d members (roster %d)", a.waves, #targets, #roster.names)
end

function NET.Ask(_, ask)
  local zone = tonumber(ask.zone)
  if not zone or ask.want then
    return
  end
  local a = { ask = ask, zone = zone, nonce = Nonce(), waves = 0, sent = 0, queue = {}, queued = {}, tried = {},
    nonces = {}, asked = {} }
  asking = a
  local t = Now()
  for k, c in pairs(census) do
    if c.zone == zone and t - c.t <= CENSUS_HOST then
      Enqueue(a, k)
    end
  end
  TryNext()
  Wave(a, true)
  if t - roster.at > ROSTER_FRESH then
    ReadRoster(function()
      Wave(a)
    end)
  end
  LB.After(WAVE_GAP, Wave, a)
end

function NET.StopAsk(_, ask)
  if asking and asking.ask == ask then
    asking = nil
  end
end

function NET.OnSwapResult(_, _, result, host)
  local k = LB.Key(host)
  if k and (result == "moved" or result == "same") then
    census[k] = nil
  end
end

function NET.OnHostFailed(_, ask, why, host)
  local k = LB.Key(host)
  if k and why == "same" then
    census[k] = nil
  end
  local a = asking
  if a and a.ask == ask and a.cur and a.cur.k == k then
    a.cur = nil
    TryNext()
  end
end

-------------------------------------------------------------------------------
-- Messages
-------------------------------------------------------------------------------

local function Relay(zone, nonce, asker, exclude)
  local text = ("Q:1:0:%d:%s:%s"):format(zone, nonce, asker)
  for _, name in ipairs(PickRandom(RELAY, exclude)) do
    Send(VL, text, name, false, RELAY_TTL)
  end
end

local function OnQ(text, sender, k)
  local ttl, zone, nonce, asker = text:match("^Q:1:(%d+):(%d+):(%d+):(.+)$")
  ttl, zone = tonumber(ttl), tonumber(zone)
  if not ttl or ttl > 1 or not ValidName(asker) then
    return
  end
  local ak = LB.Key(asker)
  if not ak or ak == LB.MyKey() then
    return
  end
  if ttl == 1 and ak ~= k then
    return
  end
  if ttl == 0 and not (roster.keys[ak] or heard[ak]) then
    return
  end
  if seenQ[nonce] == ak then
    return
  end
  seenQ[nonce] = ak
  if ttl == 1 and #queue < RELAY_QUEUE_MAX then
    Relay(zone, nonce, asker, { [k] = true, [ak] = true })
  end
  if LB.InInstance() or zone ~= LB.Zone() then
    return
  end
  if not LB.Gate("voidnet answer", ak, ANSWER_GAP) then
    return
  end
  Send(VL, ("A:1:%d:%s:%d"):format(zone, Pair(), LB.Host.Can(asker, zone) and 1 or 0), asker, true, A_TTL)
end

local function OnA(text, sender, k)
  local zone, p, h = text:match("^A:1:(%d+):(%d+%-%d+):([01])$")
  zone = tonumber(zone)
  local a = asking
  if not zone or #p > PAIR_MAX or h ~= "1" or not a or not a.ask.active then
    return
  end
  if zone ~= a.zone or not a.lastQ or Now() - a.lastQ > A_WINDOW then
    return
  end
  census[k] = { name = sender, zone = zone, pair = p, t = Now() }
  book:Remember(sender, { host = true, zone = zone })
  LB.Step("VoidNet: %s hosts here", sender)
  Enqueue(a, k)
  TryNext()
end

local function HostReply(sender, zone, p)
  local ok, why = LB.Host.Can(sender, zone)
  if not ok then
    return HR_REPLY[why] or "busy"
  end
  if Canon(p) ~= Canon(Pair()) then
    return "layer"
  end
  if not LB.Host.Invite(sender, NET.id) then
    return "busy"
  end
end

local function OnHR(text, sender)
  local zone, p, nonce = text:match("^HR:1:(%d+):(%d+%-%d+):(%d+)$")
  zone = tonumber(zone)
  if not zone or #p > PAIR_MAX then
    return
  end
  local no = HostReply(sender, zone, p)
  if no then
    return Send(VL, ("HA:1:%s:no:%s"):format(nonce, no), sender, true, H_TTL)
  end
  Send(VL, ("HA:1:%s:ok"):format(nonce), sender, true, H_TTL)
  Send(VL, ("HP:1:%s:%s"):format(nonce, Pair()), sender, true, H_TTL)
end

local function OnHA(text, sender, k)
  local nonce, rest = text:match("^HA:1:(%d+):(.+)$")
  local a = asking
  if not nonce or not a or a.nonces[nonce] ~= k then
    return
  end
  local try = a.cur and a.cur.nonce == nonce and a.cur or nil
  if rest == "ok" then
    a.ask.Offer(sender, NET.id)
    book:Remember(sender, { host = true, zone = a.zone })
    if try then
      try.ok = true
    end
  elseif rest:sub(1, 2) == "no" then
    LB.Step("VoidNet: %s won't (%s)", sender, rest)
    a.ask.Refuse(sender)
    census[k] = nil
    if try then
      a.cur = nil
      TryNext()
    end
  end
end

local HANDLERS = { Q = OnQ, A = OnA, HR = OnHR, HA = OnHA }

local function OnSlotVote(text, k, wasHeard)
  local slot, hour = text:match("^M:(%d+):(%d+)$")
  slot, hour = tonumber(slot), tonumber(hour)
  if not slot or not chan or hour ~= chan.hour or slot <= chan.slot or slot > SLOTS then
    return
  end
  if not wasHeard or not roster.keys[k] then
    return
  end
  local v = votes[slot]
  if not v or v.hour ~= hour then
    v = { hour = hour, n = 0, by = {} }
    votes[slot] = v
  end
  if v.by[k] then
    return
  end
  v.by[k], v.n = true, v.n + 1
  if v.n >= VOTES_NEEDED then
    MoveToSlot(hour, slot, "votes")
  end
end

local function OnGuard(text, sender, k, wasHeard)
  if not text:find("^O:%d+$") then
    return OnSlotVote(text, k, wasHeard)
  end
  if LB.Gate("voidnet ping", k, PING_GAP) then
    Send(VN, "o", sender, true)
  end
end

local function OverLimit(k, t)
  local r = inbound[k] or {}
  inbound[k] = r
  if not r.t or t - r.t > IN_WINDOW then
    r.t, r.n = t, 0
  end
  r.n = r.n + 1
  return r.n > IN_MAX
end

local function NoteHeard(k, sender, t)
  local h = heard[k]
  if h then
    h.name, h.t = sender, t
    return true
  end
  heard[k] = { name = sender, t = t }
  return false
end

function NET.OnAddon(_, prefix, text, chatType, sender, k)
  if chatType ~= "WHISPER" or type(text) ~= "string" or #text > TEXT_MAX then
    return
  end
  local t = Now()
  local wasHeard = NoteHeard(k, sender, t)
  if prefix == VN then
    return OnGuard(text, sender, k, wasHeard)
  end
  if OverLimit(k, t) then
    return
  end
  local handler = HANDLERS[text:match("^(%u%u?):1:")]
  if handler then
    handler(text, sender, k)
  end
end

function NET.Init()
  F.char.voidnet = type(F.char.voidnet) == "table" and F.char.voidnet or {}
  db = F.char.voidnet
  db.slots = type(db.slots) == "table" and db.slots or {}
  book = LB.Book(NET.id)
  started, waiting, joinTries, chan, reading, asking = false, false, 0, nil, nil, nil
  wipe(queue)
  tokens, filled, pumping, held = BURST, 0, false, false
  for _, e in ipairs({ "PLAYER_REGEN_ENABLED", "ZONE_CHANGED_NEW_AREA", "ENCOUNTER_END",
    "ADDON_RESTRICTION_STATE_CHANGED" }) do
    LB.On(e, Unlocked)
  end
  LB.On("CHANNEL_ROSTER_UPDATE", OnRoster)
  LB.On("GROUP_LEFT", function()
    local a = asking
    if a then
      if a.cur then
        Check(a, a.cur)
      else
        TryNext()
      end
    end
  end)
end

function NET.Seen()
  local n = #roster.names
  if roster.keys[LB.MyKey()] then
    n = n - 1
  end
  return n
end

function NET.OnChannels()
  started = true
  Join()
  ScheduleHour()
end

function NET.Stop()
  LB.LeaveChannels(NET.id)
  chan, started = nil, false
end

function NET.Sync()
  if LB.NetOn(NET) then
    if not started then
      NET.OnChannels()
    end
  elseif chan then
    NET.Stop()
  end
end

LB.RegisterNetwork(NET)
