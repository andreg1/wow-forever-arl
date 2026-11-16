-- Associação Rei Leão's Extensions: the one global table and its namespaces.
--
--   ARLE.Core      lifecycle helpers, saved variables (Core/DB.lua), guild gate
--   ARLE.Modules   packs and features (Core/Modules.lua)
--   ARLE.Options   option presets and value parsing (Core/Options.lua)
--   ARLE.Lib       small helpers without UI (Lib/*.lua)
--   ARLE.Secure    combat queue, secure buttons, key bindings (Secure/*.lua)
--   ARLE.Macro     macros owned by a feature (Secure/Macro.lua)
--   ARLE.Bridge    one adapter per outside addon (Bridge/*.lua)
--   ARLE.UI        Skin, Kit (widgets), Window, Alert, the /arl panel (UI/*.lua)
--
-- Rule: ARLExtensions is the only global this suite writes, apart from the
-- slash command and key binding names the game asks for. ./bin/arle check
-- enforces it. Never assign a game global (StaticPopupDialogs = ..., ...):
-- that taints every Blizzard function that reads it.
local ADDON_NAME, ns = ...

local ARLE = _G.ARLExtensions or {}
_G.ARLExtensions = ARLE
ns.ARLE = ARLE

ARLE.name = ADDON_NAME
ARLE.title = "Associação Rei Leão's Extensions"
ARLE.shortTitle = "ARL Extensions"
ARLE.modules = {}   -- feature id -> definition table passed to RegisterModule
ARLE.catalog = {}   -- feature id -> toc metadata for every installed feature
ARLE.listeners = {} -- functions called after any state change (UI refresh)

ARLE.Core = ARLE.Core or {}
ARLE.Modules = ARLE.Modules or {}
ARLE.Options = ARLE.Options or {}
ARLE.Lib = ARLE.Lib or {}
ARLE.Secure = ARLE.Secure or {}
ARLE.Macro = ARLE.Macro or {}
ARLE.Bridge = ARLE.Bridge or {}
ARLE.UI = ARLE.UI or {}

local C = C_AddOns
local API = {
  GetNumAddOns = (C and C.GetNumAddOns) or GetNumAddOns,
  GetAddOnInfo = (C and C.GetAddOnInfo) or GetAddOnInfo,
  GetAddOnMetadata = (C and C.GetAddOnMetadata) or GetAddOnMetadata,
  IsAddOnLoaded = (C and C.IsAddOnLoaded) or IsAddOnLoaded,
  EnableAddOn = (C and C.EnableAddOn) or EnableAddOn,
  LoadAddOn = (C and C.LoadAddOn) or LoadAddOn,
  DoesAddOnExist = C and C.DoesAddOnExist,
}
ARLE.API = API

local function Blank(value)
  if value == nil or value == "" then
    return nil
  end
  return value
end
ARLE.Blank = Blank

local function Strip(text)
  if not text then
    return ""
  end
  return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end
ARLE.Strip = Strip

function ARLE:Print(message)
  print("|cff7fd4ffARL Extensions|r: " .. tostring(message))
end

function ARLE:IsAddonLoaded(name)
  if not name or name == "" or not API.IsAddOnLoaded then
    return false
  end
  return API.IsAddOnLoaded(name) and true or false
end

-- Why an addon can't be used right now, or nil when it's loaded or will
-- load (installed and turned on; LoadOnDemand addons load later).
function ARLE:AddonProblem(name)
  if not name or self:IsAddonLoaded(name) then
    return nil
  end
  if not self:AddonExists(name) then
    return "not installed"
  end
  local state
  local who = UnitName and UnitName("player")
  if C and C.GetAddOnEnableState then
    local ok, v = pcall(C.GetAddOnEnableState, name, who)
    state = ok and v or nil
  elseif GetAddOnEnableState then
    local ok, v = pcall(GetAddOnEnableState, who, name)
    state = ok and v or nil
  end
  if state == 0 then
    return "turned off in the AddOns list"
  end
  return nil
end

-- A requirement is an addon name, or a list of names where any one will do.
-- Returns nil when it's met, else the addon title(s) and why not.
function ARLE:RequirementProblem(req)
  if not req then
    return nil
  end
  local list = type(req) == "table" and req or { req }
  local titles, why = {}, nil
  for _, name in ipairs(list) do
    local problem = self:AddonProblem(name)
    if not problem then
      return nil
    end
    titles[#titles + 1] = self:AddonTitle(name) or name
    why = why or problem
  end
  return table.concat(titles, " or "), #list == 1 and why or "none of them is installed and on"
end

function ARLE:AddonExists(name)
  if not name or name == "" then
    return false
  end
  if API.DoesAddOnExist then
    return API.DoesAddOnExist(name) and true or false
  end
  return API.GetAddOnInfo(name) ~= nil
end

-- Names of the addons features build on, for when they aren't installed.
local KNOWN_TITLES = {
  ForeverLevelingBiS = "Forever Leveling BiS",
  ForeverDungeonJournal = "DungeonJournal",
  EllesmereUIQuestTracker = "EllesmereUI Quest Tracker",
  EllesmereUIBags = "EllesmereUI Bags",
}

-- An installed addon's own title, colour codes stripped ("Forever Leveling
-- BiS" for ForeverLevelingBiS), or a known name, or the folder name.
function ARLE:AddonTitle(name)
  if not name or not self:AddonExists(name) then
    return name and KNOWN_TITLES[name] or name
  end
  local title = Strip(API.GetAddOnMetadata(name, "Title") or "")
  return title ~= "" and title or name
end

-- Groups that are not an addon folder of the same name, and their labels.
local GROUP_ADDON = {
  BlizzardUI = false,
  General = false,
  QualityOfLife = false,
  RestedXP = "RXPGuides",
}
local GROUP_LABEL = {
  BlizzardUI = "Blizzard UI",
  QualityOfLife = "Quality of Life",
}

-- The addon folder a group stands for, or nil (BlizzardUI, General, ...).
function ARLE:GroupAddon(group)
  local mapped = GROUP_ADDON[group]
  if mapped == false then
    return nil
  end
  return mapped or group
end

function ARLE:GroupLabel(group)
  return GROUP_LABEL[group] or self:AddonTitle(self:GroupAddon(group)) or group
end

function ARLE:Changed()
  for _, fn in ipairs(self.listeners) do
    local ok, err = pcall(fn)
    if not ok then
      geterrorhandler()(err)
    end
  end
end

function ARLE:OnChange(fn)
  self.listeners[#self.listeners + 1] = fn
end
