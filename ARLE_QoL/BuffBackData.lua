-- Buff Back: what each class can put on somebody else on WoW Forever, the level
-- each rank is learned at, and the names players type for each buff.
--
-- The spell ids, rank levels, blockers and chat nicknames are taken from
-- Manners by Sacha (https://github.com/fpsacha/Manners, Buffs.lua and
-- Requests.lua, version 1.11.26), which checked them against Forever's own
-- spell data. Manners is under the MIT License:
--
--   Copyright (c) 2026 Sacha
--
--   Permission is hereby granted, free of charge, to any person obtaining a
--   copy of this software and associated documentation files (the "Software"),
--   to deal in the Software without restriction, including without limitation
--   the rights to use, copy, modify, merge, publish, distribute, sublicense,
--   and/or sell copies of the Software, and to permit persons to whom the
--   Software is furnished to do so, subject to the following conditions:
--
--   The above copyright notice and this permission notice shall be included in
--   all copies or substantial portions of the Software.
--
--   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
--   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
--   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
--   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
--   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
--   FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
--   IN THE SOFTWARE.
--
-- Fields of a buff (Forever's set: Classic Era's, without Salvation, Light and
-- Sanctuary, with Kings and Divine Spirit trained; no shaman, hunter or rogue
-- buffs for others):
--   key        stable id, used in settings
--   ranks      castable spell ids, highest first (the macro names a rank for a
--              target too low for the top one: a cast lands within ten levels)
--   group      other ids that count as the buff already being there (the
--              party-wide versions)
--   blockers   auras that refuse the cast ("A more powerful spell is already
--              active"): scrolls, camping buffs, other sources of the stat
--   manaOnly   only for classes with mana (grid default)
--   meleeOnly  attack power: not for mages, warlocks, priests (grid default)
--   tanks      thorns: default only for classes that tank
--   optIn      off for every class until ticked (grid default)
--   returnOnly given back to whoever buffed you, or asked for by name; never
--              offered to the group on its own (Unending Breath)
--   membersOnly only to your party or raid
--   selfCast   cast on yourself, reaches your party (Battle Shout)
--   exclusive  (class-level) one of these per target from you: a paladin's
--              blessings overwrite each other
local _, ns = ...
local D = {}
ns.BuffBackData = D

D.BUFFS = {
  MAGE = {
    { key = "intellect", ranks = { 10157, 10156, 1461, 1460, 1459 }, group = { 23028 }, manaOnly = true,
      blockers = { 8096, 8097, 8098, 12176, 1229513, 364161, 13326, 16876 } },
  },
  PRIEST = {
    { key = "fortitude", ranks = { 10938, 10937, 2791, 1245, 1244, 1243 }, group = { 21564, 21562 },
      blockers = { 8099, 8100, 8101, 12178, 1230124 } },
    { key = "spirit", ranks = { 27841, 14819, 14818, 14752 }, group = { 27681 }, manaOnly = true,
      blockers = { 8112, 8113, 8114, 12177, 1229718 } },
    { key = "shadow", ranks = { 10958, 10957, 976 }, group = { 27683 }, optIn = true },
  },
  DRUID = {
    { key = "motw", ranks = { 9885, 9884, 8907, 5234, 6756, 5232, 1126 }, group = { 21850, 21849 } },
    { key = "thorns", ranks = { 9910, 9756, 8914, 1075, 782, 467 }, tanks = true },
  },
  PALADIN = {
    exclusive = true,
    -- Kings first: the one a paladin with it gives everybody.
    { key = "kings", ranks = { 20217 }, group = { 25898 } },
    { key = "wisdom", ranks = { 25290, 19854, 19853, 19852, 19850, 19742 }, group = { 25918, 25894 },
      manaOnly = true },
    { key = "might", ranks = { 25291, 19838, 19837, 19836, 19835, 19834, 19740 }, group = { 25916, 25782 },
      meleeOnly = true },
  },
  WARLOCK = {
    { key = "breath", ranks = { 5697 }, group = { 131 }, returnOnly = true },
    { key = "detectgroup", ranks = { 11743, 2970, 132 }, membersOnly = true, optIn = true },
  },
  WARRIOR = {
    { key = "battleshout", ranks = { 25289, 11551, 11550, 11549, 6192, 5242, 6673 }, selfCast = true },
  },
}

-- The level each rank is learned at (vanilla trainers; Forever trains Kings
-- and Divine Spirit). A rank missing here counts as level 1.
D.RANK_LEVEL = {
  [1459] = 1, [1460] = 14, [1461] = 28, [10156] = 42, [10157] = 56,
  [1243] = 1, [1244] = 12, [1245] = 24, [2791] = 36, [10937] = 48, [10938] = 60,
  [976] = 30, [10957] = 42, [10958] = 56,
  [1126] = 1, [5232] = 10, [6756] = 20, [5234] = 30, [8907] = 40, [9884] = 50, [9885] = 60,
  [467] = 6, [782] = 14, [1075] = 24, [8914] = 34, [9756] = 44, [9910] = 54,
  [19742] = 14, [19850] = 24, [19852] = 34, [19853] = 44, [19854] = 54, [25290] = 60,
  [19740] = 4, [19834] = 12, [19835] = 22, [19836] = 32, [19837] = 42, [19838] = 52, [25291] = 60,
  [5697] = 16,
  [20217] = 20, [14752] = 30, [14818] = 40, [14819] = 50, [27841] = 60,
  [132] = 26, [2970] = 38, [11743] = 50,
}

-- The names players type for each buff, lower case. A leading ~ marks a
-- looser word (an everyday word too): it counts only with a please, or alone,
-- and never in group chat ("mark pls" is about raid markers there).
D.ASK_NAMES = {
  intellect = { "int", "intellect", "ai", "arcane intellect", "brilliance", "arcane brilliance", "inte" },
  fortitude = { "fort", "fortitude", "stam", "stamina", "pwf", "pw f", "power word fortitude",
    "prayer of fortitude", "stamina" },
  spirit = { "divine spirit", "prayer of spirit", "~spirit" },
  shadow = { "shadow prot", "shadow protection", "sprot", "prayer of shadow protection", "~shadow" },
  motw = { "motw", "gotw", "mark of the wild", "gift of the wild", "~mark" },
  thorns = { "thorns" },
  wisdom = { "bow", "blessing of wisdom", "~wisdom" },
  might = { "bom", "blessing of might", "~might" },
  kings = { "kings", "bok", "blessing of kings" },
  breath = { "unending breath", "water breathing", "ub", "~breath" },
  detectgroup = { "detect invisibility", "detect invis", "detect lesser invisibility",
    "detect greater invisibility" },
  battleshout = { "battle shout", "~shout" },
}

-- "buff pls" asks for every buff you'd give them (English and Portuguese).
D.GENERIC = { buff = true, buffs = true, buffa = true, bufa = true }
-- Words that make it a request.
D.PLEASE = { pls = true, plz = true, please = true, pleas = true, plox = true, ty = true, need = true,
  pf = true, pfv = true, pfvr = true, porfa = true, ["por favor"] = true, preciso = true, quero = true,
  can = true, could = true, any = true, anyone = true, someone = true, alguem = true, ["alguém"] = true,
  pode = true, podes = true, da = true, ["dá"] = true }
-- Small words that may stand beside a buff's name in a bare request ("int me").
D.FILLER = { me = true, i = true, on = true, a = true, some = true, get = true, the = true, ["for"] = true,
  mim = true, pra = true, para = true, um = true, uma = true, o = true, e = true, ["and"] = true }
-- Words that say no.
D.NO = { no = true, ["don't"] = true, dont = true, nao = true, ["não"] = true, stop = true, without = true,
  sem = true }

-- Classes with mana (manaOnly) and the casters attack power does nothing for (meleeOnly).
D.MANA = { PALADIN = true, HUNTER = true, PRIEST = true, SHAMAN = true, MAGE = true, WARLOCK = true, DRUID = true }
D.CASTERS = { MAGE = true, WARLOCK = true, PRIEST = true }
D.TANKS = { WARRIOR = true, PALADIN = true, DRUID = true }

-- The grid's rows, in the game's class order.
D.CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

-- Every id that marks a buff somebody else put on you (any class's): what a
-- favour is.
D.FAVOUR_IDS = {}
for _, list in pairs(D.BUFFS) do
  for _, buff in ipairs(list) do
    for _, id in ipairs(buff.ranks) do
      D.FAVOUR_IDS[id] = true
    end
    for _, id in ipairs(buff.group or {}) do
      D.FAVOUR_IDS[id] = true
    end
  end
end
