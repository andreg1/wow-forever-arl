-- Auto Uprank: when you (or your pet) learn a higher rank of a spell, every
-- lower rank of it on your action bars is swapped for the new one, and chat
-- says so.
--
-- Our own code, written against Blizzard's API (EllesmereUI has a similar
-- option, but its code is all rights reserved, so nothing of it is used).
-- When EllesmereUI's "Auto Uprank Spells on Bars" is on
-- (EllesmereUIDB.spellUprank.enabled), this one stands aside so the two
-- don't both swap and both report.
--
-- How:
--   * The highest rank of every active spell in your spellbook is read by
--     name (ranks share a name; C_SpellBook.IsSpellBookItemLowRank tells
--     them apart, else the last rank in the book wins, as books list ranks
--     lowest first). The same for your pet's spellbook.
--   * The highest rank seen per name is kept per character (char.top) and per
--     pet (char.pets["family:name"]). A name whose highest rank changed is
--     upranked on the bars. So a rank learned while this was off, or while
--     the pet was away, is caught at the next check.
--   * The first check on a character only records what you know: lower ranks
--     you placed on purpose before turning this on stay. "Uprank all now"
--     (/arl uprank all) swaps every lower rank on the bars once.
--   * Swapping = pick the new rank up and drop it on the slot
--     (C_Spell.PickupSpell / PlaceAction / ClearCursor), the same thing you'd do by hand. Only out
--     of combat (bars are locked in combat) and with an empty cursor (it
--     waits for you to drop whatever you're holding).
--   * Only "spell" actions are touched: macros and items never are. A bar
--     spell is only replaced by a rank of the same spell name, and only when
--     it's yours (a known player spell) or, for pet spells, no longer known.
local ADDON = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end

local MAX_SLOT = 180

local F = {
  id = "AutoUprank",
  addon = ADDON,
  title = "Auto Uprank",
  group = "QualityOfLife",
  command = "uprank",
  commandHelp = "swaps lower spell ranks on your bars when you learn a new rank",
  description = "When you or your pet learn a higher rank of a spell, every lower rank of it on your action bars "
    .. "is swapped for the new one (out of combat). Stands aside while EllesmereUI's own Auto Uprank is on.",
  options = {
    { key = "pet", type = "boolean", label = "Pet spells too", default = true },
    { key = "chat", type = "boolean", label = "Chat message for each uprank", default = true },
    { type = "info", text = function(def) return def:StatusText() end },
    { type = "button", label = "Uprank all now", desc = "swaps every lower rank on your bars once", nocmd = true,
      run = function(def) def:UprankAll() end },
  },
}

-------------------------------------------------------------------------------
-- API (feature-checked: names differ between clients)
-------------------------------------------------------------------------------

local SB = C_SpellBook
local BANK_PLAYER = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player
local BANK_PET = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Pet
local TYPE_SPELL = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell

-- (the host's shared helpers: ARLExtensions/Lib/Util.lua)
local Lib = ARLE.Lib
local Call, SpellName = Lib.Call, Lib.SpellName

-- v when the client doesn't hide it and it's of that type (number by default).
local function Readable(v, kind)
  v = Lib.Plain(v)
  if type(v) == (kind or "number") then
    return v
  end
end

local function IsPlayerSpellKnown(id)
  if SB and SB.IsSpellKnown then
    return Call(SB.IsSpellKnown, id) and true or false
  end
  return Call(IsSpellKnown, id) and true or false
end

local PickupSpellByID = (C_Spell and C_Spell.PickupSpell) or _G.PickupSpell

local function Supported()
  return SB and SB.GetNumSpellBookSkillLines and SB.GetSpellBookSkillLineInfo and SB.GetSpellBookItemInfo
    and BANK_PLAYER ~= nil and PickupSpellByID ~= nil and PlaceAction ~= nil and GetActionInfo ~= nil
end

-- EllesmereUI's own Auto Uprank (Forever Essentials) is on.
local function EllesmereUprankOn()
  local db = _G.EllesmereUIDB
  local c = type(db) == "table" and db.spellUprank
  return type(c) == "table" and c.enabled == true
end

-------------------------------------------------------------------------------
-- Spellbooks
-------------------------------------------------------------------------------

-- name -> spellID of the highest rank you know (active spells only).
local function PlayerBook()
  local top = {}
  for line = 1, (Call(SB.GetNumSpellBookSkillLines) or 0) do
    local info = Call(SB.GetSpellBookSkillLineInfo, line)
    if type(info) == "table" and not info.offSpecID and info.itemIndexOffset and info.numSpellBookItems then
      for slot = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
        local item = Call(SB.GetSpellBookItemInfo, slot, BANK_PLAYER)
        local id = type(item) == "table" and Readable(item.spellID)
        local name = type(item) == "table" and Readable(item.name, "string")
        local isSpell = type(item) == "table" and (TYPE_SPELL == nil or item.itemType == TYPE_SPELL)
        if id and name and isSpell and not item.isPassive then
          local low = SB.IsSpellBookItemLowRank and Call(SB.IsSpellBookItemLowRank, slot, BANK_PLAYER)
          if not low then
            top[name] = id -- (without the low-rank check, the book's last rank wins)
          end
        end
      end
    end
  end
  return top
end

-- name -> spellID of the pet's highest rank, and spellID -> book slot for
-- every rank it knows; nil when there's no pet with spells.
local function PetBook()
  if not (BANK_PET and SB.HasPetSpells) then
    return nil
  end
  local n = Call(SB.HasPetSpells)
  if not n or n == 0 then
    return nil
  end
  local top, slots = {}, {}
  for slot = 1, n do
    local item = Call(SB.GetSpellBookItemInfo, slot, BANK_PET)
    local id = type(item) == "table" and Readable(item.spellID)
    local name = type(item) == "table" and Readable(item.name, "string")
    if id and name and not item.isPassive then
      slots[id] = slot
      local low = SB.IsSpellBookItemLowRank and Call(SB.IsSpellBookItemLowRank, slot, BANK_PET)
      if not low then
        top[name] = id
      end
    end
  end
  return top, slots
end

-- "family:name": two of a hunter's pets are told apart.
local function PetKey()
  if not UnitExists("pet") then
    return nil
  end
  local family = Readable(UnitCreatureFamily("pet"), "string")
  local name = Readable(UnitName("pet"), "string")
  if not name or name == UNKNOWNOBJECT then
    return nil
  end
  return (family or "?") .. ":" .. name
end

-------------------------------------------------------------------------------
-- Swapping
-------------------------------------------------------------------------------

local queued = { player = {}, pet = {} } -- names to uprank on the bars
local waitingCursor = false

local function Report(counts)
  if F.db.chat == false then
    return
  end
  for id, count in pairs(counts) do
    local link = (C_Spell and C_Spell.GetSpellLink and Call(C_Spell.GetSpellLink, id)) or SpellName(id) or "?"
    local rank = C_Spell and C_Spell.GetSpellSubtext and Call(C_Spell.GetSpellSubtext, id)
    F:Print(("upranked %s%s on %d action slot%s."):format(link,
      (type(rank) == "string" and rank ~= "") and (" (" .. rank .. ")") or "", count, count == 1 and "" or "s"))
  end
end

-- The pickup worked: PlaceAction with an empty cursor would lift the old
-- spell off the bar instead, and ClearCursor would then drop it.
local function Holding()
  local kind = GetCursorInfo()
  return kind == "spell" or kind == "petaction"
end

-- Swaps the queued names on all bars. Out of combat, empty cursor.
local function SwapQueued()
  local wantPlayer, wantPet = next(queued.player) ~= nil, next(queued.pet) ~= nil
  if not (wantPlayer or wantPet) then
    return
  end
  local playerTop = wantPlayer and PlayerBook() or {}
  local petTop, petSlots
  if wantPet then
    petTop, petSlots = PetBook()
  end
  local counts = {}
  for slot = 1, MAX_SLOT do
    local kind, id = GetActionInfo(slot)
    id = kind == "spell" and Readable(id)
    local name = id and SpellName(id)
    if name then
      local newPlayer = queued.player[name] and playerTop[name]
      local newPet = petTop and queued.pet[name] and petTop[name]
      if newPlayer and newPlayer ~= id and IsPlayerSpellKnown(id) then
        PickupSpellByID(newPlayer)
        if Holding() then
          PlaceAction(slot)
          counts[newPlayer] = (counts[newPlayer] or 0) + 1
        end
        ClearCursor()
      elseif newPet and newPet ~= id and not IsPlayerSpellKnown(id) and petSlots[newPet]
        and SB.PickupSpellBookItem then
        SB.PickupSpellBookItem(petSlots[newPet], BANK_PET)
        if Holding() then
          PlaceAction(slot)
          counts[newPet] = (counts[newPet] or 0) + 1
        end
        ClearCursor()
      end
    end
  end
  wipe(queued.player)
  wipe(queued.pet)
  Report(counts)
end

local function Flush()
  if not (next(queued.player) or next(queued.pet)) then
    return
  end
  if InCombatLockdown() then
    F:OutOfCombat(Flush)
    return
  end
  if GetCursorInfo() then
    -- You're holding something: try again once the cursor changes.
    if not waitingCursor then
      waitingCursor = F:On("CURSOR_CHANGED", function()
        if not GetCursorInfo() then
          F:Off("CURSOR_CHANGED")
          waitingCursor = false
          Flush()
        end
      end)
    end
    return
  end
  SwapQueued()
end

-------------------------------------------------------------------------------
-- Checks
-------------------------------------------------------------------------------

-- Compares the books with the remembered highest ranks; a changed name is
-- queued (unless this is the character's first look, which only records).
local function Check()
  if EllesmereUprankOn() then
    return
  end
  local char = F.char
  local first = type(char.top) ~= "table"
  char.top = first and {} or char.top
  for name, id in pairs(PlayerBook()) do
    if char.top[name] ~= id then
      if not first and char.top[name] ~= nil then
        queued.player[name] = true
      end
      char.top[name] = id
    end
  end
  if F.db.pet ~= false then
    local key = PetKey()
    local petTop = key and PetBook()
    if petTop then
      char.pets = type(char.pets) == "table" and char.pets or {}
      local known = char.pets[key]
      local firstPet = type(known) ~= "table"
      known = firstPet and {} or known
      char.pets[key] = known
      for name, id in pairs(petTop) do
        if known[name] ~= id then
          if not firstPet and known[name] ~= nil then
            queued.pet[name] = true
          end
          known[name] = id
        end
      end
    end
  end
  Flush()
end

local function Queue(self, delay)
  self:Debounce("check", delay or 0.5, Check)
end

function F:UprankAll()
  if not self._active then
    self:Print("turn it on first (/arl uprank on).")
    return
  end
  if EllesmereUprankOn() then
    self:Print("EllesmereUI's Auto Uprank is on and does this already.")
    return
  end
  for name in pairs(PlayerBook()) do
    queued.player[name] = true
  end
  if self.db.pet ~= false then
    local petTop = PetBook()
    for name in pairs(petTop or {}) do
      queued.pet[name] = true
    end
  end
  if InCombatLockdown() then
    self:Print("after combat.")
  end
  Flush()
end

function F:StatusText()
  if not Supported() then
    return "This client is missing the spellbook API it needs."
  end
  if EllesmereUprankOn() then
    return "Standing aside: EllesmereUI's Auto Uprank Spells on Bars is on."
  end
  local n = 0
  for _ in pairs(type(self.char.top) == "table" and self.char.top or {}) do
    n = n + 1
  end
  return n > 0 and ("Watching " .. n .. " spells.") or "Reads your spellbook at the next spell change."
end

function F:GetStatus()
  return "Active · " .. self:StatusText()
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function F:OnEnable()
  wipe(queued.player)
  wipe(queued.pet)
  waitingCursor = false
  if not Supported() then
    self:Print("this client is missing the spellbook API it needs; nothing will be swapped.")
    return
  end
  if EllesmereUprankOn() then
    self:Print("EllesmereUI's Auto Uprank Spells on Bars is on, so this stands aside (turn one of them off).")
  end
  -- SPELLS_CHANGED covers everything (a pet learning a rank fires only
  -- that); the others just make it quicker. Missing events are skipped.
  self:On("SPELLS_CHANGED", function() Queue(self, 0.5) end)
  self:On("LEARNED_SPELL_IN_SKILL_LINE", function() Queue(self, 0.2) end)
  self:On("PET_BAR_UPDATE", function() Queue(self, 0.5) end)
  self:OnUnit("UNIT_PET", "player", function() Queue(self, 1) end)
  -- (A Debounce from OnEnable at login runs after the spellbook is there.)
  Queue(self, 2)
end

function F:OnDisable()
  wipe(queued.player)
  wipe(queued.pet)
  waitingCursor = false
end

F.commands = {
  { name = "all", help = "swaps every lower rank on your bars once", run = function(self) self:UprankAll() end },
}

ARLE:RegisterModule(F)
