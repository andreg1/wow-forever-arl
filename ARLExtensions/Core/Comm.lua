-- Addon messages: one prefix for the whole suite. A message is
-- "<kind>\t<payload>"; handlers are registered per kind. Only guild members
-- send or read anything. Sends are spaced out to stay under the client's
-- addon message throttle.
local _, ns = ...
local ARLE = ns.ARLE

local PREFIX = "ARLE"
ARLE.commPrefix = PREFIX
ARLE.comm = {}

local SendAddon = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or _G.SendAddonMessage
local RegisterPrefix = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or _G.RegisterAddonMessagePrefix
if RegisterPrefix then
  RegisterPrefix(PREFIX)
end

-- Several handlers may listen to one kind (a feature's next to a built-in's).
function ARLE:RegisterComm(kind, fn)
  local list = self.comm[kind] or {}
  self.comm[kind] = list
  for _, f in ipairs(list) do
    if f == fn then
      return
    end
  end
  list[#list + 1] = fn
end

function ARLE:UnregisterComm(kind, fn)
  local list = self.comm[kind]
  if not list then
    return
  end
  for i = #list, 1, -1 do
    if not fn or list[i] == fn then
      table.remove(list, i)
    end
  end
  if #list == 0 then
    self.comm[kind] = nil
  end
end

-- The server allows a burst of about 10 addon messages per prefix, then
-- about one a second. A token bucket keeps under that; a send the client
-- reports as throttled is put back and retried a second later.
local BURST, REFILL, MAX_QUEUE = 8, 1, 200
local THROTTLED = {}
if Enum and Enum.SendAddonMessageResult then
  local r = Enum.SendAddonMessageResult
  for _, k in ipairs({ "AddonMessageThrottle", "ChannelThrottle" }) do
    if r[k] then
      THROTTLED[r[k]] = true
    end
  end
end
local queue, pumping = {}, false
local tokens, lastRefill = BURST, 0

local function Pump()
  local now = GetTime()
  tokens = math.min(BURST, tokens + (now - lastRefill) * REFILL)
  lastRefill = now
  local m = queue[1]
  if not m then
    pumping = false
    return
  end
  if tokens < 1 then
    C_Timer.After((1 - tokens) / REFILL, Pump)
    return
  end
  local ok, result = pcall(SendAddon, PREFIX, m[1], m[2], m[3])
  if ok and THROTTLED[result] then
    tokens = 0
    C_Timer.After(1, Pump)
    return
  end
  table.remove(queue, 1)
  tokens = tokens - 1
  C_Timer.After(0.05, Pump)
end

-- channel: "GUILD", "PARTY", "INSTANCE_CHAT" or "WHISPER" (with target).
function ARLE:Send(kind, payload, channel, target)
  if not self:IsMember() or not SendAddon then
    return
  end
  local msg = kind .. "\t" .. (payload or "")
  if #msg > 255 then
    self:Print("Internal: message too long for " .. kind)
    return
  end
  if #queue >= MAX_QUEUE then
    return
  end
  queue[#queue + 1] = { msg, channel, target }
  if not pumping then
    pumping = true
    Pump()
  end
end

-- Sends a list in as few messages as fit: "<head>~<part>~<total>~a;b;c".
function ARLE:SendChunks(kind, head, items, sep, channel, target)
  sep = sep or ";"
  local room = 255 - #kind - 1 - #head - #"~99~99~"
  local chunks, chunk = {}, ""
  for _, item in ipairs(items) do
    if chunk ~= "" and #chunk + #item + 1 > room then
      chunks[#chunks + 1] = chunk
      chunk = ""
    end
    chunk = chunk == "" and item or (chunk .. sep .. item)
  end
  chunks[#chunks + 1] = chunk
  for i, c in ipairs(chunks) do
    self:Send(kind, head .. "~" .. i .. "~" .. #chunks .. "~" .. c, channel, target)
  end
end

-- The group channel to use right now, or nil when not in a group.
function ARLE:GroupChannel()
  if IsInGroup and LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
    return "INSTANCE_CHAT"
  end
  if IsInRaid and IsInRaid() then
    return "RAID"
  end
  if IsInGroup and IsInGroup() then
    return "PARTY"
  end
end

-- "Name" for this realm, "Name-Realm" for others: the same form for roster
-- names, unit names and message senders.
function ARLE:ShortName(name)
  if not name then
    return nil
  end
  if Ambiguate then
    return Ambiguate(name, "none")
  end
  return (name:gsub("%-" .. (GetRealmName and GetRealmName():gsub("[%s%-]", "") or "") .. "$", ""))
end

-- Our own name as senders carry it: on Forever UnitName gives the first name
-- and the surname apart, and messages come from "First Surname".
function ARLE:MyName()
  return ARLE.Lib.UnitFullName("player") or UnitName("player")
end

-- A unit's name in the form addon messages come from: "First Surname" on
-- Forever (UnitName gives the two apart; GetUnitName(unit, true) only the
-- first), with "-Realm" for another realm. Every name a feature keys data by
-- uses this form, so a sender's messages land where the group list looks.
function ARLE:UnitShortName(unit)
  local full = ARLE.Lib.UnitFullName(unit)
  local named = GetUnitName and ARLE.Lib.Str(GetUnitName(unit, true))
  if not full then
    return named and self:ShortName(named) or nil
  end
  local realm = named and named:match("%-([^%-]+)$")
  return self:ShortName(realm and (full .. "-" .. realm) or full)
end

-- The group unit a name (short form, with or without the surname) belongs
-- to, and that member's name as UnitShortName gives it; nil if none.
function ARLE:GroupMember(name)
  if not name then
    return nil
  end
  local raid = IsInRaid and IsInRaid()
  local loose, looseKey
  for i = 1, raid and 40 or 4 do
    local unit = (raid and "raid" or "party") .. i
    if UnitExists(unit) and not UnitIsUnit(unit, "player") then
      local key = self:UnitShortName(unit)
      local first = ARLE.Lib.Str(UnitName(unit))
      local named = GetUnitName and ARLE.Lib.Str(GetUnitName(unit, true))
      if key == name or first == name or (named and self:ShortName(named) == name)
        or (key and self:ShortName(key) == name) then
        return unit, key
      end
      -- (the client may know only a member's first name while their
      -- messages carry the surname: match on the first name then)
      if first and not loose and name:match("^([^%s%-]+)") == first then
        loose, looseKey = unit, key
      end
    end
  end
  if loose then
    return loose, looseKey
  end
end

-- A sender in our party or raid (short name).
function ARLE:InMyGroup(name)
  return self:GroupMember(name) ~= nil
end

local comms = CreateFrame("Frame")
comms:RegisterEvent("CHAT_MSG_ADDON")
comms:SetScript("OnEvent", function(_, _, prefix, message, channel, sender)
  if prefix ~= PREFIX or not ARLE:IsMember() then
    return
  end
  if type(message) ~= "string" or type(sender) ~= "string" then
    return
  end
  local from = ARLE:ShortName(sender)
  if from == ARLE:ShortName(ARLE:MyName()) or from == ARLE:ShortName(UnitName("player")) then
    return
  end
  -- A group member is named the way the group list names them, whatever
  -- form the client gave the sender in (with or without the surname).
  local _, key = ARLE:GroupMember(from)
  from = key or from
  -- Whispers can come from anyone on the realm: only guildmates and the
  -- group are heard (GUILD, PARTY and RAID messages already are just them).
  if channel == "WHISPER" and not (ARLE:InMyGroup(from) or ARLE:IsGuildmate(from)) then
    return
  end
  local kind, payload = message:match("^(%w+)\t(.*)$")
  local list = kind and ARLE.comm[kind]
  if list then
    for _, fn in ipairs({ unpack(list) }) do
      local ok, err = pcall(fn, from, payload, channel)
      if not ok then
        ARLE.Debug:Record(nil, err)
      end
    end
  end
end)

-- Whether name (short form) is in our guild's roster. Messages on the
-- GUILD channel can only come from members; whispers can come from anyone.
function ARLE:IsGuildmate(name)
  if not name or not GetNumGuildMembers then
    return false
  end
  for i = 1, GetNumGuildMembers() or 0 do
    local n = GetGuildRosterInfo(i)
    if n and self:ShortName(n) == name then
      return true
    end
  end
  return false
end

-------------------------------------------------------------------------------
-- Party presence: who in the group runs ARL, which version, and what it can
-- share. Every member's client (any feature on or off) sends
--   AP <version>~<flags>      flags: j = DungeonJournal installed,
--                             f = Forever Leveling BiS installed,
--                             d = Dungeon Helper on, s = shares its loot numbers
-- to the group when it joins one, when the group's members change, after a
-- /reload in a group, and once in answer to a member it hadn't heard from, so
-- the Dungeon Helper can say why a partymate has no numbers (no ARL, an old
-- one, no Leveling BiS...). Clients older than 0.10.0 send nothing.
-------------------------------------------------------------------------------

ARLE.partyInfo = {} -- member name (UnitShortName form) -> { version, flb, fdj, dh, share, at }

local presenceSentAt, presenceRoster = -math.huge, nil

local function Flags()
  local B = ARLE.Bridge or {}
  local fdj = B.FDJ and B.FDJ() and true or false
  local flb = B.FLB and B.FLB() and true or false
  local dh = ARLE.modules and ARLE.modules.BiSDungeonHelper
  dh = dh and dh._active and true or false
  local share = fdj and flb and (dh or ARLE:SharesLoot())
  return (fdj and "j" or "") .. (flb and "f" or "") .. (dh and "d" or "") .. (share and "s" or "")
end

-- Whether this client answers loot questions with the Dungeon Helper off
-- (Settings: "Share my Leveling BiS numbers", on unless turned off).
function ARLE:SharesLoot()
  return not (self.db and self.db.shareLoot == false)
end

function ARLE:SendPresence()
  local channel = self:GroupChannel()
  if not channel or not self:IsMember() then
    return
  end
  presenceSentAt = GetTime()
  self:Send("AP", tostring(self.version or "0") .. "~" .. Flags(), channel)
end

-- Sent a moment from now, once per burst.
local presenceQueued = false
function ARLE:QueuePresence(delay)
  if presenceQueued then
    return
  end
  presenceQueued = true
  C_Timer.After(delay or 1.5, function()
    presenceQueued = false
    local ok, err = pcall(ARLE.SendPresence, ARLE)
    if not ok then
      ARLE.Debug:Record(nil, err)
    end
  end)
end

-- What a partymate's ARL told us, or nil (no ARL, or older than 0.10.0).
function ARLE:PartyInfo(name)
  return name and self.partyInfo[name] or nil
end

ARLE:RegisterComm("AP", function(sender, payload, channel)
  if channel == "GUILD" or channel == "WHISPER" or not ARLE:InMyGroup(sender) then
    return
  end
  local version, flags = tostring(payload or ""):match("^([%d%.]+)~(%a*)$")
  if not version then
    return
  end
  local new = ARLE.partyInfo[sender] == nil
  ARLE.partyInfo[sender] = {
    version = version,
    fdj = flags:find("j", 1, true) ~= nil,
    flb = flags:find("f", 1, true) ~= nil,
    dh = flags:find("d", 1, true) ~= nil,
    share = flags:find("s", 1, true) ~= nil,
    at = GetTime(),
  }
  -- A member we hadn't heard from may not have heard from us either.
  if new and GetTime() - presenceSentAt > 3 then
    ARLE:QueuePresence(1 + math.random() * 2)
  end
end)

local function RosterKey()
  local names = {}
  local raid = IsInRaid and IsInRaid()
  for i = 1, raid and 40 or 4 do
    local unit = (raid and "raid" or "party") .. i
    if UnitExists(unit) and not UnitIsUnit(unit, "player") then
      names[#names + 1] = ARLE:UnitShortName(unit) or "?"
    end
  end
  table.sort(names)
  return table.concat(names, ","), names
end

local presence = CreateFrame("Frame")
presence:RegisterEvent("GROUP_ROSTER_UPDATE")
presence:RegisterEvent("PLAYER_ENTERING_WORLD")
local rosterQueued = false
presence:SetScript("OnEvent", function(_, event, isLogin, isReload)
  if event == "PLAYER_ENTERING_WORLD" then
    if isLogin or isReload then
      presenceRoster = nil
    end
  end
  if rosterQueued then
    return
  end
  rosterQueued = true
  -- (roster events come in bursts; a fresh login waits for the guild check)
  C_Timer.After(event == "PLAYER_ENTERING_WORLD" and 6 or 2, function()
    rosterQueued = false
    local ok, err = pcall(function()
      local key, names = RosterKey()
      local keep = {}
      for _, n in ipairs(names) do
        keep[n] = true
      end
      for name in pairs(ARLE.partyInfo) do
        if not keep[name] then
          ARLE.partyInfo[name] = nil
        end
      end
      if key ~= presenceRoster then
        presenceRoster = key
        if key ~= "" then
          ARLE:SendPresence()
        end
      end
    end)
    if not ok then
      ARLE.Debug:Record(nil, err)
    end
  end)
end)
