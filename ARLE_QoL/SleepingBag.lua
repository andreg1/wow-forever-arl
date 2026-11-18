-- Sleeping Bag: reminds you to use the Cozy Sleeping Bag.
-- Based on ForeverSleepingBag by andreg1 (MIT),
-- https://github.com/andreg1/wow-forever-addons
--
-- WoW Forever's Cozy Sleeping Bag (item 211527): using it (Unroll Bag, 429961,
-- one hour cooldown) lays a bag down; resting in it (area aura 429960) grants
-- Well-Rested (429959, two hours, up to three stacks).
--
-- Reminds you, below max level, while the bag is in your bags and off
-- cooldown, when Well-Rested is missing, under three stacks, or has less than
-- refreshMinutes left: a small movable alert whose bag icon uses the bag (the
-- host's secure item button, ARLE.Secure "UseItem"), plus one chat line per
-- reminder. Hidden in combat, while dead, flying or on a flight path.
--
-- Timeline (option): while lying in the bag (area aura 429960), a bar 0-3
-- with "next stack in / 3/3 in" (or "refresh in" at 3 stacks). The timing
-- model, one stack per minute of rest counted from the last stack or
-- expiration change, is the one Forever SnackTrack shows; the code is ours.
local ADDON = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local Skin, Kit, Secure = ARLE.Skin, ARLE.UI.Kit, ARLE.Secure

local ITEM = 211527
local BUFF = 429959
local AREA = 429960
local MAX_STACKS = 3
local MAX_LEVEL = 60
local FALLBACK_ICON = 133662
local SNOOZE_MINUTES = 10

local F = {
  id = "SleepingBag",
  addon = ADDON,
  title = "Sleeping Bag",
  group = "QualityOfLife",
  command = "bag",
  commandHelp = "Cozy Sleeping Bag reminders",
  description = "Reminds you to use the Cozy Sleeping Bag when Well-Rested is missing, low or ending.",
  options = {
    { key = "chat", type = "boolean", label = "Chat message", default = true },
    { key = "timeline", type = "boolean", label = "Stack timeline while lying in the bag", default = true },
    { key = "refreshMinutes", type = "range", label = "Remind with minutes left",
      min = 1, max = 119, step = 5, default = 20, cmd = "refresh" },
    { type = "info", text = function(def) return def:StatusLine() end },
    { type = "button", label = "Show a test alert", desc = "for 20 seconds, so you can move it", nocmd = true,
      run = function(def) def:Test() end },
    ARLE.Options.Preset.ResetPosition(),
  },
}

local alert
local currentKey   -- the reminder being shown
local dismissedKey -- dismissed until the need goes away
local lastChatKey  -- chat once per reminder
local snoozeUntil
local testUntil
local missingSince -- when Well-Rested was first read as gone (it can blink out while refreshed)
local CONFIRM_MISSING = 3

-------------------------------------------------------------------------------
-- Status
-------------------------------------------------------------------------------

-- What a secret aura reads as (in combat or an instance the client can hide
-- it): there, at full stacks and no known end, so nothing is reminded about
-- a buff that can't be read. Never indexed or compared as the real one.
local HIDDEN = { applications = 3, expirationTime = 0 }

local Secret, SpellName = ARLE.Lib.IsSecret, ARLE.Lib.SpellName

-- The direct lookup first; then every buff on you, by spell id or by the
-- spell's name (the direct lookup has been seen missing a Well-Rested that was
-- up, 3 stacks, 2026-11-17). By name only when asked (Well-Rested).
local function PlayerAura(spellID, byName)
  if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
    local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellID)
    if ok and aura and Secret(aura) then
      return HIDDEN
    end
    if ok and type(aura) == "table" then
      return aura
    end
  end
  if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then
    return nil
  end
  local name = byName and SpellName(spellID)
  if name and name == SpellName(AREA) then
    name = nil -- (the bag's own aura has the same name: by id only)
  end
  for index = 1, 80 do
    local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", index, "HELPFUL")
    if not ok or not aura then
      return nil
    end
    if Secret(aura) then
      -- (can't be read: it might be this one)
    else
      local id, auraName = aura.spellId, aura.name
      if (not Secret(id) and id == spellID) or (name and not Secret(auraName) and auraName == name) then
        return aura
      end
    end
  end
end

local function CooldownRemaining(now)
  local getCooldown = (C_Container and C_Container.GetItemCooldown) or _G.GetItemCooldown
  if not getCooldown then
    return 0
  end
  local ok, start, duration, enable = pcall(getCooldown, ITEM)
  if not ok then
    return 0
  end
  if enable == 0 or enable == false then
    return math.huge
  end
  if type(start) ~= "number" or type(duration) ~= "number" or start <= 0 or duration <= 1.5 then
    return 0
  end
  return math.max(0, start + duration - now)
end

local function BagIcon()
  return ARLE.Lib.Items.GetIcon and ARLE.Lib.Items.GetIcon(ITEM) or FALLBACK_ICON
end

local function Status(now)
  local aura = PlayerAura(BUFF, true)
  local stacks = 0
  if aura then
    local applications = aura.applications
    stacks = not Secret(applications) and type(applications) == "number" and applications or MAX_STACKS
    if stacks < 1 then
      stacks = 1
    end
  end
  local owned = ARLE.Lib.Items.Count(ITEM) > 0
  local lying = PlayerAura(AREA) ~= nil
  local cooldown = owned and CooldownRemaining(now) or 0
  local expirationTime = aura and aura.expirationTime
  if Secret(expirationTime) then
    expirationTime = nil
  end
  local remaining = stacks > 0 and type(expirationTime) == "number" and expirationTime > 0
    and expirationTime - now or nil
  return {
    owned = owned,
    stacks = stacks,
    remaining = remaining,
    lying = lying,
    cooldown = cooldown,
    ready = owned and not lying and cooldown <= 0,
  }
end

local function FormatMinutes(seconds)
  local minutes = math.max(1, math.ceil(seconds / 60))
  if minutes >= 60 then
    return string.format("%dh %dm", math.floor(minutes / 60), minutes % 60)
  end
  return string.format("%dm", minutes)
end

local function StatusText(s)
  if s.stacks == 0 then
    return "Well-Rested: not active"
  end
  local text = string.format("Well-Rested: %d/%d stacks", s.stacks, MAX_STACKS)
  if s.remaining and s.remaining > 0 then
    text = text .. " (" .. FormatMinutes(s.remaining) .. " left)"
  end
  return text
end

-------------------------------------------------------------------------------
-- Timeline while lying in the bag
-------------------------------------------------------------------------------

local STACK_SECONDS = 60
local timeline, timelineTicker
local tl = {} -- stacks, expires, startedAt: when the current stack began

local function Clock(seconds)
  seconds = math.max(0, math.ceil(seconds))
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Text and bar value (0..3) for status s, or nil when not lying in the bag.
local function TimelineInfo(s, now)
  if not s.lying then
    return nil
  end
  -- A new stack or a refreshed buff starts the next minute.
  local expiresAt = s.remaining and (now + s.remaining) or 0
  if tl.stacks ~= s.stacks or math.abs((tl.expiresAt or 0) - expiresAt) > 1 then
    tl.stacks, tl.expiresAt, tl.startedAt = s.stacks, expiresAt, now
  end
  local elapsed = math.min(STACK_SECONDS, now - (tl.startedAt or now))
  local nextIn = STACK_SECONDS - elapsed
  if s.stacks >= MAX_STACKS then
    return string.format("Well-Rested %d/%d  ·  refresh in %s", MAX_STACKS, MAX_STACKS, Clock(nextIn)), MAX_STACKS
  end
  local full = nextIn + (MAX_STACKS - s.stacks - 1) * STACK_SECONDS
  return string.format("Well-Rested %d/%d  ·  next stack %s  ·  %d/%d in %s", s.stacks, MAX_STACKS, Clock(nextIn),
    MAX_STACKS, MAX_STACKS, Clock(full)), s.stacks + elapsed / STACK_SECONDS
end

function F:StatusLine()
  local s = Status(GetTime())
  local lying = TimelineInfo(s, GetTime())
  if lying then
    return lying
  end
  return StatusText(s) .. "  ·  bag " .. (s.owned and "in your bags" or "not in your bags")
    .. (s.owned and ("  ·  " .. (s.lying and "lying in it" or (s.cooldown <= 0 and "ready"
      or (s.cooldown == math.huge and "cooldown pending" or ("ready in " .. FormatMinutes(s.cooldown))))))
      or "")
end

-------------------------------------------------------------------------------
-- Alert frame (themed); the bag icon is the host's secure item button
-------------------------------------------------------------------------------

-- Kit.Movable's place functions (the alert holds a secure button, so its
-- moves wait for combat to end); the alert and the timeline share a spot.
local placeAlert, placeTimeline

local function PlaceAlert()
  if placeAlert then
    placeAlert()
  end
end

-- The alert holds a secure button, so it can only be hidden out of combat
-- (it's hidden as combat starts, before the lockdown).
local function HideAlert()
  if alert and alert:IsShown() then
    if InCombatLockdown() then
      Secure:Run(HideAlert, "SleepingBag.alert")
    else
      alert:Hide()
    end
  end
end

local function AttachUseButton()
  -- Over the icon (same spot), anchored to the alert itself.
  local C = Kit.CARD
  local use = Secure:Attach("UseItem", alert, { "TOPLEFT", C.pad + C.edge, -C.pad }, C.icon)
  if not use then
    return
  end
  use:SetAttribute("type", "item")
  use:SetAttribute("item", "item:" .. ITEM)
  F:Script(use, "OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(ITEM)
    GameTooltip:AddLine("Click to use", 0.5, 0.84, 1)
    GameTooltip:Show()
  end)
  F:Script(use, "OnLeave", GameTooltip_Hide)
end

-- A Kit.Card, every ARL popup's look.
local function BuildAlert()
  local f = Kit.Card(F, { icon = true, move = { y = 200, secure = true } })
  placeAlert = f.place
  f:AddButton("Dismiss", 52, function()
    dismissedKey = currentKey
    HideAlert()
  end)
  f:AddButton("Snooze " .. SNOOZE_MINUTES .. "m", 64, function()
    snoozeUntil = GetTime() + SNOOZE_MINUTES * 60
    HideAlert()
  end)
  alert = f
end

local function ShowAlert(message, s)
  if InCombatLockdown() then
    return
  end
  if not alert then
    BuildAlert()
  end
  AttachUseButton()
  alert.icon:SetTexture(BagIcon())
  alert:SetLines(message, nil, StatusText(s))
  alert:Show()
end

local function PlaceTimeline()
  if placeTimeline then
    placeTimeline()
  end
end

-- A Kit.Card too: its line, and the 0-3 bar under it.
local function BuildTimeline()
  local C = Kit.CARD
  local f = Kit.Card(F, { titleFont = "GameFontHighlightSmall",
    move = { y = 200, key = "position", onMoved = PlaceAlert } })
  placeTimeline = f.place
  f.bar = CreateFrame("StatusBar", nil, f)
  f.bar:SetPoint("BOTTOMLEFT", C.pad + C.edge, C.pad)
  f.bar:SetPoint("BOTTOMRIGHT", -C.pad, C.pad)
  f.bar:SetHeight(12)
  f.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  f.bar:SetStatusBarColor(0.12, 0.75, 0.62)
  f.bar:SetMinMaxValues(0, MAX_STACKS)
  f.extra = 6 + 12 -- (the bar under the line)
  local bg = f.bar:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.5)
  for i = 1, MAX_STACKS - 1 do
    local mark = f.bar:CreateTexture(nil, "OVERLAY")
    mark:SetColorTexture(1, 0.82, 0, 0.9)
    mark:SetSize(2, 12)
    mark:SetPoint("LEFT", f.bar, "LEFT", 0, 0)
    f.bar["mark" .. i] = mark
  end
  F:Script(f.bar, "OnSizeChanged", function(bar, width)
    for i = 1, MAX_STACKS - 1 do
      bar["mark" .. i]:SetPoint("LEFT", bar, "LEFT", width * i / MAX_STACKS - 1, 0)
    end
  end)
  timeline = f
end

local function HideTimeline()
  if timeline then
    timeline:Hide()
  end
  if timelineTicker then
    timelineTicker:Cancel()
    timelineTicker = nil
  end
end

-- Shown while lying in the bag (where the reminder never is).
local function UpdateTimeline()
  local now = GetTime()
  local s = Status(now)
  local text, value = TimelineInfo(s, now)
  if not text or not F.db.timeline or UnitAffectingCombat("player") or UnitIsDeadOrGhost("player")
    or (IsFlying and IsFlying()) then
    HideTimeline()
    return
  end
  if not timeline then
    BuildTimeline()
  end
  timeline:SetLines(text)
  timeline.bar:SetValue(value)
  timeline:Show()
  if not timelineTicker then
    timelineTicker = F:Ticker(0.25, UpdateTimeline)
  end
end

function F:OnResetPosition()
  PlaceAlert()
  PlaceTimeline()
end

-------------------------------------------------------------------------------
-- Evaluation
-------------------------------------------------------------------------------

local function Blocked()
  local level = UnitLevel("player")
  return (type(level) == "number" and level >= MAX_LEVEL)
    or UnitAffectingCombat("player")
    or (InCombatLockdown and InCombatLockdown())
    or UnitIsDeadOrGhost("player")
    or (IsFlying and IsFlying())
    or (UnitOnTaxi and UnitOnTaxi("player"))
end

function F:Evaluate()
  UpdateTimeline()
  local now = GetTime()
  if testUntil then
    if now < testUntil and not InCombatLockdown() then
      return
    end
    testUntil = nil
  end
  local s = Status(now)
  if s.stacks > 0 then
    missingSince = nil
  end
  local key, message
  if s.ready then
    if s.stacks == 0 then
      -- (only once it has stayed gone a few seconds: one empty read isn't enough)
      missingSince = missingSince or now
      if now - missingSince < CONFIRM_MISSING then
        self:Debug("Well-Rested reads as gone; checking again before reminding")
        self:After(CONFIRM_MISSING + 0.2, self.Evaluate)
        return
      end
      key = "missing"
      message = "Your Cozy Sleeping Bag is ready, but Well-Rested is not active."
    elseif s.remaining and s.remaining <= (self.db.refreshMinutes or 20) * 60 then
      key = "refresh"
      message = string.format("Well-Rested ends in about %d min. Use your Cozy Sleeping Bag to refresh it.",
        math.max(1, math.ceil(s.remaining / 60)))
    elseif s.stacks < MAX_STACKS then
      key = "stacks:" .. s.stacks
      message = string.format("Your Cozy Sleeping Bag is ready: Well-Rested is at %d/%d stacks.", s.stacks, MAX_STACKS)
    end
  end
  if not key then
    -- Nothing to do (bag used, on cooldown, buff full): start fresh next time.
    currentKey, dismissedKey, lastChatKey = nil, nil, nil
    HideAlert()
    return
  end
  currentKey = key
  if Blocked() or dismissedKey == key or (snoozeUntil and now < snoozeUntil) then
    HideAlert()
    return
  end
  snoozeUntil = nil
  if self.db.chat and lastChatKey ~= key then
    lastChatKey = key
    self:Print(message)
  end
  ShowAlert(message, s)
end

function F:Test()
  if InCombatLockdown() then
    return
  end
  testUntil = GetTime() + 20
  ShowAlert("Test: drag this alert to move it. It closes in 20 seconds.", Status(GetTime()))
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

local function Schedule(self)
  self:Debounce("eval", 0.3, self.Evaluate)
end

function F:OnEnable()
  for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_LEVEL_UP", "PLAYER_REGEN_ENABLED", "PLAYER_ALIVE",
    "PLAYER_UNGHOST", "BAG_UPDATE_DELAYED", "BAG_UPDATE_COOLDOWN", "PLAYER_MOUNT_DISPLAY_CHANGED" }) do
    self:On(e, Schedule)
  end
  self:On("PLAYER_REGEN_DISABLED", function()
    HideAlert()
    HideTimeline()
  end)
  self:On("PLAYER_DEAD", function()
    HideAlert()
    HideTimeline()
  end)
  self:OnUnit("UNIT_AURA", "player", Schedule)
  -- Catches the refresh window, cooldown ends, flight and taxi changes.
  self:Ticker(5, self.Evaluate)
  Schedule(self)
end

-- The UseItem button is shared: once off, hand it back clean (hidden, under
-- UIParent, no item, no tooltip scripts) so another feature doesn't inherit
-- our bag. Secure attributes and parents only change out of combat; it's
-- skipped if this was turned on again, or another feature took the button.
local function DetachUseButton()
  if not F._active then
    Secure:Detach("UseItem", alert, { "type", "item" })
  end
end

function F:OnDisable()
  currentKey, dismissedKey, lastChatKey, snoozeUntil, testUntil, missingSince = nil, nil, nil, nil, nil, nil
  HideAlert()
  HideTimeline()
  tl = {}
  -- (Secure:Run, not OutOfCombat: OutOfCombat drops work once the feature is off.)
  Secure:Run(DetachUseButton)
end

-- ForeverSleepingBagDB (per character): chat, refreshMinutes, x/y (the
-- alert's centre offset from UIParent's centre, the same shape as
-- char.position here). Its "enabled" (reminders on/off) is left out: turning
-- this feature on is the player's choice of which one runs.
function F:Import()
  local old = _G.ForeverSleepingBagDB
  if type(old) ~= "table" then
    return
  end
  if type(old.chat) == "boolean" then
    self.db.chat = old.chat
  end
  if type(old.refreshMinutes) == "number" then
    self.db.refreshMinutes = math.max(1, math.min(119, math.floor(old.refreshMinutes)))
  end
  if type(old.x) == "number" and type(old.y) == "number" then
    self.char.position = { old.x, old.y }
  end
end

function F:OnOptionChanged()
  dismissedKey, lastChatKey = nil, nil
  self:Evaluate()
end

function F:GetStatus()
  return "Active · " .. StatusText(Status(GetTime()))
end

F.commands = {
  { name = "test", help = "shows the alert for 20 seconds so you can move it", run = function(self) self:Test() end },
  { name = "status", help = "your stacks, time left and the bag's cooldown", always = true,
    run = function(self) self:Print(self:StatusLine()) end },
  { name = "reset", help = "puts the alert back in its default spot", run = function(self)
    self.char.position = nil
    self:OnResetPosition()
    self:Print("alert position reset.")
  end },
}

ARLE:RegisterModule(F)
