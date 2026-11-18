-- Layer Bridge: AutoLayer and LayerSwap users reach each other.
--
-- Both addons change layer by getting the player invited by someone on
-- another layer, but they don't speak to each other on Forever:
--  * AutoLayer (raizo) asks with a visible chat line, "<SEG> inv layer", in
--    the "layer" channels, and hosts by inviting anyone whose line says
--    "layer". On the live Forever realms an addon can't post chat lines at
--    all (C_ChatInfo.AreOutgoingAddonChatMessagesRestricted), so its asks
--    don't leave the client, and a line with digits is dropped unless
--    NovaWorldBuffs knows the layer (it isn't on Forever).
--  * LayerSwap (Adam5288) asks out of sight: a click runs /who on the zone
--    and sends each name a hidden addon whisper, prefix "LayerSwap", text
--    "inv layer <LS <zoneMap> [want <id>|not <id> ...] [x,y]>". A host on
--    another layer in that zone invites; every LayerSwap user in the zone
--    answers "heard <asker>|<layer id or ->|<zone or ->|<h or ->", and a
--    host on the asker's own layer whispers "same". The layer id is a
--    creature GUID's "server-zoneUID"; only the server part tells layers
--    apart on Forever.
--
-- Neither addon has a license, so this is our own code speaking those two
-- public message formats; nothing of theirs is copied or changed.
--
-- What the bridge does, on the ARL member's own client only:
--  1. Reads the layer from creatures around the player (nameplates, target,
--     mouseover): the GUID's server part, set by 2 agreeing readings and
--     changed by 3 of the last 5.
--  2. Hosting for LayerSwap users: an ARL member who hosts with AutoLayer
--     (and has no LayerSwap) answers LayerSwap's hidden asks, and its tagged
--     lines in General / whispers / guild, the way a LayerSwap host would:
--     "heard" back, "same" when on the asker's layer, otherwise the invite is
--     handed to AutoLayer (AutoLayer:ProcessMessage as a whisper "inv layer",
--     so its leader check, group cap and invite whisper apply).
--  3. Hosting for AutoLayer users: an ARL member who hosts with LayerSwap
--     (and has no AutoLayer) invites plain AutoLayer asks seen in a "layer"
--     channel, which LayerSwap ignores on Forever. Only where AutoLayer users
--     can still post (realms that allow addon chat).
--  4. Asking LayerSwap hosts for an AutoLayer user: AutoLayer's hop button
--     (a click, so the game answers /who) also runs the /who on the zone and
--     sends the hidden LayerSwap ask to each name, 8 a second. "/arl layer
--     ask" and the panel button do the same by hand, on their own: neither
--     addon needs to be installed, and with LayerSwap installed our asks and
--     their answers are still ours (we don't press LayerSwap's button).
--  5. Leaving the host's group once the read layer changes, after an ask of
--     ours (AutoLayer doesn't leave by itself; LayerSwap does).
-- Never touches either addon's tables or frames; InviteUnit / LeaveParty /
-- SendWho are the same calls both addons make.
local ADDON = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end

local PREFIX = "LayerSwap"
local ZONE_TYPE = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
local VOTES = 5
local ASKER_COOLDOWN = 60 -- s before the same asker is answered again
local HOST_WINDOW, HOST_MAX = 600, 6 -- our own invites (lane 3): at most 6 per 10 min
local INVITE_GAP = 1
local BURST, BURST_WAIT, ASK_MAX = 8, 1, 49 -- a search lists 50 players at most
local ANYWAY_WAIT, ANYWAY_LATE = 3, 10 -- s after the last whisper: re-ask hosts that can't read their layer
local BOOK_TTL, ASKED_FOR = 7 * 86400, 6 * 3600 -- known LayerSwap users; strangers not asked again for 6 h
local WHO_CLASSES = { 1, 2, 3, 4, 5, 7, 8, 9, 11 } -- the classes this client has (searched one per press)
local KNOWN_MAX = 20 -- known hosts asked directly when no search can run
local OFFLINE_FOR = 3600 -- a known host the game says is offline isn't asked directly for 1 h
local WHO_WAIT = 15 -- the server can take a while (or refuse: "Unable to complete your request")
local ASK_GAP = 10 -- s between two asks of ours
local LEAVE_AFTER = 4
local ASK_TTL = 180 -- s an ask of ours stays "ours" for the leave-after-move
local LOG_MAX = 30

local F = {
  id = "LayerBridge",
  addon = ADDON,
  title = "Layer Bridge",
  group = "QualityOfLife",
  command = "layer",
  commandHelp = "change layer with LayerSwap and AutoLayer users",
  description = "Change layer with LayerSwap and AutoLayer users, with or without either addon installed. "
    .. "Two buttons: LayerSwap asks LayerSwap hosts in your zone out of sight; AutoLayer says \"inv layer\" in "
    .. "the layer channel for AutoLayer hosts. With hosting on, you also invite their users' asks.",
  options = {
    { type = "info", text = function(def) return def:GetStatus() end },
    { key = "layerswap", type = "boolean", label = "Work with LayerSwap users", default = true, cmd = "ls",
      desc = "Your asks reach LayerSwap hosts in your zone, out of sight (a player search, then hidden whispers)." },
    { key = "autolayer", type = "boolean", label = "Work with AutoLayer users", default = true, cmd = "al",
      desc = "The AutoLayer button says \"inv layer\" in the \"layer\" channel, if you're in it (ARL never joins "
        .. "it for you). On realms that refuse addon chat lines, such as live Forever, the line may not go out, "
        .. "and a refused line can get you barred from the channel." },
    { key = "host", type = "boolean", label = "Host for the other addon's users", default = false,
      desc = "Off: ARL never invites anyone or answers anyone's ask. On, and only while AutoLayer or LayerSwap "
        .. "hosts too: answer LayerSwap users (AutoLayer hosting) or invite AutoLayer users (LayerSwap hosting)." },
    { key = "leave", type = "boolean", label = "Leave the group after the move", default = true,
      desc = "After an ask of ours, leave the host's group once the layer has changed." },
    { key = "button", type = "boolean", label = "Show the LayerSwap / AutoLayer buttons", default = true,
      desc = "A small movable box with the two buttons, the layer you're on and the AutoLayer button's state." },
    ARLE.Options.Preset.ResetPosition(),
    { type = "button", label = "Ask LayerSwap hosts now", nocmd = true,
      run = function(def) def:Ask("panel", "layerswap") end },
  },
}

local Skin = ARLE.Skin
local Kit = ARLE.UI.Kit

-------------------------------------------------------------------------------
-- Small helpers
-------------------------------------------------------------------------------

-- (the host's shared helpers: ARLExtensions/Lib/Util.lua)
local Secret, Str = ARLE.Lib.IsSecret, ARLE.Lib.Str

local function Loaded(name)
  return ARLE:IsAddonLoaded(name)
end

local function AutoLayerAddon()
  local a = Loaded("AutoLayer") and rawget(_G, "AutoLayer")
  return type(a) == "table" and a or nil
end

local function AutoLayerHosting()
  local a = AutoLayerAddon()
  return a and type(a.db) == "table" and type(a.db.profile) == "table" and a.db.profile.enabled == true
end

local function LayerSwapHosting()
  local db = Loaded("LayerSwap") and rawget(_G, "LayerSwapDB")
  return type(db) == "table" and db.hosting ~= false
end

-- "First Surname-Realm" -> "First Surname", as LayerSwap names players.
local Short = ARLE.Lib.StripRealm

-- Our name as other players' messages carry it: on Forever "First Surname"
-- (UnitName gives the two parts apart; measured 2026-11-16: LayerSwap hosts
-- answered "heard Haru Pala" while UnitName's first part was "Haru").
local function MyName()
  return ARLE.Lib.UnitFullName("player")
end

local function ZoneMap()
  local ok, m = pcall(C_Map.GetBestMapForUnit, "player")
  if not ok or Secret(m) or type(m) ~= "number" or m <= 0 then
    return nil
  end
  local zone = m
  for _ = 1, 6 do
    local okI, info = pcall(C_Map.GetMapInfo, zone)
    if not okI or type(info) ~= "table" or Secret(info) or type(info.mapType) ~= "number" then
      break
    end
    if info.mapType == ZONE_TYPE then
      return zone
    end
    local up = info.parentMapID
    if info.mapType < ZONE_TYPE or type(up) ~= "number" or up <= 0 then
      break
    end
    zone = up
  end
  return m
end

local function InInstance()
  local ok, inside = pcall(IsInInstance)
  return ok and inside == true
end

local log = {}
local function Log(what, ...)
  local parts = { date("%H:%M:%S"), what }
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring((select(i, ...)))
  end
  table.insert(log, 1, table.concat(parts, " "))
  log[LOG_MAX + 1] = nil
end

local stats = { answered = 0, handed = 0, invited = 0, asked = 0, heard = 0, hosts = 0, same = 0 }

-------------------------------------------------------------------------------
-- 1. The layer, from creatures around us
-------------------------------------------------------------------------------

local layer = { id = nil, zone = nil, votes = {}, seen = {} }

local function Key(id)
  return type(id) == "string" and id:match("^(%d+)%-") or id
end

local function SameLayer(a, b)
  return a ~= nil and b ~= nil and (a == b or Key(a) == Key(b))
end

local function ResetLayer()
  layer.id, layer.zone = nil, nil
  wipe(layer.votes)
  wipe(layer.seen)
end

function F:Observe(unit)
  local guid = UnitGUID(unit)
  if Secret(guid) or type(guid) ~= "string" or layer.seen[guid] then
    return
  end
  local kind, _, server, _, zoneUID = strsplit("-", guid)
  if (kind ~= "Creature" and kind ~= "Vehicle") or not server or not zoneUID then
    return
  end
  local okP, pc = pcall(UnitPlayerControlled, unit)
  if okP and not Secret(pc) and pc == true then
    return
  end
  layer.seen[guid] = true
  local id = server .. "-" .. zoneUID
  local votes = layer.votes
  votes[#votes + 1] = id
  if #votes > VOTES then
    table.remove(votes, 1)
  end
  if SameLayer(id, layer.id) then
    return
  end
  local n = 0
  for _, v in ipairs(votes) do
    if SameLayer(v, id) then
      n = n + 1
    end
  end
  if n >= (layer.id and 3 or 2) then
    local was = layer.id
    layer.id, layer.zone = id, ZoneMap()
    self:Debug("layer %s (was %s)", Key(id), tostring(Key(was)))
    self:Paint()
    self:OnLayerChanged(was)
  end
end

-- Everything in view, read now (a press reads before it asks).
function F:ScanUnits()
  for i = 1, 40 do
    self:Observe("nameplate" .. i)
  end
  self:Observe("target")
  self:Observe("mouseover")
end

-------------------------------------------------------------------------------
-- LayerSwap's ask tag: "<LS 1429 not 7088-2 not 6990-4 48.2,42.5>"
-------------------------------------------------------------------------------

local function ParseTag(msg)
  local body = Str(msg) and msg:match("<LS([^<>]*)>")
  if not body then
    return nil
  end
  local avoids = {}
  for id in body:gmatch("not%s+(%d+%-%d+)") do
    avoids[#avoids + 1] = id
  end
  return {
    zone = tonumber(body:match("^%s*(%d+)%s") or body:match("^%s*(%d+)%s*$")),
    want = body:match("want%s+(%d+%-%d+)"),
    avoids = avoids,
  }
end

local function AskLine()
  local parts = { "<LS" }
  local zone = ZoneMap()
  if zone then
    parts[#parts + 1] = tostring(zone)
  end
  if layer.id then
    parts[#parts + 1] = "not " .. layer.id
  end
  if zone and C_Map.GetPlayerMapPosition then
    local ok, pos = pcall(C_Map.GetPlayerMapPosition, zone, "player")
    if ok and pos and not Secret(pos) then
      local okXY, x, y = pcall(pos.GetXY, pos)
      if okXY and type(x) == "number" and type(y) == "number" and x > 0 and y > 0 then
        parts[#parts + 1] = string.format("%.1f,%.1f", x * 100, y * 100)
      end
    end
  end
  return "inv layer " .. table.concat(parts, " ") .. ">"
end

-- [short name] = GetTime() of our last hidden whisper to them, to tell the
-- game's "No player named 'X' is currently playing" for our own asks apart.
local whisperedAt = {}
local WHISPER_ECHO = 10

local function Note(text, to)
  local ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, text, "WHISPER", to)
  res = ok and not Secret(res) and res or nil
  local key = Short(to)
  if res == 0 and key then
    whisperedAt[key] = GetTime()
  end
  return res
end

-- The name in the game's "player not found" line, or nil.
local notFoundPattern
local function NotFoundName(msg)
  if not Str(msg) then
    return nil
  end
  if notFoundPattern == nil then
    local fmt = Str(rawget(_G, "ERR_CHAT_PLAYER_NOT_FOUND_S")) or "No player named '%s' is currently playing."
    notFoundPattern = "^" .. fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)") .. "$"
  end
  return msg:match(notFoundPattern)
end

-- True when that name was whispered by one of our asks a moment ago.
local function OurWhisper(name)
  local key = Short(name)
  local at = key and whisperedAt[key]
  return at and GetTime() - at <= WHISPER_ECHO or false
end

-------------------------------------------------------------------------------
-- 2. Hosting with AutoLayer, for LayerSwap askers
-------------------------------------------------------------------------------

local answeredAt = {} -- [short name] = GetTime()

local function GroupRoom()
  local n = GetNumGroupMembers() or 0
  if IsInRaid() then
    return false
  end
  if n > 0 and not UnitIsGroupLeader("player") then
    return false
  end
  return n < 5
end

function F:AnswerLayerSwap(text, sender, how)
  local name = Short(sender)
  if not name or name == MyName() then
    return
  end
  local tag = ParseTag(text)
  if not tag then
    return
  end
  local zone = ZoneMap()
  if not tag.zone or tag.zone ~= zone then
    self:Debug("%s asks from zone %s, we're in %s: skipped", name, tostring(tag.zone), tostring(zone))
    return
  end
  if answeredAt[name] and GetTime() - answeredAt[name] < ASKER_COOLDOWN then
    self:Debug("%s asked again within %d s: skipped", name, ASKER_COOLDOWN)
    return
  end
  answeredAt[name] = GetTime()
  stats.answered = stats.answered + 1
  local can = layer.id and not InInstance() and not InCombatLockdown() and GroupRoom()
  local function heard(host)
    Note("heard " .. name .. "|" .. (layer.id or "-") .. "|" .. (zone or "-") .. "|" .. (host and "h" or "-"), sender)
  end
  if not layer.id then
    self:Debug("%s: our layer isn't read yet, no invite (target or mouse over a creature)", name)
    Log("skip", name, "our layer unknown")
    heard(false)
    return
  end
  for _, id in ipairs(tag.avoids) do
    if SameLayer(id, layer.id) then
      self:Debug("%s is on our layer: told them \"same\"", name)
      Log("same", name)
      heard(false)
      Note("same", sender)
      return
    end
  end
  if tag.want and not SameLayer(tag.want, layer.id) then
    self:Debug("%s wants layer %s, we're on %s: skipped", name, Key(tag.want), Key(layer.id))
    heard(false)
    return
  end
  if not can then
    self:Debug("%s: can't invite now (instance, combat, raid, not leader or group full)", name)
    Log("skip", name, "can't invite now")
    heard(false)
    return
  end
  heard(true)
  local al = AutoLayerHosting() and AutoLayerAddon()
  if al and type(al.ProcessMessage) == "function" then
    -- As a whisper "inv layer": AutoLayer applies its own rules and invites.
    local ok, err = pcall(al.ProcessMessage, al, "CHAT_MSG_WHISPER", "inv layer", sender)
    if ok then
      stats.handed = stats.handed + 1
      self:Debug("%s (%s): handed to AutoLayer", name, how)
      Log("invite", name, "via AutoLayer", how)
      return
    end
    self:Debug("AutoLayer refused the hand-off: %s", tostring(err))
  end
  self:Invite(sender, name, "LayerSwap " .. how)
end

-------------------------------------------------------------------------------
-- 3. Our own invites (no AutoLayer hosting), for both addons' askers
-------------------------------------------------------------------------------

local invitedAt, recentInvites, lastInvite = {}, {}, 0

-- 60 s per asker, 6 invites per 10 min, 1 s apart; leader or solo, room left.
function F:Invite(sender, name, why)
  local now = GetTime()
  if invitedAt[name] and now - invitedAt[name] < ASKER_COOLDOWN then
    return
  end
  for i = #recentInvites, 1, -1 do
    if now - recentInvites[i] > HOST_WINDOW then
      table.remove(recentInvites, i)
    end
  end
  if #recentInvites >= HOST_MAX then
    self:Debug("%s: %d invites in 10 min already, taking a break", name, HOST_MAX)
    return
  end
  if not layer.id or InInstance() or InCombatLockdown() or not GroupRoom() or now - lastInvite < INVITE_GAP then
    self:Debug("%s: can't invite now (layer unknown, instance, combat, not leader or group full)", name)
    return
  end
  invitedAt[name], lastInvite = now, now
  recentInvites[#recentInvites + 1] = now
  pcall(C_PartyInfo.InviteUnit, sender)
  stats.invited = stats.invited + 1
  Log("invite", name, why)
  self:Debug("%s: invited (%s)", name, why)
end

function F:AnswerAutoLayer(msg, sender, channelName)
  local name = Short(sender)
  if not name or name == MyName() then
    return
  end
  local base = Str(channelName) and channelName:lower() or ""
  if not base:find("^layer") then
    return
  end
  local body = msg:gsub("^<%w+>%s*", "")
  if not body:lower():find("^inv%s+layer%s*$") then
    if body:lower():find("^inv%s+layer") then
      self:Debug("%s asks for numbered layers (%s): can't match those, skipped", name, body)
    end
    return
  end
  self:Invite(sender, name, "AutoLayer ask in " .. tostring(channelName))
end

-------------------------------------------------------------------------------
-- 4. Asking LayerSwap hosts (for an AutoLayer user, or by hand)
-------------------------------------------------------------------------------

local ask -- the ask in flight: { at, zone, layer, line, queue, sent, whoAt }
local muted = {}
local WHO_LISTS = { "LFGWhoListFrame", "FriendsFrame" }

-- The game's who windows open on any who answer; keep them out of it while
-- our search is out (unless the player has one open), and give it back after.
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

-- The swap attempt in progress, step by step, for "/arl layer last" and the
-- summary printed RUN_SUMMARY seconds after a press: each step of a press
-- (search, whispers, replies, the chat line and what the server said about
-- it, invites) is recorded whether or not "/arl debug layer" is on.
local RUN_SUMMARY, RUN_WATCH = 25, 90
local run, lastRun
-- Kept in char so a /reload doesn't forget them (GetTime() runs on across a
-- reload; a value from before a restart is in the future and ignored):
--   char.invitedAt          the last invite after a press (AutoLayer hosts
--                           invite a player from the channel once per 5 min)
--   char.searched[zone]     { at, heard, noAnswer } of the last player search
-- The server turns searches down when they come too often ("Unable to
-- complete your request"), and a zone where no LayerSwap user answered is
-- skipped for a while.
local SEARCH_GAP, SEARCH_EMPTY, AUTOLAYER_AGAIN = 60, 300, 300

local function Since(t)
  local d = type(t) == "number" and GetTime() - t or nil
  return d and d >= 0 and d or nil
end

function F:Step(fmt, ...)
  if not run then
    return
  end
  local ok, text = pcall(string.format, fmt, ...)
  text = ok and text or tostring(fmt)
  run.lines[#run.lines + 1] = string.format("+%.1fs %s", GetTime() - run.at, text)
  self:Debug("swap: %s", text)
end

function F:StartRun(via)
  run = { at = GetTime(), via = via, invitedBefore = Since(self.char.alInvitedAt), lines = {}, whoFound = nil, sent = 0, refused = 0, refusedWhy = nil,
    heard = 0, hosts = 0, same = 0, invites = {}, line = nil, notices = {} }
  lastRun = run
  local mine = run
  -- One result line per burst of presses: a press a newer one replaced
  -- doesn't print its own (/arl layer last still has the latest's steps).
  self:After(RUN_SUMMARY, function(def)
    if lastRun == mine then
      def:Summary(mine)
    end
  end)
  self:After(RUN_WATCH, function()
    if run == mine then
      run = nil
    end
  end)
end

function F:Summary(r)
  local parts = { r.pool == "autolayer" and "asked AutoLayer hosts"
    or (r.pool == "layerswap" and "asked LayerSwap hosts" or "not asked") }
  if r.pool == "autolayer" then
    -- nothing to say about a search: none was made
  elseif r.whoFound == nil then
    parts[#parts + 1] = r.skipWho and r.skipWho or "player search: no answer"
  else
    parts[#parts + 1] = string.format("found %d players, asked %d%s", r.whoFound, r.sent,
      r.refused > 0 and string.format(" (%d refused: %s)", r.refused, tostring(r.refusedWhy)) or "")
    parts[#parts + 1] = string.format("%d LayerSwap users answered (%d hosting, %d on your layer)", r.heard,
      r.hosts, r.same)
  end
  if r.pool == "layerswap" then
    -- no line this press
  elseif r.box == nil then
    parts[#parts + 1] = "chat line: not used"
  elseif r.line then
    parts[#parts + 1] = "chat line: sent"
  elseif #r.invites > 0 and r.box ~= "to be typed by hand" then
    parts[#parts + 1] = "chat line: sent (invites came, though no echo was seen)"
  else
    parts[#parts + 1] = "chat line: never left (" .. (r.box or "?") .. ")"
  end
  parts[#parts + 1] = #r.invites > 0 and ("invited by " .. table.concat(r.invites, ", ")) or "no invite"
  -- AutoLayer hosts invite a player from the channel once per 5 minutes.
  local ago = r.invitedBefore
  if #r.invites == 0 and ago and ago < AUTOLAYER_AGAIN then
    parts[#parts + 1] = string.format("AutoLayer hosts invited you %d s before this press and won't again until "
      .. "5 min have passed (wait %d s more)", ago, AUTOLAYER_AGAIN - ago)
  end
  for _, n in ipairs(r.notices) do
    if n:find("Unable to complete") then
      parts[#parts + 1] = "the server turned the player search down (too many searches?): wait a minute"
      break
    end
  end
  if #r.invites == 0 then
    local nextPool, wait = self:Pool()
    parts[#parts + 1] = nextPool == "autolayer" and "next press: AutoLayer hosts"
      or (wait and string.format("next press: LayerSwap hosts (AutoLayer again in %d s)", math.floor(wait))
        or "next press: LayerSwap hosts")
  end
  self:Print("Swap result: " .. table.concat(parts, "; ") .. ". Details: /arl layer last")
end

-- Live realms refuse chat lines an addon posts, so the line for AutoLayer
-- hosts goes into the chat box and the player's own Enter sends it.
local function Restricted()
  local f = C_ChatInfo and C_ChatInfo.AreOutgoingAddonChatMessagesRestricted
  if type(f) ~= "function" then
    return false
  end
  local ok, r = pcall(f)
  return ok and r == true
end

-- AutoLayer's channel. ARL joins it while "Work with AutoLayer users" is on
-- and leaves it again only when ARL was the one that joined it.
local LAYER_CHANNEL = "layer"

local function LayerChannelId()
  local id = GetChannelName(LAYER_CHANNEL)
  return not Secret(id) and type(id) == "number" and id > 0 and id or nil
end

-- ARL never joins the layer channel itself. On restricted realms (live
-- Forever) the game bars a character from a channel after a line it refused
-- there, or even after a join (LayerSwap's notes, 6-7 Nov 2026; here too on
-- 2026-11-16: after ARL's join and refused lines "/leave layer" did nothing).
-- LeaveLayer stays, to undo a join an older ARL made (char.joinedLayer).

function F:LeaveLayer()
  if self.char.joinedLayer and LayerChannelId() then
    pcall(LeaveChannelByName, LAYER_CHANNEL)
    self:Debug("left %s (ARL had joined it)", LAYER_CHANNEL)
  end
  self.char.joinedLayer = nil
end

local boxAt = 0
function F:BoxLine(via, retried)
  if not self.db.autolayer or GetTime() - boxAt < ASK_GAP then
    return
  end
  local id = LayerChannelId()
  if not id then
    -- ARL never joins it (see LeaveLayer's note): a join can get the character
    -- barred from the channel on restricted realms.
    self:Step("chat line: not in the layer channel (ARL doesn't join it by itself)")
    if run then
      run.box = "not in the layer channel"
    end
    return
  end
  boxAt = GetTime()
  if via == "button" and self.armedText then
    -- The secure button's macro sent it as the player's own line.
    self.char.lineAt = GetTime()
    self:Step("chat line: sent by %s: %s (restricted realm: %s)",
      self.armedMacro and ("the character macro \"" .. self.armedMacro .. "\"") or "the button's own text",
      self.armedText, tostring(Restricted()))
    if run then
      run.box = "the macro ran but no echo came back"
    end
    return
  end
  -- A line an addon types into the chat box isn't sent as a channel line
  -- (measured: Enter answered "Type '/help'..."), so only say what to type.
  self:Step("chat line: not sendable from here (%s); told to type /%d inv layer", via, id)
  if run then
    run.box = "to be typed by hand"
  end
  self:Print(string.format("to reach AutoLayer hosts, type: /%d inv layer  (or press the AutoLayer button)", id))
end

-- One pool per press: AutoLayer hosts first (the line in the layer channel),
-- LayerSwap hosts while AutoLayer is on cooldown:
--   AL_COOLDOWN after an invite that followed our line (AutoLayer hosts don't
--     invite the same player from the channel again within 5 min), or
--   AL_QUIET after a line that brought no invite (nobody there to answer).
-- Kept in char so a /reload doesn't forget them.
local AL_COOLDOWN, AL_QUIET = 300, 60

-- Seconds until the AutoLayer pool can be asked again (0 = now), or nil when
-- "Work with AutoLayer users" is off.
function F:AutoLayerWait()
  -- On a restricted realm the line is refused, and a refused line can get the
  -- character barred from the channel: no AutoLayer asks there.
  if not self.db.autolayer or Restricted() then
    return nil
  end
  local wait = 0
  local inv = Since(self.char.alInvitedAt)
  if inv and inv < AL_COOLDOWN then
    wait = AL_COOLDOWN - inv
  end
  local line = Since(self.char.lineAt)
  if line and line < AL_QUIET and not (inv and inv < line) then
    wait = math.max(wait, AL_QUIET - line)
  end
  return wait
end

-- "autolayer" or "layerswap", and the AutoLayer wait.
function F:Pool()
  local wait = self:AutoLayerWait()
  if wait == 0 then
    return "autolayer", 0
  end
  if self.db.layerswap then
    return "layerswap", wait
  end
  if wait == nil then
    return "none", nil -- AutoLayer not askable here and LayerSwap switched off
  end
  return "autolayer", wait -- LayerSwap users switched off: the line goes anyway
end

-- The Swap layer button's macro: "/<layer channel> inv layer" when the next
-- press goes to the AutoLayer pool, otherwise nothing. Set out of combat
-- (ARLE.Secure queues it); re-decided in PreClick, so a press uses the pool
-- of that moment.
--
-- The line goes through a stored character macro ("ARL Layer"), clicked by
-- the button (type=macro, macro=<name>), not through macrotext: a line from
-- addon-set macrotext never showed in the layer channel on a restricted realm
-- (2026-11-16: no echo, no other channel traffic seen, no AutoLayer invite).
-- Falls back to macrotext when no macro slot is free.
local MACRO_BASE = "ARL Layer"
local function OurMacro(body)
  return type(body) == "string" and body:match("^/%d+ inv layer$") ~= nil
end

function F:ArmButton()
  -- The secure button is the AutoLayer button: its macro is the line,
  -- whenever "Work with AutoLayer users" is on and we're in the channel.
  local id = self.db.autolayer and LayerChannelId() or nil
  local text = id and ("/" .. id .. " inv layer") or nil
  -- A line went out a moment ago: the next click says nothing (no spamming
  -- the channel by clicking fast), PostClick says how long to wait.
  if text and GetTime() - boxAt < ASK_GAP then
    text = nil
  end
  self.armedText = text
  self.armedPool = "autolayer"
  if InCombatLockdown() then
    return
  end
  local name
  if text then
    local res, why = ARLE.Macro:Ensure(self.char, "layerMacro", MACRO_BASE, text, true, OurMacro)
    name = res and self.char.layerMacro or nil
    if not name and not self.toldMacro then
      self.toldMacro = true
      self:Print("couldn't make the \"" .. MACRO_BASE .. "\" macro (" .. tostring(why) .. "); using the button's "
        .. "own text instead.")
    end
  end
  self.armedMacro = name
  ARLE.Secure:SetAttributes("LayerSwap", {
    macro = name or false,
    macrotext = (not name and text) or "",
  })
end

-- LayerSwap's Swap layer button: its own asks reach LayerSwap hosts; the box
-- line reaches AutoLayer hosts. The panel may be made late, so look a few times.
function F:HookLayerSwap(tries)
  if self.swapHooked or not Loaded("LayerSwap") then
    return
  end
  local button = rawget(_G, "LayerSwapPanelSwapButton")
  if type(button) == "table" and button.HookScript then
    self.swapHooked = self:HookScript(button, "OnClick", function()
      F:Asked()
      F:BoxLine("LayerSwap")
    end)
    return
  end
  if (tries or 0) < 10 then
    self:After(3, function(def)
      def:HookLayerSwap((tries or 0) + 1)
    end)
  end
end

-- Any ask of ours (for leaving the host's group after the move).
local lastAsk
function F:Asked()
  lastAsk = { at = GetTime(), layer = layer.id }
end

-- forced: "layerswap" or "autolayer" from the pad's two buttons; otherwise
-- (/arl layer ask, AutoLayer's hop button) F:Pool decides.
function F:Ask(via, forced)
  if not self.db.layerswap and not self.db.autolayer then
    self:Print("\"Work with LayerSwap users\" and \"Work with AutoLayer users\" are both off.")
    return
  end
  if InInstance() then
    self:Print("can't change layer in an instance.")
    return
  end
  local now = GetTime()
  if forced ~= "autolayer" and ask and now - ask.at < ASK_GAP then
    self:Print(string.format("wait %d s before asking again.", ASK_GAP - (now - ask.at)))
    return
  end
  self:StartRun(via)
  self:ScanUnits()
  self:Step("press (%s): zone %s, your layer %s, in a group: %s, AutoLayer %s, LayerSwap %s", via,
    tostring(ZoneMap()), layer.id and Key(layer.id) or "unknown", tostring(IsInGroup()),
    Loaded("AutoLayer") and "on" or "off", Loaded("LayerSwap") and "on" or "off")
  -- As LayerSwap: no ask from inside a group (no host's invite can reach you).
  -- AutoLayer's own button leaves the group first, so its press goes on.
  if IsInGroup() and via ~= "AutoLayer" then
    run.skipWho = "you're in a group: leave it, then press again"
    self:Step(run.skipWho)
    self:Print("you're in a group. Leave it to swap layers.")
    return
  end
  -- One pool per press: the button pressed, or F:Pool.
  local pool, wait = self:Pool()
  if forced then
    pool = forced
  end
  run.pool = pool
  if pool == "none" then
    run.skipWho = "nobody to ask: AutoLayer hosts can't be asked on this realm and LayerSwap users are switched off"
    self:Step(run.skipWho)
    self:Print("nobody to ask: turn on \"Work with LayerSwap users\".")
    return
  end
  if pool == "autolayer" then
    if not self.db.autolayer then
      run.skipWho = "AutoLayer hosts: \"Work with AutoLayer users\" is off"
      self:Step(run.skipWho)
      self:Print("\"Work with AutoLayer users\" is off.")
      return
    end
    if via == "button" then
      local fresh = self.preClickAt and GetTime() - self.preClickAt < 2
      self:Step("AutoLayer button: macro %s, armed %s", tostring(self.armedMacro or self.armedText or "none"),
        fresh and "at the click" or "EARLIER (PreClick didn't run)")
    end
    if GetTime() - boxAt < ASK_GAP then
      run.skipWho = "AutoLayer hosts: a line went out a moment ago"
      self:Step(run.skipWho)
      self:Print(string.format("wait %d s before asking again.", math.ceil(ASK_GAP - (GetTime() - boxAt))))
      return
    end
    self:Step("pool: AutoLayer hosts (the inv layer line)")
    if not LayerChannelId() then
      self:Print("you're not in the \"layer\" channel, so AutoLayer hosts can't hear you (ARL doesn't join it "
        .. "for you).")
    end
    -- AutoLayer posts its own line where the realm allows it.
    if via ~= "AutoLayer" or Restricted() then
      self:BoxLine(via)
    end
    self:Asked()
    run.skipWho = "LayerSwap hosts: not this press"
    return
  end
  if not self.db.layerswap then
    run.skipWho = "LayerSwap hosts: \"Work with LayerSwap users\" is off"
    self:Step(run.skipWho)
    self:Print("\"Work with LayerSwap users\" is off.")
    return
  end
  if wait == nil then
    self:Step("pool: LayerSwap hosts (AutoLayer hosts aren't asked: %s)",
      self.db.autolayer and "this realm refuses addon chat lines" or "switched off")
  else
    self:Step("pool: LayerSwap hosts (AutoLayer hosts again in %d s)", wait)
  end
  -- As LayerSwap: the ask names the layer you leave, so hosts on it stay out.
  -- Without it they'd invite you for nothing; read it first.
  if not layer.id then
    run.skipWho = "LayerSwap users not asked: your layer isn't read yet"
    self:Step(run.skipWho)
    self:Print("reading your layer first: target or mouse over a creature, then press again.")
    return
  end
  local zone = ZoneMap()
  local okInfo, info = pcall(C_Map.GetMapInfo, zone or 0)
  local zoneName = okInfo and type(info) == "table" and Str(info.name) or nil
  if not zone or not zoneName then
    self:Print("couldn't tell which zone you're in.")
    return
  end
  local searched = self.char.searched or {}
  self.char.searched = searched
  local last = searched[zone]
  local ago = last and Since(last.at)
  if ago and ago < SEARCH_GAP then
    -- No search (the server would refuse it), but the LayerSwap hosts we
    -- already know can still be asked directly.
    local n = self:AskKnown(zone, via)
    if n > 0 then
      self:Asked()
    end
    run.skipWho = string.format("player search skipped: the last one here was %d s ago (the server refuses "
      .. "searches that come too often); asked %d known LayerSwap hosts directly", ago, n)
    self:Step(run.skipWho)
    -- Say so now: otherwise nothing shows until the result line.
    if n > 0 then
      self:Print(string.format("asked %d known LayerSwap hosts; a new player search here in %d s.", n,
        math.ceil(SEARCH_GAP - ago)))
    else
      self:Print(string.format("no known LayerSwap host to ask (offline or on your layer); a new player search "
        .. "here in %d s.", math.ceil(SEARCH_GAP - ago)))
    end
    return
  end
  local rec = { at = now, heard = 0 }
  searched[zone] = rec
  ask = { at = now, zone = zone, layer = layer.id, line = AskLine(), queue = {}, sent = 0, via = via,
    heard = 0, hosts = 0, rec = rec }
  stats.asked = stats.asked + 1
  if C_FriendList.SetWhoToUi then
    pcall(C_FriendList.SetWhoToUi, true)
  end
  Hush()
  local tagZone = WHO_TAG_ZONE
  if Secret(tagZone) or type(tagZone) ~= "string" or tagZone == "" then
    tagZone = "z-"
  end
  local text = tagZone .. '"' .. zoneName .. '"'
  local origin = (Enum and Enum.SocialWhoOrigin and Enum.SocialWhoOrigin.Social) or 1
  -- Each search lists 50 players at most: like LayerSwap, every press asks
  -- the zone's map for one class in turn (the first for all of them), so
  -- presses reach different players.
  local round = ((self.char.whoRound or -1) + 1) % (#WHO_CLASSES + 1)
  self.char.whoRound = round
  local cls = round > 0 and WHO_CLASSES[round] or nil
  local ok, err = pcall(C_FriendList.SendWho, text, origin,
    { classIDs = cls and { cls } or {}, raceIDs = {}, uiMapIDs = { zone } })
  local how = "map filter" .. (cls and (", class " .. cls) or ", all classes")
  if not ok then
    self:Step("search with map filter refused: %s", tostring(err))
    ok, err = pcall(C_FriendList.SendWho, text, origin)
    how = "zone name"
  end
  if not ok then
    Unhush()
    ask = nil
    self:Step("search refused: %s", tostring(err))
    self:Print("the game refused the player search; try /arl layer ask.")
    return
  end
  ask.whoAt = now
  self:Asked()
  self:Step("search sent (%s): %s; ask line %s", how, text, ask.line)
  Log("ask", via, zoneName, layer.id and ("leaving " .. Key(layer.id)) or "layer unknown")
  local mine = ask
  self:After(WHO_WAIT, function(def)
    if mine.whoAt then
      -- (the who windows get the event back even if a newer press took over)
      mine.whoAt = nil
      mine.rec.noAnswer = true
      Unhush()
      if ask == mine then
        def:Step("search: no answer within %d s", WHO_WAIT)
        def:Print("the player search got no answer; try again in a moment.")
      end
    end
  end)
end

function F:OnWho()
  local p = ask
  if not p or not p.whoAt then
    Unhush()
    if run then
      local okN, n = pcall(C_FriendList.GetNumWhoResults)
      self:Step("a player search answer came with nothing of ours waiting (%s players)", tostring(okN and n))
    end
    return
  end
  p.whoAt = nil
  local okN, n = pcall(C_FriendList.GetNumWhoResults)
  if not okN or Secret(n) or type(n) ~= "number" then
    n = 0
  end
  local book, asked = self:Book(), self:AskedList()
  local okI, zinfo = pcall(C_Map.GetMapInfo, p.zone or 0)
  local zoneName = okI and type(zinfo) == "table" and Str(zinfo.name) or nil
  -- Order, as LayerSwap does: known hosts, other known LayerSwap users, then
  -- players standing in our zone, then the rest. A stranger asked within
  -- ASKED_FOR who didn't answer isn't asked again (whispering the same
  -- players over and over gets players reported for spam).
  -- Guildmates go last (LayerSwap: "Your guild last"); a host that just
  -- answered from our own layer is left out for AVOID_FOR (Who.avoidHost).
  local me, hosts, known, here, rest, mates, skipped, areas = MyName(), {}, {}, {}, {}, {}, 0, {}
  local guild = Str((GetGuildInfo("player")))
  local avoided = 0
  for i = 1, math.min(n, 50) do
    local ok, info = pcall(C_FriendList.GetWhoInfo, i)
    local full = ok and type(info) == "table" and not Secret(info) and Str(info.fullName)
    if full and Short(full) ~= me then
      local area = Str(info.area)
      if area then
        areas[area] = (areas[area] or 0) + 1
      end
      local theirs = Str(info.fullGuildName)
      local mate = guild and theirs and (theirs == guild or theirs:sub(1, #guild + 1) == guild .. "-")
      local e = book[Short(full)]
      if self:Avoided(full) then
        avoided = avoided + 1
      elseif e and e.host then
        hosts[#hosts + 1] = full
      elseif e then
        known[#known + 1] = full
      elseif asked[full] and time() - asked[full] < ASKED_FOR then
        skipped = skipped + 1
      elseif mate then
        mates[#mates + 1] = full
      elseif zoneName and area == zoneName then
        here[#here + 1] = full
      else
        rest[#rest + 1] = full
      end
    end
  end
  Unhush()
  if avoided > 0 then
    self:Step("left out %d hosts that just answered from your own layer", avoided)
  end
  for _, list in ipairs({ hosts, known, here, rest, mates }) do
    for _, full in ipairs(list) do
      if #p.queue < ASK_MAX then
        p.queue[#p.queue + 1] = full
      end
    end
  end
  local where = {}
  for area, k in pairs(areas) do
    where[#where + 1] = area .. " " .. k
  end
  table.sort(where)
  self:Step("search answered: %d players (known hosts %d, other LayerSwap users %d, in your zone %d, elsewhere %d, "
    .. "guildmates (last) %d, asked lately %d), asking %d; where: %s", n, #hosts, #known, #here, #rest, #mates,
    skipped, #p.queue,
    #where > 0 and table.concat(where, ", ", 1, math.min(#where, 5)) or "?")
  if run then
    run.whoFound = n
  end
  if #p.queue == 0 then
    self:Print(skipped > 0 and "everyone this search found was asked lately and didn't answer; try later, or "
      .. "another zone." or "nobody else found in your zone to ask.")
    return
  end
  self:Send(p)
end

-------------------------------------------------------------------------------
-- What we know of other LayerSwap users (account-wide, self.shared):
--   book[First Surname] = { at = time(), host = true|nil }  anyone who sent
--     us a LayerSwap message (an answer, an ask); also imported once from
--     LayerSwapDB.book when LayerSwap is installed
--   asked[full name] = time()  strangers whispered by our asks
-------------------------------------------------------------------------------

-- Asks the LayerSwap hosts we know (newest first) without a search. Only one
-- in our zone can move us; the others just answer "heard". Returns how many.
function F:AskKnown(zone, via)
  local list = {}
  for key, e in pairs(self:Book()) do
    local away = type(e) == "table" and type(e.offline) == "number" and time() - e.offline < OFFLINE_FOR
    if away then
      self:Debug("known host %s skipped: offline at the last ask", key)
    end
    if type(e) == "table" and e.host and not away and not self:Avoided(key) then
      list[#list + 1] = { key = key, at = e.at or 0, to = e.from or key }
    end
  end
  if #list == 0 then
    return 0
  end
  table.sort(list, function(a, b)
    return a.at > b.at
  end)
  ask = { at = GetTime(), zone = zone, layer = layer.id, line = AskLine(), queue = {}, sent = 0, via = via,
    heard = 0, hosts = 0 }
  for i = 1, math.min(#list, KNOWN_MAX) do
    ask.queue[i] = list[i].to
  end
  local n = #ask.queue
  self:Send(ask)
  return n
end

-- A known host our ask whispered is offline ("No player named 'X' is
-- currently playing"): left out of direct asks for OFFLINE_FOR (they count
-- again once they send us anything).
function F:NoteOffline(msg)
  local name = NotFoundName(msg)
  if not name or not OurWhisper(name) then
    return
  end
  local key = Short(name)
  local e = self:Book()[key]
  if type(e) == "table" and not (type(e.offline) == "number" and time() - e.offline < OFFLINE_FOR) then
    e.offline = time()
    self:Step("%s is offline: not asked directly for %d min", key, OFFLINE_FOR / 60)
  end
end

-- Hides the game's "No player named 'X' is currently playing" when X is
-- someone our hidden ask just whispered (the player never typed to them).
-- A chat message filter is the game's public way to do it; nothing is hooked.
local function NotFoundFilter(_, _, msg)
  local ok, hide = pcall(function()
    local name = NotFoundName(msg)
    return name and OurWhisper(name) or false
  end)
  return ok and hide or false
end

local filterOn = false
function F:ChatFilter(on)
  local util = rawget(_G, "ChatFrameUtil")
  local add = rawget(_G, "ChatFrame_AddMessageEventFilter")
    or (type(util) == "table" and util.AddMessageEventFilter)
  local remove = rawget(_G, "ChatFrame_RemoveMessageEventFilter")
    or (type(util) == "table" and util.RemoveMessageEventFilter)
  if on and not filterOn and type(add) == "function" then
    filterOn = pcall(add, "CHAT_MSG_SYSTEM", NotFoundFilter) and true or false
  elseif not on and filterOn and type(remove) == "function" then
    pcall(remove, "CHAT_MSG_SYSTEM", NotFoundFilter)
    filterOn = false
  end
end

-- Hosts standing on our own layer: left out of our asks for AVOID_FOR, and
-- only while we're still on that layer (after a move they count again).
local AVOID_FOR, avoid = 20, {}

function F:Avoid(sender, onLayer)
  local key = Short(sender)
  if key and onLayer then
    avoid[key] = { at = GetTime(), layer = onLayer }
  end
end

function F:Avoided(name)
  local key = Short(name)
  local e = key and avoid[key]
  if not e then
    return false
  end
  if GetTime() - e.at > AVOID_FOR then
    avoid[key] = nil
    return false
  end
  return SameLayer(e.layer, layer.id)
end

function F:Book()
  local book = self.shared.book
  if type(book) ~= "table" then
    book = {}
    self.shared.book = book
  end
  return book
end

function F:AskedList()
  local asked = self.shared.asked
  if type(asked) ~= "table" then
    asked = {}
    self.shared.asked = asked
  end
  return asked
end

function F:Remember(sender, host)
  local key = Short(sender)
  if not key then
    return
  end
  local book = self:Book()
  local e = book[key] or {}
  e.at = time()
  e.offline = nil -- they just sent us something: online
  e.from = sender -- the name as the game gives it, for whispering back
  if host ~= nil then
    e.host = host or nil
  end
  book[key] = e
end

function F:PruneBook()
  local now = time()
  local book, asked = self:Book(), self:AskedList()
  for k, e in pairs(book) do
    if type(e) ~= "table" or type(e.at) ~= "number" or now - e.at > BOOK_TTL then
      book[k] = nil
    end
  end
  for k, at in pairs(asked) do
    if type(at) ~= "number" or now - at > ASKED_FOR then
      asked[k] = nil
    end
  end
  -- LayerSwap's own book, when it's installed: the users it has met.
  local ls = rawget(_G, "LayerSwapDB")
  if type(ls) == "table" and type(ls.book) == "table" then
    for k, e in pairs(ls.book) do
      if type(k) == "string" and type(e) == "table" and type(e.at) == "number" and now - e.at <= BOOK_TTL
        and not book[k] then
        book[k] = { at = e.at, host = e.host and true or nil }
      end
    end
  end
end

function F:Send(p)
  if ask ~= p then
    return
  end
  local n = 0
  while #p.queue > 0 and n < BURST do
    local res = Note(p.line, p.queue[1])
    if res == 3 then -- throttled: try this name again next round
      break
    end
    local to = table.remove(p.queue, 1)
    n = n + 1
    if res == 0 then
      p.sent = p.sent + 1
      if not self:Book()[Short(to)] then
        self:AskedList()[to] = time()
      end
      if run then
        run.sent = run.sent + 1
      end
    elseif run then
      run.refused = run.refused + 1
      run.refusedWhy = run.refusedWhy or ("result " .. tostring(res))
    end
  end
  if #p.queue > 0 then
    self:After(BURST_WAIT, function(def)
      def:Send(p)
    end)
  else
    self:Step("asks sent: %d whispered%s", p.sent,
      run and run.refused > 0 and (", " .. run.refused .. " refused (" .. tostring(run.refusedWhy) .. ")") or "")
    Log("asked", p.sent .. " players")
    p.doneAt = GetTime()
    for _, wait in ipairs({ ANYWAY_WAIT, ANYWAY_LATE }) do
      self:After(wait, function(def)
        def:Anyway(p)
      end)
    end
  end
end

-- A host in our zone that hasn't read its own layer ("-" in its answer)
-- skips an ask that names the layer we leave: it can't rule out standing on
-- it. When no invite has come, each such host gets the ask once more without
-- that layer, and then invites (LayerSwap does the same).
function F:Anyway(p)
  if ask ~= p or (run and #run.invites > 0) or IsInGroup() then
    return
  end
  -- A host known to stand on another layer gets until ANYWAY_LATE to invite
  -- before the unread ones are asked again (as LayerSwap).
  local other = 0
  for _, r in pairs(p.replies or {}) do
    if r.host and r.layer and r.zone == tostring(p.zone) and not SameLayer(r.layer, layer.id) then
      other = other + 1
    end
  end
  if other > 0 and p.doneAt and GetTime() - p.doneAt < ANYWAY_LATE then
    return
  end
  local line = "inv layer <LS " .. tostring(p.zone) .. ">"
  for name, r in pairs(p.replies or {}) do
    if r.host and r.layer == nil and not r.anyway and r.zone == tostring(p.zone) then
      r.anyway = true
      local res = Note(line, r.from)
      self:Step("asked %s again without our layer (it hasn't read its own): result %s", name, tostring(res))
    end
  end
end

-- Replies to our ask: "heard <us>|<layer>|<zone>|<h|->" and "same".
function F:OnReply(text, sender)
  local p = ask
  if not p or GetTime() - p.at > ASK_TTL then
    return
  end
  local name = Short(sender)
  if text == "same" then
    -- Only from someone our ask whispered: anyone else's "same" would let a
    -- stranger keep real hosts out and land in the book as a host.
    local at = name and whisperedAt[name]
    if not (at and at >= p.at - 1) then
      self:Step("%s: \"same\" but we didn't ask them: ignored", tostring(name))
      return
    end
    self:Remember(sender, true)
    self:Avoid(sender, layer.id)
    stats.same = stats.same + 1
    if run then
      run.same = run.same + 1
    end
    self:Step("%s: \"same\" (a host already on your layer)", tostring(name))
    return
  end
  local target, theirs, theirZone, host = text:match("^heard (.-)|([^|]*)|([^|]*)|([^|]*)$")
  if target and target ~= MyName() then
    self:Step("%s answered someone else (%s), not us (%s)", tostring(name), tostring(target), tostring(MyName()))
  end
  if target and target == MyName() then
    self:Remember(sender, host == "h")
    p.replies = p.replies or {}
    local r = { from = sender, host = host == "h", zone = theirZone, layer = theirs ~= "-" and theirs or nil }
    p.replies[name or sender] = r
    if r.layer and SameLayer(r.layer, layer.id) and r.zone == tostring(p.zone) then
      self:Avoid(sender, layer.id)
    end
    -- A late answer from a host that hasn't read its layer: ask it again now.
    if r.host and not r.layer and p.doneAt and GetTime() - p.doneAt >= ANYWAY_WAIT then
      self:After(0, function(def)
        def:Anyway(p)
      end)
    end
    p.heard = p.heard + 1
    if p.rec then
      p.rec.heard = p.heard
    end
    stats.heard = stats.heard + 1
    if run then
      run.heard = run.heard + 1
      run.hosts = run.hosts + (host == "h" and 1 or 0)
    end
    self:Step("%s heard us: layer %s, %s", tostring(name), tostring(theirs),
      host == "h" and "hosting" or "not hosting")
    if host == "h" then
      p.hosts = p.hosts + 1
      stats.hosts = stats.hosts + 1
      if p.hosts == 1 then
        self:Print((name or "a LayerSwap host") .. " heard you and hosts: accept the invite when it comes.")
      end
    end
    self:Debug("%s heard us%s", tostring(name), host == "h" and " (hosts)" or "")
    -- Don't ask the ones that answered again in this ask.
    for i = #p.queue, 1, -1 do
      if Short(p.queue[i]) == name then
        table.remove(p.queue, i)
      end
    end
  end
end

-------------------------------------------------------------------------------
-- 5. Leaving the host's group after the move
-------------------------------------------------------------------------------

local joined -- { at, layer }: we joined someone's group while our ask was fresh

function F:OnGroupJoined()
  if lastAsk and GetTime() - lastAsk.at < ASK_TTL and not UnitIsGroupLeader("player") then
    joined = { at = GetTime(), layer = lastAsk.layer or layer.id }
    self:Step("joined a group; waiting for the layer to change (now %s)", layer.id and Key(layer.id) or "unknown")
  end
end

function F:OnLayerChanged(was)
  if not joined or not self.db.leave then
    return
  end
  if GetTime() - joined.at > ASK_TTL or not IsInGroup() then
    joined = nil
    return
  end
  if joined.layer and SameLayer(joined.layer, layer.id) then
    return
  end
  if not joined.layer and not was then
    return
  end
  joined = nil
  ask = nil
  self:Step("layer changed %s -> %s, leaving the group in %d s", tostring(Key(was)), tostring(Key(layer.id)),
    LEAVE_AFTER)
  self:Print("layer changed; leaving the group.")
  Log("moved", Key(was), "->", Key(layer.id))
  self:After(LEAVE_AFTER, function()
    if IsInGroup() and not UnitIsGroupLeader("player") then
      pcall(C_PartyInfo.LeaveParty)
    end
  end)
end

-------------------------------------------------------------------------------
-- The box: a LayerSwap button (plain: a click is what /who needs) and an
-- AutoLayer button (the host's secure macro button laid over it)
-------------------------------------------------------------------------------

local pad
-- Kit.Movable's place function. The pad holds the secure button and the
-- AutoLayer button has it anchored on top, so both are protected: in combat
-- they can't be moved, dragged, enabled or disabled (ADDON_ACTION_BLOCKED,
-- 2026-11-17, from PadText's Disable); those changes wait for combat to end.
local placePad

local function PlacePad()
  if placePad then
    placePad()
  end
end

local function BuildPad()
  local f = Skin:CreateTooltipWindow(nil, UIParent)
  f:SetSize(226, 62)
  f:SetFrameStrata("MEDIUM")
  placePad = Kit.Movable(f, F, { y = -220, secure = true })
  -- Two buttons, one per pool. LayerSwap: a plain button (its click is the
  -- hardware event /who needs). AutoLayer: the host's secure macro button,
  -- laid over the visible one.
  f.ls = Kit.Button(f, "LayerSwap", 104)
  f.ls:SetPoint("TOPLEFT", 6, -6)
  f.al = Kit.Button(f, "AutoLayer", 104)
  f.al:SetPoint("TOPRIGHT", -6, -6)
  f.swap = f.al -- the secure overlay's target
  F:Script(f.ls, "OnClick", function()
    F:Ask("button", "layerswap")
  end)
  F:Script(f.ls, "OnEnter", function(self)
    Kit.SimpleTooltip(self, "LayerSwap hosts", "Searches your zone and asks LayerSwap hosts out of sight (known "
      .. "hosts first). Accept the invite that comes; the group is left once you've moved. Drag the box to move it.")
  end)
  F:Script(f.ls, "OnLeave", GameTooltip_Hide)
  local function AlTip(owner)
    local lines = "Says \"inv layer\" in the layer channel, through your \"" .. MACRO_BASE .. "\" macro, for "
      .. "AutoLayer hosts. Only while you're in the layer channel (ARL never joins it for you)."
    if Restricted() then
      lines = lines .. "\n\n|cffff6060This realm refuses addon chat lines: the line may not go out, and a "
        .. "refused line can get you barred from the channel.|r"
    end
    Kit.SimpleTooltip(owner, "AutoLayer hosts", lines)
  end
  -- Fallback when the host's secure button is missing (game not restarted
  -- since the update): the click can't say the line.
  F:Script(f.al, "OnClick", function()
    F:Ask("plain button", "autolayer")
  end)
  F:Script(f.al, "OnEnter", AlTip)
  f.alTip = AlTip
  F:Script(f.al, "OnLeave", GameTooltip_Hide)
  f.text = Kit.Text(f, "GameFontHighlightSmall")
  f.text:SetPoint("BOTTOM", 0, 5)
  f.text:SetJustifyH("CENTER")
  f:Hide()
  pad = f
end

-- The host's secure macro button laid over the AutoLayer one (out of combat):
-- its macro says "inv layer" as the player; PostClick runs the rest. Handed
-- back with Secure:Detach when the feature goes off, laid again when it's on.
local secAttached = false
local function AttachSecure()
  if secAttached or not pad then
    return
  end
  local sec = ARLE.Secure:Button("LayerSwap")
  if not sec then
    F:Step("the secure AutoLayer button is missing: restart the game")
    return
  end
  secAttached = true
  local al = pad.al
  ARLE.Secure:Run(function()
    if not (F._active and secAttached) then
      return
    end
    sec:SetParent(pad)
    sec:ClearAllPoints()
    sec:SetAllPoints(al)
    sec:SetFrameLevel(al:GetFrameLevel() + 5)
    sec:Show()
    -- F:Script (SetScript with errors caught), as Buff Back and Rare
    -- Objectives do on their host buttons (a hooked PreClick on this template
    -- didn't run: 2026-11-16, a second press 20 s after a line still went to
    -- AutoLayer). Our own button, ours to script.
    F:Script(sec, "PreClick", function()
      if F._active and not InCombatLockdown() then
        F.preClickAt = GetTime()
        F:ArmButton()
      end
    end)
    F:Script(sec, "PostClick", function()
      if F._active then
        F:Ask("button", "autolayer")
      end
    end)
    F:Script(sec, "OnEnter", function(self)
      al:LockHighlight()
      pad.alTip(self)
    end)
    F:Script(sec, "OnLeave", function()
      al:UnlockHighlight()
      GameTooltip:Hide()
    end)
  end, "LayerBridge.sec")
  F:ArmButton()
end

local function DetachSecure()
  if not secAttached then
    return
  end
  secAttached = false
  ARLE.Secure:Run(function()
    if not secAttached and pad then
      ARLE.Secure:Detach("LayerSwap", pad, { "macro", "macrotext" })
    end
  end, "LayerBridge.sec")
end

-- How the layer is shown. The real id is the creature GUID's server number
-- (7100). LayerSwap numbers the layers it has seen in its own order (A, B,
-- ... then 27, 28, ...), a nickname kept in LayerSwapDB.layers; when it has
-- one for this layer, show that too so the two panels can be matched.
function F:LayerLabel(id)
  local db = Loaded("LayerSwap") and rawget(_G, "LayerSwapDB")
  local okI, info = pcall(C_Map.GetMapInfo, ZoneMap() or 0)
  local zoneName = okI and type(info) == "table" and Str(info.name) or nil
  if type(db) == "table" and type(db.layers) == "table" then
    for other, l in pairs(db.layers) do
      if type(l) == "table" and l.letter and Key(other) == Key(id) and (l.zone == nil or l.zone == zoneName) then
        return string.format("Layer %s (LayerSwap) · id %s", tostring(l.letter), tostring(Key(id)))
      end
    end
  end
  return "Layer id " .. tostring(Key(id))
end

-- The pad's two lines: the layer, and where the next press goes.
function F:PadText()
  if not pad then
    return
  end
  local top = layer.id and self:LayerLabel(layer.id) or "|cff999999Layer unknown: look at a creature|r"
  -- The AutoLayer button's state: off, not in the channel, a refusing realm,
  -- or AutoLayer hosts' 5-minute wait after they invited you.
  local al
  local inChannel = LayerChannelId() ~= nil
  if not self.db.autolayer then
    al = "AutoLayer: off"
  elseif not inChannel then
    al = "AutoLayer: not in the layer channel"
  elseif Restricted() then
    al = "|cffff8040AutoLayer: realm blocks addon chat|r"
  else
    local inv = Since(self.char.alInvitedAt)
    local wait = inv and inv < AL_COOLDOWN and math.floor(AL_COOLDOWN - inv) or 0
    al = wait > 0 and string.format("AutoLayer: hosts again in %d:%02d", math.floor(wait / 60), wait % 60)
      or "AutoLayer: ready"
  end
  local usable = self.db.autolayer and inChannel and true or false
  ARLE.Secure:Run(function()
    pad.al:SetEnabled(usable)
  end, "LayerBridge.al")
  pad.ls:SetEnabled(self.db.layerswap and true or false)
  pad.text:SetText(top .. "\n|cffaaaaaa" .. al .. "|r")
end

-- Shown while on, wanted and outside instances; checked again when it runs,
-- since it may wait for combat to end.
local function SyncPad()
  pad:SetShown((F._active and F.db.button and not InInstance()) and true or false)
end

function F:Paint()
  -- The pad holds a secure button: shown and hidden out of combat only.
  if not self._active or not self.db.button or InInstance() then
    if pad then
      ARLE.Secure:Run(SyncPad, "LayerBridge.pad")
    end
    return
  end
  if not pad then
    BuildPad()
  end
  AttachSecure()
  self:PadText()
  ARLE.Secure:Run(SyncPad, "LayerBridge.pad")
end

function F:OnResetPosition()
  PlacePad()
end

function F:OnOptionChanged(key, value)
  if key == "button" then
    self:Paint()
  elseif key == "autolayer" then
    if not value then
      self:LeaveLayer()
    end
    self:After(1, self.ArmButton)
  end
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

function F:OnAddonMessage(_, prefix, text, kind, sender)
  if Secret(prefix) or prefix ~= PREFIX or not Str(text) or not Str(sender) then
    return
  end
  if not self.db.layerswap then
    return
  end
  if kind == "WHISPER" and text:find("^inv layer") then
    self:Remember(sender) -- a LayerSwap user (host or not: unknown)
    -- LayerSwap, when loaded, answers asks to us itself.
    if self.db.host and not Loaded("LayerSwap") then
      self:AnswerLayerSwap(text, sender, "hidden ask")
    end
    return
  end
  -- Answers to our own asks: ours to read whether or not LayerSwap is loaded
  -- (OnReply only takes them while an ask of ours is out, and only those
  -- naming us).
  self:OnReply(text, sender)
end

-- A LayerSwap line someone typed (General, a whisper, guild): "inv layer <LS ...>".
-- AutoLayer drops it (digits, no NovaWorldBuffs layer), so we answer it.
function F:OnChatLine(event, msg, sender, _, _, _, _, _, _, channelName, _, _, guid)
  -- How the layer channel's lines look to us during a swap (the first few):
  -- whether the game hides their text, sender or GUID from addons here.
  if run and event == "CHAT_MSG_CHANNEL" and (run.chanSeen or 0) < 4 then
    local base = Str(channelName)
    if not base or base:lower():find("^layer") then
      run.chanSeen = (run.chanSeen or 0) + 1
      local function look(v)
        return Secret(v) and "hidden" or (Str(v) and "readable" or "empty")
      end
      self:Step("layer channel line: channel %s, text %s, sender %s (%s), guid %s (ours: %s)",
        tostring(base or look(channelName)), look(msg), look(sender), tostring(Str(sender) or "?"), look(guid),
        tostring(Str(guid) and guid == UnitGUID("player")))
    end
  end
  if not Str(msg) or not Str(sender) then
    if run and Str(guid) and guid == UnitGUID("player") then
      run.line = true -- our own line, its text hidden from addons
      self:Step("your line went out (%s; its text is hidden from addons)", event)
    end
    return
  end
  local mine = (Str(guid) and guid == UnitGUID("player")) or Short(sender) == MyName()
  if run and mine and msg:lower():find("inv%s+layer") then
    run.line = true
    self:Step("your line went out: \"%s\" in %s", msg, tostring(Str(channelName) or event))
    return
  end
  if msg:find("<LS", 1, true) then
    if self.db.host and self.db.layerswap and not Loaded("LayerSwap") and msg:lower():find("inv%s+layer") then
      local al = AutoLayerAddon()
      local known = al and type(al.getCurrentLayer) == "function" and select(2, pcall(al.getCurrentLayer, al))
      if type(known) == "number" and known > 0 then
        return -- AutoLayer knows its layer (NovaWorldBuffs) and answers this itself
      end
      self:AnswerLayerSwap(msg, sender, event == "CHAT_MSG_WHISPER" and "whisper" or "line")
    end
    return
  end
  -- AutoLayer hosting answers these itself.
  if event == "CHAT_MSG_CHANNEL" and self.db.host and self.db.autolayer and not AutoLayerHosting() then
    self:AnswerAutoLayer(msg, sender, channelName)
  end
end

function F:OnEnable()
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
  end
  ResetLayer()
  self:PruneBook()
  self:On("NAME_PLATE_UNIT_ADDED", function(def, _, unit)
    def:Observe(unit)
  end)
  self:On("PLAYER_TARGET_CHANGED", function(def)
    def:Observe("target")
  end)
  self:On("UPDATE_MOUSEOVER_UNIT", function(def)
    def:Observe("mouseover")
  end)
  -- Creatures already on screen count too, without targeting them.
  self:Ticker(2, function(def)
    def:ScanUnits()
    def:PadText()
  end)
  for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA" }) do
    self:On(e, function(def)
      if layer.zone ~= ZoneMap() then
        ResetLayer()
      end
      def:Paint()
    end)
  end
  self:On("CHAT_MSG_ADDON", self.OnAddonMessage)
  for _, e in ipairs({ "CHAT_MSG_CHANNEL", "CHAT_MSG_WHISPER", "CHAT_MSG_GUILD" }) do
    self:On(e, self.OnChatLine)
  end
  self:On("WHO_LIST_UPDATE", self.OnWho)
  -- Joining or leaving channels renumbers them: re-arm the button's macro.
  self:On("CHANNEL_UI_UPDATE", function(def)
    def:Debounce("arm", 0.5, def.ArmButton)
  end)
  self:On("GROUP_JOINED", self.OnGroupJoined)
  self:ChatFilter(true)
  -- What the game says while a swap is in progress (refusals, invites).
  -- self:On keeps one handler per event, so CHAT_MSG_SYSTEM's offline check
  -- lives in this same handler (0.6.2 registered it separately, and this one
  -- replaced it: offline hosts were never left out).
  for _, e in ipairs({ "CHAT_MSG_SYSTEM", "UI_ERROR_MESSAGE", "CHAT_MSG_CHANNEL_NOTICE",
    "CHAT_MSG_CHANNEL_NOTICE_USER" }) do
    self:On(e, function(def, event, a1, a2, _, a4, _, _, _, _, a9)
      if event == "CHAT_MSG_SYSTEM" then
        def:NoteOffline(a1)
      end
      if not run then
        return
      end
      local text = event == "UI_ERROR_MESSAGE" and a2 or a1
      if event:find("NOTICE") then
        text = tostring(Str(a1) or "?") .. " " .. tostring(Str(a4) or Str(a9) or "")
      end
      -- Only what can concern a swap: not "Spell is not ready yet" and the like.
      local low = Str(text) and text:lower() or ""
      local relevant = event ~= "UI_ERROR_MESSAGE" and event ~= "CHAT_MSG_SYSTEM"
      for _, w in ipairs({ "chat", "channel", "invit", "group", "party", "request", "player", "message",
        "permitted", "silenc", "spam", "too fast", "layer" }) do
        if low:find(w, 1, true) then
          relevant = true
          break
        end
      end
      if relevant and Str(text) and text ~= run.lastNotice and #run.notices < 12 then
        run.lastNotice = text
        run.notices[#run.notices + 1] = text
        def:Step("game says (%s): %s", event, text)
      end
    end)
  end
  self:On("PARTY_INVITE_REQUEST", function(def, _, inviter)
    local who = Str(inviter) or "?"
    if run then
      run.invites[#run.invites + 1] = who
      def.char.invitedAt = GetTime()
      if run.pool == "autolayer" then
        def.char.alInvitedAt = GetTime() -- AutoLayer's 5-minute cooldown starts
      end
      def:PadText()
    end
    def:Step("invite from %s", who)
  end)
  self:HookAutoLayer()
  self:HookLayerSwap()
  self:Paint()
  -- Again once the loading screen is gone.
  self:After(3, function(def)
    def:Paint()
  end)
end

-- AutoLayer's hop button and "/autolayer req" both end in SendLayerRequest:
-- from the button that's a click, so the game still answers our /who.
function F:HookAutoLayer()
  local al = AutoLayerAddon()
  if not al or self.hooked then
    return
  end
  self.hooked = self:Hook(al, "SendLayerRequest", function()
    F:Ask("AutoLayer")
  end)
end

function F:OnDisable()
  -- Our "ARL Layer" macro goes with the feature (only if it's still ours).
  local name = self.char.layerMacro
  ARLE.Secure:Run(function()
    if name and not F._active and ARLE.Macro:Delete(name, OurMacro) then
      F.char.layerMacro = nil
    end
  end)
  Unhush()
  self:ChatFilter(false)
  ask, joined, lastAsk = nil, nil, nil
  self:LeaveLayer()
  if pad then
    ARLE.Secure:Run(SyncPad, "LayerBridge.pad")
  end
  DetachSecure()
end

-- For /arl report: settings, channel, the last swap step by step, recent log.
function F:ReportDetails()
  local out = {
    string.format("switches: layerswap %s, autolayer %s, host %s, leave %s, button %s", tostring(self.db.layerswap),
      tostring(self.db.autolayer), tostring(self.db.host), tostring(self.db.leave), tostring(self.db.button)),
    string.format("layer %s (zone %s), layer channel %s, restricted realm %s, pad %s", tostring(layer.id),
      tostring(ZoneMap()), tostring(LayerChannelId() or "not joined"), tostring(Restricted()),
      pad and (pad:IsShown() and "shown" or "hidden") or "not built"),
  }
  if lastRun then
    out[#out + 1] = "last swap:"
    for _, l in ipairs(lastRun.lines) do
      out[#out + 1] = "  " .. l
    end
  end
  for i = math.min(#log, 10), 1, -1 do
    out[#out + 1] = "log: " .. log[i]
  end
  return out
end

function F:GetStatus()
  local found = {}
  if Loaded("AutoLayer") then
    found[#found + 1] = "AutoLayer" .. (AutoLayerHosting() and " (hosting)" or "")
  end
  if Loaded("LayerSwap") then
    found[#found + 1] = "LayerSwap" .. (LayerSwapHosting() and " (hosting)" or "")
  end
  if #found == 0 then
    found[1] = "On its own"
  end
  return string.format("%s · layer %s · answered %d, invites %d, asks %d (%d heard, %d hosts)",
    table.concat(found, " + "), layer.id and Key(layer.id) or "unknown (look at a creature)",
    stats.answered, stats.handed + stats.invited, stats.asked, stats.heard, stats.hosts)
end

F.commands = {
  { name = "last", help = "every step of the last Swap layer press", always = true, run = function(self)
    if not lastRun then
      self:Print("no swap pressed yet this session.")
      return
    end
    self:Print("last swap, step by step:")
    for _, l in ipairs(lastRun.lines) do
      print("   " .. l)
    end
  end },
  { name = "button", help = "shows the LayerSwap / AutoLayer buttons (or says why they're hidden)", run = function(self)
    local why = not self.db.button and "\"Show the LayerSwap / AutoLayer buttons\" is off"
      or InInstance() and "you're in an instance" or nil
    self:Paint()
    if why then
      self:Print("the button is hidden: " .. why .. ".")
    elseif pad and pad:IsShown() then
      local x, y = pad:GetCenter()
      self:Print(string.format("the button is shown at %d, %d (Reset position brings it back to the middle).",
        x or -1, y or -1))
    else
      self:Print("the button couldn't be shown; /arl errors may say why.")
    end
  end },
  { name = "ask", help = "asks LayerSwap hosts in your zone (a /who search, then hidden whispers)",
    run = function(self) self:Ask("command") end },
  { name = "log", help = "the last bridged asks and invites", always = true, run = function(self)
    if #log == 0 then
      self:Print("nothing bridged yet this session.")
      return
    end
    for i = #log, 1, -1 do
      print("   " .. log[i])
    end
  end },
}

ARLE:RegisterModule(F)
