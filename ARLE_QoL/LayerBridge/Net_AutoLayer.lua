-- Layer Bridge network: AutoLayer (raizo; no license, so only its chat format
-- is spoken, nothing copied).
--
-- AutoLayer asks and hosts with chat lines in its "layer" channels: "layer"
-- and one per realm and day, "layer" .. adler32-hex("<realm>-<date>") for the
-- three date spellings dd-mm-yyyy, yyyy-mm-dd and mm-dd-yyyy. An ask reads
-- "<SEG> <ALZxxxx> inv layer": SEG the continent segment, xxxx the zone's map
-- id in four letters (base 26). Lines with digits are numbered asks
-- (NovaWorldBuffs layers) and skipped.
-- Live Forever refuses chat lines an addon posts, so our ask is put in the
-- player's chat box (Swap.lua's fallback, after a few seconds without any
-- other host): the player's own Enter sends it. Hosting invites asks seen in
-- those channels, and plain "inv layer" lines in guild chat.
local _, ns = ...
local LB = ns.LayerBridge
if not LB then
  return
end
local ARLE = _G.ARLExtensions
local F = LB.F
local Lib = ARLE.Lib
local Plain, Str = Lib.Plain, Lib.Str

local ROOT = "layer"
-- continent segments by map id (a map, or the first parent found here)
local SEG_ROOT = { [947] = "AZ", [1945] = "OL", [2521] = "ZI", [2665] = "ZI", [2524] = "DI" }
local SEG_FIXED = { [1941] = "OL", [1942] = "OL", [1943] = "OL", [1947] = "OL", [1950] = "OL", [1954] = "OL",
  [1957] = "OL", [908] = "AZ" }
local ZONE_FIXED = { [2521] = 2521, [2524] = 2524, [2665] = 2521 }
local NOT_ASK = { "wts", "wtb", "lfm", "lfg", "what layer", "which layer" }
local ZONE = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
local MICRO = Enum and Enum.UIMapType and Enum.UIMapType.Micro or 5
local ADLER, MAP_CLIMB, HEADERS = 65521, 32, 2
local CODE_LEN, CODE_BASE, CODE_MAX = 4, 26, 456975
local ALLOW_ANY_FOR, REPEAT_FOR = 45, 3

local NET = {
  id = "autolayer", name = "AutoLayer", key = "autolayer", addons = { "AutoLayer", "LayerHopForAutoLayer" },
  offers = false,
  desc = "Keeps AutoLayer's \"layer\" channels (out of your chat windows) so AutoLayer hosts can be asked "
    .. "(\"inv layer\" from your chat box, sent with your Enter) and, with Host on, AutoLayer users' asks "
    .. "invited.",
}

local names, lists = {}, {}
local failed, zoneOfRaw = {}, {}
local ready, joined = false, false
local lastText, lastAt, lastSeen = {}, {}, -math.huge

local function AdlerHex(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + s:byte(i)) % ADLER
    b = (b + a) % ADLER
  end
  return string.format("%04x%04x", b, a)
end

local function AddList(name)
  names[#names + 1] = name
  lists[name] = true
end

local function BuildNames()
  names, lists = {}, {}
  AddList(ROOT)
  local t = C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime and Lib.Call(C_DateAndTime.GetCurrentCalendarTime)
  local realm = Str(Plain(GetRealmName()))
  if type(t) ~= "table" or not t.monthDay or not realm then
    return
  end
  local d, m, y = t.monthDay, t.month, t.year
  for _, date in ipairs({ string.format("%02d-%02d-%04d", d, m, y), string.format("%04d-%02d-%02d", y, m, d),
    string.format("%02d-%02d-%04d", m, d, y) }) do
    local name = ROOT .. AdlerHex(realm .. "-" .. date)
    if not lists[name] then
      AddList(name)
    end
  end
end

local function Segment()
  local id = LB.RawMap()
  for _ = 1, MAP_CLIMB do
    if not id or id == 0 then
      return nil
    end
    local seg = SEG_FIXED[id] or SEG_ROOT[id]
    if seg then
      return seg
    end
    local info = Lib.Call(C_Map.GetMapInfo, id)
    id = type(info) == "table" and info.parentMapID or nil
  end
end

-- AutoLayer's zone: micro maps climb to their zone; nil outside zones.
local function ALZone()
  local raw = LB.RawMap()
  if not raw then
    return nil
  end
  if zoneOfRaw[raw] == nil then
    local id, found = raw, false
    for _ = 1, MAP_CLIMB do
      if ZONE_FIXED[id] then
        found = ZONE_FIXED[id]
        break
      end
      local info = id and Lib.Call(C_Map.GetMapInfo, id)
      if type(info) ~= "table" or (info.mapType ~= ZONE and info.mapType ~= MICRO) then
        break
      end
      if info.mapType == ZONE then
        found = id
        break
      end
      id = info.parentMapID
    end
    zoneOfRaw[raw] = found
  end
  return zoneOfRaw[raw] or nil
end

local function Encode(v)
  if not v or v < 1 or v > CODE_MAX then
    return nil
  end
  local out = {}
  for i = CODE_LEN, 1, -1 do
    out[i] = string.char(65 + v % CODE_BASE)
    v = math.floor(v / CODE_BASE)
  end
  return table.concat(out)
end

local function Decode(code)
  local v = 0
  for i = 1, CODE_LEN do
    local d = code:byte(i) - 97
    if d < 0 or d >= CODE_BASE then
      return nil
    end
    v = v * CODE_BASE + d
  end
  return v >= 1 and v or nil
end

local function OnJoined(name, id, why)
  if not id then
    failed[name] = true
    LB.Log("autolayer-channel", name, why)
  end
end

local function Wanted()
  return F.db.host or F.db.askAutoLayer ~= false
end

local function JoinAll()
  if not ready or joined or not Wanted() then
    return
  end
  joined = true
  for _, name in ipairs(names) do
    if not failed[name] then
      LB.JoinChannel(NET.id, name, nil, OnJoined)
    end
  end
end

local function PostChannel()
  for _, name in ipairs(names) do
    local id = LB.ChannelId(name)
    if id then
      return id, name
    end
  end
end

-- zone (nil when the line has none), body (lower case, headers cut) or nil
local function Parse(text)
  local s = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):lower():gsub("^%s+", "")
  if s:find("^%[nwb%]") or s:find("^%[autolayer%]") then
    return nil
  end
  local zone
  for _ = 1, HEADERS do
    local token, rest = s:match("^<(%w+)>%s*(.*)$")
    if not token then
      break
    end
    local code = token:match("^alz(%a%a%a%a)$")
    if code then
      zone = Decode(code)
    end
    s = rest
  end
  if s:find("%d") or not s:find("%f[%w]layer%f[%W]") then
    return nil
  end
  return zone, s
end

local function Blocked(body)
  for _, word in ipairs(NOT_ASK) do
    if body:find("%f[%w]" .. word .. "%f[%W]") then
      return true
    end
  end
  return false
end

local function HostAsk(text, sender, needsZone)
  local zone, body = Parse(text)
  if not body or (needsZone and not zone) then
    return
  end
  if not zone and Blocked(body) then
    return
  end
  local here
  if zone then
    here = LB.Zone()
    if zone ~= here and zone ~= ALZone() then
      return
    end
  end
  if LB.Host.Can(sender, here) then
    LB.Host.Invite(sender, NET.id)
  end
end

-- The same line from the same sender within a few seconds (AutoLayer posts
-- to every one of its channels at once).
local function Repeated(sender, text)
  local now = GetTime()
  if now - lastSeen > REPEAT_FOR then
    wipe(lastText)
    wipe(lastAt)
  end
  lastSeen = now
  if lastText[sender] == text and now - lastAt[sender] < REPEAT_FOR then
    return true
  end
  lastText[sender], lastAt[sender] = text, now
  return false
end

local function OnChannel(_, text, sender, _, _, _, _, _, _, base)
  if not LB.NetOn(NET) then
    return
  end
  text = Str(Plain(text))
  if not text or not text:find("<[Aa][Ll][Zz]%a%a%a%a>") then
    return
  end
  base = Str(Plain(base))
  sender = Str(Plain(sender))
  if not base or not lists[base:lower()] or not sender then
    return
  end
  local key = LB.Key(sender)
  LB.Stats.Heard(NET.id, key)
  if LB.IsMe(sender) then
    LB.Step("AutoLayer: your line went out in %s", base)
    return
  end
  if Repeated(sender, text) or not F.db.host then
    return
  end
  HostAsk(text, sender, true)
end

local function OnGuild(_, text, sender)
  if not LB.NetOn(NET) or not F.db.host then
    return
  end
  text, sender = Str(Plain(text)), Str(Plain(sender))
  if text and sender and not LB.IsMe(sender) and text:find("[Ll][Aa][Yy][Ee][Rr]") then
    HostAsk(text, sender, false)
  end
end

local function RequestLine()
  local seg = Segment()
  if not seg then
    return "inv layer "
  end
  local code = Encode(ALZone() or LB.Zone())
  return "<" .. seg .. "> " .. (code and ("<ALZ" .. code .. "> ") or "") .. "inv layer "
end

function NET.Init()
  BuildNames()
  ready, joined = false, false
  wipe(failed)
  wipe(zoneOfRaw)
  LB.On("CHAT_MSG_CHANNEL", OnChannel)
  LB.On("CHAT_MSG_GUILD", OnGuild)
end

-- A while after login (the player's own channels first).
function NET.OnChannels()
  ready = true
  LB.LeaveChannels(NET.id, lists) -- yesterday's
  JoinAll()
end

function NET.Ask()
  JoinAll()
end

-- No host from the other networks yet: our line into the chat box.
function NET.Fallback(_, ask)
  if LB.ChatLocked() then
    return nil
  end
  local id, name = PostChannel()
  if not id then
    JoinAll()
    LB.Step("AutoLayer: not in its channels yet, no line")
    return nil
  end
  local line = RequestLine()
  local how = LB.Prefill(line, "CHANNEL", id)
  if how then
    ask.AllowAny(ALLOW_ANY_FOR)
    LB.Step("AutoLayer: \"%s\" put in the chat box for %s (/%d)", line, name, id)
  else
    LB.Step("AutoLayer: the chat box is in use, no line")
  end
  return how
end

-- Players in its channels (the count is only known once the game listed them).
function NET.Seen()
  local most
  local n = Plain(GetNumDisplayChannels and GetNumDisplayChannels()) or 0
  for i = 1, n do
    local name, header, _, _, count = GetChannelDisplayInfo(i)
    name, count = Str(Plain(name)), tonumber(Plain(count))
    if not Plain(header) and name and lists[name:lower()] and count and count > 0 then
      most = math.max(most or 0, count - 1)
    end
  end
  return most
end

function NET.Stop()
  LB.LeaveChannels(NET.id)
  joined = false
end

-- Settings changed: join when needed, leave when nothing needs the channels.
function NET.Sync()
  if Wanted() and LB.NetOn(NET) then
    ready = true
    JoinAll()
  elseif joined then
    NET.Stop()
  end
end

LB.RegisterNetwork(NET)
