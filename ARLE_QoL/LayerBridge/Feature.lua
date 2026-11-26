-- Layer Bridge: turning it on and off, commands, the status line, the report,
-- and what's taken over from Layer Anarchy and from Layer Bridge before 0.14.0.
-- See Core.lua for the design.
local _, ns = ...
local LB = ns.LayerBridge
if not LB then
  return
end
local ARLE = _G.ARLExtensions
local F = LB.F
local Lib = ARLE.Lib
local Plain, Str = Lib.Plain, Lib.Str

local CHANNEL_DELAY = 10 -- s after enabling before networks join channels (the player's own first)
local LA_DEFAULTS = { help = true, hostWhileFlying = true, auto = true, sound = false, askAutoLayer = true,
  invitesPerHour = 0 }
local LA_KEYS = { help = "host", hostWhileFlying = "hostWhileFlying", auto = "auto", sound = "sound",
  askAutoLayer = "askAutoLayer", invitesPerHour = "invitesPerHour" }

-------------------------------------------------------------------------------
-- Addon messages: one router for every network's prefixes
-------------------------------------------------------------------------------

local byPrefix = {}

local function Router(_, prefix, text, chatType, sender)
  prefix = Plain(prefix)
  local net = prefix and byPrefix[prefix]
  if not net then
    return
  end
  sender = Str(Plain(sender))
  local key = LB.Key(sender)
  if not key or key == LB.MyKey() then
    return
  end
  LB.Heard(key)
  LB.Stats.Heard(net.id, key)
  if LB.NetOn(net) then
    LB.CallNet(net, "OnAddon", prefix, Plain(text), Plain(chatType), sender, key)
  end
end

-------------------------------------------------------------------------------
-- Data from Layer Bridge before 0.14.0
-------------------------------------------------------------------------------

local function OldMacro(body)
  return type(body) == "string" and body:match("^/%d+ inv layer$") ~= nil
end

function F:Migrate()
  local c, sh = self.char, self.shared
  -- The LayerSwap book: [First Surname] = { at, host, from } -> books.layerswap
  if type(sh.book) == "table" then
    local book = LB.Book("layerswap")
    for name, e in pairs(sh.book) do
      if type(name) == "string" and type(e) == "table" and type(e.at) == "number" then
        local key = LB.Key(name)
        local have = key and book.entries[key]
        if key and (not have or have.at < e.at) then
          book.entries[key] = { name = Str(e.from) or name, at = e.at, host = e.host and true or nil }
        end
      end
    end
    sh.book = nil
  end
  -- The AutoLayer button's "ARL Layer" macro and its secure button's text.
  local name = c.layerMacro
  if name then
    ARLE.Secure:Run(function()
      if ARLE.Macro:Delete(name, OldMacro) then
        LB.Log("deleted the old macro", name)
      end
      F.char.layerMacro = nil
    end)
  end
  -- A "layer" channel an ARL before 0.6 joined (the AutoLayer network keeps
  -- its own channels now, in char.channels).
  if c.joinedLayer then
    c.joinedLayer = nil
    c.channels.layer = c.channels.layer or "autolayer"
  end
  c.searched, c.whoRound, c.alInvitedAt, c.lineAt, c.joins = nil, nil, nil, nil, nil
end

-- Layer Anarchy is loaded (the feature stays paused): copy its settings and
-- the hosts it has met, once a session.
function F:Import()
  local db = rawget(_G, "LayerAnarchyDB")
  if type(db) ~= "table" then
    return
  end
  local settings = type(db.settings) == "table" and db.settings or {}
  for theirs, ours in pairs(LA_KEYS) do
    local v = settings[theirs]
    if v == nil then
      v = LA_DEFAULTS[theirs]
    end
    if type(v) == type(LA_DEFAULTS[theirs]) then
      self.db[ours] = v
    end
  end
  local books = type(self.shared.books) == "table" and self.shared.books or {}
  self.shared.books = books
  for id, store in pairs(type(db.nets) == "table" and db.nets or {}) do
    if type(id) == "string" and type(store) == "table" and type(store.book) == "table" then
      books[id] = type(books[id]) == "table" and books[id] or {}
      for key, e in pairs(store.book) do
        if type(key) == "string" and type(e) == "table" and type(e.at) == "number" and type(e.name) == "string" then
          local have = books[id][key]
          if not have or (have.at or 0) < e.at then
            books[id][key] = { name = e.name, at = e.at, host = e.host and true or nil,
              zone = tonumber(e.zone) }
          end
        end
      end
    end
  end
end

-------------------------------------------------------------------------------
-- The Swap key binding: the host's secure button (a click there is a
-- hardware event, which the /who needs); its macro is empty, the swap runs
-- in PostClick.
-------------------------------------------------------------------------------

local function ArmKey()
  ARLE.Secure:SetAttributes("LayerSwap", { macro = false, macrotext = "" })
  ARLE.Secure:Run(function()
    local b = ARLE.Secure:Button("LayerSwap")
    if b and F._active then
      F:Script(b, "PostClick", function()
        LB.Swap.Click("key")
      end)
    end
  end, "LayerBridge.key")
end

local function DisarmKey()
  ARLE.Secure:Run(function()
    local b = ARLE.Secure:Button("LayerSwap")
    if b and not F._active then
      ARLE.Secure:Detach("LayerSwap", b:GetParent(), { "macro", "macrotext" })
    end
  end, "LayerBridge.key")
end

-------------------------------------------------------------------------------
-- On / off
-------------------------------------------------------------------------------

function F:OnEnable()
  LB.ResetBus()
  LB.ResetCore()
  wipe(LB.log)
  self.char.channels = type(self.char.channels) == "table" and self.char.channels or {}
  self:Migrate()
  wipe(byPrefix)
  for _, net in ipairs(LB.nets) do
    net.started = false
    for _, prefix in ipairs(net.prefixes or {}) do
      byPrefix[prefix] = net
      if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, prefix)
      end
    end
  end
  LB.On("CHAT_MSG_ADDON", Router)
  LB.On("CHAT_MSG_ADDON_LOGGED", Router)
  LB.On("CHAT_MSG_CHANNEL_NOTICE", LB.ChannelNotice)
  LB.On("CHAT_MSG_CHANNEL_NOTICE_USER", LB.ChannelNotice)
  LB.On("CHANNEL_PASSWORD_REQUEST", LB.PasswordRequest)
  LB.Filters(true)
  LB.Swap.Init()
  for _, net in ipairs(LB.nets) do
    local native = LB.Native(net)
    if native then
      self:Debug("%s left to %s", net.name, native)
    else
      LB.CallNet(net, "Init")
      net.started = true
    end
  end
  -- Leftover channels of networks that are off now.
  for name, owner in pairs(self.char.channels) do
    local net = LB.Net(owner)
    if not net or not LB.NetOn(net) then
      if LB.ChannelId(name) then
        pcall(LeaveChannelByName, name)
      end
      self.char.channels[name] = nil
    end
  end
  self:After(CHANNEL_DELAY, function()
    LB.Each("OnChannels")
  end)
  ArmKey()
  self:HookAutoLayer()
  LB.UI.Init()
  self:Ticker(0.2, function()
    LB.UI.Hover()
  end)
  self:Ticker(5, function()
    LB.Refresh()
  end)
end

-- AutoLayer's hop button (and "/autolayer req") end in SendLayerRequest: from
-- the button that's a click, so our /who still works. Its press asks our
-- networks too (AutoLayer hosts are its own business).
function F:HookAutoLayer()
  local al = ARLE:IsAddonLoaded("AutoLayer") and rawget(_G, "AutoLayer")
  if type(al) ~= "table" or self.hookedAL then
    return
  end
  self.hookedAL = self:Hook(al, "SendLayerRequest", function()
    if not LB.Swap.Busy() and not LB.Swap.Blocked() and not LB.Limit.Left() then
      LB.Swap.Start("AutoLayer")
    end
  end)
end

function F:OnDisable()
  LB.Swap.Shutdown()
  for _, net in ipairs(LB.nets) do
    if net.started then
      LB.CallNet(net, "Stop")
    end
    net.started = false
  end
  LB.LeaveChannels(nil)
  LB.Filters(false)
  if LB.Unhush then
    LB.Unhush()
  end
  LB.UI.Hide()
  DisarmKey()
end

function F:OnOptionChanged(key)
  local net
  for _, n in ipairs(LB.nets) do
    if n.key == key then
      net = n
    end
  end
  if net then
    if net.Sync then
      LB.CallNet(net, "Sync")
    elseif LB.NetOn(net) then
      LB.CallNet(net, "OnChannels")
    end
  elseif key == "host" or key == "askAutoLayer" then
    local al = LB.Net("autolayer")
    if al and al.started then
      LB.CallNet(al, "Sync")
    end
    if key == "host" and F.db.host then
      local flh = LB.Net("flh")
      if flh and LB.NetOn(flh) then
        LB.CallNet(flh, "OnChannels")
      end
    end
  end
  LB.Refresh()
end

function F:OnResetPosition()
  LB.UI.Placed()
end

-------------------------------------------------------------------------------
-- Status, report, commands
-------------------------------------------------------------------------------

function F:GetStatus()
  if not self._active then
    return "Off"
  end
  local v = LB.View()
  local nets = {}
  for _, net in ipairs(LB.nets) do
    local native = LB.Native(net)
    if native then
      nets[#nets + 1] = net.name .. " (its own addon)"
    elseif LB.NetOn(net) then
      local seen = LB.Stats.Net(net)
      nets[#nets + 1] = net.name .. (seen > 0 and (" " .. seen) or "")
    end
  end
  local n, limit = LB.Limit.ThisHour()
  return string.format("Active · %s · %s · networks: %s · %d of %d swaps this hour", v.label,
    tostring(v.status or "idle"), #nets > 0 and table.concat(nets, ", ") or "none", n, limit)
end

function F:ReportDetails()
  local out = {}
  local sw = {}
  for _, k in ipairs({ "host", "auto", "askAutoLayer", "avoidVisited", "hostWhileFlying", "button", "minimized" }) do
    sw[#sw + 1] = k .. " " .. tostring(self.db[k])
  end
  out[#out + 1] = "switches: " .. table.concat(sw, ", ") .. ", invitesPerHour " .. tostring(self.db.invitesPerHour)
  out[#out + 1] = string.format("%s (epoch %d), zone %s, restricted realm %s, in a group %s", LB.Label(), LB.Epoch(),
    tostring(LB.Zone()), tostring(LB.Restricted()), tostring(IsInGroup()))
  for _, net in ipairs(LB.nets) do
    local seen, talking, hosts = LB.Stats.Net(net)
    out[#out + 1] = string.format("network %s: %s, seen %d, talking %d, hosts %s", net.name,
      LB.Native(net) and ("left to " .. LB.Native(net)) or (LB.NetOn(net) and "on" or "off"), seen, talking,
      tostring(hosts or "-"))
  end
  local chans = {}
  for name, owner in pairs(self.char.channels or {}) do
    chans[#chans + 1] = string.format("%s (%s, /%s)", name, tostring(owner), tostring(LB.ChannelId(name) or "-"))
  end
  out[#out + 1] = "channels: " .. (#chans > 0 and table.concat(chans, ", ") or "none")
  local n, limit = LB.Limit.ThisHour()
  local left = LB.Limit.Left()
  out[#out + 1] = string.format("swaps this hour %d of %d%s", n, limit,
    left and (", waiting " .. math.ceil(left) .. " s") or "")
  local history = LB.History.List()
  out[#out + 1] = string.format("history (%d):", #history)
  for _, e in ipairs(history) do
    out[#out + 1] = string.format("  %s zone %s, id %s, via %s, %s", LB.Label(e.epoch), tostring(e.zone),
      tostring(e.id or "-"), tostring(e.host or "-"), LB.Ago(e.at))
  end
  if LB.steps then
    out[#out + 1] = "last swap (" .. tostring(LB.steps.via) .. "):"
    for _, l in ipairs(LB.steps.lines) do
      out[#out + 1] = "  " .. l
    end
  end
  for i = math.min(#LB.log, 15), 1, -1 do
    out[#out + 1] = "log: " .. LB.log[i]
  end
  return out
end

F.commands = {
  { name = "swap", aliases = { "ask" }, help = "swap layer (again: ask more players, or stop)",
    run = function() LB.Swap.Click("command") end },
  { name = "stop", help = "stops the swap in progress", run = function(self)
    if LB.Swap.Busy() then
      LB.Swap.Stop()
    else
      self:Print("no swap in progress.")
    end
  end },
  { name = "last", help = "every step of the last swap", always = true, run = function(self)
    if not LB.steps then
      self:Print("no swap yet this session.")
      return
    end
    self:Print("last swap (" .. tostring(LB.steps.via) .. "), step by step:")
    for _, l in ipairs(LB.steps.lines) do
      print("   " .. l)
    end
  end },
  { name = "log", help = "the last asks, invites and moves", always = true, run = function(self)
    if #LB.log == 0 then
      self:Print("nothing logged yet this session.")
      return
    end
    for i = #LB.log, 1, -1 do
      print("   " .. LB.log[i])
    end
  end },
  { name = "networks", help = "opens the Networks drawer", run = function()
    LB.UI.Refresh()
    LB.UI.ToggleDrawer("network")
  end },
  { name = "history", help = "opens the list of layers you've been on", run = function()
    LB.UI.Refresh()
    LB.UI.ToggleDrawer("history")
  end },
  { name = "button", aliases = { "where" }, help = "shows the box (or says why it's hidden)", run = function(self)
    if self.db.minimized then
      ARLE:SetOption(self.id, "minimized", false)
    end
    LB.UI.Refresh()
    local shown, box = LB.UI.Shown()
    if self.db.button == false then
      self:Print("the box is hidden: \"Show the Layer Bridge box\" is off.")
    elseif LB.InInstance() then
      self:Print("the box is hidden in instances.")
    elseif shown and box then
      local x, y = box:GetCenter()
      self:Print(string.format("the box is at %d, %d (Reset position brings it back).", x or -1, y or -1))
    else
      self:Print("the box couldn't be shown; /arl errors may say why.")
    end
  end },
}

ARLE:RegisterModule(F)
