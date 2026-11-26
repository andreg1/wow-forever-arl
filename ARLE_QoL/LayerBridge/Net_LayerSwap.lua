-- Layer Bridge network: LayerSwap (Adam5288; no license, so only its message
-- format is spoken, nothing copied).
--
-- Asking: a /who of the zone, then a hidden whisper to each name, prefix
-- "LayerSwap": "inv layer <LS <zone> [want <id>|not <id> ...] r3 [x,y]>".
-- LayerSwap users in the zone answer "heard <asker>|<id|->|<zone|->|<h|s|->"
-- (h = hosting, s = hosting but skipping us), a host on our layer "same".
-- On Forever its hosts invite only asks carrying the rules mark "r<n>"
-- (LayerSwap 1.14.52: at most 16 joins an hour, which Swap.lua's Limit keeps).
-- A layer id is "<number>-<number>": ours is a random token per epoch, or the
-- id of the host who moved us (adopted), so its "not" lists mean something.
-- Hosting: answers hidden asks and typed "inv layer" whispers through Host.
local _, ns = ...
local LB = ns.LayerBridge
if not LB then
  return
end
local ARLE = _G.ARLExtensions
local F = LB.F
local Lib = ARLE.Lib
local Plain, Str = Lib.Plain, Lib.Str

local PREFIX = "LayerSwap"
local RULES_MARK = "r3"
local BURST, BURST_GAP, ASK_MAX = 8, 1, 49 -- a /who lists 50 players at most
local HEARD_GAP = 10
local WHO_WAIT, WHO_GAP, MORE_GAP, WHO_MAX = 15, 60, 15, 50 -- s; the server refuses searches that come too often
local ANYWAY_WAIT, ANYWAY_LATE = 3, 10
local AVOID_FOR, ASKED_FOR = 20, 6 * 3600 -- hosts on our layer; strangers who never answered
local LINE_MAX = 250
local WHO_CLASSES = { 1, 2, 3, 4, 5, 7, 8, 9, 11 }
local BLOCKED_PREFIXES = { "^%[NWB%]", "^%[AutoLayer%]" }
local BLOCKED_PHRASES = { "what layer", "which layer", "how many layer", "auto inv", "pst for" }
local BLOCKED_WORDS = {}
for word in ("wts wtb wtt lfm lfg guild raid enchant enchanting recruiting selling buying worldbuffs autoinv")
  :gmatch("%a+") do
  BLOCKED_WORDS[word] = true
end
local ASK_WORDS = { inv = true, invite = true, layer = true, layers = true }

local NET = {
  id = "layerswap", name = "LayerSwap", key = "layerswap", prefixes = { PREFIX }, addons = { "LayerSwap" },
  desc = "Asks LayerSwap hosts in your zone out of sight (a player search, then hidden whispers), and with Host "
    .. "on answers LayerSwap users' asks.",
}

-------------------------------------------------------------------------------
-- /who of the zone, shared by whoever needs it (LB.Who)
-------------------------------------------------------------------------------

local who = { round = 0 }
local muted = {}
local WHO_LISTS = { "LFGWhoListFrame", "FriendsFrame", "WhoFrame" }

-- The game's who windows open on any who answer: keep them off it while our
-- search is out (unless the player has one open), and give it back after.
local function Hush()
  for _, n in ipairs(WHO_LISTS) do
    local frame = rawget(_G, n)
    if type(frame) == "table" and not muted[n] and frame.IsEventRegistered and not frame:IsVisible()
      and frame:IsEventRegistered("WHO_LIST_UPDATE") then
      if pcall(frame.UnregisterEvent, frame, "WHO_LIST_UPDATE") then
        muted[n] = frame
      end
    end
  end
end

local function Unhush()
  for n, frame in pairs(muted) do
    pcall(frame.RegisterEvent, frame, "WHO_LIST_UPDATE")
    muted[n] = nil
  end
  if C_FriendList.SetWhoToUi then
    pcall(C_FriendList.SetWhoToUi, false)
  end
end
LB.Unhush = Unhush

local function ClassIDs()
  if not who.classes then
    local get = C_SpecializationInfo and C_SpecializationInfo.GetAllClassIDs
    local ids = type(get) == "function" and (Lib.Call(get)) or nil
    who.classes = type(ids) == "table" and #ids > 0 and ids or WHO_CLASSES
  end
  return who.classes
end

-- Round 0 searches every class; round n only one (the filter lists the
-- classes to leave out), so presses reach different players.
local function Filters(zone, round)
  local f = { classIDs = {}, raceIDs = {}, uiMapIDs = { zone } }
  if round == 0 then
    return f
  end
  local ids = ClassIDs()
  local keep = ids[(round - 1) % #ids + 1]
  for _, id in ipairs(ids) do
    if id ~= keep then
      f.classIDs[#f.classIDs + 1] = id
    end
  end
  return f
end

local function WhoDone(players, why)
  local p = who.pending
  if not p then
    return
  end
  who.pending = nil
  Unhush()
  if players then
    who.last = { zone = p.zone, at = GetTime(), players = players }
  end
  for _, cb in ipairs(p.callbacks) do
    ARLE.Debug.Call(F, cb, players, why)
  end
end

local function OnWhoList()
  local p = who.pending
  if not p then
    return
  end
  local num, total = C_FriendList.GetNumWhoResults()
  num = tonumber(Plain(num)) or 0
  total = tonumber(Plain(total)) or num
  who.capped = total > num or num >= WHO_MAX
  if total > num or who.round > 0 then
    who.round = (who.round + 1) % (#ClassIDs() + 1)
  end
  local players, me = {}, LB.MyKey()
  for i = 1, math.min(num, WHO_MAX) do
    local info = Lib.Call(C_FriendList.GetWhoInfo, i)
    local full = type(info) == "table" and Str(Plain(info.fullName))
    local key = LB.Key(full)
    if key and key ~= me then
      players[#players + 1] = { name = full, key = key, area = Str(Plain(info.area)),
        guild = Str(Plain(info.fullGuildName)) }
    end
  end
  LB.Step("search answered: %d players (of %s)", #players, tostring(total))
  WhoDone(players)
end

-- cb(players or nil, why): { name, key, area, guild } of the zone's players.
-- A search within WHO_GAP of the last one in the zone reuses its answer.
function LB.Who(zone, cb, fresh)
  zone = tonumber(zone)
  local name = LB.ZoneName(zone)
  if not zone or not name then
    return LB.After(0, cb, nil, "nozone")
  end
  local last = who.last
  if not fresh and last and last.zone == zone and GetTime() - last.at < WHO_GAP then
    return LB.After(0, cb, last.players, "cached")
  end
  local p = who.pending
  if p then
    if p.zone ~= zone then
      return LB.After(0, cb, nil, "busy")
    end
    p.callbacks[#p.callbacks + 1] = cb
    return
  end
  if who.roundZone ~= zone then
    who.round, who.roundZone = 0, zone
  end
  local tag = Str(Plain(rawget(_G, "WHO_TAG_ZONE"))) or "z-"
  local query = tag .. '"' .. name .. '"'
  p = { zone = zone, callbacks = { cb } }
  who.pending = p
  who.sentAt = GetTime()
  if C_FriendList.SetWhoToUi then
    pcall(C_FriendList.SetWhoToUi, true)
  end
  Hush()
  local origin = (Enum and Enum.SocialWhoOrigin and Enum.SocialWhoOrigin.Social) or 1
  local ok, err = pcall(C_FriendList.SendWho, query, origin, Filters(zone, who.round))
  if not ok then
    ok, err = pcall(C_FriendList.SendWho, query, origin)
  end
  if not ok then
    LB.Step("search refused: %s", tostring(err))
    return WhoDone(nil, "error")
  end
  LB.Step("search sent: %s (round %d)", query, who.round)
  LB.After(WHO_WAIT, function()
    if who.pending == p then
      LB.Step("search: no answer within %d s", WHO_WAIT)
      WhoDone(nil, "timeout")
    end
  end)
end

function LB.WhoAge()
  return who.sentAt and GetTime() - who.sentAt or nil
end

-------------------------------------------------------------------------------
-- Our layer id, and the ask line
-------------------------------------------------------------------------------

local book, cur, adopted
local avoid = {} -- [key] = { at, epoch }: hosts that answered from our layer

local function OurId()
  local epoch = LB.Epoch()
  if adopted and adopted.epoch == epoch then
    return adopted.id
  end
  return LB.Token(NET.id) .. "-" .. (epoch % 100)
end
NET.OurId = OurId

local function Position(zone)
  if not C_Map.GetPlayerMapPosition then
    return nil
  end
  local pos = Lib.Call(C_Map.GetPlayerMapPosition, zone, "player")
  if type(pos) ~= "table" then
    return nil
  end
  local ok, x, y = pcall(pos.GetXY, pos)
  x, y = ok and Plain(x), ok and Plain(y)
  if type(x) ~= "number" or type(y) ~= "number" or x <= 0 or y <= 0 or x > 1 or y > 1 then
    return nil
  end
  return string.format("%.1f,%.1f", x * 100, y * 100)
end

-- want: the one layer to be invited to (a History click); otherwise ours and
-- the visited ones are named "not <id>", as many as fit.
local function AskLine(zone, want, avoids)
  local parts = { "<LS", tostring(zone) }
  local pos = Position(zone)
  if want then
    parts[#parts + 1] = "want " .. want
  else
    local len = 10 + #table.concat(parts, " ") + #RULES_MARK + 1 + (pos and #pos + 1 or 0) + 1
    for _, id in ipairs(avoids) do
      local add = " not " .. id
      if len + #add > LINE_MAX then
        break
      end
      parts[#parts + 1] = "not " .. id
      len = len + #add
    end
  end
  parts[#parts + 1] = RULES_MARK
  if pos then
    parts[#parts + 1] = pos
  end
  return "inv layer " .. table.concat(parts, " ") .. ">"
end

local function ParseTag(text)
  local body = text:match("<LS([^<>]*)>")
  if not body then
    return nil
  end
  local tag = { nots = {} }
  tag.zone = tonumber(body:match("^%s*(%d+)%s") or body:match("^%s*(%d+)%s*$"))
  tag.want = body:match("want%s+(%d+%-%d+)")
  for id in body:gmatch("not%s+(%d+%-%d+)") do
    tag.nots[#tag.nots + 1] = id
  end
  tag.rules = tonumber((" " .. body .. " "):match("%sr(%d+)%s"))
  return tag
end

local function Whisper(text, target)
  return LB.SendAddon(PREFIX, text, "WHISPER", target)
end

local function Avoided(key)
  local e = key and avoid[key]
  return e ~= nil and GetTime() - e.at < AVOID_FOR and e.epoch == LB.Epoch()
end

local function AskedList()
  local asked = F.shared.asked
  if type(asked) ~= "table" then
    asked = {}
    F.shared.asked = asked
  end
  return asked
end

-------------------------------------------------------------------------------
-- Asking
-------------------------------------------------------------------------------

local function Live(st)
  return st ~= nil and cur == st and not st.stopped and st.ask.active
end

local function Progress(st)
  st.ask.Progress(NET.id, st.i - 1, #st.queue, st.more)
end

local function Enqueue(st, name)
  local key = LB.Key(name)
  if not key or st.seen[key] or #st.queue >= ASK_MAX + st.i - 1 then
    return false
  end
  st.seen[key] = true
  st.queue[#st.queue + 1] = name
  return true
end

local Anyway

local function Round(st)
  if not Live(st) then
    return
  end
  if IsInGroup() then
    st.held = true
    return
  end
  local sent = 0
  while sent < BURST and st.i <= #st.queue do
    local name = st.queue[st.i]
    st.ask.Asked(name)
    local res = Whisper(st.line, name)
    if res == LB.THROTTLED then
      break
    end
    st.i, sent = st.i + 1, sent + 1
    if res == 0 then
      st.sent = st.sent + 1
      if not book:Get(name) then
        AskedList()[name] = time()
      end
    else
      st.refused = st.refused + 1
      st.refusedWhy = st.refusedWhy or tostring(res)
    end
  end
  Progress(st)
  if st.i <= #st.queue then
    LB.After(BURST_GAP, Round, st)
  elseif sent > 0 then
    LB.Step("LayerSwap: %d asked (%d refused%s)", st.sent, st.refused,
      st.refusedWhy and (", result " .. st.refusedWhy) or "")
    st.doneAt = GetTime()
    LB.After(ANYWAY_WAIT, Anyway, st)
    LB.After(ANYWAY_LATE, Anyway, st)
  end
end

-- Known hosts in this zone, newest first (not offline, not on our layer).
local function KnownHosts(zone)
  local out = {}
  local list = book:List(function(e, key)
    return e.host and (e.zone == nil or e.zone == zone) and not LB.Offline(key) and not Avoided(key)
  end)
  for _, e in ipairs(list) do
    out[#out + 1] = e.name
  end
  return out
end

-- Who first: hosts we know, LayerSwap users we know, players in our zone,
-- then the rest, guildmates last; strangers asked lately who never answered
-- are left out (whispering the same people again gets players reported).
local function AddPlayers(st, players)
  local hosts, known, here, rest, mates, skipped = {}, {}, {}, {}, {}, 0
  local guild = Str((GetGuildInfo("player")))
  local zoneName = LB.ZoneName(st.zone)
  local asked, now = AskedList(), time()
  for _, p in ipairs(players or {}) do
    local e = book.entries[p.key]
    local mate = guild and p.guild and (p.guild == guild or p.guild:sub(1, #guild + 1) == guild .. "-")
    if Avoided(p.key) or LB.Offline(p.key) then
      skipped = skipped + 1
    elseif e and e.host then
      hosts[#hosts + 1] = p.name
    elseif e then
      known[#known + 1] = p.name
    elseif asked[p.name] and now - asked[p.name] < ASKED_FOR then
      skipped = skipped + 1
    elseif mate then
      mates[#mates + 1] = p.name
    elseif zoneName and p.area == zoneName then
      here[#here + 1] = p.name
    else
      rest[#rest + 1] = p.name
    end
  end
  local added = 0
  for _, list in ipairs({ hosts, known, here, rest, mates }) do
    for _, name in ipairs(list) do
      if Enqueue(st, name) then
        added = added + 1
      end
    end
  end
  LB.Step("LayerSwap: %d to ask (hosts %d, known %d, here %d, elsewhere %d, guild %d, left out %d)", added, #hosts,
    #known, #here, #rest, #mates, skipped)
  return added
end

function NET.Ask(_, ask)
  local zone = tonumber(ask.zone)
  if not zone then
    return
  end
  local avoids = { OurId() }
  for _, id in ipairs(LB.History.Avoid()) do
    if id ~= avoids[1] then
      avoids[#avoids + 1] = id
    end
  end
  local st = { ask = ask, zone = zone, id = OurId(), queue = {}, seen = {}, i = 1, replies = {}, sent = 0,
    refused = 0, want = ask.want }
  st.line = AskLine(zone, ask.want, avoids)
  cur = st
  LB.Step("LayerSwap ask: %s", st.line)
  -- The host of a History layer first, then the hosts we know here.
  if ask.wantHost then
    local e = book:Get(ask.wantHost)
    Enqueue(st, e and e.name or ask.wantHost)
  end
  for _, name in ipairs(KnownHosts(zone)) do
    Enqueue(st, name)
  end
  Progress(st)
  Round(st)
  LB.Who(zone, function(players, why)
    if not Live(st) then
      return
    end
    st.more = who.capped == true
    if not players then
      LB.Step("LayerSwap: no search answer (%s); asked the known hosts only", tostring(why))
      Progress(st)
      return
    end
    if AddPlayers(st, players) > 0 then
      Round(st)
    else
      Progress(st)
    end
  end)
end

function NET.More(_, ask)
  local st = cur
  if not (Live(st) and st.ask == ask) then
    return
  end
  st.more = false
  Progress(st)
  local age = LB.WhoAge()
  local wait = age and math.max(0, MORE_GAP - age) or 0
  LB.After(wait, function()
    if not Live(st) then
      return
    end
    LB.Who(st.zone, function(players)
      if not Live(st) then
        return
      end
      local added = players and AddPlayers(st, players) or 0
      st.more = who.capped == true and added > 0
      if added > 0 then
        Round(st)
      else
        Progress(st)
      end
    end, true)
  end)
end

function NET.StopAsk(_, ask)
  if cur and cur.ask == ask then
    cur.stopped = true
  end
end

-- A host that hasn't read its own layer ("-") skips an ask naming ours (it
-- can't rule out standing on it). Without an invite, each gets the ask once
-- more naming no layer, as LayerSwap does (that one can land on a visited
-- layer; LayerSwap's own trade-off). Not for a "want" ask.
Anyway = function(st)
  if not Live(st) or st.want or st.ask.phase ~= "asking" or IsInGroup() then
    return
  end
  local other = 0
  for _, r in pairs(st.replies) do
    if r.host and r.layer and r.zone == st.zone and r.layer ~= st.id then
      other = other + 1
    end
  end
  if other > 0 and st.doneAt and GetTime() - st.doneAt < ANYWAY_LATE then
    return
  end
  local line = "inv layer <LS " .. st.zone .. " " .. RULES_MARK .. ">"
  for _, r in pairs(st.replies) do
    if r.host and not r.layer and not r.anyway and r.zone == st.zone then
      r.anyway = true
      LB.Step("LayerSwap: asked %s again naming no layer (it can't read its own): %s", r.from,
        tostring(Whisper(line, r.from)))
    end
  end
end

function NET.OnSwapResult(_, ask, result, host)
  local st = cur
  if result ~= "moved" or not st or st.ask ~= ask then
    return
  end
  local r = st.replies[LB.Key(host) or ""]
  if r and r.layer and r.zone == st.zone and r.layer ~= st.id then
    adopted = { id = r.layer, epoch = LB.Epoch() }
    LB.History.SetId(r.layer, host)
    LB.Step("LayerSwap: our layer is now known as %s (%s's)", r.layer, tostring(host))
  end
end

function NET.OnHostFailed(_, _, why, host)
  local key = LB.Key(host)
  if key and why == "same" then
    avoid[key] = { at = GetTime(), epoch = LB.Epoch() }
  end
end

local function OnHeard(sender, key, asker, layer, zone, flag)
  if not LB.IsMe(asker) then
    return
  end
  zone = tonumber(zone)
  local hosting = flag == "h" or flag == "s"
  book:Remember(sender, { zone = zone, host = hosting or nil })
  local st = cur
  if not Live(st) then
    return
  end
  local id = layer:match("^%d+%-%d+$") and #layer <= 24 and layer or nil
  st.replies[key] = { from = sender, layer = id, zone = zone, host = flag == "h" }
  LB.Step("LayerSwap: %s heard us (layer %s, %s)", sender, tostring(layer),
    flag == "h" and "hosting" or (flag == "s" and "skipping us" or "not hosting"))
  if id and id == st.id and zone == st.zone then
    avoid[key] = { at = GetTime(), epoch = LB.Epoch() }
  end
  if flag == "h" then
    st.ask.Offer(sender, NET.id)
    -- A late answer from a host that hasn't read its layer: ask it again now.
    if not id and st.doneAt and GetTime() - st.doneAt >= ANYWAY_WAIT then
      LB.After(0, Anyway, st)
    end
  end
end

local function OnSame(sender, key)
  local st = cur
  -- Only from someone our ask whispered: a stranger's "same" could keep real
  -- hosts out.
  if not (Live(st) and st.ask.asked[key]) then
    return
  end
  book:Remember(sender, { host = true })
  avoid[key] = { at = GetTime(), epoch = LB.Epoch() }
  st.ask.Refuse(sender)
  LB.Step("LayerSwap: %s says \"same\" (a host on your layer)", sender)
end

-------------------------------------------------------------------------------
-- Hosting
-------------------------------------------------------------------------------

local function Heard(asker, key, flag, force)
  if not LB.Gate("layerswap heard", key, force and 0 or HEARD_GAP) then
    return
  end
  Whisper("heard " .. (Lib.StripRealm(asker) or asker) .. "|" .. OurId() .. "|" .. (LB.Zone() or "-") .. "|" .. flag,
    asker)
end

local function SkipsUs(tag)
  local me = OurId()
  if tag.want and tag.want ~= me then
    return true
  end
  for _, id in ipairs(tag.nots) do
    if id == me then
      return true
    end
  end
  return false
end

local function HostAsk(text, sender, key)
  local tag = ParseTag(text)
  if not (tag and tag.zone) then
    return
  end
  book:Remember(sender, { zone = tag.zone })
  if not LB.Host.Can(sender, tag.zone) then
    return Heard(sender, key, "-")
  end
  if SkipsUs(tag) then
    if tag.nots[1] == OurId() then
      Whisper("same", sender)
    end
    return Heard(sender, key, "s")
  end
  Heard(sender, key, "h", true)
  if not LB.Host.Invite(sender, NET.id) then
    Heard(sender, key, "-", true)
  end
end

-- A plain whisper like "inv layer pls" (no LayerSwap tag).
local function TypedAsk(text)
  if not (text:find("[Ii][Nn][Vv]") or text:find("[Ll][Aa][Yy][Ee][Rr]")) then
    return false
  end
  for _, pattern in ipairs(BLOCKED_PREFIXES) do
    if text:find(pattern) then
      return false
    end
  end
  local low = text:lower()
  for _, phrase in ipairs(BLOCKED_PHRASES) do
    if low:find(phrase, 1, true) then
      return false
    end
  end
  local hit = false
  for word in low:gmatch("%a+") do
    if BLOCKED_WORDS[word] then
      return false
    end
    if ASK_WORDS[word] then
      hit = true
    end
  end
  return hit
end

local function OnWhisper(_, text, sender)
  if not LB.NetOn(NET) or not F.db.host then
    return
  end
  text, sender = Str(Plain(text)), Str(Plain(sender))
  if not text or not sender or not TypedAsk(text) then
    return
  end
  local tag = ParseTag(text)
  if LB.Host.Can(sender, tag and tag.zone) then
    LB.Host.Invite(sender, NET.id)
  end
end

function NET.OnAddon(_, _, text, chatType, sender, key)
  if type(text) ~= "string" or #text > 255 then
    return
  end
  local whispered = chatType == "WHISPER"
  if whispered and text:find("^[Ii][Nn][Vv] [Ll][Aa][Yy][Ee][Rr]") then
    return HostAsk(text, sender, key)
  end
  local asker, layer, zone, flag = text:match("^heard (.-)|([^|]*)|([^|]*)|([^|]*)$")
  if asker then
    return OnHeard(sender, key, asker, layer, zone, flag)
  end
  if whispered and text == "same" then
    OnSame(sender, key)
  end
end

local function Resume()
  local st = cur
  if st and st.held then
    st.held = nil
    Round(st)
  end
end

function NET.Init()
  book = LB.Book(NET.id)
  cur, adopted = nil, adopted -- (the adopted id stays for its epoch across a re-enable)
  wipe(avoid)
  who.pending = nil
  LB.On("WHO_LIST_UPDATE", OnWhoList)
  LB.On("CHAT_MSG_WHISPER", OnWhisper)
  LB.On("GROUP_LEFT", Resume)
  -- LayerSwap's own book, when installed: the users it has met.
  local ls = rawget(_G, "LayerSwapDB")
  if type(ls) == "table" and type(ls.book) == "table" then
    for k, e in pairs(ls.book) do
      if type(k) == "string" and type(e) == "table" and type(e.at) == "number" and not book:Get(k) then
        book.entries[LB.Key(k)] = { name = k, at = e.at, host = e.host and true or nil }
      end
    end
  end
end

function NET.Stop()
  Unhush()
  who.pending = nil
end

function NET.Book()
  return book
end

LB.RegisterNetwork(NET)
