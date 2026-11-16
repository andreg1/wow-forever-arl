-- Leveling BiS Spec: sets Forever Leveling BiS's Talent spec to the spec
-- you're playing, and follows dual spec switches.
-- Based on ForeverLevelingBiS_AutoSpec by andreg1 (MIT),
-- https://github.com/andreg1/wow-forever-addons
--
-- Forever Leveling BiS can't read talents ("Forever has no API for the
-- talent spec"), so its Talent spec box keeps what you picked (or the
-- class's first spec) and never follows a spec switch.
--
-- Detection: the active talent group (GetActiveTalentGroup) and the talent
-- tree with the most points in it (GetTalentTabInfo; both return shapes are
-- handled). No points, or a tie: nothing is changed.
-- Tree -> spec key: ForeverLevelingBiS_API.GetSpecs(classFile) lists the keys
-- in talent-tab order (its public, read-only API). Druid feral is "feral"
-- (cat) or "bear", Hunter survival "survival" or "survivalmelee": there the
-- key you already had is kept, else the first.
--
-- Writing: the API is read-only, so the spec is written where its own Talent
-- spec box writes it (UI.SetMainSpec): ForeverLevelingBiSDB.chars[<full
-- name>-<realm>].spec, clearing a planned spec (sim.spec) for your own class
-- as that box does. Nothing else of it is touched. If that layout changes in
-- an update, nothing is written and the status says so.
--
-- Only on a change: the last applied "group:tree" is kept per character
-- (char.last), and the spec is only set when it differs, so a spec picked by
-- hand in Forever Leveling BiS stays until you switch spec or respec.
--
-- Refresh: its tooltips cache per spec, so they follow at once; its window
-- redraws on OnShow, so an open window is hidden and shown again; its bag
-- arrows follow on the next bag or gear change.
local ADDON = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end

local F = {
  id = "LevelingBiSSpec",
  addon = ADDON,
  title = "Leveling BiS Spec",
  group = "ForeverLevelingBiS",
  extends = "ForeverLevelingBiS",
  command = "spec",
  commandHelp = "sets Forever Leveling BiS's spec to the one you play",
  description = "Sets Forever Leveling BiS's Talent spec to the spec you're playing (the talent tree with the most "
    .. "points), and follows dual spec switches. A spec you pick by hand stays until your next switch or respec.",
  options = {
    { key = "verbose", type = "boolean", label = "Chat message when the spec changes", default = true,
      cmd = "chat" },
    { type = "info", text = function(def) return def:StatusText() end },
    { type = "button", label = "Apply now", desc = "sets the spec from your talents right away", nocmd = true,
      run = function(def) def:Apply(true) end },
  },
}

-------------------------------------------------------------------------------
-- Talents
-------------------------------------------------------------------------------

local function ActiveGroup()
  if GetActiveTalentGroup then
    local ok, g = pcall(GetActiveTalentGroup)
    if ok and g then
      return g
    end
  end
  if C_SpecializationInfo and C_SpecializationInfo.GetActiveSpecGroup then
    local ok, g = pcall(C_SpecializationInfo.GetActiveSpecGroup)
    if ok and g then
      return g
    end
  end
  return 1
end

-- Tab index with the most points in `group`, its name and points (nil on a
-- tie or no points).
local function MainTab(group)
  if not (GetNumTalentTabs and GetTalentTabInfo) then
    return nil
  end
  local bestTab, bestName, bestPts, tie = nil, nil, 0, false
  for tab = 1, (GetNumTalentTabs() or 0) do
    local ok, a, b, c, _, e = pcall(GetTalentTabInfo, tab, false, false, group)
    if not ok then
      ok, a, b, c, _, e = pcall(GetTalentTabInfo, tab)
    end
    if ok then
      local name, pts
      if type(a) == "number" then
        name, pts = b, e -- id, name, description, icon, points
      else
        name, pts = a, c -- name, icon, points, file
      end
      pts = tonumber(pts) or 0
      if pts > bestPts then
        bestTab, bestName, bestPts, tie = tab, name, pts, false
      elseif pts == bestPts and pts > 0 then
        tie = true
      end
    end
  end
  if tie or not bestTab then
    return nil, nil, bestPts
  end
  return bestTab, bestName, bestPts
end

-------------------------------------------------------------------------------
-- Forever Leveling BiS side
-------------------------------------------------------------------------------

-- Spec keys per talent tab where the addon has more than one per tree.
local SHARED = {
  DRUID = { { "balance" }, { "feral", "bear" }, { "restoration" } },
  HUNTER = { { "beastmastery" }, { "marksmanship" }, { "survival", "survivalmelee" } },
}

local function CandidatesFor(classFile, tab)
  local api = _G.ForeverLevelingBiS_API
  local ok, specs = false, nil
  if type(api) == "table" and type(api.GetSpecs) == "function" then
    ok, specs = pcall(api.GetSpecs, classFile)
  end
  if not ok or type(specs) ~= "table" then
    return nil
  end
  local valid = {}
  for _, k in ipairs(specs) do
    valid[k] = true
  end
  local out = {}
  local shared = SHARED[classFile]
  if shared and shared[tab] then
    for _, k in ipairs(shared[tab]) do
      if valid[k] then
        out[#out + 1] = k
      end
    end
  end
  if #out == 0 and #specs == 3 and specs[tab] then
    out[1] = specs[tab]
  end
  return #out > 0 and out or nil
end

-- This character's entry in Forever Leveling BiS's saved data (the key its
-- Core.lua builds at login), or nil.
local function CharEntry()
  local root = _G.ForeverLevelingBiSDB
  if type(root) ~= "table" or type(root.chars) ~= "table" then
    return nil
  end
  local key = (GetUnitName("player", true) or UnitName("player")) .. "-" .. GetRealmName()
  local entry = root.chars[key]
  return type(entry) == "table" and entry or nil
end

local function RefreshFLB()
  local f = _G.ForeverLevelingBiSFrame
  if f and f.IsShown and f:IsShown() then
    f:Hide()
    f:Show() -- its OnShow runs UI.Refresh
  end
end

-- The spec keys it would set, or nil and why not; then group, tab, tree name.
local function Detect()
  local _, classFile = UnitClass("player")
  local group = ActiveGroup()
  local tab, treeName, pts = MainTab(group)
  if not tab then
    return nil, (pts or 0) > 0 and "two talent trees have the same points" or "no talent points spent yet", group
  end
  local cands = CandidatesFor(classFile, tab)
  if not cands then
    return nil, "Forever Leveling BiS has no spec for " .. tostring(treeName), group
  end
  return cands, nil, group, tab, treeName
end

local function SpecLabel(key)
  return "|cffffd200" .. tostring(key) .. "|r"
end

function F:Apply(force)
  if not self._active then
    if force then
      self:Print("turn it on first (/arl spec on).")
    end
    return
  end
  local entry = CharEntry()
  if not entry then
    if force then
      self:Print("Forever Leveling BiS hasn't set up this character yet (open its window once).")
    end
    return
  end
  local cands, why, group, tab, treeName = Detect()
  if not cands then
    if force then
      self:Print("not changed: " .. why .. ".")
    end
    return
  end
  local sig = group .. ":" .. tab
  if not force and self.char.last == sig then
    return
  end
  local spec = cands[1]
  for _, k in ipairs(cands) do
    if k == entry.spec then
      spec = k
      break
    end
  end
  local _, classFile = UnitClass("player")
  local changed = entry.spec ~= spec
  entry.spec = spec
  -- A spec planned in its window for your own class would hide this one (its
  -- own spec box clears it the same way).
  local sim = entry.sim
  if type(sim) == "table" and sim.spec and (sim.classFile == nil or sim.classFile == classFile) then
    sim.spec = nil
    changed = true
  end
  self.char.last = sig
  if changed then
    RefreshFLB()
    if self.db.verbose ~= false or force then
      self:Print(("Talent spec set to %s (%s, talent group %d)."):format(SpecLabel(spec), tostring(treeName), group))
    end
  elseif force then
    self:Print(("already on %s (%s)."):format(SpecLabel(spec), tostring(treeName)))
  end
end

function F:StatusText()
  local cands, why, group, _, treeName = Detect()
  local entry = CharEntry()
  local set = entry and entry.spec or (entry and "not set (its first spec)" or "unknown (not set up yet)")
  return ("Talent group %d: %s.  Forever Leveling BiS spec: %s."):format(group or ActiveGroup(),
    cands and (tostring(treeName) .. " -> " .. table.concat(cands, " / ")) or tostring(why), tostring(set))
end

function F:GetStatus()
  return "Active · " .. self:StatusText()
end

-- FLBAutoSpecDB (per character): last ("group:tab" last applied), verbose.
-- Its "enabled" is left out: db.enabled is this feature's own switch.
function F:Import()
  local old = _G.FLBAutoSpecDB
  if type(old) ~= "table" then
    return
  end
  if type(old.last) == "string" and old.last:match("^%d+:%d+$") then
    self.char.last = old.last
  end
  if type(old.verbose) == "boolean" then
    self.db.verbose = old.verbose
  end
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

local function Queue(self, delay)
  self:Debounce("apply", delay or 1, function()
    self:Apply(false)
  end)
end

function F:OnEnable()
  -- Talents can read empty right after login, and its character entry is
  -- made at its PLAYER_LOGIN: a short wait covers both.
  self:On("PLAYER_ENTERING_WORLD", function()
    Queue(self, 2)
  end)
  -- Not every client has every talent event; self:On skips a missing one.
  for _, e in ipairs({ "ACTIVE_TALENT_GROUP_CHANGED", "PLAYER_TALENT_UPDATE", "CHARACTER_POINTS_CHANGED" }) do
    self:On(e, function()
      Queue(self, 1)
    end)
  end
  Queue(self, 2)
end

F.commands = {
  { name = "now", help = "sets the spec from your talents right away", run = function(self) self:Apply(true) end },
}

ARLE:RegisterModule(F)
