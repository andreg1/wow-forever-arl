-- PallyPower Auto-Hide: PallyPower's buttons only show while a blessing is
-- missing or one ends soon.
--
-- PallyPower (Forever port) is all rights reserved, so none of its code is
-- used; only its public surfaces:
--   * self:Wrap(PallyPower, "UpdateButton"): PallyPower works out each class
--     button there and returns its numbers (class / special blessing time
--     left, players who have, need a Greater, need a normal one). We pass the
--     call through untouched and keep a copy of those numbers.
--   * self:Wrap(PallyPower, "ButtonsUpdate"): it calls UpdateButton for every
--     class with players, on every aura / roster change and once a second
--     while blessings are up. The copy is cleared before it runs (a class
--     that left keeps no numbers) and the decision is made after.
--   * PallyPowerFrame: the parent of all its buttons, which PallyPower itself
--     never shows or hides (it shows and hides the buttons inside). We hide
--     that one frame. It holds secure buttons, so it's changed only out of
--     combat (ARLE.Secure:Run); in combat it stays as it was.
-- Shown again when: a player needs a blessing, one ends within the set
-- minutes (counted on by a ticker between PallyPower's updates), PallyPower's
-- frame is unlocked (being placed), we have no numbers yet, or the feature
-- goes off.
local ADDON = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local Lib = ARLE.Lib

local NONE = 9999 -- PallyPower's "no such blessing found" time
local TICK = 5 -- seconds between our own checks (time passes between its updates)

local F = {
  id = "PallyPowerHide",
  addon = ADDON,
  title = "PallyPower Auto-Hide",
  group = "PallyPower",
  extends = "PallyPower",
  command = "pally",
  commandHelp = "hides PallyPower's buttons while every blessing is up",
  description = "Hides PallyPower's buttons while nobody needs a blessing and none ends soon. "
    .. "They come back on their own (out of combat) when someone needs one.",
  options = {
    { type = "info", text = function(def) return def:GetStatus() end },
    { key = "minutes", type = "range", label = "Show it when a blessing ends within (minutes)",
      min = 1, max = 30, step = 1, default = 5, cmd = "minutes" },
    { key = "showUnlocked", type = "boolean", label = "Keep it shown while PallyPower's frame is unlocked",
      default = true, cmd = "unlocked",
      desc = "So you can still move it: lock it again in PallyPower's settings to let it hide." },
  },
}

local byClass = {} -- [classID] = { need = n, endsAt = GetTime() + seconds left, or nil }
local updatedAt -- GetTime() of PallyPower's last ButtonsUpdate
local hidden = false -- what we last asked the frame to be
local why = "waiting for PallyPower's first update"

local function Frame()
  local f = _G.PallyPowerFrame
  return type(f) == "table" and f.IsShown and f or nil
end

local function PP()
  local pp = _G.PallyPower
  return type(pp) == "table" and pp or nil
end

local function Unlocked()
  local pp = PP()
  local display = pp and type(pp.opt) == "table" and type(pp.opt.display) == "table" and pp.opt.display
  return display and display.frameLocked == false
end

local function Plain(n)
  n = Lib.Plain(n)
  return type(n) == "number" and n or nil
end

-- Whether PallyPower should be shown now, and why (for the status line).
function F:Wanted()
  if self.db.showUnlocked ~= false and Unlocked() then
    return true, "PallyPower's frame is unlocked"
  end
  if not updatedAt or not next(byClass) then
    return true, "no blessing numbers from PallyPower yet"
  end
  local now, need, soonest = GetTime(), 0, nil
  for _, c in pairs(byClass) do
    need = need + c.need
    if c.endsAt and (not soonest or c.endsAt < soonest) then
      soonest = c.endsAt
    end
  end
  if need > 0 then
    return true, string.format("%d %s a blessing", need, need == 1 and "player needs" or "players need")
  end
  local left = soonest and soonest - now
  if left and left <= (self.db.minutes or 5) * 60 then
    return true, string.format("a blessing ends in %d min", math.max(0, math.ceil(left / 60)))
  end
  return false, left and string.format("every blessing is up, the first ends in %d min", math.floor(left / 60))
    or "every blessing is up"
end

local function SetHidden(want)
  local f = Frame()
  if not f then
    return
  end
  ARLE.Secure:Run(function()
    f:SetShown(not want)
  end, "PallyPowerHide.frame")
end

function F:Decide()
  local show, reason = self:Wanted()
  why = reason
  if hidden == not show or not Frame() then
    return
  end
  hidden = not show
  self:Debug("%s: %s", show and "shown" or "hidden", reason)
  SetHidden(hidden)
end

-- A copy of the numbers PallyPower's UpdateButton returns for one class.
function F:Record(classID, classExpire, specialExpire, nneed, nspecial)
  if type(classID) ~= "number" then
    return
  end
  local soonest
  for _, left in ipairs({ Plain(classExpire) or NONE, Plain(specialExpire) or NONE }) do
    if left < NONE and (not soonest or left < soonest) then
      soonest = left
    end
  end
  byClass[classID] = {
    need = (Plain(nneed) or 0) + (Plain(nspecial) or 0),
    endsAt = soonest and GetTime() + soonest or nil,
  }
end

function F:OnEnable()
  wipe(byClass)
  updatedAt, hidden, why = nil, false, "waiting for PallyPower's first update"
  local pp = PP()
  if not pp then
    self:Print("PallyPower wasn't found, so its buttons can't be hidden.")
    return
  end
  local okButton = self:Wrap(pp, "UpdateButton", function(orig, ppSelf, button, baseName, classID, ...)
    local r = { orig(ppSelf, button, baseName, classID, ...) }
    -- classExpire, classDuration, specialExpire, specialDuration, nhave, nneed, nspecial
    self:Record(classID, r[1], r[3], r[6], r[7])
    return unpack(r, 1, 7)
  end)
  local okAll = self:Wrap(pp, "ButtonsUpdate", function(orig, ...)
    wipe(byClass)
    orig(...)
    updatedAt = GetTime()
    self:Decide()
  end)
  if not (okButton and okAll) then
    self:Print("PallyPower has changed (its button update wasn't found), so its buttons stay shown.")
    return
  end
  self:Ticker(TICK, self.Decide)
  self:On("PLAYER_REGEN_ENABLED", self.Decide)
end

function F:OnDisable()
  if hidden then
    hidden = false
    SetHidden(false)
  end
end

function F:OnOptionChanged()
  self:Decide()
end

function F:GetStatus()
  if not Frame() then
    return "Active · waiting for PallyPower's frame"
  end
  return string.format("Active · %s: %s%s", hidden and "hidden" or "shown", why,
    InCombatLockdown() and " (no change until the fight ends)" or "")
end

function F:ReportDetails()
  local out = { string.format("hidden %s, frame shown %s, last update %s s ago, unlocked %s", tostring(hidden),
    tostring(Frame() and Frame():IsShown()), updatedAt and string.format("%.0f", GetTime() - updatedAt) or "never",
    tostring(Unlocked())) }
  for classID, c in pairs(byClass) do
    out[#out + 1] = string.format("  class %d: need %d, ends in %s", classID, c.need,
      c.endsAt and string.format("%.0f s", c.endsAt - GetTime()) or "-")
  end
  return out
end

ARLE:RegisterModule(F)
