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

local comms = CreateFrame("Frame")
comms:RegisterEvent("CHAT_MSG_ADDON")
comms:SetScript("OnEvent", function(_, _, prefix, message, channel, sender)
  if prefix ~= PREFIX or not ARLE:IsMember() then
    return
  end
  local from = ARLE:ShortName(sender)
  if from == ARLE:ShortName(UnitName("player")) then
    return
  end
  if type(message) ~= "string" then
    return
  end
  local kind, payload = message:match("^(%w+)\t(.*)$")
  local list = kind and ARLE.comm[kind]
  if list then
    for _, fn in ipairs({ unpack(list) }) do
      local ok, err = pcall(fn, from, payload, channel)
      if not ok then
        geterrorhandler()(err)
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
