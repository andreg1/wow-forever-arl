-- ARLE.UI.Alert: one alert look for every feature (Fishing Pole Alert, Rare
-- Objectives, Sleeping Bag): a themed bar near the top of the screen with an
-- icon, a line and a sub-line, pulsing; plus raid-warning text, a sound and a
-- taskbar flash, each following the feature's Alert settings
-- (ARLE.Options.Preset.Alert: alertWarning, alertSound, alertFlash).
--
--   feature:Alert({ text = "Fishing pole equipped!", sub = "...", icon = 132932,
--                   warning = "FISHING POLE EQUIPPED!", pulse = true, duration = 5 })
--   ARLE.UI.Alert:Nag(feature, warningText)   only the sound / warning / flash
--   ARLE.UI.Alert:Hide(feature)
--   ARLE.UI.Alert:Frame(feature)              the bar (to add buttons to it)
-- Drag the bar to move it; its position is kept per character.
local _, ns = ...
local ARLE = ns.ARLE
local Skin = ARLE.Skin
local Kit = ARLE.UI.Kit

local Alert = {}
ARLE.UI.Alert = Alert

local frames = {}

local function Setting(def, key)
  return not (def.db and def.db[key] == false)
end

function Alert:Nag(def, text)
  if Setting(def, "alertSound") and PlaySound then
    pcall(PlaySound, (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959, "Master")
  end
  if text and Setting(def, "alertWarning") and RaidNotice_AddMessage and RaidWarningFrame then
    RaidNotice_AddMessage(RaidWarningFrame, text, (ChatTypeInfo and ChatTypeInfo.RAID_WARNING)
      or { r = 1, g = 0.3, b = 0.1 })
  end
  if Setting(def, "alertFlash") and FlashClientIcon then
    pcall(FlashClientIcon)
  end
end

function Alert:Frame(def)
  local f = frames[def.id]
  if f then
    return f
  end
  f = Skin:CreateTooltipWindow(nil, UIParent)
  f:SetSize(380, 56)
  f:SetFrameStrata("HIGH")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, rel, x, y = self:GetPoint()
    def.char.alertPos = { point, rel, x, y }
  end)
  function f:RestorePosition()
    self:ClearAllPoints()
    local pos = def.char and def.char.alertPos
    if type(pos) == "table" and pos[1] then
      self:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
      self:SetPoint("TOP", UIParent, "TOP", 0, -150)
    end
  end
  f:RestorePosition()

  f.icon = f:CreateTexture(nil, "ARTWORK")
  f.icon:SetSize(40, 40)
  f.icon:SetPoint("LEFT", 8, 0)
  f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  f.text = Kit.Text(f, "GameFontNormalLarge")
  f.text:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 10, -2)
  f.text:SetPoint("RIGHT", -10, 0)
  f.text:SetWordWrap(false)
  f.sub = Kit.Text(f, "GameFontHighlightSmall")
  f.sub:SetPoint("TOPLEFT", f.text, "BOTTOMLEFT", 0, -4)
  f.sub:SetPoint("RIGHT", -10, 0)
  -- A thin accent bar on the left edge: the alert reads as ours in every theme.
  f.edge = f:CreateTexture(nil, "OVERLAY")
  f.edge:SetPoint("TOPLEFT", 1, -1)
  f.edge:SetPoint("BOTTOMLEFT", 1, 1)
  f.edge:SetWidth(3)

  if f.CreateAnimationGroup then
    local ag = f:CreateAnimationGroup()
    ag:SetLooping("BOUNCE")
    local a = ag:CreateAnimation("Alpha")
    a:SetFromAlpha(1)
    a:SetToAlpha(0.45)
    a:SetDuration(0.5)
    f.pulse = ag
  end
  f:SetScript("OnHide", function(self)
    if self.pulse then
      self.pulse:Stop()
    end
  end)
  f:Hide()
  frames[def.id] = f
  return f
end

-- color: { r, g, b } for the line; default the theme accent (red for urgent).
function Alert:Show(def, spec)
  local f = self:Frame(def)
  f.icon:SetTexture(spec.icon or 134400)
  f.text:SetText(spec.text or "")
  f.sub:SetText(spec.sub or "")
  local r, g, b
  if spec.color then
    r, g, b = spec.color[1], spec.color[2], spec.color[3]
  else
    r, g, b = Skin:Accent()
  end
  f.text:SetTextColor(r, g, b)
  f.edge:SetColorTexture(r, g, b, 0.9)
  local wasShown = f:IsShown()
  f:Show()
  if spec.pulse and f.pulse and not f.pulse:IsPlaying() then
    f.pulse:Play()
  end
  if not wasShown and not spec.quiet then
    self:Nag(def, spec.warning)
  end
  f.token = (f.token or 0) + 1
  if spec.duration then
    local token = f.token
    C_Timer.After(spec.duration, function()
      if f.token == token then
        f:Hide()
      end
    end)
  end
  return f
end

function Alert:Hide(def)
  local f = frames[def.id]
  if f and f:IsShown() then
    f:Hide()
  end
end

function Alert:IsShown(def)
  local f = frames[def.id]
  return f ~= nil and f:IsShown()
end
