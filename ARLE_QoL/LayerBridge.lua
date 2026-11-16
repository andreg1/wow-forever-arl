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
--     ask" and the panel button do the same by hand.
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
local BURST, BURST_WAIT, ASK_MAX = 8, 1, 40
local WHO_WAIT = 5
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
    .. "The Swap layer button asks LayerSwap hosts in your zone out of sight and readies \"inv layer\" for "
    .. "AutoLayer hosts (press Enter). With hosting on, you also invite their users' asks.",
  options = {
    { type = "info", text = function(def) return def:GetStatus() end },
    { key = "layerswap", type = "boolean", label = "Work with LayerSwap users", default = true, cmd = "ls",
      desc = "Your asks reach LayerSwap hosts in your zone, out of sight (a player search, then hidden whispers)." },
    { key = "autolayer", type = "boolean", label = "Work with AutoLayer users", default = true, cmd = "al",
      desc = "Joins the \"layer\" channel AutoLayer uses, and when you ask, puts \"inv layer\" for it in the chat "
        .. "box: press Enter to send it (the game doesn't let addons send it themselves). Off leaves the channel "
        .. "if ARL joined it." },
    { key = "host", type = "boolean", label = "Host for the other addon's users", default = false,
      desc = "Off: ARL never invites anyone or answers anyone's ask. On, and only while AutoLayer or LayerSwap "
        .. "hosts too: answer LayerSwap users (AutoLayer hosting) or invite AutoLayer users (LayerSwap hosting)." },
    { key = "leave", type = "boolean", label = "Leave the group after the move", default = true,
      desc = "After an ask of ours, leave the host's group once the layer has changed." },
    { key = "button", type = "boolean", label = "Show the Swap layer button", default = true,
      desc = "A small movable button: one click asks for another layer (and shows the layer you're on)." },
    ARLE.Options.Preset.ResetPosition(),
    { type = "button", label = "Swap layer now", nocmd = true,
      run = function(def) def:Ask("button") end },
  },
}

local Skin = ARLE.Skin
local Kit = ARLE.UI.Kit

-------------------------------------------------------------------------------
-- Small helpers
-------------------------------------------------------------------------------

local function Secret(v)
  return issecretvalue and issecretvalue(v)
end

local function Str(v)
  return not Secret(v) and type(v) == "string" and v ~= "" and v or nil
end

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
local function Short(name)
  return Str(name) and name:match("^([^%-]+)") or nil
end

local function MyName()
  return Str((UnitName("player")))
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

local function Note(text, to)
  local ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, text, "WHISPER", to)
  return ok and not Secret(res) and res or nil
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
  run = { at = GetTime(), via = via, lines = {}, whoFound = nil, sent = 0, refused = 0, refusedWhy = nil,
    heard = 0, hosts = 0, same = 0, invites = {}, line = nil, notices = {} }
  lastRun = run
  local mine = run
  self:After(RUN_SUMMARY, function(def)
    def:Summary(mine)
  end)
  self:After(RUN_WATCH, function()
    if run == mine then
      run = nil
    end
  end)
end

function F:Summary(r)
  local parts = {}
  if r.whoFound == nil then
    parts[#parts + 1] = r.skipWho and r.skipWho or "player search: no answer"
  else
    parts[#parts + 1] = string.format("found %d players, asked %d%s", r.whoFound, r.sent,
      r.refused > 0 and string.format(" (%d refused: %s)", r.refused, tostring(r.refusedWhy)) or "")
    parts[#parts + 1] = string.format("%d LayerSwap users answered (%d hosting, %d on your layer)", r.heard,
      r.hosts, r.same)
  end
  if r.box == nil then
    parts[#parts + 1] = "chat line: not used"
  elseif r.line then
    parts[#parts + 1] = "chat line: sent"
  else
    parts[#parts + 1] = "chat line: never left (" .. (r.box or "?") .. ")"
  end
  parts[#parts + 1] = #r.invites > 0 and ("invited by " .. table.concat(r.invites, ", ")) or "no invite"
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

local function ActiveBox()
  local f = (ChatFrameUtil and ChatFrameUtil.GetActiveWindow) or ChatEdit_GetActiveWindow
  local ok, box = pcall(f or function() end)
  return ok and type(box) == "table" and box or nil
end

-- AutoLayer's channel. ARL joins it while "Work with AutoLayer users" is on
-- and leaves it again only when ARL was the one that joined it.
local LAYER_CHANNEL = "layer"

local function LayerChannelId()
  local id = GetChannelName(LAYER_CHANNEL)
  return not Secret(id) and type(id) == "number" and id > 0 and id or nil
end

function F:JoinLayer()
  if LayerChannelId() then
    return true
  end
  local ok = pcall(JoinChannelByName, LAYER_CHANNEL)
  if ok then
    self.char.joinedLayer = true
  end
  self:Debug("join %s: %s", LAYER_CHANNEL, ok and "asked" or "refused")
  return false
end

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
    -- From a click a join goes through; the channel number comes a moment later.
    self:JoinLayer()
    self:Step("chat line: not in the layer channel yet, joining%s", retried and " (second try)" or "")
    if run then
      run.box = "not in the layer channel"
    end
    if not retried then
      self:After(1, function(def)
        def:BoxLine(via, true)
      end)
    elseif not self.toldJoin then
      self.toldJoin = true
      self:Print("couldn't join the \"layer\" channel AutoLayer uses; type /join layer and ask again.")
    end
    return
  end
  if ActiveBox() then
    self:Step("chat line: the chat box was already open, line not put in")
    if run then
      run.box = "chat box was in use"
    end
    return
  end
  local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
  if type(open) ~= "function" then
    self:Step("chat line: this client has no way to open the chat box")
    return
  end
  boxAt = GetTime()
  -- One frame later: a slash command (/arl layer ask) empties the box right after it runs.
  self:After(0, function(def)
    if not ActiveBox() then
      local ok, err = pcall(open, "/" .. id .. " inv layer", DEFAULT_CHAT_FRAME)
      local box = ActiveBox()
      local okT, text = pcall(function() return box and box:GetText() end)
      def:Step("chat line: opened %s (channel %d, restricted realm: %s), box holds \"%s\"",
        ok and "ok" or ("failed: " .. tostring(err)), id, tostring(Restricted()),
        okT and not Secret(text) and tostring(text) or "?")
      if run then
        run.box = "Enter not pressed, or the game refused it"
      end
      def:Print("press Enter to send \"inv layer\" to the layer channel, so AutoLayer hosts hear you too.")
      Log("box", via)
    end
  end)
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

function F:Ask(via)
  if not self.db.layerswap and not self.db.autolayer then
    self:Print("\"Work with LayerSwap users\" and \"Work with AutoLayer users\" are both off.")
    return
  end
  if InInstance() then
    self:Print("can't change layer in an instance.")
    return
  end
  local now = GetTime()
  if ask and now - ask.at < ASK_GAP then
    self:Print(string.format("wait %d s before asking again.", ASK_GAP - (now - ask.at)))
    return
  end
  self:Asked()
  self:StartRun(via)
  self:Step("press (%s): zone %s, your layer %s, in a group: %s, AutoLayer %s, LayerSwap %s", via,
    tostring(ZoneMap()), layer.id and Key(layer.id) or "unknown", tostring(IsInGroup()),
    Loaded("AutoLayer") and "on" or "off", Loaded("LayerSwap") and "on" or "off")
  -- AutoLayer posts its own line where the realm allows it.
  if via ~= "AutoLayer" or Restricted() then
    self:BoxLine(via)
  end
  if not self.db.layerswap then
    run.skipWho = "LayerSwap users: switched off"
    return
  end
  if Loaded("LayerSwap") then
    -- LayerSwap asks its own hosts best: press its button for the player
    -- (still inside this click, so its /who is answered).
    local button = rawget(_G, "LayerSwapPanelSwapButton")
    if via ~= "LayerSwap" and type(button) == "table" and button.Click and button:IsEnabled() then
      pcall(button.Click, button)
      self:Step("pressed LayerSwap's own Swap layer button (its panel shows how that went)")
    else
      self:Step("LayerSwap's Swap layer button wasn't found or was greyed out")
    end
    run.skipWho = "asked through LayerSwap"
    return
  end
  local zone = ZoneMap()
  local okInfo, info = pcall(C_Map.GetMapInfo, zone or 0)
  local zoneName = okInfo and type(info) == "table" and Str(info.name) or nil
  if not zone or not zoneName then
    self:Print("couldn't tell which zone you're in.")
    return
  end
  if not layer.id then
    self:Print("your layer isn't read yet (target or mouse over a creature first), so hosts on your own "
      .. "layer may invite you too.")
  end
  ask = { at = now, zone = zone, layer = layer.id, line = AskLine(), queue = {}, sent = 0, via = via,
    heard = 0, hosts = 0 }
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
  local ok, err = pcall(C_FriendList.SendWho, text, origin,
    { classIDs = {}, raceIDs = {}, uiMapIDs = { zone } })
  local how = "map filter"
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
  self:Step("search sent (%s): %s; ask line %s", how, text, ask.line)
  Log("ask", via, zoneName, layer.id and ("leaving " .. Key(layer.id)) or "layer unknown")
  local mine = ask
  self:After(WHO_WAIT, function(def)
    if ask == mine and mine.whoAt then
      mine.whoAt = nil
      Unhush()
      def:Step("search: no answer within %d s", WHO_WAIT)
      def:Print("the player search got no answer; try again in a moment.")
    end
  end)
end

function F:OnWho()
  local p = ask
  if not p or not p.whoAt then
    return
  end
  p.whoAt = nil
  local okN, n = pcall(C_FriendList.GetNumWhoResults)
  if not okN or Secret(n) or type(n) ~= "number" then
    n = 0
  end
  local me, mates, others = MyName(), {}, {}
  local guild = Str((GetGuildInfo("player")))
  for i = 1, math.min(n, 50) do
    local ok, info = pcall(C_FriendList.GetWhoInfo, i)
    local full = ok and type(info) == "table" and not Secret(info) and Str(info.fullName)
    if full and Short(full) ~= me then
      if guild and Str(info.fullGuildName) == guild then
        mates[#mates + 1] = full
      else
        others[#others + 1] = full
      end
    end
  end
  Unhush()
  for _, list in ipairs({ mates, others }) do
    for _, full in ipairs(list) do
      if #p.queue < ASK_MAX then
        p.queue[#p.queue + 1] = full
      end
    end
  end
  self:Step("search answered: %d players (%d guildmates, %d others), asking %d", n, #mates, #others, #p.queue)
  if run then
    run.whoFound = n
  end
  if #p.queue == 0 then
    self:Print("nobody else found in your zone to ask.")
    return
  end
  self:Send(p)
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
    table.remove(p.queue, 1)
    n = n + 1
    if res == 0 then
      p.sent = p.sent + 1
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
    stats.same = stats.same + 1
    if run then
      run.same = run.same + 1
    end
    self:Step("%s: \"same\" (a host already on your layer)", tostring(name))
    return
  end
  local target, theirs, _, host = text:match("^heard (.-)|([^|]*)|([^|]*)|([^|]*)$")
  if target and target ~= MyName() then
    self:Step("%s answered someone else (%s), not us (%s)", tostring(name), tostring(target), tostring(MyName()))
  end
  if target and target == MyName() then
    p.heard = p.heard + 1
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
-- The Swap layer button (a plain button: a click is what /who needs)
-------------------------------------------------------------------------------

local pad

local function PlacePad()
  pad:ClearAllPoints()
  local pos = F.char.position
  pad:SetPoint("CENTER", UIParent, "CENTER", pos and pos[1] or 0, pos and pos[2] or -220)
end

local function BuildPad()
  local f = Skin:CreateTooltipWindow(nil, UIParent)
  f:SetSize(150, 46)
  f:SetFrameStrata("MEDIUM")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  F:Script(f, "OnDragStart", f.StartMoving)
  F:Script(f, "OnDragStop", function(self)
    self:StopMovingOrSizing()
    local x, y = self:GetCenter()
    local cx, cy = UIParent:GetCenter()
    if x and cx then
      F.char.position = { x - cx, y - cy }
    end
    PlacePad()
  end)
  f.swap = Kit.Button(f, "Swap layer", 134)
  f.swap:SetPoint("TOP", 0, -6)
  F:Script(f.swap, "OnClick", function()
    F:Ask("button")
  end)
  F:Script(f.swap, "OnEnter", function(self)
    Kit.SimpleTooltip(self, "Swap layer", "Asks LayerSwap hosts in your zone out of sight, and puts \"inv layer\" "
      .. "in the chat box for AutoLayer hosts (press Enter). Accept the invite that comes; the group is left "
      .. "once you've moved. Drag the box to move it.")
  end)
  F:Script(f.swap, "OnLeave", GameTooltip_Hide)
  f.text = Kit.Text(f, "GameFontHighlightSmall")
  f.text:SetPoint("BOTTOM", 0, 5)
  f:Hide()
  pad = f
  PlacePad()
end

function F:Paint()
  if not self._active or not self.db.button or InInstance() then
    if pad then
      pad:Hide()
    end
    return
  end
  if not pad then
    BuildPad()
  end
  pad.text:SetText(layer.id and ("Layer " .. Key(layer.id)) or "|cff999999Layer unknown: look at a creature|r")
  pad:Show()
end

function F:OnResetPosition()
  if pad then
    PlacePad()
  end
end

function F:OnOptionChanged(key, value)
  if key == "button" then
    self:Paint()
  elseif key == "autolayer" then
    if value then
      self:JoinLayer()
    else
      self:LeaveLayer()
    end
  end
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

function F:OnAddonMessage(_, prefix, text, kind, sender)
  if Secret(prefix) or prefix ~= PREFIX or not Str(text) or not Str(sender) then
    return
  end
  if Loaded("LayerSwap") or not self.db.layerswap then
    return -- LayerSwap answers and reads its own messages
  end
  if kind == "WHISPER" and text:find("^inv layer") then
    if self.db.host then
      self:AnswerLayerSwap(text, sender, "hidden ask")
    end
    return
  end
  self:OnReply(text, sender)
end

-- A LayerSwap line someone typed (General, a whisper, guild): "inv layer <LS ...>".
-- AutoLayer drops it (digits, no NovaWorldBuffs layer), so we answer it.
function F:OnChatLine(event, msg, sender, _, _, _, _, _, _, channelName)
  if not Str(msg) or not Str(sender) then
    return
  end
  if run and Short(sender) == MyName() and msg:lower():find("inv%s+layer") then
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
  self:On("NAME_PLATE_UNIT_ADDED", function(def, _, unit)
    def:Observe(unit)
  end)
  self:On("PLAYER_TARGET_CHANGED", function(def)
    def:Observe("target")
  end)
  self:On("UPDATE_MOUSEOVER_UNIT", function(def)
    def:Observe("mouseover")
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
  self:On("GROUP_JOINED", self.OnGroupJoined)
  -- What the game says while a swap is in progress (refusals, invites).
  for _, e in ipairs({ "CHAT_MSG_SYSTEM", "UI_ERROR_MESSAGE", "CHAT_MSG_CHANNEL_NOTICE",
    "CHAT_MSG_CHANNEL_NOTICE_USER" }) do
    self:On(e, function(def, event, a1, a2, _, a4, _, _, _, _, a9)
      if not run then
        return
      end
      local text = event == "UI_ERROR_MESSAGE" and a2 or a1
      if event:find("NOTICE") then
        text = tostring(Str(a1) or "?") .. " " .. tostring(Str(a4) or Str(a9) or "")
      end
      if Str(text) and #run.notices < 12 then
        run.notices[#run.notices + 1] = text
        def:Step("game says (%s): %s", event, text)
      end
    end)
  end
  self:On("PARTY_INVITE_REQUEST", function(def, _, inviter)
    local who = Str(inviter) or "?"
    if run then
      run.invites[#run.invites + 1] = who
    end
    def:Step("invite from %s", who)
  end)
  self:HookAutoLayer()
  self:HookLayerSwap()
  self:Paint()
  if self.db.autolayer then
    self:JoinLayer() -- may need a click on some realms; BoxLine tries again from one
  end
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
  Unhush()
  ask, joined, lastAsk = nil, nil, nil
  self:LeaveLayer()
  if pad then
    pad:Hide()
  end
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
  { name = "button", help = "shows the Swap layer button (or says why it's hidden)", run = function(self)
    local why = not self.db.button and "\"Show the Swap layer button\" is off"
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
