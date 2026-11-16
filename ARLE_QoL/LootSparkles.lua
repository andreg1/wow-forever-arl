-- Loot Sparkles: keeps the sparkle on lootable quest items.
--
-- Our own code. Forever Loot Sparkles (Ashtar Senior) does the same, but it is
-- GPL-3.0 and ARL is MIT, so none of its code is used, only the fact it is
-- built on: quest-item sparkles need the CVar
-- outlineModeShowLootEffectWhenDisabled = 1, and a graphics preset change
-- resets it.
--
-- How: set it to 1 on enable, on entering the world and again 5 s later
-- (account-synced settings can arrive late), and 1 s after any CVAR_UPDATE
-- for the graphics presets or the CVar itself. Our own writes are skipped by a
-- guard. Written out of combat only. The outline mode is the player's and is
-- never touched. Turning the feature off writes 0; the client keeps showing
-- the sparkles until it is restarted (a /reload is not enough), which is said
-- in chat.
local ADDON = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end

local CVAR = "outlineModeShowLootEffectWhenDisabled"
local WATCHED = {
  graphicsquality = true,
  raidgraphicsquality = true,
  [CVAR:lower()] = true,
}

local F = {
  id = "LootSparkles",
  addon = ADDON,
  title = "Loot Sparkles",
  group = "QualityOfLife",
  command = "sparkle",
  commandHelp = "keeps the sparkle on quest loot",
  description = "Keeps the game's sparkle on lootable quest items, even after a graphics preset turns it off.",
  options = {
    { type = "info", text = function(def) return def:GetStatus() end },
  },
}

local applying = false

local function Get()
  if C_CVar and C_CVar.GetCVar then
    local ok, value = pcall(C_CVar.GetCVar, CVAR)
    if ok then
      return value
    end
  end
end

local function Set(value)
  local current = Get()
  if current == nil or current == value then
    return
  end
  applying = true
  pcall(C_CVar.SetCVar, CVAR, value)
  applying = false
end

function F:Apply()
  self:OutOfCombat(function()
    Set("1")
  end)
end

function F:OnCVarUpdate(_, name)
  if not applying and type(name) == "string" and WATCHED[name:lower()] then
    self:Debounce("apply", 1, self.Apply)
  end
end

function F:OnEnable()
  self:On("PLAYER_ENTERING_WORLD", function(def)
    def:Apply()
    def:After(5, def.Apply)
  end)
  self:On("CVAR_UPDATE", self.OnCVarUpdate)
  self:Apply()
  self:After(5, self.Apply)
end

function F:OnDisable()
  -- (Secure:Run, not OutOfCombat: OutOfCombat drops work once the feature is off.)
  ARLE.Secure:Run(function()
    if not F._active then
      Set("0")
    end
  end)
  self:Print("the sparkles go away after you restart the game (a /reload is not enough).")
end

function F:GetStatus()
  local value = Get()
  if value == nil then
    return "This client has no loot sparkle setting"
  end
  return value == "1" and "Active · quest loot sparkles are on" or "Waiting to switch the sparkles on"
end

ARLE:RegisterModule(F)
