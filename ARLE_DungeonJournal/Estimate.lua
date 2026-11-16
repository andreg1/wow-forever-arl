-- Estimated scores for party members who don't run this addon.
--
-- Forever Leveling BiS can only score items exactly for the player it runs
-- for. For anyone else we take their class, level and the spec picked for
-- them in the window, ask our own Forever Leveling BiS for that spec's stat
-- weights (public API: GetWeights), read item stats from the game
-- (C_Item.GetItemStats) and add them up. Close to its numbers, not equal:
-- it scores from its own item data with more rules (weapon speed, racial
-- bonuses, random suffixes). Nothing of its data or code is copied here.
local _, ns = ...

local Estimate = {}
ns.Estimate = Estimate

local GetItemStats = (C_Item and C_Item.GetItemStats) or _G.GetItemStats
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant

-- Game stat keys -> Forever Leveling BiS weight keys (see its API.md).
-- Forever gear carries percentage stats (1 = 1%), reported under the
-- rating keys.
local STAT_KEYS = {
  ITEM_MOD_STRENGTH_SHORT = "str",
  ITEM_MOD_AGILITY_SHORT = "agi",
  ITEM_MOD_STAMINA_SHORT = "sta",
  ITEM_MOD_INTELLECT_SHORT = "int",
  ITEM_MOD_SPIRIT_SHORT = "spi",
  ITEM_MOD_ATTACK_POWER_SHORT = "atkpwr",
  ITEM_MOD_RANGED_ATTACK_POWER_SHORT = "rgdatkpwr",
  ITEM_MOD_FERAL_ATTACK_POWER_SHORT = "feratkpwr",
  ITEM_MOD_SPELL_POWER_SHORT = "splpwr",
  ITEM_MOD_SPELL_DAMAGE_DONE_SHORT = "spldmg",
  ITEM_MOD_SPELL_HEALING_DONE_SHORT = "splheal",
  ITEM_MOD_MANA_REGENERATION_SHORT = "manargn",
  ITEM_MOD_HEALTH_REGENERATION_SHORT = "healthrgn",
  ITEM_MOD_DEFENSE_SKILL_RATING_SHORT = "defrtng",
  ITEM_MOD_BLOCK_VALUE_SHORT = "block",
  ITEM_MOD_EXPERTISE_RATING_SHORT = "exprtng",
  ITEM_MOD_SPELL_PENETRATION_SHORT = "splpen",
  RESISTANCE0_NAME = "armor",
  ITEM_MOD_CRIT_RATING_SHORT = "critPct",
  ITEM_MOD_CRIT_MELEE_RATING_SHORT = "critPct",
  ITEM_MOD_CRIT_RANGED_RATING_SHORT = "critPct",
  ITEM_MOD_CRIT_SPELL_RATING_SHORT = "critPct",
  ITEM_MOD_HIT_RATING_SHORT = "hitPct",
  ITEM_MOD_HIT_MELEE_RATING_SHORT = "hitPct",
  ITEM_MOD_HIT_RANGED_RATING_SHORT = "hitPct",
  ITEM_MOD_HIT_SPELL_RATING_SHORT = "hitPct",
  ITEM_MOD_DODGE_RATING_SHORT = "dodgePct",
  ITEM_MOD_PARRY_RATING_SHORT = "parryPct",
  ITEM_MOD_BLOCK_RATING_SHORT = "blockPct",
}

-- Armor: 1 cloth, 2 leather, 3 mail, 4 plate (item subclass IDs).
local function MaxArmor(class, level)
  if class == "WARRIOR" or class == "PALADIN" then
    return (level or 0) >= 40 and 4 or 3
  elseif class == "HUNTER" or class == "SHAMAN" then
    return (level or 0) >= 40 and 3 or 2
  elseif class == "ROGUE" or class == "DRUID" then
    return 2
  end
  return 1
end

-- Weapon subclass IDs each class can wield (Classic proficiencies).
-- 0 1H axe, 1 2H axe, 2 bow, 3 gun, 4 1H mace, 5 2H mace, 6 polearm,
-- 7 1H sword, 8 2H sword, 10 staff, 13 fist, 15 dagger, 16 thrown,
-- 18 crossbow, 19 wand.
local function Set(list)
  local s = {}
  for _, v in ipairs(list) do
    s[v] = true
  end
  return s
end
local WEAPONS = {
  WARRIOR = Set({ 0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 13, 15, 16, 18 }),
  PALADIN = Set({ 0, 1, 4, 5, 6, 7, 8 }),
  HUNTER = Set({ 0, 1, 2, 3, 6, 7, 8, 10, 13, 15, 16, 18 }),
  ROGUE = Set({ 2, 3, 4, 7, 13, 15, 16, 18 }),
  PRIEST = Set({ 4, 10, 15, 19 }),
  SHAMAN = Set({ 0, 1, 4, 5, 10, 13, 15 }),
  MAGE = Set({ 7, 10, 15, 19 }),
  WARLOCK = Set({ 7, 10, 15, 19 }),
  DRUID = Set({ 4, 5, 10, 13, 15 }),
}
local SHIELDS = { WARRIOR = true, PALADIN = true, SHAMAN = true }

-- Whether the class can wear or wield the item at that level.
function Estimate.CanUse(itemID, class, level)
  local _, _, _, loc, _, classID, subclassID = GetItemInfoInstant(itemID)
  if classID == 4 then
    if subclassID == 6 then
      return SHIELDS[class] == true
    end
    if subclassID and subclassID >= 1 and subclassID <= 4 and loc ~= "INVTYPE_CLOAK" then
      return subclassID <= MaxArmor(class, level)
    end
    return true -- rings, necks, trinkets, cloaks, off-hand items
  elseif classID == 2 then
    local allowed = WEAPONS[class]
    return allowed == nil or allowed[subclassID] == true
  end
  return false
end

local function DpsKey(loc)
  if loc == "INVTYPE_RANGED" or loc == "INVTYPE_RANGEDRIGHT" or loc == "INVTYPE_THROWN" then
    return "rangedDps"
  elseif loc == "INVTYPE_WEAPONOFFHAND" then
    return "ohDps"
  end
  return "dps"
end

-- Score of one item for the weights, or nil while its stats are loading.
function Estimate.Score(item, weights)
  if not item or not weights then
    return 0
  end
  local link = type(item) == "number" and ("item:" .. item) or item
  local stats = GetItemStats(link)
  if not stats then
    local id = tonumber(tostring(link):match("item:(%d+)"))
    if id and C_Item and C_Item.RequestLoadItemDataByID then
      C_Item.RequestLoadItemDataByID(id)
    end
    return nil
  end
  local _, _, _, loc = GetItemInfoInstant(link)
  local score = 0
  for key, value in pairs(stats) do
    local w
    if key == "ITEM_MOD_DAMAGE_PER_SECOND_SHORT" then
      w = weights[DpsKey(loc)]
    else
      w = weights[STAT_KEYS[key] or ""]
    end
    if w and tonumber(value) then
      score = score + value * w
    end
  end
  return score
end

-- Inventory slots an item competes with, and how to read what is worn there:
-- the weaker of two rings or trinkets; a two-hander against main + off hand.
local PAIRS = { INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 } }
local SINGLE = {
  INVTYPE_HEAD = 1, INVTYPE_NECK = 2, INVTYPE_SHOULDER = 3, INVTYPE_CHEST = 5, INVTYPE_ROBE = 5,
  INVTYPE_WAIST = 6, INVTYPE_LEGS = 7, INVTYPE_FEET = 8, INVTYPE_WRIST = 9, INVTYPE_HAND = 10,
  INVTYPE_CLOAK = 15, INVTYPE_WEAPON = 16, INVTYPE_WEAPONMAINHAND = 16, INVTYPE_WEAPONOFFHAND = 17,
  INVTYPE_SHIELD = 17, INVTYPE_HOLDABLE = 17, INVTYPE_RANGED = 18, INVTYPE_RANGEDRIGHT = 18,
  INVTYPE_THROWN = 18, INVTYPE_RELIC = 18,
}

-- Score of what is worn where the item would go; nil while loading.
local function WornScore(loc, worn, weights)
  local function At(slot)
    local item = worn[slot]
    if not item then
      return 0
    end
    return Estimate.Score(item, weights)
  end
  if PAIRS[loc] then
    local a, b = At(PAIRS[loc][1]), At(PAIRS[loc][2])
    if not a or not b then
      return nil
    end
    return math.min(a, b)
  elseif loc == "INVTYPE_2HWEAPON" then
    local a, b = At(16), At(17)
    if not a or not b then
      return nil
    end
    return a + b
  elseif SINGLE[loc] then
    return At(SINGLE[loc])
  end
  return 0
end

-- gains[itemID] = estimated gain over worn gear, for items that gain
-- something. member = { class, level, spec, worn = { slot = link or ID } }.
-- Returns gains, loading (true when some stats were not there yet).
function Estimate.Gains(member, items, api)
  local gains, loading = {}, false
  local weights = api and api.GetWeights and api.GetWeights(member.class, member.spec, member.level)
  if type(weights) ~= "table" then
    return gains, false
  end
  for _, item in ipairs(items) do
    if Estimate.CanUse(item.id, member.class, member.level) then
      local score = Estimate.Score(item.id, weights)
      local base = WornScore(item.loc, member.worn or {}, weights)
      if not score or not base then
        loading = true
      elseif score - base > 0 then
        gains[item.id] = score - base
      end
    end
  end
  return gains, loading
end
