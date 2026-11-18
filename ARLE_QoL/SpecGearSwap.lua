-- Spec Gear Swap: equips the gear set that goes with your talent spec when
-- you switch specs, keeps that set up to date when you change a piece, and
-- puts back action bars the game empties on a spec switch.
-- Based on SpecGearSwap by andreg1 (MIT),
-- https://github.com/andreg1/wow-forever-addons
--
-- Why not EllesmereUI's character sheet: it listens for the retail
-- PLAYER_SPECIALIZATION_CHANGED / GetSpecialization, which this client's dual
-- spec never fires. Surfaces (Blizzard API only): ACTIVE_TALENT_GROUP_CHANGED,
-- GetActiveTalentGroup, C_EquipmentSet.*, EquipmentManager_EquipSet.
--
-- Which set a spec gets: the set you linked to it (link / set / learned: the
-- first set you equip by hand in a spec with no link), else a set named like
-- that spec's main talent tree ("Holy", "Feral"). Links are kept by set name
-- (and ID, so a renamed set still works), per character.
--
-- Gear auto-save: while you wear a set and replace a piece of it, the set is
-- re-saved, with safeguards: never a guess between sets that share pieces; no
-- save if a slot the set filled is now empty, a fishing pole is in your main
-- hand, or your gear fully matches another set; more than 4 slots changed at
-- once looks like other gear (not saved; "save" forces it). Set contents come
-- from C_EquipmentSet.GetItemIDs (GetItemLocations crashes this client).
--
-- Action bar restore: the client sometimes empties one of your action bars
-- when you switch spec after a relog. Each spec's bars are backed up as you
-- change them, and empty slots that have something in the backup are refilled
-- right after a switch. Slots that hold something are never replaced. Up to
-- 15 s after a switch, 6+ slots emptied within 1 s count as the bug.
-- Gear and bar changes wait for combat to end.
local ADDON = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local Items = ARLE.Lib.Items

local F = {
  id = "SpecGearSwap",
  addon = ADDON,
  title = "Spec Gear Swap",
  group = "QualityOfLife",
  command = "gear",
  commandAliases = { "specgear" },
  commandHelp = "gear sets and action bars that follow your talent spec",
  description = "Equips each spec's gear set when you switch spec, keeps it updated, and restores emptied action bars.",
  pages = {
    { key = "gear", label = "Gear sets" },
    { key = "bars", label = "Action bars", notes = "The game sometimes empties a bar on a spec switch; this refills it." },
  },
  options = {
    { type = "info", text = function(def) return def:SpecsText() end },
    { key = "autoSwap", type = "boolean", label = "Swap gear on spec switch", default = true,
      cmd = "swap", page = "gear" },
    { key = "learn", type = "boolean", label = "Learn a set for a spec without one", tooltip = "The first set you put on by hand in a spec with no set is linked to it.", default = true,
      page = "gear" },
    { key = "byName", type = "boolean", label = "Use sets named after the talent tree", default = true,
      cmd = "byname", page = "gear" },
    { key = "autoSave", type = "boolean", label = "Save gear changes into the worn set", tooltip = "Replacing a piece of the set you wear saves it into that set. /arl gear why says why a change wasn't saved.", default = true,
      cmd = "autosave", page = "gear" },
    { type = "info", page = "gear", text = function(def) return def:SpecsText(true) end },
    { type = "button", page = "gear", label = "Link the worn set to this spec", nocmd = true,
      run = function(def) def:LinkWorn() end },
    { type = "button", page = "gear", label = "Equip this spec's set now", nocmd = true,
      run = function(def) def:EquipNow() end },
    { key = "barRestore", type = "boolean", label = "Restore emptied action bars", default = true,
      cmd = "bars", page = "bars" },
    { type = "info", page = "bars", text = function(def) return def:BarsText() end },
    { type = "button", page = "bars", label = "Fill empty slots from the backup now", nocmd = true,
      run = function(def) def:RestoreNow() end },
    { type = "button", page = "bars", label = "Back up the bars as they are now", nocmd = true,
      run = function(def) def:SnapshotNow() end },
  },
}

local lastGroup
local pendingEquip -- group to equip after combat
local selfSwap = 0 -- GetTime() of our own last swap (ignored by learn)
local wornSet      -- setID of the set you last put on
local swapPending = false
local pendingSave = false
local saveToken = 0

local function Links()
  F.char.links = type(F.char.links) == "table" and F.char.links or {}
  return F.char.links
end

-------------------------------------------------------------------------------
-- Spec helpers
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

local function NumGroups()
  if GetNumTalentGroups then
    local ok, n = pcall(GetNumTalentGroups)
    if ok and n and n > 0 then
      return n
    end
  end
  return 2
end

-- Name of the talent tree with the most points in group, or nil.
local function MainTree(group)
  if not (GetNumTalentTabs and GetTalentTabInfo) then
    return nil
  end
  local bestName, bestPts = nil, 0
  for tab = 1, (GetNumTalentTabs() or 0) do
    local ok, a, b, c, d, e = pcall(GetTalentTabInfo, tab, false, false, group)
    if not ok then
      ok, a, b, c, d, e = pcall(GetTalentTabInfo, tab)
    end
    if ok then
      local name, pts
      if type(a) == "number" then
        name, pts = b, e -- id, name, desc, icon, points
      else
        name, pts = a, c -- name, icon, points, file
      end
      pts = tonumber(pts) or 0
      if name and pts > bestPts then
        bestName, bestPts = name, pts
      end
    end
  end
  return bestName
end

local function SpecLabel(group)
  local tree = MainTree(group)
  return string.format("Spec %d%s", group, tree and (" (" .. tree .. ")") or "")
end

-------------------------------------------------------------------------------
-- Gear sets
-------------------------------------------------------------------------------

local function HasAPI()
  return C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs
end

local function SetIDs()
  if not HasAPI() then
    return {}
  end
  local ok, ids = pcall(C_EquipmentSet.GetEquipmentSetIDs)
  return (ok and ids) or {}
end

-- name, setID, isEquipped, numLost
local function SetInfo(id)
  if not id or not HasAPI() then
    return nil
  end
  local ok, name, _, setID, isEquipped, _, _, _, numLost = pcall(C_EquipmentSet.GetEquipmentSetInfo, id)
  if ok and name then
    return name, setID or id, isEquipped, numLost or 0
  end
end

local function FindSetByName(name)
  if not name then
    return nil
  end
  if C_EquipmentSet and C_EquipmentSet.GetEquipmentSetID then
    local ok, id = pcall(C_EquipmentSet.GetEquipmentSetID, name)
    if ok and id then
      return id
    end
  end
  local lower = name:lower()
  for _, id in ipairs(SetIDs()) do
    local n = SetInfo(id)
    if n and n:lower() == lower then
      return id
    end
  end
end

local function EquippedSet()
  for _, id in ipairs(SetIDs()) do
    local name, setID, isEquipped = SetInfo(id)
    if isEquipped then
      return setID, name
    end
  end
end

-- The set for group: setID, name, how ("linked" / "tree name").
local function SetForGroup(group)
  local link = Links()[group]
  if link then
    local id = FindSetByName(link.name)
    if not id and link.id and SetInfo(link.id) then
      id = link.id
    end
    if id then
      local name = SetInfo(id)
      if name ~= link.name then
        link.name = name -- follow a rename
      end
      return id, name, "linked"
    end
  end
  if F.db.byName ~= false then
    local tree = MainTree(group)
    local id = tree and FindSetByName(tree)
    if id then
      return id, SetInfo(id), "tree name"
    end
  end
end

local function EquipForGroup(group, quiet)
  local id, name = SetForGroup(group)
  if not id then
    if not quiet then
      F:Print(SpecLabel(group) .. " has no gear set. Link one: /arl gear link (equips nothing until then).")
    end
    return
  end
  local _, _, isEquipped, numLost = SetInfo(id)
  if isEquipped then
    if not quiet then
      F:Print(string.format("%s: |cffffffff%s|r is already on.", SpecLabel(group), name))
    end
    return
  end
  if InCombatLockdown() or UnitAffectingCombat("player") then
    pendingEquip = group
    F:Print(string.format("in combat: |cffffffff%s|r goes on when combat ends.", name))
    return
  end
  selfSwap = GetTime()
  local ok, err
  if EquipmentManager_EquipSet then
    ok, err = pcall(EquipmentManager_EquipSet, id)
  else
    ok, err = pcall(C_EquipmentSet.UseEquipmentSet, id)
  end
  if ok then
    F:Print(string.format("%s: equipping |cffffffff%s|r.", SpecLabel(group), name))
    if numLost and numLost > 0 then
      F:Print(string.format("|cffff8080%d item%s of %s %s not in your bags.|r", numLost, numLost == 1 and "" or "s", name,
        numLost == 1 and "is" or "are"))
    end
  else
    F:Print("couldn't equip " .. name .. ": " .. tostring(err))
  end
end

local function Link(group, id)
  local name = SetInfo(id)
  if not name then
    return
  end
  Links()[group] = { name = name, id = id }
  F:Print(string.format("%s now uses |cffffffff%s|r.", SpecLabel(group), name))
  ARLE:Changed()
end

-------------------------------------------------------------------------------
-- Gear auto-save
-------------------------------------------------------------------------------

local SKIP_SLOTS = { [4] = true, [19] = true } -- shirt, tabard
local MAX_AT_ONCE = 4
-- Slots auto-save has changed in a set since it was last put on from the set
-- (setID -> { [slot] = true }): one piece at a time adds up, so a slow switch
-- to other gear can't get around MAX_AT_ONCE either.
local drift = {}
local SLOT_LABEL = {
  [1] = "head", [2] = "neck", [3] = "shoulder", [5] = "chest", [6] = "waist", [7] = "legs",
  [8] = "feet", [9] = "wrist", [10] = "hands", [11] = "ring", [12] = "ring", [13] = "trinket",
  [14] = "trinket", [15] = "back", [16] = "main hand", [17] = "off hand", [18] = "ranged",
}

local function Norm(id)
  return (type(id) == "number" and id > 1) and id or nil
end

local function SetItems(setID)
  if not (C_EquipmentSet and C_EquipmentSet.GetItemIDs) then
    return nil
  end
  local ok, ids = pcall(C_EquipmentSet.GetItemIDs, setID)
  if not (ok and type(ids) == "table") then
    return nil
  end
  local ignored = {}
  if C_EquipmentSet.GetIgnoredSlots then
    local okI, ig = pcall(C_EquipmentSet.GetIgnoredSlots, setID)
    if okI and type(ig) == "table" then
      ignored = ig
    end
  end
  return ids, ignored
end

-- Changed slots ({slot = newID or false}, count) if setID should be re-saved,
-- else nil + reason. force skips the many-slots limit.
local function GearChanges(setID, force)
  local ids, ignored = SetItems(setID)
  if not ids then
    return nil, "can't read the set"
  end
  local main = Norm(GetInventoryItemID("player", 16))
  if main and Items.IsFishingPole(main) then
    return nil, "a fishing pole is in your main hand"
  end
  local mainIs2H = main and Items.GetInfoInstant and select(4, Items.GetInfoInstant(main)) == "INVTYPE_2HWEAPON"
  local changes, n = {}, 0
  for slot = 1, 18 do
    if not SKIP_SLOTS[slot] and not ignored[slot] then
      local want, have = Norm(ids[slot]), Norm(GetInventoryItemID("player", slot))
      if want ~= have then
        -- An emptied slot is taking gear off (repairs, mid-swap), not a new piece.
        if not have and want and not (slot == 17 and mainIs2H) then
          return nil, "your " .. (SLOT_LABEL[slot] or ("slot " .. slot)) .. " slot is empty"
        end
        -- The set's piece isn't with you (in the bank, mailed): the swap
        -- couldn't put it on, which isn't you choosing another piece.
        if want and Items.Count(want) == 0 then
          return nil, "the set's " .. (SLOT_LABEL[slot] or ("slot " .. slot)) .. " piece isn't in your bags"
        end
        changes[slot] = have or false
        n = n + 1
      end
    end
  end
  if n == 0 then
    return nil, "you're wearing exactly the set"
  end
  if n > MAX_AT_ONCE and not force then
    return nil, string.format("%d slots changed at once (looks like different gear, not an upgrade; "
      .. "/arl gear save saves it anyway)", n)
  end
  if not force then
    local total, seen = 0, {}
    for slot in pairs(drift[setID] or {}) do
      seen[slot], total = true, total + 1
    end
    for slot in pairs(changes) do
      if not seen[slot] then
        total = total + 1
      end
    end
    if total > MAX_AT_ONCE then
      return nil, string.format("%d slots changed since you last put the set on (looks like different gear; "
        .. "/arl gear save saves it anyway)", total)
    end
  end
  return changes, n
end

local function SaveWorn(force)
  local name = SetInfo(wornSet)
  local changes, why = GearChanges(wornSet, force)
  if not changes then
    if force then
      F:Print("not saved: " .. why .. ".")
    elseif why:find("slots changed") then
      F:Print(name .. " not updated: " .. why .. ".")
    end
    return
  end
  local ok, err = pcall(C_EquipmentSet.SaveEquipmentSet, wornSet)
  if not ok then
    F:Print("couldn't update " .. name .. ": " .. tostring(err))
    return
  end
  if force then
    drift[wornSet] = nil
  else
    drift[wornSet] = drift[wornSet] or {}
    for slot in pairs(changes) do
      drift[wornSet][slot] = true
    end
  end
  local parts = {}
  for slot = 1, 18 do
    if changes[slot] ~= nil then
      parts[#parts + 1] = (SLOT_LABEL[slot] or ("slot " .. slot)) .. " "
        .. (changes[slot] and Items.Link(changes[slot]) or "|cff808080empty|r")
    end
  end
  F:Print(string.format("updated |cffffffff%s|r: %s.", name, table.concat(parts, ", ")))
end

local function CheckGearSave()
  -- A set that fully matches now is simply the set you're wearing.
  local equipped = EquippedSet()
  if equipped then
    wornSet = equipped
    return
  end
  if not (F.db.autoSave ~= false and wornSet and SetInfo(wornSet)) then
    return
  end
  if swapPending or GetTime() - selfSwap < 2 then
    return
  end
  if InCombatLockdown() then
    pendingSave = true
    return
  end
  if not C_EquipmentSet.SaveEquipmentSet then
    return
  end
  SaveWorn(false)
end

-- Debounced 0.7 s, restarting on each change (a swap fires several events).
local function QueueGearSave()
  saveToken = saveToken + 1
  local token = saveToken
  F:After(0.7, function()
    if token == saveToken then
      CheckGearSave()
    end
  end)
end

-------------------------------------------------------------------------------
-- Action bar backup
-------------------------------------------------------------------------------

local MAX_SLOTS = 120
if GetActionInfo then
  for _, n in ipairs({ 180, 132 }) do
    if pcall(GetActionInfo, n) then
      MAX_SLOTS = n
      break
    end
  end
end
local WIPE_COUNT = 6
local WIPE_WINDOW = 1.0
local WIPE_AFTER_SWITCH = 15
local barGuardUntil = 0
local lastSpecSwitch = -100
local clearedSlots = {}
local clearPending = false
local restorePending = false
local barsReady = false

local function Bars(group)
  F.char.bars = type(F.char.bars) == "table" and F.char.bars or {}
  F.char.bars[group] = F.char.bars[group] or {}
  return F.char.bars[group]
end

-- What a slot holds, as stored: { type, id, name } or nil.
local function ReadSlot(slot)
  local kind, id = GetActionInfo(slot)
  if not kind then
    return nil
  end
  local e = { type = kind, id = id }
  if kind == "macro" then
    e.name = GetActionText(slot)
    if not e.name then
      return nil
    end
  elseif kind == "spell" then
    local f = (C_Spell and C_Spell.GetSpellName) or GetSpellInfo
    e.name = id and f and f(id) or nil
  elseif kind ~= "item" and kind ~= "equipmentset" then
    return nil -- companions, flyouts...: not restorable here
  end
  return e
end

local function Record(slot)
  Bars(ActiveGroup())[slot] = ReadSlot(slot) or false
end

local function SnapshotAll(group, keepEmpties)
  local bars = Bars(group)
  for slot = 1, MAX_SLOTS do
    local e = ReadSlot(slot)
    if e then
      bars[slot] = e
    elseif not keepEmpties then
      bars[slot] = false
    end
  end
end

local PickupSpellF = (C_Spell and C_Spell.PickupSpell) or _G.PickupSpell
local PickupItemF = (C_Item and C_Item.PickupItem) or _G.PickupItem

local function PickupEntry(e)
  if e.type == "spell" then
    pcall(PickupSpellF, e.id)
    if not GetCursorInfo() and e.name then
      pcall(PickupSpellF, e.name)
    end
  elseif e.type == "item" then
    pcall(PickupItemF, e.id)
  elseif e.type == "macro" then
    pcall(PickupMacro, e.name)
  elseif e.type == "equipmentset" then
    local setID = C_EquipmentSet.GetEquipmentSetID and C_EquipmentSet.GetEquipmentSetID(e.id)
    if setID then
      pcall(C_EquipmentSet.PickupEquipmentSet, setID)
    end
  end
  return GetCursorInfo() == e.type
end

-- Fills the empty slots the backup has something for. Returns restored, failed.
local function RestoreBars(onlySlots, quiet)
  if InCombatLockdown() then
    restorePending = true
    return 0, 0
  end
  if GetCursorInfo() then -- you're holding something: try again shortly
    F:After(1, function()
      RestoreBars(onlySlots, quiet)
    end)
    return 0, 0
  end
  local bars = Bars(ActiveGroup())
  local restored, failed = 0, {}
  for slot = 1, MAX_SLOTS do
    local e = bars[slot]
    if e and (not onlySlots or onlySlots[slot]) and not GetActionInfo(slot) then
      if PickupEntry(e) then
        PlaceAction(slot)
        restored = restored + 1
      else
        failed[#failed + 1] = e.name or tostring(e.id)
      end
      ClearCursor()
    end
  end
  if restored > 0 then
    F:Print(string.format("restored %d action bar slot%s.", restored, restored == 1 and "" or "s"))
  end
  if #failed > 0 and not quiet then
    F:Print("couldn't restore: " .. table.concat(failed, ", ") .. ".")
  end
  return restored, #failed
end

-- Emptied slots are judged together: a handful is you, a whole bar is the bug.
local function JudgeCleared()
  clearPending = false
  local slots, n = {}, 0
  for slot in pairs(clearedSlots) do
    if not GetActionInfo(slot) then
      slots[slot] = true
      n = n + 1
    else
      Record(slot)
    end
  end
  wipe(clearedSlots)
  if n == 0 then
    return
  end
  if n >= WIPE_COUNT and F.db.barRestore ~= false and GetTime() - lastSpecSwitch < WIPE_AFTER_SWITCH then
    F:Print(string.format("%d action slots emptied at once; putting them back.", n))
    RestoreBars(slots)
  else
    for slot in pairs(slots) do
      Record(slot)
    end
  end
end

local function OnSlotChanged(slot)
  if not (F.db.barRestore ~= false and barsReady) then
    return
  end
  if not slot or slot < 1 or slot > MAX_SLOTS then
    return
  end
  -- Mid-switch: the bars are loading the other spec's layout.
  if GetTime() < barGuardUntil or ActiveGroup() ~= lastGroup then
    return
  end
  if GetActionInfo(slot) then
    clearedSlots[slot] = nil
    Record(slot)
  else
    clearedSlots[slot] = true
    if not clearPending then
      clearPending = true
      F:After(WIPE_WINDOW, JudgeCleared)
    end
  end
end

local function BarsAfterSpecChange(group)
  if F.db.barRestore == false then
    return
  end
  wipe(clearedSlots)
  lastSpecSwitch = GetTime()
  barGuardUntil = GetTime() + 4
  -- Two passes: bars can arrive a little after the switch.
  F:After(1.0, function()
    if ActiveGroup() == group then
      RestoreBars(nil, true) -- (what fails here is tried again, and told, at 3 s)
    end
  end)
  F:After(3.0, function()
    if ActiveGroup() ~= group then
      return
    end
    RestoreBars()
    -- The new spec's own layout counts from here: record what's set.
    SnapshotAll(group, true)
  end)
end

local function BarsAtLogin()
  F:After(3, function()
    local g = ActiveGroup()
    local bars = Bars(g)
    local first = next(bars) == nil
    -- First time: full backup. Later: a few slots emptied since (while this
    -- was off) are yours and stay empty; a whole bar's worth looks like the
    -- client's wipe, and the backup is kept for them.
    local emptied = 0
    for slot = 1, MAX_SLOTS do
      if bars[slot] and not GetActionInfo(slot) then
        emptied = emptied + 1
      end
    end
    SnapshotAll(g, not first and emptied >= WIPE_COUNT)
    barsReady = true
  end)
end

-------------------------------------------------------------------------------
-- Spec change
-------------------------------------------------------------------------------

local function OnSpecChanged()
  local g = ActiveGroup()
  if g == lastGroup then
    return
  end
  lastGroup = g
  BarsAfterSpecChange(g)
  if F.db.autoSwap == false then
    return
  end
  -- Let the talent swap settle (spells, stats) before swapping gear.
  F:After(0.3, function()
    if ActiveGroup() == g then
      EquipForGroup(g)
    end
  end)
end

-------------------------------------------------------------------------------
-- Text for the panel and chat
-------------------------------------------------------------------------------

function F:SpecsText(perSpec)
  if not HasAPI() then
    return "|cffff8080This client has no equipment manager API: nothing to do.|r"
  end
  if not perSpec then
    local worn = wornSet and SetInfo(wornSet)
    return "Now in " .. SpecLabel(ActiveGroup()) .. "  ·  wearing "
      .. (worn and ("|cffffffff" .. worn .. "|r" .. (EquippedSet() == wornSet and "" or " (gear changed since)"))
        or "|cff808080no set|r")
  end
  local lines = {}
  for g = 1, NumGroups() do
    local id, name, how = SetForGroup(g)
    local line = id and string.format("|cffffffff%s|r (%s)", name, how) or "|cff808080no set|r"
    if Links()[g] and not id then
      line = string.format("|cffff8080%s (set not found)|r", Links()[g].name)
    end
    lines[#lines + 1] = string.format("%s%s: %s", SpecLabel(g), g == ActiveGroup() and " (active)" or "", line)
  end
  return table.concat(lines, "\n")
end

function F:BarsText()
  local lines = {}
  for g = 1, NumGroups() do
    local n = 0
    for _, e in pairs(Bars(g)) do
      if e then
        n = n + 1
      end
    end
    lines[#lines + 1] = string.format("%s%s: %d action%s backed up", SpecLabel(g),
      g == ActiveGroup() and " (active)" or "", n, n == 1 and "" or "s")
  end
  return table.concat(lines, "\n")
end

function F:LinkWorn(group)
  local id = EquippedSet()
  if not id then
    F:Print("you aren't wearing a complete gear set. Equip one first, or use /arl gear assign <spec> <set name>.")
    return
  end
  Link(group or ActiveGroup(), id)
end

function F:EquipNow()
  EquipForGroup(ActiveGroup())
end

function F:RestoreNow()
  local r, f = RestoreBars()
  if r == 0 and f == 0 and not InCombatLockdown() then
    F:Print("no empty slots to fill from the backup.")
  end
end

function F:SnapshotNow()
  SnapshotAll(ActiveGroup(), false)
  F:Print(SpecLabel(ActiveGroup()) .. ": action bars backed up as they are now.")
  ARLE:Changed()
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function F:OnEnable()
  if not HasAPI() then
    self:Print("this client has no equipment manager API; Spec Gear Swap does nothing.")
    return
  end
  self:On("PLAYER_ENTERING_WORLD", function()
    if not lastGroup then
      lastGroup = ActiveGroup()
      BarsAtLogin()
    end
    if not wornSet then
      wornSet = EquippedSet()
    end
  end)
  self:On("ACTIONBAR_SLOT_CHANGED", function(_, _, slot)
    OnSlotChanged(slot)
  end)
  self:On("PLAYER_EQUIPMENT_CHANGED", function(_, _, slot)
    if slot and slot >= 1 and slot <= 18 and not SKIP_SLOTS[slot] then
      QueueGearSave()
    end
  end)
  pcall(self.On, self, "EQUIPMENT_SWAP_PENDING", function()
    swapPending = true
  end)
  local function SpecEvent()
    if lastGroup then
      OnSpecChanged()
    end
  end
  -- Talent events differ between clients (On registers nothing for an unknown one).
  local okA = self:On("ACTIVE_TALENT_GROUP_CHANGED", SpecEvent)
  local okT = self:On("PLAYER_TALENT_UPDATE", SpecEvent)
  if not (okA or okT) then
    F:Print("no talent group events on this client; spec changes won't be seen.")
  end
  self:On("PLAYER_REGEN_ENABLED", function()
    if restorePending then
      restorePending = false
      RestoreBars()
    end
    if pendingSave then
      pendingSave = false
      QueueGearSave()
    end
    if pendingEquip then
      local g = pendingEquip
      pendingEquip = nil
      if g == ActiveGroup() then
        EquipForGroup(g, true)
      end
    end
  end)
  -- Learn: a set equipped by hand while the active spec has no link (and no
  -- tree-name set) becomes its set.
  self:On("EQUIPMENT_SWAP_FINISHED", function(_, _, ok, setID)
    swapPending = false
    if ok and setID then
      wornSet = setID
      drift[setID] = nil -- (put on from the set: a fresh start)
    end
    if not (ok and setID and self.db.learn ~= false) or GetTime() - selfSwap < 3 then
      return
    end
    local g = ActiveGroup()
    if Links()[g] or SetForGroup(g) then
      return
    end
    Link(g, setID)
  end)
  -- Turned on after login: start from the current state (never from what
  -- was true when it was last on: the spec or gear may have changed since).
  if IsLoggedIn and IsLoggedIn() then
    lastGroup = ActiveGroup()
    wornSet = EquippedSet()
    if not barsReady then
      BarsAtLogin()
    end
  end
end

function F:OnDisable()
  -- The helpers' timers are dropped on disable, so nothing they were going
  -- to clear (clearPending, swapPending) may stay set, and a re-enable
  -- starts from the state at that time (OnEnable / PLAYER_ENTERING_WORLD).
  pendingEquip, pendingSave, restorePending = nil, false, false
  lastGroup, wornSet = nil, nil
  swapPending, clearPending = false, false
  saveToken = saveToken + 1
  barGuardUntil, lastSpecSwitch = 0, -100
  barsReady = false
  wipe(clearedSlots)
end

-- SpecGearSwapDB (per character): enabled (= auto swap), learn, byName,
-- autoSave, barRestore, links = { [group] = { name, id } },
-- bars = { [group] = { [slot] = { type, id, name } | false } }.
local function CopyBarEntry(e)
  if e == false then
    return false
  end
  if type(e) ~= "table" or type(e.type) ~= "string" then
    return nil
  end
  local id = e.id
  if type(id) ~= "number" and type(id) ~= "string" then
    id = nil
  end
  local name = type(e.name) == "string" and e.name or nil
  if e.type == "macro" and not name then
    return nil -- restored by name only
  end
  if id == nil and not name then
    return nil
  end
  return { type = e.type, id = id, name = name }
end

function F:Import()
  local old = _G.SpecGearSwapDB
  if type(old) ~= "table" then
    return
  end
  local map = { enabled = "autoSwap", learn = "learn", byName = "byName", autoSave = "autoSave",
    barRestore = "barRestore" }
  for from, to in pairs(map) do
    if type(old[from]) == "boolean" then
      self.db[to] = old[from]
    end
  end
  if type(old.links) == "table" then
    local links = {}
    for g, link in pairs(old.links) do
      if type(g) == "number" and type(link) == "table" and type(link.name) == "string" then
        links[g] = { name = link.name, id = type(link.id) == "number" and link.id or nil }
      end
    end
    self.char.links = links
  end
  if type(old.bars) == "table" then
    local bars = {}
    for g, slots in pairs(old.bars) do
      if type(g) == "number" and type(slots) == "table" then
        local copy = {}
        for slot, e in pairs(slots) do
          if type(slot) == "number" and slot >= 1 and slot <= MAX_SLOTS then
            local c = CopyBarEntry(e)
            if c ~= nil then
              copy[slot] = c
            end
          end
        end
        bars[g] = copy
      end
    end
    self.char.bars = bars
  end
end

function F:GetStatus()
  local id, name = SetForGroup(ActiveGroup())
  return "Active · " .. SpecLabel(ActiveGroup()) .. " uses " .. (id and name or "no set")
end

local function ParseGroup(s)
  local g = tonumber(s)
  if g and g >= 1 and g <= NumGroups() then
    return g
  end
end

F.commands = {
  { name = "sets", aliases = { "list" }, help = "your gear sets", always = true, run = function(self)
    local ids = SetIDs()
    if #ids == 0 then
      self:Print("you have no gear sets.")
      return
    end
    self:Print("your gear sets:")
    for _, id in ipairs(ids) do
      local name, _, isEquipped, numLost = SetInfo(id)
      if name then
        print(string.format("   %s%s%s", name, isEquipped and " |cff00ff00(equipped)|r" or "",
          numLost > 0 and string.format(" |cffff8080(%d missing)|r", numLost) or ""))
      end
    end
    print(self:SpecsText(true))
  end },
  { name = "link", args = "[spec]", help = "links the set you're wearing to this spec (or spec 1 / 2)",
    run = function(self, rest) self:LinkWorn(ParseGroup(rest)) end },
  { name = "assign", args = "<spec> <set name>", help = "links a set to a spec by name", run = function(self, _, raw)
    local gs, name = raw:match("^(%d)%s+(.+)$")
    local g = ParseGroup(gs)
    if not g then
      self:Print("usage: /arl gear assign <1-" .. NumGroups() .. "> <set name>")
      return
    end
    local id = FindSetByName(name)
    if not id then
      self:Print("no gear set named \"" .. name .. "\". /arl gear sets lists them.")
      return
    end
    Link(g, id)
    if g == ActiveGroup() and self.db.autoSwap ~= false then
      EquipForGroup(g, true)
    end
  end },
  { name = "unlink", args = "<spec>", help = "removes a spec's link", run = function(self, rest)
    local g = ParseGroup(rest)
    if not g then
      self:Print("usage: /arl gear unlink <1-" .. NumGroups() .. ">")
      return
    end
    Links()[g] = nil
    self:Print(SpecLabel(g) .. " link cleared.")
    ARLE:Changed()
  end },
  { name = "equip", help = "puts on this spec's set now", run = function(self) self:EquipNow() end },
  { name = "save", help = "saves what you're wearing into that set now", run = function(self)
    if not wornSet or not SetInfo(wornSet) then
      self:Print("not wearing a set (put one on first).")
      return
    end
    if InCombatLockdown() then
      self:Print("can't save a set in combat.")
      return
    end
    SaveWorn(true)
  end },
  { name = "why", help = "would a gear change be saved right now, and if not, why", run = function(self)
    if not wornSet or not SetInfo(wornSet) then
      self:Print("not wearing a set.")
      return
    end
    local changes, reason = GearChanges(wornSet)
    self:Print(SetInfo(wornSet) .. ": " .. (changes and (reason .. " slot(s) differ, it would be saved")
      or ("no save: " .. reason)))
  end },
  { name = "restore", help = "fills empty action slots from the backup now", run = function(self) self:RestoreNow() end },
  { name = "backup", help = "backs up the action bars as they are now", run = function(self) self:SnapshotNow() end },
}

ARLE:RegisterModule(F)
