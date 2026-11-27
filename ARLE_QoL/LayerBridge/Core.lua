-- Layer Bridge: one Swap button for every layer-swapping network on Forever,
-- and hosting for all of them.
--
-- Design (0.14.0 overhaul, modelled on how Layer Anarchy by srhinos works;
-- Layer Anarchy is GPL-3, so none of its code is in here: this is our own
-- code, speaking the networks' public message formats):
--  * Networks are plug-ins (LayerBridge/Net_*.lua, each calls
--    LB.RegisterNetwork). One press asks every network that's switched on at
--    once; the first host on another layer to invite wins. Today:
--      LayerSwap (Adam5288)      hidden addon whispers after a /who of the zone
--      AutoLayer (raizo)         chat lines in its "layer" channels
--      VoidNet (Void* addons)    hidden whispers, an hourly private channel
--      Forever Layer Hop         hidden whispers and guild hellos
--    None of those addons has a license we could reuse code under, so only
--    their message formats are spoken. A network whose own addon is loaded
--    is left to that addon (it answers its users itself).
--  * The layer isn't read from creature GUIDs any more (since 2026-11-21
--    creatures standing together show different GUID parts on Forever).
--    Instead a move is seen: SHARD_TRANSFER (not a zone border crossing), a
--    group leader's UnitPhaseReason, and the invite's isCrossShard flag. Each
--    move starts a new "epoch", shown as "Layer A".."Layer Z"; networks that
--    need a layer id make a random token per epoch, and LayerSwap adopts the
--    host's id after a move through them.
--  * The swap is one state machine (LayerBridge/Swap.lua): asking -> invited
--    -> joining -> joined -> moved -> left, with retries until the deadline,
--    same-layer invites declined, and the game's hourly limit learned from
--    its own refusals.
--  * Hosting is one gate for every network (Host.Can / Host.Invite), so the
--    invite limits, "only my own group" and the guest bookkeeping are shared.
-- Never touches any of those addons' tables or frames. InviteUnit,
-- AcceptGroup, LeaveParty, SendWho and channel joins are the calls they make.
local ADDON, ns = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local Lib = ARLE.Lib

local HOUR, DAY = 3600, 86400
local MAP_CLIMB = 10
local NOT_FOUND_FOR, OFFLINE_FOR = 30, 1800 -- s: our whisper's "No player named" echo; offline kept
local GATE_MAX, GATE_AGE = 256, 120
local BOOK_DAYS, BOOK_MAX = 7, 300
local JOIN_TIMEOUT, LOW_SLOTS, RELOCATE_AFTER = 10, 5, 30 -- s; channel numbers 1-5 are the player's own
local LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
local TOKEN_MIN, TOKEN_MAX = 100000, 999999
local LOG_MAX, STEPS_MAX = 60, 80
local SECONDS_SHOWN, COUNTDOWN_MINUTES = 60, { 5, 10, 15, 30, 45 }

local F = {
  id = "LayerBridge",
  addon = ADDON,
  title = "Layer Bridge",
  group = "QualityOfLife",
  command = "layer",
  commandHelp = "swap layers through every layer network (LayerSwap, AutoLayer, VoidNet, Layer Hop)",
  description = "One Swap button for every layer network on Forever: LayerSwap, AutoLayer, VoidNet and Forever "
    .. "Layer Hop users can move you, with or without those addons installed. Turn on Host to move them too.",
  options = {
    { type = "info", text = function(def) return def:GetStatus() end },
    { type = "header", label = "Swapping" },
    { key = "auto", type = "boolean", label = "Accept and leave automatically", default = true, cmd = "auto",
      desc = "Accept a host's invite by itself, and leave the group a few seconds after the move." },
    { key = "askAutoLayer", type = "boolean", label = "Ask AutoLayer hosts too", default = true, cmd = "askal",
      desc = "When no other host answers within a few seconds, put \"inv layer\" in your chat box for the "
        .. "AutoLayer channel: press Enter to send it (the game doesn't let addons say it for you)." },
    { key = "avoidVisited", type = "boolean", label = "Don't go back to layers I've been on", default = true,
      cmd = "avoid",
      desc = "LayerSwap asks also name the layers you've been on in the last 6 hours (when ARL knows their "
        .. "id), so only hosts on a new layer invite. Click a layer in History to go back to it." },
    { key = "sound", type = "boolean", label = "Sound when moved", default = false, cmd = "sound" },
    { key = "forceTriple", type = "boolean", label = "Triple-click Swap to try anyway while swaps are on cooldown",
      default = true, cmd = "force",
      desc = "While the box says \"Swaps reset in ...\", three quick clicks on Swap (or on the small pill) ask "
        .. "anyway. The wait is ARL's guess of the game's hourly limit: if the move works, ARL learns the limit is "
        .. "shorter; if the game refuses, the wait starts over." },
    { type = "header", label = "Hosting" },
    { key = "host", type = "boolean", label = "Host for others", default = false, cmd = "host",
      desc = "Invite players of every network who ask for another layer, and leave them be once they've moved. "
        .. "Only while you're solo or leading a group of your guests." },
    { key = "hostWhileFlying", type = "boolean", label = "Host while flying", default = true, cmd = "flying" },
    { key = "invitesPerHour", type = "range", label = "Invites per hour (0 = no limit)", min = 0, max = 100,
      step = 5, default = 0, cmd = "invites",
      desc = "Players report invite spam; nobody knows the threshold." },
    { type = "header", label = "Box" },
    { key = "button", type = "boolean", label = "Show the Layer Bridge box", default = true, cmd = "box",
      desc = "The layer you're on, what's happening, Host and Swap. Hidden in instances. The Swap key binding "
        .. "(Key Bindings > ARL Extensions) works without it." },
    { key = "locked", type = "boolean", label = "Lock its position", default = false, cmd = "lock" },
    { key = "scale", type = "range", label = "Size (%)", min = 70, max = 150, step = 5, default = 100, cmd = "size" },
    ARLE.Options.Preset.ResetPosition(),
    { type = "button", label = "Swap layer now", nocmd = true,
      run = function() ns.LayerBridge.Swap.Click("panel") end },
    { type = "header", label = "Networks" },
    -- (one switch per network, added by LB.RegisterNetwork)
  },
}
F.replaces = "LayerAnarchy" -- both would answer and accept the same invites

local LB = { F = F, nets = {}, netById = {} }
ns.LayerBridge = LB

local Plain, Str = Lib.Plain, Lib.Str

-------------------------------------------------------------------------------
-- Names (Forever: "First Surname", "-Realm" for another realm)
-------------------------------------------------------------------------------

-- The key every per-player table uses: lower case, realm dropped.
function LB.Key(name)
  name = Str(Plain(name))
  if not name then
    return nil
  end
  local short = name:match("^(.-)%-[^%-%s]+$") or name
  return short:lower()
end

local myKey
function LB.Me()
  return ARLE:MyName()
end

function LB.MyKey()
  myKey = myKey or LB.Key(LB.Me())
  return myKey
end

function LB.IsMe(name)
  local key = LB.Key(name)
  return key ~= nil and key == LB.MyKey()
end

-------------------------------------------------------------------------------
-- Where we are
-------------------------------------------------------------------------------

local ZONE = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
local zoneOf, rawMap, zoneMap = {}, nil, nil

local function Climb(map)
  local id = map
  for _ = 1, MAP_CLIMB do
    local info = id and Lib.Call(C_Map.GetMapInfo, id)
    if type(info) ~= "table" or type(info.mapType) ~= "number" or info.mapType < ZONE then
      return map
    end
    if info.mapType == ZONE then
      return id
    end
    id = info.parentMapID
  end
  return map
end

-- The zone (a uiMapType Zone) a map is in; the map itself when it has none.
function LB.ZoneOf(map)
  map = tonumber(map)
  if not map or map <= 0 then
    return nil
  end
  zoneOf[map] = zoneOf[map] or Climb(map)
  return zoneOf[map]
end

function LB.RawMap()
  if not rawMap then
    rawMap = (Lib.Call(C_Map.GetBestMapForUnit, "player"))
    zoneMap = LB.ZoneOf(rawMap)
  end
  return rawMap
end

function LB.Zone()
  LB.RawMap()
  return zoneMap
end

function LB.ZoneName(map)
  local info = map and Lib.Call(C_Map.GetMapInfo, map)
  return type(info) == "table" and Str(info.name) or nil
end

function LB.MapsChanged()
  rawMap, zoneMap = nil, nil
end

function LB.InInstance()
  return (Lib.Call(IsInInstance)) == true
end

-------------------------------------------------------------------------------
-- Events: F:On keeps one handler per event, so the parts share a bus
-------------------------------------------------------------------------------

local handlers = {}

local function Dispatch(_, event, ...)
  local list = handlers[event]
  if not list then
    return
  end
  for i = 1, #list do
    ARLE.Debug.Call(F, list[i], event, ...)
  end
end

-- fn(event, ...) while the feature is on. Registered from the parts' Init
-- (OnEnable), so a re-enable starts clean.
function LB.On(event, fn)
  local list = handlers[event]
  if not list then
    list = {}
    handlers[event] = list
    F:On(event, Dispatch)
  end
  list[#list + 1] = fn
end

function LB.ResetBus()
  wipe(handlers)
end

-- A timer that can be cancelled; dropped when the feature goes off.
function LB.After(sec, fn, ...)
  local n, args = select("#", ...), { ... }
  local t = { cancelled = false }
  function t.Cancel()
    t.cancelled = true
  end
  F:After(math.max(0, sec or 0), function()
    if not t.cancelled then
      fn(unpack(args, 1, n))
    end
  end)
  return t
end

-------------------------------------------------------------------------------
-- Debugging: a log of decisions and the steps of the swap in progress
-------------------------------------------------------------------------------

LB.log, LB.steps = {}, nil

function LB.Log(what, ...)
  local parts = { date("%H:%M:%S"), tostring(what) }
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    parts[#parts + 1] = Lib.IsSecret(v) and "<secret>" or tostring(v)
  end
  local line = table.concat(parts, " ")
  table.insert(LB.log, 1, line)
  LB.log[LOG_MAX + 1] = nil
  F:Debug("%s", line)
end

-- A step of the current swap (kept for "/arl layer last" and the report).
function LB.Step(fmt, ...)
  local ok, text = pcall(string.format, fmt, ...)
  text = ok and text or tostring(fmt)
  local s = LB.steps
  if s and #s.lines < STEPS_MAX then
    s.lines[#s.lines + 1] = string.format("+%.1fs %s", GetTime() - s.at, text)
  end
  F:Debug("swap: %s", text)
end

-------------------------------------------------------------------------------
-- Addon whispers, and the game's "No player named ..." for ours
-------------------------------------------------------------------------------

local RESULT = Enum and Enum.SendAddonMessageResult or {}
LB.RESULT = RESULT
local THROTTLED = RESULT.AddonMessageThrottle or 3
local OFFLINE_RESULT = RESULT.TargetOffline
local whisperedAt, offlineAt, lastWhisperAt = {}, {}, -math.huge

function LB.SendAddon(prefix, text, chatType, target)
  local ok, result = pcall(C_ChatInfo.SendAddonMessage, prefix, text, chatType, target)
  if not ok then
    LB.Log("send-error", prefix, chatType, result)
    return nil
  end
  result = Plain(result)
  if chatType == "WHISPER" then
    local key = LB.Key(target)
    if key then
      local now = GetTime()
      if now - lastWhisperAt > NOT_FOUND_FOR then
        wipe(whisperedAt)
      end
      whisperedAt[key], lastWhisperAt = now, now
      if OFFLINE_RESULT and result == OFFLINE_RESULT then
        offlineAt[key] = now
      end
    end
  end
  return result
end

LB.THROTTLED = THROTTLED

function LB.Offline(key)
  local at = key and offlineAt[key]
  return at ~= nil and GetTime() - at < OFFLINE_FOR
end

function LB.Heard(key)
  if key then
    offlineAt[key] = nil
  end
end

local notFoundPattern
local function NotFoundName(msg)
  msg = Str(Plain(msg))
  if not msg then
    return nil
  end
  if notFoundPattern == nil then
    local fmt = Str(rawget(_G, "ERR_CHAT_PLAYER_NOT_FOUND_S")) or "No player named '%s' is currently playing."
    notFoundPattern = "^" .. fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)", 1) .. "$"
  end
  return msg:match(notFoundPattern)
end

-- Hides the game's "No player named 'X'" when X is someone our hidden
-- whisper reached a moment ago (the player never typed to them), and notes
-- them offline. A chat message filter is the game's public way to do it.
local function NotFoundFilter(_, _, msg)
  local ok, hide = pcall(function()
    if GetTime() - lastWhisperAt > NOT_FOUND_FOR then
      return false
    end
    local key = LB.Key(NotFoundName(msg))
    local at = key and whisperedAt[key]
    if not at or GetTime() - at > NOT_FOUND_FOR then
      return false
    end
    offlineAt[key] = GetTime()
    return true
  end)
  return ok and hide or false
end

-- Our own channels' join / leave notices, hidden from chat.
local function OurNotice(_, _, _, _, _, _, _, _, _, _, base)
  local ok, hide = pcall(function()
    base = Str(Plain(base))
    return base ~= nil and LB.OwnedChannel(base) ~= nil
  end)
  return ok and hide or false
end

local filters = {}
local function Filter(event, fn, on)
  local util = rawget(_G, "ChatFrameUtil")
  local add = rawget(_G, "ChatFrame_AddMessageEventFilter") or (type(util) == "table" and util.AddMessageEventFilter)
  local remove = rawget(_G, "ChatFrame_RemoveMessageEventFilter")
    or (type(util) == "table" and util.RemoveMessageEventFilter)
  local key = event .. tostring(fn)
  if on and not filters[key] and type(add) == "function" then
    filters[key] = pcall(add, event, fn) and true or nil
  elseif not on and filters[key] and type(remove) == "function" then
    pcall(remove, event, fn)
    filters[key] = nil
  end
end

function LB.Filters(on)
  Filter("CHAT_MSG_SYSTEM", NotFoundFilter, on)
  Filter("CHAT_MSG_CHANNEL_NOTICE", OurNotice, on)
  Filter("CHAT_MSG_CHANNEL_NOTICE_USER", OurNotice, on)
end

function LB.Restricted()
  local f = C_ChatInfo and C_ChatInfo.AreOutgoingAddonChatMessagesRestricted
  return type(f) == "function" and (Lib.Call(f)) == true
end

function LB.ChatLocked()
  local f = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown
  return type(f) == "function" and (Lib.Call(f)) == true
end

-------------------------------------------------------------------------------
-- The chat box: a line the player sends with Enter (addons can't post chat
-- on live Forever). Only an empty chat box is used.
-------------------------------------------------------------------------------

local prefilled = {}

local function ActiveBox()
  local util = rawget(_G, "ChatFrameUtil")
  if type(util) == "table" and type(util.GetActiveWindow) == "function" then
    return (Lib.Call(util.GetActiveWindow))
  end
  local get = rawget(_G, "ChatEdit_GetActiveWindow")
  return type(get) == "function" and (Lib.Call(get)) or nil
end

function LB.Prefill(text, chatType, target)
  local typing = ActiveBox()
  if typing and (typing:GetText() or "") ~= "" then
    return nil
  end
  local util = rawget(_G, "ChatFrameUtil")
  local open = (type(util) == "table" and util.OpenChat) or rawget(_G, "ChatFrame_OpenChat")
  if type(open) ~= "function" or not pcall(open, text, DEFAULT_CHAT_FRAME) then
    return nil
  end
  local box = ActiveBox() or (DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.editBox)
  if not box then
    return nil
  end
  pcall(box.SetAttribute, box, "chatType", chatType)
  if chatType == "CHANNEL" then
    pcall(box.SetAttribute, box, "channelTarget", target)
  elseif chatType == "WHISPER" then
    pcall(box.SetAttribute, box, "tellTarget", target)
  end
  if box.UpdateHeader then
    pcall(box.UpdateHeader, box)
  else
    local upd = rawget(_G, "ChatEdit_UpdateHeader")
    if type(upd) == "function" then
      pcall(upd, box)
    end
  end
  prefilled.box, prefilled.text = box, text
  return "prefilled"
end

-- Takes our line back out of the chat box if the player didn't send it.
function LB.ClearPrefill()
  local box, text = prefilled.box, prefilled.text
  prefilled.box = nil
  if not (box and box:IsShown() and box:GetText() == text) then
    return
  end
  box:SetText("")
  local util = rawget(_G, "ChatFrameUtil")
  local close = (type(util) == "table" and util.DeactivateChat) or rawget(_G, "ChatEdit_DeactivateChat")
  if type(close) == "function" then
    pcall(close, box)
  end
end

-------------------------------------------------------------------------------
-- Channels a network keeps (owner = network id), in char.channels[name]
-------------------------------------------------------------------------------

local joins, relocated = {}, {}
local StartJoin

function LB.ChannelId(name)
  local id = Plain((GetChannelName(name)))
  return type(id) == "number" and id > 0 and id or nil
end

function LB.OwnedChannel(name)
  local owned = F.char and F.char.channels
  return type(owned) == "table" and owned[name] or nil
end

-- Out of every chat window: a network's channel is for its addon messages.
local function HideChannel(name)
  local low = name:lower()
  local max = (Constants and Constants.ChatFrameConstants and Constants.ChatFrameConstants.MaxChatWindows)
    or NUM_CHAT_WINDOWS or 10
  for i = 1, max do
    local frame = rawget(_G, "ChatFrame" .. i)
    local list = frame and frame.channelList
    if type(list) == "table" then
      for _, listed in pairs(list) do
        if type(listed) == "string" and listed:lower() == low then
          local remove = frame.RemoveChannel or rawget(_G, "ChatFrame_RemoveChannel")
          if type(remove) == "function" then
            pcall(remove, frame, name)
          end
          break
        end
      end
    end
  end
end

local function FinishJoin(name, why)
  local job = joins[name]
  if not job then
    return
  end
  joins[name] = nil
  job.timer.Cancel()
  local id = not why and LB.ChannelId(name)
  if not id then
    why = why or "timeout"
    F.char.channels[name] = nil
    LB.Log("channel-failed", name, why)
    return job.onDone(name, nil, why)
  end
  HideChannel(name)
  -- In one of the player's own first slots: give it back and come back later
  -- (the player's /1../5 shouldn't shift because of us).
  if id <= LOW_SLOTS and not relocated[name] then
    relocated[name] = true
    pcall(LeaveChannelByName, name)
    LB.After(RELOCATE_AFTER, StartJoin, job)
    return
  end
  job.onDone(name, id)
end

StartJoin = function(job)
  local name = job.name
  local id = LB.ChannelId(name)
  if id then
    return job.onDone(name, id)
  end
  if joins[name] then
    return
  end
  joins[name] = job
  F.char.channels[name] = job.owner
  job.timer = LB.After(JOIN_TIMEOUT, FinishJoin, name)
  local join = rawget(_G, "JoinTemporaryChannel") or rawget(_G, "JoinChannelByName")
    or rawget(_G, "JoinPermanentChannel")
  local ok, err = pcall(join, name, job.pw)
  if not ok then
    FinishJoin(name, tostring(err))
  end
end

-- onDone(name, id or nil, why)
function LB.JoinChannel(owner, name, pw, onDone)
  StartJoin({ owner = owner, name = name, pw = pw, onDone = onDone or function() end })
end

-- Leaves every channel owner joined, but those in keep ({ [name] = true }).
function LB.LeaveChannels(owner, keep)
  local owned = F.char.channels
  for name, by in pairs(owned) do
    if (owner == nil or by == owner) and not (keep and keep[name]) then
      if LB.ChannelId(name) then
        pcall(LeaveChannelByName, name)
      end
      owned[name] = nil
    end
  end
end

function LB.ChannelNotice(_, kind, _, _, _, _, _, _, _, base)
  kind, base = Plain(kind), Str(Plain(base))
  if not (base and joins[base]) then
    return
  end
  if kind == "YOU_CHANGED" or kind == "YOU_JOINED" then
    FinishJoin(base)
  elseif kind == "WRONG_PASSWORD" or kind == "BANNED" then
    FinishJoin(base, kind)
  end
end

function LB.PasswordRequest(_, name)
  name = Str(Plain(name))
  if not (name and joins[name]) then
    return
  end
  LB.After(0, function()
    if type(StaticPopup_Hide) == "function" then
      pcall(StaticPopup_Hide, "CHAT_CHANNEL_PASSWORD", name)
    end
  end)
  FinishJoin(name, "password")
end

-------------------------------------------------------------------------------
-- Gates: "at most once per gap seconds per key"
-------------------------------------------------------------------------------

local gates, gateCount = {}, 0

-- peek: only says whether it's open, without closing it.
function LB.Gate(kind, key, gap, peek)
  if not key then
    return false
  end
  local byKey = gates[kind] or {}
  gates[kind] = byKey
  local now, last = GetTime(), byKey[key]
  if last and now - last < gap then
    return false
  end
  if peek then
    return true
  end
  byKey[key] = now
  if not last then
    gateCount = gateCount + 1
    if gateCount > GATE_MAX then
      gateCount = 0
      for _, keys in pairs(gates) do
        for k, at in pairs(keys) do
          if now - at > GATE_AGE then
            keys[k] = nil
          else
            gateCount = gateCount + 1
          end
        end
      end
    end
  end
  return true
end

-------------------------------------------------------------------------------
-- Books: the players a network has met, account-wide (shared.books[net])
--   [key] = { name = "First Surname", at = time(), host = true|nil, zone = uiMapID }
-------------------------------------------------------------------------------

local Book = {}
Book.__index = Book

local function PruneBook(entries, now)
  local cutoff, keys = now - BOOK_DAYS * DAY, {}
  for key, e in pairs(entries) do
    if type(e) ~= "table" or type(e.at) ~= "number" or e.at < cutoff or type(e.name) ~= "string" then
      entries[key] = nil
    else
      keys[#keys + 1] = key
    end
  end
  if #keys <= BOOK_MAX then
    return #keys
  end
  table.sort(keys, function(x, y)
    return entries[x].at > entries[y].at
  end)
  for i = BOOK_MAX + 1, #keys do
    entries[keys[i]] = nil
  end
  return BOOK_MAX
end

function LB.Book(netId)
  local books = F.shared.books
  if type(books) ~= "table" then
    books = {}
    F.shared.books = books
  end
  if type(books[netId]) ~= "table" then
    books[netId] = {}
  end
  return setmetatable({ entries = books[netId], size = PruneBook(books[netId], time()) }, Book)
end

function Book:Remember(name, fields)
  local key = LB.Key(name)
  if not key then
    return
  end
  local e = self.entries[key]
  if not e then
    e = {}
    self.entries[key] = e
    self.size = self.size + 1
  end
  e.name, e.at = name, time()
  for field, value in pairs(fields or {}) do
    e[field] = value
  end
  if self.size > BOOK_MAX then
    self.size = PruneBook(self.entries, e.at)
  end
end

function Book:Get(name)
  local key = LB.Key(name)
  return key and self.entries[key] or nil
end

-- The entries keep(e, key) accepts, newest first.
function Book:List(keep)
  local out = {}
  for key, e in pairs(self.entries) do
    if keep(e, key) then
      out[#out + 1] = e
    end
  end
  table.sort(out, function(a, b)
    return a.at > b.at
  end)
  return out
end

-------------------------------------------------------------------------------
-- The group
-------------------------------------------------------------------------------

local party, partyStale, leader = {}, true, nil

local function ScanParty()
  wipe(party)
  leader, partyStale = nil, false
  for i = 1, 4 do
    local unit = "party" .. i
    if UnitExists(unit) then
      local name = ARLE:UnitShortName(unit)
      if not Str(name) then
        partyStale = true
      end
      party[LB.Key(name) or unit] = unit
      if (Lib.Call(UnitIsGroupLeader, unit)) == true then
        leader = unit
      end
    end
  end
end

-- [key] = "partyN"
function LB.Party()
  if partyStale then
    ScanParty()
  end
  return party
end

function LB.UnitFor(key)
  return LB.Party()[key]
end

function LB.LeaderUnit()
  LB.Party()
  return leader
end

function LB.PartyChanged()
  partyStale = true
end

-- nil = same phase (and layer) as us; Enum.PhaseReason.Sharding = another layer.
function LB.PhaseOf(unit)
  if type(UnitPhaseReason) ~= "function" then
    return false
  end
  local ok, phase = pcall(UnitPhaseReason, unit)
  if not ok or Lib.IsSecret(phase) then
    return false
  end
  return phase
end

LB.SHARDING = Enum and Enum.PhaseReason and Enum.PhaseReason.Sharding or 1

function LB.LeaveGroup(why)
  LB.Log("leave", why)
  LB.Step("leaving the group (%s)", tostring(why))
  local leave = (C_PartyInfo and C_PartyInfo.LeaveParty) or rawget(_G, "LeaveParty")
  if type(leave) == "function" then
    pcall(leave)
  end
end

-------------------------------------------------------------------------------
-- Networks
-------------------------------------------------------------------------------

--   net = {
--     id, name,            "layerswap", "LayerSwap"
--     key,                 F.db switch (defaults on); the panel gets a checkbox
--     desc,                the switch's tooltip
--     prefixes = {...},    addon message prefixes it listens on
--     addons = {...},      its own addons: while one is loaded the network is left to it
--     offers = false,      when it never says who hosts (no Hosts column)
--     Init(net), OnAddon(net, prefix, text, chatType, sender, key), Ask(net, ask), More(net, ask),
--     StopAsk(net, ask), Fallback(net, ask), OnSwapResult(net, ask, result, host),
--     OnHostFailed(net, ask, why, host), OnChannels(net), Seen(net), Stop(net)
--   }
function LB.RegisterNetwork(net)
  LB.nets[#LB.nets + 1] = net
  LB.netById[net.id] = net
  net.key = net.key or net.id
  F.options[#F.options + 1] = { key = net.key, type = "boolean", label = net.name, default = true,
    desc = net.desc }
end

function LB.Net(id)
  return LB.netById[id]
end

-- The network's own addon, when it's loaded (it answers its users itself).
function LB.Native(net)
  for _, name in ipairs(net.addons or {}) do
    if ARLE:IsAddonLoaded(name) then
      return name
    end
  end
end

function LB.NetOn(net)
  return F.db and F.db[net.key] ~= false and not LB.Native(net) and net.started == true
end

function LB.CallNet(net, method, ...)
  local fn = net and net[method]
  if type(fn) == "function" then
    local ok, a, b = ARLE.Debug.Call(F, fn, net, ...)
    if ok then
      return a, b
    end
  end
end

-- method on every network that's on; the last non-nil result.
function LB.Each(method, ...)
  local result
  for _, net in ipairs(LB.nets) do
    if LB.NetOn(net) then
      result = LB.CallNet(net, method, ...) or result
    end
  end
  return result
end

-------------------------------------------------------------------------------
-- The layer we're on: an epoch counter, moved on every layer change
-------------------------------------------------------------------------------

local tokens = {}

function LB.Epoch()
  return F.char and tonumber(F.char.epoch) or 0
end

function LB.Label(epoch)
  epoch = epoch or LB.Epoch()
  local i = epoch % #LETTERS + 1
  return "Layer " .. LETTERS:sub(i, i)
end

-- A random number standing for our layer on a network, new every epoch.
function LB.Token(netId)
  local epoch, t = LB.Epoch(), tokens[netId]
  if not t or t.epoch ~= epoch then
    t = { epoch = epoch, value = math.random(TOKEN_MIN, TOKEN_MAX) }
    tokens[netId] = t
  end
  return t.value
end

-- Short times: "12s", then "~5m".."~45m", "~1hr"; and when it next changes.
function LB.Countdown(sec)
  if sec <= SECONDS_SHOWN then
    local shown = math.max(1, math.ceil(sec))
    return shown .. "s", sec - (shown - 1)
  end
  local below = SECONDS_SHOWN
  for _, minutes in ipairs(COUNTDOWN_MINUTES) do
    if sec <= minutes * 60 then
      return "~" .. minutes .. "m", sec - below
    end
    below = minutes * 60
  end
  return "~1hr", sec - below
end

function LB.Ago(at)
  local d = type(at) == "number" and time() - at or nil
  if not d then
    return "?"
  end
  if d < 60 then
    return "now"
  elseif d < HOUR then
    return math.floor(d / 60) .. "m"
  end
  return string.format("%dh%02d", math.floor(d / HOUR), math.floor(d % HOUR / 60))
end

-------------------------------------------------------------------------------
-- Refresh the box (once per frame at most), and wake it for countdowns
-------------------------------------------------------------------------------

local pending, wakeAt, wakeTimer = false, nil, nil

function LB.Refresh()
  if pending then
    return
  end
  pending = true
  F:After(0, function()
    pending = false
    if LB.UI then
      LB.UI.Refresh()
    end
  end)
end

function LB.WakeIn(sec)
  local at = GetTime() + sec
  if wakeAt and wakeAt <= at and wakeAt > GetTime() then
    return
  end
  if wakeTimer then
    wakeTimer.Cancel()
  end
  wakeAt = at
  wakeTimer = LB.After(sec + 0.02, function()
    wakeAt, wakeTimer = nil, nil
    LB.Refresh()
  end)
end

function LB.ResetCore()
  pending, wakeAt, wakeTimer = false, nil, nil
  wipe(joins)
  wipe(tokens)
  myKey = nil
  LB.MapsChanged()
  partyStale = true
end
