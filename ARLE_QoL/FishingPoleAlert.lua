-- Fishing Pole Alert: warns you when you're in combat with a fishing pole
-- equipped, with a key to put your weapons back on.
-- Based on FishingPoleAlert by andreg1 (MIT),
-- https://github.com/andreg1/wow-forever-addons
--
-- Detection: main-hand item (slot 16) is a Weapon / Fishing Pole
-- (ARLE.Lib.Items.IsFishingPole). Checked when combat starts and when gear
-- changes during combat.
--
-- Weapon swap key: addons can't change gear in combat, but a key the player
-- presses can. The host's secure button ARLE_SecureFishingSwap (binding in
-- the host's Bindings.xml, under "ARL Extensions") runs "/equipslot 16
-- item:<main>" and "/equipslot 17 item:<off>" for the last non-pole weapons
-- you wore. They are remembered out of combat, and the button's text is only
-- rewritten out of combat (attributes are locked in combat).
local ADDON = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local Items, Secure, Alert = ARLE.Lib.Items, ARLE.Secure, ARLE.UI.Alert

local MAIN, OFF = 16, 17
local POLE_ICON = 132932

local F = {
  id = "FishingPoleAlert",
  addon = ADDON,
  title = "Fishing Pole Alert",
  group = "QualityOfLife",
  command = "fish",
  commandHelp = "warns when you fight with a fishing pole equipped",
  description = "Warns when you fight with a fishing pole equipped, with a key to put your weapons back on.",
  options = {
    ARLE.Options.Preset.Alert(),
    { key = "repeatSec", type = "range", label = "Repeat every (seconds, 0 = once)",
      min = 0, max = 60, step = 2, default = 8, cmd = "repeat" },
    { type = "header", label = "Weapon swap" },
    { type = "keybind", binding = Secure:Binding("FishingSwap"), label = "Put my weapons back on" },
    { type = "info", text = function(def) return "Remembered weapons: " .. def:WeaponsText() end },
    { type = "button", label = "Test the alert", desc = "shows it for 5 seconds", nocmd = true,
      run = function(def) def:Test() end },
  },
}

local lastNag = 0

local function PoleEquipped()
  local id = GetInventoryItemID("player", MAIN)
  if id and Items.IsFishingPole(id) then
    return id
  end
end

function F:WeaponsText()
  local w = self.char
  if not w.main then
    return "none yet (wear your weapons once)"
  end
  return Items.Name(w.main) .. (w.off and (" + " .. Items.Name(w.off)) or "")
end

-------------------------------------------------------------------------------
-- Weapon swap button
-------------------------------------------------------------------------------

local function SwapText()
  local w = F.char
  if not w.main then
    return ""
  end
  local text = "/equipslot " .. MAIN .. " item:" .. w.main
  if w.off then
    text = text .. "\n/equipslot " .. OFF .. " item:" .. w.off
  end
  return text
end

local function UpdateSwapButton()
  Secure:SetAttributes("FishingSwap", { type = "macro", macrotext = F._active and SwapText() or "" })
end

-- Remembers the weapons you wear when they aren't a pole (out of combat only,
-- so the button text matches what is remembered).
local function RememberWeapons()
  if InCombatLockdown() then
    return
  end
  local main = GetInventoryItemID("player", MAIN)
  if not main or Items.IsFishingPole(main) then
    return
  end
  local off = GetInventoryItemID("player", OFF)
  if F.char.main ~= main or F.char.off ~= off then
    F.char.main, F.char.off = main, off
    UpdateSwapButton()
  end
end

-------------------------------------------------------------------------------
-- Alert
-------------------------------------------------------------------------------

local function SubText()
  if not F.char.main then
    return "Unequip it! (wear your weapon once so the swap key knows it)"
  end
  local key = Secure:BoundKey("FishingSwap")
  if key then
    return string.format("Press |cffffff00%s|r for %s", key, F:WeaponsText())
  end
  return "Swap to " .. F:WeaponsText() .. "  |cffaaaaaa(bind a key: /arl open fish)|r"
end

local WARNING = "FISHING POLE EQUIPPED!"

local function ShowAlert(poleID, duration)
  local _, _, _, _, icon = Items.GetInfoInstant and Items.GetInfoInstant(poleID)
  local shown = Alert:IsShown(F)
  F:Alert({ text = "Fishing pole equipped!", sub = SubText(), icon = icon or POLE_ICON, color = { 1, 0.25, 0.25 },
    pulse = true, warning = WARNING, duration = duration })
  if not shown then
    lastNag = GetTime()
  end
end

-- combatStarting: from PLAYER_REGEN_DISABLED, where InCombatLockdown() isn't
-- true yet.
local function Check(combatStarting)
  local pole = PoleEquipped()
  if pole and (combatStarting or InCombatLockdown() or UnitAffectingCombat("player")) then
    ShowAlert(pole)
  else
    Alert:Hide(F)
  end
end

-- No duration on the test alert: its timer would also hide a real alert
-- that came up meanwhile. After 5 s the normal check decides instead (and
-- keeps it up if you really are fighting with a pole). While off, nothing
-- would run that check, so the alert times out by itself.
function F:Test()
  if not self._active then
    ShowAlert(PoleEquipped() or 6256, 5) -- 6256 = Fishing Pole
    return
  end
  ShowAlert(PoleEquipped() or 6256)
  self:After(5, function()
    Check()
  end)
end

-- FishingPoleAlertDB (per character): main / off (the last non-pole
-- weapons), sound, warning, flash, repeatSec. Its "enabled" is left out:
-- turning this feature on is the player's choice of which one runs.
function F:Import()
  local old = _G.FishingPoleAlertDB
  if type(old) ~= "table" then
    return
  end
  if type(old.main) == "number" and old.main > 0 then
    self.char.main = old.main
    self.char.off = (type(old.off) == "number" and old.off > 0) and old.off or nil
  end
  local map = { sound = "alertSound", warning = "alertWarning", flash = "alertFlash" }
  for from, to in pairs(map) do
    if type(old[from]) == "boolean" then
      self.db[to] = old[from]
    end
  end
  if type(old.repeatSec) == "number" and old.repeatSec >= 0 then
    self.db.repeatSec = math.min(60, old.repeatSec)
  end
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function F:OnEnable()
  UpdateSwapButton()
  self:On("PLAYER_ENTERING_WORLD", function()
    RememberWeapons()
    Check()
  end)
  self:On("PLAYER_EQUIPMENT_CHANGED", function(_, _, slot)
    if slot == MAIN or slot == OFF then
      RememberWeapons()
      Check()
    end
  end)
  self:On("PLAYER_REGEN_DISABLED", function()
    Check(true)
  end)
  self:On("PLAYER_REGEN_ENABLED", function()
    RememberWeapons()
    Alert:Hide(self)
  end)
  self:On("UPDATE_BINDINGS", function()
    if Alert:IsShown(self) then
      local bar = Alert:Frame(self)
      bar.sub:SetText(SubText())
      bar:Fit()
    end
  end)
  -- Repeat the sound / raid warning while the alert stays up.
  self:Ticker(1, function()
    local every = tonumber(self.db.repeatSec) or 0
    if Alert:IsShown(self) and every > 0 and GetTime() - lastNag >= every then
      lastNag = GetTime()
      Alert:Nag(self, WARNING)
    end
  end)
  RememberWeapons()
end

function F:OnDisable()
  Alert:Hide(self)
  UpdateSwapButton()
end

function F:GetStatus()
  local key = Secure:BoundKey("FishingSwap")
  return "Active · swap key " .. (key or "not bound") .. " · " .. self:WeaponsText()
end

F.commands = {
  { name = "test", help = "shows the alert for 5 seconds", run = function(self) self:Test() end },
}

ARLE:RegisterModule(F)
