-- Layer Bridge network: Forever Layer Hop (no license we could reuse code
-- under, so only its message format is spoken).
--
-- Prefix FLHNET2, fields split on "|" or ":"; every message may end in
-- "|CID=<player GUID>". Peers announce themselves ("HI|<map>|<layer key>|
-- <hosting 0/1>|<version>|<realm>|LANG=..|POP=0|BUILD=..") to the guild and
-- on request; an asker either asks a known host directly ("DR|<id>|<map>|
-- <their key>|<our key>") or asks a few peers for offers ("LQ|<id>|<map>|*|
-- <key>|<key>|LANG=..") and then takes the best ("LO" offer -> "LR" request).
-- A host answers "LW" (wait), "LI" (invited) or "LN|<id>|<why>".
local _, ns = ...
local LB = ns.LayerBridge
if not LB then
  return
end
local ARLE = _G.ARLExtensions
local F = LB.F
local Lib = ARLE.Lib
local Plain, Str = Lib.Plain, Lib.Str

local PREFIX = "FLHNET2"
local WIRE = "0.1.3"
local VERSION = "0.2.1" -- never above FLH's own release, or its users are told they're out of date
local LIVE, PEERS_MAX, LOAD_WINDOW, GUILD_HI_GAP = 180, 300, 60, 120
local OFFER_WINDOW, OFFER_TTL, OFFER_KEEP = 2.5, 25, 30
local REPLY_WAIT, INVITE_WAIT, MAX_TRIES, LQ_MAX = 5, 25, 3, 8
local WP_GAP, GQ_GAP, CQ_GAP, DISCOVER_GAP, DR_GAP = 2, 3, 10, 20, 3
local MSG_MAX, CID_TAG, ID_MIN, ID_MAX = 255, "|CID=", 10000, 99999
local LANGS = { en = true, pt = true, es = true, de = true, fr = true, ko = true, zh = true, ja = true, ru = true }
local REASONS = { off = "hosting disabled", instance = "inside an instance" }
local GROUP_CHATS = { PARTY = true, RAID = true, INSTANCE_CHAT = true }
local HOP_REPLIES = { "LW", "HQ", "LI", "LD", "LA", "LN" }

local NET = {
  id = "flh", name = "Layer Hop", key = "flh", prefixes = { PREFIX }, addons = { "ForeverLayerHop" },
  desc = "Forever Layer Hop: asks its hosts out of sight (they introduce themselves in guild and to each other), "
    .. "and with Host on, answers their asks.",
}

local peers, peerCount = {}, 0
local book, cur
local avoid, offersMade = {}, {}
local lastOfferAt, lastGuildHI = -math.huge, -math.huge
local cid, realm, lang, tail

local function Split(s)
  local out, pos = {}, 1
  while true do
    local at = s:find("[|:]", pos)
    if not at then
      out[#out + 1] = s:sub(pos)
      return out
    end
    out[#out + 1] = s:sub(pos, at - 1)
    pos = at + 1
  end
end

local function IsNum(v)
  return type(v) == "string" and v:match("^%d+$") ~= nil
end

local function IsKey(v)
  return IsNum(v) and tonumber(v) > 0
end

local function NewId()
  return tostring(math.random(ID_MIN, ID_MAX))
end

local function LayerKey()
  return tostring(LB.Token(NET.id))
end

local function MyMap()
  return LB.RawMap() or 0
end

local function HostFlag()
  return LB.Host.Can() and 1 or 0
end

local function Send(msg, chatType, target)
  if cid and #msg + #CID_TAG + #cid <= MSG_MAX then
    msg = msg .. CID_TAG .. cid
  end
  return LB.SendAddon(PREFIX, msg, chatType, target)
end

local function Whisper(msg, target)
  return Send(msg, "WHISPER", target)
end

local function Here(map)
  map = tonumber(map)
  if not map then
    return false
  end
  if map == LB.RawMap() then
    return true
  end
  local zone = LB.ZoneOf(map)
  return zone ~= nil and zone == LB.Zone()
end

local function PrunePeers()
  local t = GetTime()
  peerCount = 0
  for who, p in pairs(peers) do
    if t - p.t > LIVE then
      peers[who] = nil
    else
      peerCount = peerCount + 1
    end
  end
end

local function See(who, name, map, key, host)
  local p = peers[who]
  if not p then
    p = {}
    peers[who] = p
    peerCount = peerCount + 1
    if peerCount > PEERS_MAX then
      PrunePeers()
    end
  end
  p.n, p.t = name, GetTime()
  map = tonumber(map)
  if map and map > 0 then
    p.m = map
  end
  if IsKey(key) then
    p.k = key
  end
  if host ~= nil then
    p.h = tonumber(host) == 1 and 1 or 0
  end
end

local function HiMsg()
  return ("HI|%d|%s|%d|%s|%s|%s"):format(MyMap(), LayerKey(), HostFlag(), VERSION, realm, tail)
end

local function GuildHI()
  local t = GetTime()
  if t - lastGuildHI < GUILD_HI_GAP or not LB.Host.Can() or not IsInGuild() then
    return
  end
  lastGuildHI = t
  Send(HiMsg(), "GUILD")
end

-------------------------------------------------------------------------------
-- Asking: an offer if one came, else a known host, else ask peers for offers
-------------------------------------------------------------------------------

local NextStep

local function Fire(st, gen)
  if cur == st and st.gen == gen and st.ask.active then
    st.armed(st)
  end
end

local function Arm(st, secs, fn)
  st.gen = st.gen + 1
  st.armed = fn
  LB.After(secs, Fire, st, st.gen)
end

local function DropRequest(st)
  st.req = nil
  NextStep(st)
end

local function EndOfferWindow(st)
  st.waiting = false
  NextStep(st)
end

local function Offer(st, name)
  local who = LB.Key(name)
  if who and not st.offered[who] then
    st.offered[who] = true
    st.ask.Offer(name, NET.id)
  end
end

local function Avoided(who)
  return avoid[who] == LB.Epoch()
end

local function Candidate(st, who, p, t, hostsOnly)
  return p.n and p.m and p.k and t - p.t <= LIVE and not st.tried[who] and (not hostsOnly or p.h == 1)
    and not Avoided(who) and LB.ZoneOf(p.m) == st.zone
end

local function Pick(st, hostsOnly)
  local list, t = {}, GetTime()
  for who, p in pairs(peers) do
    if Candidate(st, who, p, t, hostsOnly) then
      list[#list + 1] = who
    end
  end
  table.sort(list, function(a, b)
    local ba, bb = book.entries[a] ~= nil, book.entries[b] ~= nil
    if ba ~= bb then
      return ba
    end
    return peers[a].t > peers[b].t
  end)
  return list
end

local function TryHost(st, who, o)
  local p = peers[who]
  st.tried[who], st.tries = true, st.tries + 1
  local id
  if o then
    id = st.lqId
    Whisper(("LR|%s|%d|%s|%s"):format(id, o.m, o.k, WIRE), p.n)
  else
    id = NewId()
    Whisper(("DR|%s|%d|%s|%s"):format(id, p.m, p.k, LayerKey()), p.n)
  end
  st.req = { id = id, who = who, name = p.n }
  st.ask.Asked(p.n)
  st.sent = st.sent + 1
  st.ask.Progress(NET.id, st.sent, st.sent, false)
  LB.Step("Layer Hop: asking %s to invite", p.n)
  Arm(st, REPLY_WAIT, DropRequest)
end

local function BestOffer(st)
  local best, bo, t = nil, nil, GetTime()
  for who, o in pairs(st.offers) do
    if not st.tried[who] and peers[who] and t - o.t < OFFER_TTL
      and (not bo or o.size < bo.size or (o.size == bo.size and o.load < bo.load)) then
      best, bo = who, o
    end
  end
  return best, bo
end

local function BroadcastLQ(st)
  local list = Pick(st, false)
  if not list[1] then
    return
  end
  st.lqId = NewId()
  local key = LayerKey()
  local n = math.min(#list, LQ_MAX)
  for i = 1, n do
    local p = peers[list[i]]
    st.lqTo[list[i]] = true
    Whisper(("LQ|%s|%d|*|%s|%s|LANG=%s"):format(st.lqId, p.m, key, key, lang), p.n)
    st.ask.Asked(p.n)
  end
  st.sent = st.sent + n
  st.ask.Progress(NET.id, st.sent, st.sent, false)
  LB.Step("Layer Hop: asked %d peers for offers", n)
  st.waiting = true
  Arm(st, OFFER_WINDOW, EndOfferWindow)
end

NextStep = function(st)
  if cur ~= st or not st.ask.active or not st.zone or st.req or st.waiting or st.tries >= MAX_TRIES then
    return
  end
  local best, bo = BestOffer(st)
  if best then
    return TryHost(st, best, bo)
  end
  local hosts = Pick(st, true)
  if hosts[1] then
    return TryHost(st, hosts[1])
  end
  if not st.lqId then
    BroadcastLQ(st)
  end
end

local function Poke()
  if cur then
    NextStep(cur)
  end
end

local function OnOffer(f, who, sender)
  local st = cur
  if not st or not st.ask.active or f[2] ~= st.lqId or not st.lqTo[who] then
    return
  end
  local map = tonumber(f[3])
  if not map or not IsKey(f[4]) then
    return
  end
  See(who, sender, map, f[4], 1)
  st.offers[who] = { m = map, k = f[4], size = tonumber(f[5]) or 0, load = tonumber(f[6]) or 0, t = GetTime() }
  Offer(st, sender)
  NextStep(st)
end

local function OnHop(cmd, f, who)
  local st = cur
  local r = st and st.req
  if not r or r.done or f[2] ~= r.id or who ~= r.who or not st.ask.active then
    return
  end
  if cmd == "LW" or cmd == "HQ" then
    if r.ack then
      return
    end
    r.ack = true
    Arm(st, INVITE_WAIT, DropRequest)
  elseif cmd == "LI" then
    r.done = true
    Arm(st, INVITE_WAIT, DropRequest)
    book:Remember(r.name, { host = true })
    local leader = f[3] == "S" and f[4] ~= "" and f[4]
    if leader then
      st.ask.Asked(leader)
      Offer(st, leader)
    end
    Offer(st, r.name)
  else
    LB.Step("Layer Hop: %s answered %s %s", r.name, cmd, tostring(f[3]))
    if cmd == "LN" and f[3] == "layer changed" and peers[who] then
      peers[who].k = nil
    end
    st.ask.Refuse(r.name)
    st.req = nil
    st.gen = st.gen + 1
    NextStep(st)
  end
end

-------------------------------------------------------------------------------
-- Hosting
-------------------------------------------------------------------------------

local function Serve(id, sender, zone)
  local ok, why = LB.Host.Can(sender, zone)
  if not ok then
    return Whisper(("LN|%s|%s"):format(id, REASONS[why] or "busy"), sender)
  end
  Whisper("LW|" .. id, sender)
  if LB.Host.Invite(sender, NET.id) then
    Whisper("LI|" .. id, sender)
  else
    Whisper(("LN|%s|invite failed"):format(id), sender)
  end
end

local function Direct(f, ct, who, sender, gap)
  local id = f[2]
  if ct ~= "WHISPER" or not IsNum(id) or not IsKey(f[4]) then
    return
  end
  if gap and not LB.Gate("flh dr", who, gap) then
    return
  end
  if not Here(f[3]) or f[4] ~= LayerKey() then
    return Whisper(("LN|%s|layer changed"):format(id), sender)
  end
  Serve(id, sender, nil)
end

local function RememberOffer(who, id, zone)
  local t = GetTime()
  if t - lastOfferAt > OFFER_KEEP then
    wipe(offersMade)
  end
  lastOfferAt = t
  offersMade[who] = { id = id, t = t, zone = zone }
end

local H = {}

H.WP = function(f, ct, who, sender)
  if ct ~= "WHISPER" or not IsNum(f[2]) then
    return
  end
  See(who, sender, f[5], f[6], f[7])
  if LB.Gate("flh wp", who, WP_GAP) then
    Whisper(("WR|%s|%s|%s|%d|%s|%d|%s"):format(f[2], realm, WIRE, MyMap(), LayerKey(), HostFlag(), tail), sender)
  end
  Poke()
end

H.WR = function(f, ct, who, sender)
  if ct == "WHISPER" then
    See(who, sender, f[5], f[6], f[7])
    Poke()
  end
end

H.HI = function(f, ct, who, sender)
  See(who, sender, f[2], f[3], f[4])
  if ct == "GUILD" then
    GuildHI()
  end
  Poke()
end

H.GQ = function(_, ct, who)
  if GROUP_CHATS[ct] and LB.Gate("flh gq", who, GQ_GAP) then
    Send(HiMsg(), ct)
  end
end

H.CQ = function(f, ct, who, sender)
  if (ct ~= "WHISPER" and ct ~= "CHANNEL") or not IsNum(f[2]) then
    return
  end
  See(who, sender, f[3], f[4], f[5])
  if (ct == "WHISPER" or Here(f[3])) and LB.Gate("flh cq", who, CQ_GAP) then
    Whisper(("CA|%s|%d|%s|%d|%s|%s|%s"):format(f[2], MyMap(), LayerKey(), HostFlag(), WIRE, realm, tail), sender)
  end
  Poke()
end

H.CA = function(f, ct, who, sender)
  if ct == "WHISPER" then
    See(who, sender, f[3], f[4], f[5])
    Poke()
  end
end

H.DISCOVER = function(f, ct, who, sender)
  See(who, sender, f[2], f[3])
  if Here(f[2]) and LB.Gate("flh discover", who, DISCOVER_GAP) then
    local key = LayerKey()
    Whisper(("P|%d|%s|%s|%s|%s"):format(MyMap(), key, WIRE, key, tail), sender)
  end
  if ct == "GUILD" then
    GuildHI()
  end
end

H.LQ = function(f, ct, who, sender)
  if (ct ~= "WHISPER" and ct ~= "CHANNEL") or not IsNum(f[2]) then
    return
  end
  See(who, sender, f[3], f[5])
  local key = LayerKey()
  if not Here(f[3]) or (f[4] ~= "*" and f[4] ~= key) or f[5] == key then
    return
  end
  local zone = LB.ZoneOf(f[3])
  if not LB.Host.Can(sender, zone) then
    return
  end
  RememberOffer(who, f[2], zone)
  Whisper(("LO|%s|%d|%s|%d|%d|ACT=0|LANG=%s"):format(f[2], MyMap(), key, GetNumGroupMembers() or 0,
    LB.Host.Recent(LOAD_WINDOW), lang), sender)
end

H.LR = function(f, _, who, sender)
  local id = f[2]
  if not IsNum(id) then
    return
  end
  local o = offersMade[who]
  offersMade[who] = nil
  if not o or o.id ~= id or GetTime() - o.t > OFFER_KEEP then
    return Whisper(("LN|%s|host unavailable"):format(id), sender)
  end
  if not Here(f[3]) or f[4] ~= LayerKey() then
    return Whisper(("LN|%s|layer changed"):format(id), sender)
  end
  Serve(id, sender, o.zone)
end

H.DR = function(f, ct, who, sender)
  Direct(f, ct, who, sender, DR_GAP)
end
H.ZI = function(f, ct, who, sender)
  Direct(f, ct, who, sender)
end
H.LO = function(f, _, who, sender)
  OnOffer(f, who, sender)
end
for _, cmd in ipairs(HOP_REPLIES) do
  H[cmd] = function(f, _, who)
    OnHop(cmd, f, who)
  end
end

function NET.OnAddon(_, _, text, chatType, sender, who)
  if type(text) ~= "string" or #text > MSG_MAX then
    return
  end
  local handler = H[text:match("^[^|:]+")]
  if handler then
    handler(Split(text), chatType, who, sender)
  end
end

function NET.Init()
  book = LB.Book(NET.id)
  cur = nil
  wipe(peers)
  peerCount = 0
  wipe(avoid)
  wipe(offersMade)
  local l = (GetLocale() or "en"):sub(1, 2)
  lang = LANGS[l] and l or "other"
  realm = tostring(Plain(GetNormalizedRealmName and GetNormalizedRealmName() or GetRealmName()) or "")
    :gsub("[|:%s]", "")
  if realm == "" then
    realm = "?"
  end
  tail = ("LANG=%s|POP=0|BUILD=%s"):format(lang, VERSION)
  local guid = Str(Plain(UnitGUID("player")))
  cid = guid and (guid:gsub("[|:]", "_")) or nil
end

-- A hello to the guild once channels settle (only while hosting).
function NET.OnChannels()
  GuildHI()
end

function NET.Ask(_, ask)
  if ask.want then
    return
  end
  if cur then
    cur.gen = cur.gen + 1
  end
  cur = { ask = ask, zone = ask.zone, gen = 0, tries = 0, tried = {}, offers = {}, offered = {}, lqTo = {},
    sent = 0 }
  NextStep(cur)
end

function NET.StopAsk(_, ask)
  if cur and cur.ask == ask then
    cur.gen = cur.gen + 1
    cur = nil
  end
end

function NET.OnHostFailed(_, ask, why, host)
  local who = LB.Key(host)
  if who and why == "same" then
    avoid[who] = LB.Epoch()
  end
  if cur and cur.ask == ask then
    cur.req = nil
    cur.gen = cur.gen + 1
    NextStep(cur)
  end
end

function NET.OnSwapResult(_, ask, result, host)
  local who = LB.Key(host)
  if who and (result == "same" or result == "moved") then
    avoid[who] = LB.Epoch() - (result == "moved" and 1 or 0)
  end
  if cur and cur.ask == ask then
    cur.gen = cur.gen + 1
    cur = nil
  end
end

function NET.Seen()
  local n, t = 0, GetTime()
  for _, p in pairs(peers) do
    if t - p.t <= LIVE then
      n = n + 1
    end
  end
  return n
end

LB.RegisterNetwork(NET)
