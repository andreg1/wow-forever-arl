-- XP Food: reminds you to eat your experience food while leveling.
--
-- Our own code. Forever SnackTrack does the same, but it ships with no
-- license (all rights reserved), so none of its code is used; this follows
-- what it does, on Blizzard's API:
--
--  * XP food and the XP buff are found by reading tooltips
--    (C_TooltipInfo.GetBagItem / GetUnitBuff), not by item or spell IDs: a
--    line with an "experience", a "kill" and an "increase" word (per locale)
--    gives the percent next to those words. Food is Consumable / Food & Drink
--    (class 0, subclass 5) in bags 0..NUM_BAG_SLOTS. Results are cached per
--    itemID / spellID; a tooltip still loading is never cached as "no XP".
--  * Gourmand (Legacy talent, spell 1225499) makes a serving last
--    15 + 5 x rank minutes; read through C_Traits for the supply line.
--  * One reminder at a time: XP food in the bags beats the active XP buff
--    ("missing"), or, optionally, no XP food at all ("nofood"); a low-stock
--    line once per restock; a chat warning before the buff ends.
--  * Nothing below 60 is reminded at 60; not while resting unless asked; the
--    alert hides in combat, while dead, flying or on a flight path.
--
-- The alert is our own frame. Its food icon is the host's secure item button
-- "UseFood" (only its attributes change, out of combat; left-click eats,
-- right-click opens our own menu). The Cozy Sleeping Bag is the Sleeping Bag
-- feature's job, not this one's.
local ADDON = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local Skin, Kit, Secure, Items = ARLE.Skin, ARLE.UI.Kit, ARLE.Secure, ARLE.Lib.Items

-- A value the client hides (secret): never index, walk or compare it.
local Secret = ARLE.Lib.IsSecret

local MAX_LEVEL = 60
local GOURMAND = 1225499
local FOOD_ICON = 133964 -- INV_Misc_Food_15 (fallback)
local SNOOZE = { 1, 5, 10, 15, 30, 60 }

local snoozeValues = {}
for _, m in ipairs(SNOOZE) do
  snoozeValues[#snoozeValues + 1] = { value = m, label = m .. " min" }
end

local F = {
  id = "XPFood",
  addon = ADDON,
  title = "XP Food",
  group = "QualityOfLife",
  command = "food",
  commandHelp = "experience food reminders",
  description = "Reminds you to eat your experience food when its buff is missing, weaker or ending, "
    .. "and when you run low.",
  options = {
    { type = "header", label = "Reminders" },
    { key = "combatOnly", type = "boolean", label = "Only when a fight starts without an XP buff",
      tooltip = "No reminders out of combat. When you pull with XP food in your bags but no XP buff (or a weaker "
        .. "one), the alert bar warns you, at most once a minute. You can't eat in combat: eat after the fight.",
      default = false, cmd = "combat" },
    { key = "chat", type = "boolean", label = "Chat message", default = true },
    { key = "screen", type = "boolean", label = "On-screen alert", default = true },
    { key = "noFood", type = "boolean", label = "Remind when I have no XP food", default = false, cmd = "nofood" },
    { key = "whileResting", type = "boolean", label = "Remind in rested areas (towns, inns)", default = false,
      cmd = "resting" },
    { key = "repeatMinutes", type = "range", label = "Repeat every (minutes, 0 = once)", min = 0, max = 60, step = 1,
      default = 1, cmd = "repeat" },
    { key = "snoozeMinutes", type = "select", label = "Snooze for", values = snoozeValues, default = 1,
      cmd = "snooze" },
    { key = "expiryMinutes", type = "range", label = "Warn in chat before the buff ends (minutes, 0 = off)",
      min = 0, max = 15, step = 1, default = 5, cmd = "expiry" },
    { key = "lowStock", type = "range", label = "Low stock at (servings, 0 = off)", min = 0, max = 20, step = 1,
      default = 0, cmd = "low" },
    { type = "header", label = "Alert" },
    { key = "iconMode", type = "boolean", label = "Icon only (right-click it for the menu)", default = false,
      cmd = "icon" },
    { key = "scale", type = "range", label = "Size (%)", min = 25, max = 150, step = 5, default = 100 },
    { type = "info", text = function(def) return def:StatusLine() end },
    { type = "button", label = "Show a test alert", desc = "for 20 seconds, so you can move it", nocmd = true,
      run = function(def) def:Test() end },
    ARLE.Options.Preset.ResetPosition(),
    ARLE.Options.Preset.Alert({ header = "When a fight starts without an XP buff" }),
  },
}

-------------------------------------------------------------------------------
-- Words (facts: how each client writes "increases experience from kills")
-------------------------------------------------------------------------------

local TERMS = {
  enUS = { xp = { "experience" }, kill = { "kill" }, up = { "increas" } },
  deDE = { xp = { "erfahrung" }, kill = { "töt", "getöt", "kill", "sieg" }, up = { "erhöh", "steig" } },
  esES = { xp = { "experiencia" }, kill = { "matar", "muert", "asesin" }, up = { "aument", "increment" } },
  frFR = { xp = { "expérience" }, kill = { "tuer", "tué", "ennemi", "victime", "élimin", "adversair" },
    up = { "augment", "accroît" } },
  itIT = { xp = { "esperienza", "experience" }, kill = { "uccis", "uccid", "kill" },
    up = { "aument", "increment", "increas" } },
  ptBR = { xp = { "experiência" }, kill = { "abate", "matar", "morte" }, up = { "aument", "increment" } },
  ruRU = { xp = { "опыт" }, kill = { "убийств", "убит" }, up = { "увелич", "повыш" } },
  koKR = { xp = { "경험치" }, kill = { "처치" }, up = { "증가" } },
  zhCN = { xp = { "经验" }, kill = { "击杀", "击败" }, up = { "提高", "增加" } },
  zhTW = { xp = { "經驗" }, kill = { "擊殺", "擊敗" }, up = { "提高", "增加" } },
}
TERMS.enGB = TERMS.enUS
TERMS.esMX = TERMS.esES

local words = TERMS[GetLocale and GetLocale() or "enUS"] or TERMS.enUS
if words ~= TERMS.enUS then
  -- English as well: some Forever-only items are only written in English.
  local merged = {}
  for k, list in pairs(words) do
    merged[k] = {}
    for _, w in ipairs(list) do
      merged[k][#merged[k] + 1] = w
    end
    for _, w in ipairs(TERMS.enUS[k]) do
      merged[k][#merged[k] + 1] = w
    end
  end
  words = merged
end

-- string.lower only knows ASCII; capitals of the accented and Cyrillic
-- letters these words use are folded by hand.
local FOLD = {}
do
  local upper = "ÄÖÜÁÉÍÓÚÀÈÌÒÙÊÂÎÔÛÇÑ"
  local lower = "äöüáéíóúàèìòùêâîôûçñ"
  local ups, lows = {}, {}
  for ch in upper:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    ups[#ups + 1] = ch
  end
  for ch in lower:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    lows[#lows + 1] = ch
  end
  for i, ch in ipairs(ups) do
    FOLD[ch] = lows[i]
  end
  -- Cyrillic А..Я (U+0410..U+042F) -> а..я (U+0430..U+044F), Ё -> ё.
  local function utf8char(cp)
    return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
  end
  for cp = 0x410, 0x42F do
    FOLD[utf8char(cp)] = utf8char(cp + 0x20)
  end
  FOLD[utf8char(0x401)] = utf8char(0x451)
end

local function Normalize(text)
  text = tostring(text or ""):lower()
  return (text:gsub("[\194-\244][\128-\191]+", FOLD))
end

local function LineText(line)
  if type(line) ~= "table" or Secret(line) then
    return ""
  end
  local left, right = line.leftText, line.rightText
  if Secret(left) or Secret(right) then
    return ""
  end
  return (type(left) == "string" and left or "") .. " " .. (type(right) == "string" and right or "")
end

local function HasAny(text, list)
  for _, w in ipairs(list) do
    if text:find(w, 1, true) then
      return true
    end
  end
end

-- Characters between the span [a, b] and the nearest of list in text.
local function Nearest(text, list, a, b)
  local best = math.huge
  for _, w in ipairs(list) do
    local from = 1
    while true do
      local s, e = text:find(w, from, true)
      if not s then
        break
      end
      local d = 0
      if e < a then
        d = a - e
      elseif s > b then
        d = s - b
      end
      if d < best then
        best = d
      end
      from = e + 1
    end
  end
  return best
end

-- The XP percent one line gives, or nil.
local function LinePercent(text)
  if not (HasAny(text, words.xp) and HasAny(text, words.kill) and HasAny(text, words.up)) then
    return nil
  end
  local best, bestScore
  local from = 1
  while true do
    local s, e, num = text:find("(%d+)%s*%%", from)
    if not s then
      break
    end
    local before = s > 1 and text:sub(s - 1, s - 1) or ""
    local value = tonumber(num)
    if not before:match("[%d%.,]") and value and value > 0 then
      local score = Nearest(text, words.xp, s, e) + 2 * Nearest(text, words.up, s, e)
      if not bestScore or score < bestScore then
        best, bestScore = value, score
      end
    end
    from = e + 1
  end
  return best
end

local LOADING = Normalize(RETRIEVING_ITEM_INFO or "Retrieving item information")
local USE_PREFIX = Normalize((ITEM_SPELL_TRIGGER_ONUSE or "Use:"):match("^[^%%]*")):match("^%s*(.-)%s*$")

-- Percent (number), false (no XP bonus), or nil (not readable yet); and the
-- line it came from (for /arl food debug). hasUse: the tooltip must show a
-- "Use:" line before "no XP" is believed (bag items).
local function ParseTooltip(data, needUse)
  local lines = data and not Secret(data) and data.lines
  if type(lines) ~= "table" or Secret(lines) or #lines < 2 then
    return nil
  end
  local texts, sawUse = {}, false
  for i, line in ipairs(lines) do
    local text = Normalize(LineText(line))
    if LOADING ~= "" and text:find(LOADING, 1, true) then
      return nil
    end
    if USE_PREFIX ~= "" and text:sub(1, #USE_PREFIX) == USE_PREFIX and #text > #USE_PREFIX + 1 then
      sawUse = true
    end
    texts[i] = text
  end
  for _, text in ipairs(texts) do
    local p = LinePercent(text)
    if p then
      return p, text
    end
  end
  if needUse and not sawUse then
    return nil
  end
  return false
end

-------------------------------------------------------------------------------
-- Bags, buff, Gourmand
-------------------------------------------------------------------------------

local foodCache = {} -- itemID -> percent | false
local auraCache = {} -- spellID -> percent | false
local cacheTime = 0
local gourmandRank, gourmandKnown

local function ResetCaches(now)
  if now - cacheTime > 60 then
    cacheTime = now
    wipe(foodCache)
    wipe(auraCache)
  end
end

local function IsFood(itemID)
  local _, _, _, _, _, classID, subclassID = Items.GetInfoInstant(itemID)
  if classID == nil then
    return nil
  end
  return classID == 0 and subclassID == 5
end

-- { foods = { {itemID, name, percent, count}, ... best first },
--   complete = every food read, servings = XP food servings }
local function ScanBags(debugOut)
  local out = { foods = {}, complete = true, servings = 0 }
  if not (C_Container and C_Container.GetContainerNumSlots and C_TooltipInfo and C_TooltipInfo.GetBagItem) then
    out.complete = false
    return out
  end
  local byID = {}
  for bag = 0, (NUM_BAG_SLOTS or 4) do
    for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      local itemID = info and info.itemID
      if itemID then
        local food = IsFood(itemID)
        if food == nil then
          out.complete = false
        elseif food then
          local p, line = foodCache[itemID], nil
          if p == nil or debugOut then
            local ok, data = pcall(C_TooltipInfo.GetBagItem, bag, slot)
            p, line = nil, nil
            if ok then
              p, line = ParseTooltip(data, true)
            end
            if p ~= nil then
              foodCache[itemID] = p
            end
          end
          if debugOut then
            debugOut[#debugOut + 1] = string.format("%s: %s%s", Items.Link(itemID),
              p == nil and "not readable yet" or (p and (p .. "% XP") or "no XP bonus"),
              line and ("  |cff999999" .. line .. "|r") or "")
          end
          if p == nil then
            out.complete = false
          elseif p then
            local e = byID[itemID]
            if not e then
              e = { itemID = itemID, name = info.itemName or Items.Name(itemID), percent = p, count = 0 }
              byID[itemID] = e
              out.foods[#out.foods + 1] = e
            end
            e.count = e.count + (info.stackCount or 1)
          end
        end
      end
    end
  end
  table.sort(out.foods, function(a, b)
    if a.percent ~= b.percent then
      return a.percent > b.percent
    end
    return tostring(a.name) < tostring(b.name)
  end)
  for _, e in ipairs(out.foods) do
    out.servings = out.servings + e.count
  end
  return out
end

-- { percent (0 = none), expires (0 = no end), spellID, unknown = a buff
--   couldn't be read }
local function ScanBuff(debugOut)
  local out = { percent = 0, expires = 0, unknown = false }
  if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex and C_TooltipInfo and C_TooltipInfo.GetUnitBuff) then
    out.unknown = true
    return out
  end
  for i = 1, 40 do
    local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
    if not ok or not aura then
      break
    end
    -- In combat or an instance the aura, or any field of it, can be secret:
    -- indexing a secret table or comparing a secret number throws.
    local spellID = not Secret(aura) and aura.spellId
    if not spellID or Secret(spellID) then
      out.unknown = true
    else
      local p, line = auraCache[spellID], nil
      if p == nil or debugOut then
        local okTip, data = pcall(C_TooltipInfo.GetUnitBuff, "player", i, "HELPFUL")
        p = nil
        if okTip and data and not Secret(data) and type(data.lines) == "table" and not Secret(data.lines) then
          local lines = data.lines
          if #lines == 1 then
            p = nil -- only the name: description not loaded yet
          else
            p, line = ParseTooltip(data, false)
          end
        end
        -- "No XP" is only believed once the spell's description has loaded;
        -- before that the tooltip can hold just the name and time left, and
        -- caching "no XP" would nag to eat while the food buff is up.
        local described = true
        if p == false and C_Spell and C_Spell.GetSpellDescription and spellID then
          local okDesc, desc = pcall(C_Spell.GetSpellDescription, spellID)
          described = okDesc and type(desc) == "string" and desc ~= ""
        end
        if p == false and not described then
          p = nil
        end
        if p ~= nil and spellID then
          auraCache[spellID] = p
        end
      end
      if debugOut then
        debugOut[#debugOut + 1] = string.format("buff %s: %s%s", Secret(aura.name) and "?" or tostring(aura.name),
          p == nil and "not readable yet" or (p and (p .. "% XP") or "no XP bonus"),
          line and ("  |cff999999" .. line .. "|r") or "")
      end
      if p == nil then
        out.unknown = true
      elseif p then
        local exp = aura.expirationTime
        local expires = not Secret(exp) and type(exp) == "number" and exp > 0 and exp or 0
        if p > out.percent or (p == out.percent and (expires == 0 or expires > out.expires)) then
          out.percent, out.expires, out.spellID = p, expires, spellID
        end
      end
    end
  end
  return out
end

local Call = ARLE.Lib.Call -- (missing, throwing or hidden: nil)

local function NodeIsGourmand(configID, nodeID, node)
  if nodeID == GOURMAND then
    return true
  end
  for _, entryID in ipairs(type(node.entryIDs) == "table" and node.entryIDs or {}) do
    if entryID == GOURMAND then
      return true
    end
    local entry = Call(C_Traits.GetEntryInfo, configID, entryID)
    local defID = entry and entry.definitionID
    if defID == GOURMAND then
      return true
    end
    local def = defID and Call(C_Traits.GetDefinitionInfo, defID)
    if def and def.spellID == GOURMAND then
      return true
    end
  end
end

local function NodeRank(node)
  local r = node.ranksPurchased
  if type(r) ~= "number" then
    r = node.activeEntry and node.activeEntry.rank
  end
  if type(r) ~= "number" then
    r = node.currentRank or node.activeRank
  end
  if type(r) == "number" and r >= 0 and r <= 3 and r == math.floor(r) then
    return r
  end
end

-- Gourmand rank 0..3, or nil when it can't be read.
local function ReadGourmand()
  if not C_Traits then
    return nil
  end
  local configs, seen = {}, {}
  local function add(id, prio)
    if type(id) == "number" and not seen[id] then
      seen[id] = true
      configs[#configs + 1] = { id = id, prio = prio }
    end
  end
  if Enum and Enum.TraitConfigType and C_Traits.GetConfigsByType then
    for name, value in pairs(Enum.TraitConfigType) do
      local list = Call(C_Traits.GetConfigsByType, value)
      for _, id in ipairs(type(list) == "table" and list or {}) do
        add(id, tostring(name):lower():find("legacy", 1, true) and 2 or 1)
      end
    end
  end
  if C_ClassTalents and C_ClassTalents.GetActiveConfigID then
    add(Call(C_ClassTalents.GetActiveConfigID), 0)
  end
  table.sort(configs, function(a, b)
    return a.prio > b.prio
  end)
  for _, c in ipairs(configs) do
    local info = Call(C_Traits.GetConfigInfo, c.id)
    for _, treeID in ipairs(info and type(info.treeIDs) == "table" and info.treeIDs or {}) do
      local nodes = Call(C_Traits.GetTreeNodes, treeID)
      for _, nodeID in ipairs(type(nodes) == "table" and nodes or {}) do
        local node = Call(C_Traits.GetNodeInfo, c.id, nodeID)
        if type(node) == "table" and NodeIsGourmand(c.id, nodeID, node) then
          local r = NodeRank(node)
          if r then
            return r
          end
        end
      end
    end
  end
end

local function Gourmand()
  if not gourmandKnown then
    gourmandKnown = true
    gourmandRank = ReadGourmand()
  end
  return gourmandRank
end

local function ServingMinutes()
  return 15 + 5 * (Gourmand() or 0)
end

local function FormatDuration(minutes)
  minutes = math.max(0, math.floor(minutes + 0.5))
  if minutes >= 60 then
    return string.format("%dh %dm", math.floor(minutes / 60), minutes % 60)
  end
  return minutes .. "m"
end

local function SupplyText(bags)
  if bags.servings == 0 then
    return "No XP food in your bags"
  end
  return string.format("Food supply: %d serving%s, about %s", bags.servings, bags.servings == 1 and "" or "s",
    FormatDuration(bags.servings * ServingMinutes()))
end

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

local alert, menu
local lastBags, lastBuff
local currentKey, dismissedKey, lastFire, snoozeUntil, testUntil
local lowNotified, lowLine
local warnedKey, scheduledKey
local wasFlying

-- The food the icon eats: the player's pick while it's in the bags, else the best.
local function SelectedFood(bags)
  local pick = F.char.food
  for _, e in ipairs(bags and bags.foods or {}) do
    if e.itemID == pick then
      return e
    end
  end
  return bags and bags.foods[1]
end

local function FoodLine(e)
  if not e then
    return "No XP food in your bags"
  end
  return string.format("%s (%d%%) x%d", tostring(e.name), e.percent, e.count)
end

function F:StatusLine()
  local bags, buff = lastBags or ScanBags(), lastBuff or ScanBuff()
  local food = SelectedFood(bags)
  local parts = { food and ("XP food: " .. FoodLine(food)) or "No XP food in your bags" }
  if buff.percent > 0 then
    local left = buff.expires > 0 and (", " .. FormatDuration((buff.expires - GetTime()) / 60) .. " left") or ""
    parts[#parts + 1] = "buff " .. buff.percent .. "%" .. left
  else
    parts[#parts + 1] = buff.unknown and "buff: not readable yet" or "no XP buff"
  end
  local rank = Gourmand()
  parts[#parts + 1] = rank and ("Gourmand " .. rank) or "Gourmand ?"
  if bags.servings > 0 then
    parts[#parts + 1] = SupplyText(bags)
  end
  return table.concat(parts, "  ·  ")
end

-------------------------------------------------------------------------------
-- Alert (themed); the food icon is the host's secure "UseFood" button
-------------------------------------------------------------------------------

-- Kit.Movable's place function (the alert holds a secure button, so its
-- moves wait for combat to end).
local placeAlert

local function PlaceAlert()
  if placeAlert then
    placeAlert()
  end
end

local function HideMenu()
  if menu then
    menu:Hide()
  end
end

local function HideAlert()
  HideMenu()
  if alert and alert:IsShown() then
    if InCombatLockdown() then
      Secure:Run(HideAlert, "XPFood.alert")
    else
      alert:Hide()
    end
  end
end

local function Dismiss()
  dismissedKey = currentKey
  HideAlert()
end

local function Snooze()
  snoozeUntil = GetTime() + (F.db.snoozeMinutes or 1) * 60
  lastFire = nil
  HideAlert()
end

local function SetFoodAttribute(food)
  local use = Secure:Button("UseFood")
  if not use or InCombatLockdown() then
    return
  end
  use:SetAttribute("type", nil)
  use:SetAttribute("type1", food and "item" or nil)
  use:SetAttribute("item", food and ("item:" .. food.itemID) or nil)
end

-- Our own small menu: the XP foods in the bags, then Snooze / Dismiss.
local function OpenMenu(anchor)
  if not menu then
    menu = Skin:CreateTooltipWindow(nil, UIParent)
    menu:SetFrameStrata("DIALOG")
    menu:SetClampedToScreen(true)
    menu:EnableMouse(true)
    menu.rows = {}
  end
  local entries = {}
  for _, e in ipairs(lastBags and lastBags.foods or {}) do
    entries[#entries + 1] = { label = FoodLine(e), itemID = e.itemID, run = function()
      F.char.food = e.itemID
      F:Evaluate()
    end }
  end
  if anchor ~= "picker" then
    entries[#entries + 1] = { label = "Snooze " .. (F.db.snoozeMinutes or 1) .. " min", run = Snooze }
    entries[#entries + 1] = { label = "Dismiss", run = Dismiss }
  end
  if #entries == 0 then
    return
  end
  for i, entry in ipairs(entries) do
    local row = menu.rows[i]
    if not row then
      row = Kit.SmallButton(menu, "", 240)
      row:SetPoint("TOPLEFT", 8, -8 - (i - 1) * 18)
      menu.rows[i] = row
    end
    row:SetText(entry.label)
    F:Script(row, "OnClick", function()
      HideMenu()
      entry.run()
    end)
    -- The food's own tooltip (its stats, well-fed bonus, XP line) on hover.
    F:Script(row, "OnEnter", entry.itemID and function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(entry.itemID)
      GameTooltip:Show()
    end or nil)
    F:Script(row, "OnLeave", entry.itemID and GameTooltip_Hide or nil)
    row:Show()
  end
  for i = #entries + 1, #menu.rows do
    menu.rows[i]:Hide()
  end
  menu:SetSize(256, 16 + #entries * 18)
  menu:ClearAllPoints()
  local x, y = GetCursorPosition()
  local scale = UIParent:GetEffectiveScale()
  menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale, y / scale)
  menu:Show()
end

local function AttachUseButton()
  -- Over the icon (same spot as Layout puts it), anchored to the alert itself.
  local use = alert and Secure:Attach("UseFood", alert, F.db.iconMode and { "CENTER" } or { "TOPLEFT", 12, -12 },
    alert.icon:GetWidth())
  if not use then
    return
  end
  F:Script(use, "OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    local food = SelectedFood(lastBags)
    if food then
      GameTooltip:SetItemByID(food.itemID)
    end
    if F.db.iconMode and alert.message then
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine(alert.message, 1, 1, 1, true)
      if lastBags then
        GameTooltip:AddLine(SupplyText(lastBags), 0.7, 0.7, 0.7, true)
      end
      if lowLine then
        GameTooltip:AddLine(lowLine, 1, 0.5, 0.25, true)
      end
    end
    GameTooltip:AddLine("Click to eat · Right-click for more", 0.5, 0.84, 1)
    GameTooltip:Show()
  end)
  F:Script(use, "OnLeave", GameTooltip_Hide)
  F:Script(use, "PostClick", function(_, button)
    if button == "RightButton" then
      OpenMenu("icon")
    end
  end)
end

-- Hand the shared button back clean once off (as Sleeping Bag does).
local function DetachUseButton()
  if not F._active then
    Secure:Detach("UseFood", alert, { "type", "type1", "item" })
  end
end

local function Layout()
  local icon = F.db.iconMode
  alert:SetScale(math.max(0.25, math.min(1.5, (F.db.scale or 100) / 100)))
  PlaceAlert()
  alert.text:SetShown(not icon)
  alert.food:SetShown(not icon)
  alert.supply:SetShown(not icon)
  alert.dismiss:SetShown(not icon)
  alert.snooze:SetShown(not icon)
  alert.picker:SetShown(not icon)
  alert.glow:SetShown(icon)
  alert.icon:ClearAllPoints()
  if icon then
    alert:SetSize(64, 64)
    alert.icon:SetSize(48, 48)
    alert.icon:SetPoint("CENTER")
  else
    alert:SetSize(400, lowLine and 106 or 92)
    alert.icon:SetSize(42, 42)
    alert.icon:SetPoint("TOPLEFT", 12, -12)
  end
end

local function BuildAlert()
  local f = Skin:CreateTooltipWindow(nil, UIParent)
  f:SetFrameStrata("MEDIUM")
  placeAlert = Kit.Movable(f, F, { y = 120, secure = true })

  f.icon = f:CreateTexture(nil, "ARTWORK")
  f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

  f.glow = f:CreateTexture(nil, "OVERLAY")
  f.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
  f.glow:SetBlendMode("ADD")
  f.glow:SetVertexColor(1, 0.85, 0.2)
  f.glow:SetPoint("CENTER", f.icon, "CENTER")
  f.glow:SetSize(90, 90)
  -- Plain SetScript: a two-line pulse every frame isn't worth Debug.Call's cost.
  f:SetScript("OnUpdate", function(self)
    if self.glow:IsShown() then
      self.glow:SetAlpha(0.625 + 0.375 * math.cos(GetTime() * 2 * math.pi / 1.2))
    end
  end)

  f.text = Kit.Text(f, "GameFontHighlight")
  f.text:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 10, 0)
  f.text:SetPoint("RIGHT", -10, 0)
  f.text:SetWordWrap(true)

  f.food = Kit.Text(f, "GameFontNormalSmall")
  f.food:SetPoint("TOPLEFT", f.text, "BOTTOMLEFT", 0, -4)
  f.food:SetPoint("RIGHT", -10, 0)

  f.supply = Kit.Text(f, "GameFontDisableSmall")
  f.supply:SetPoint("TOPLEFT", f.food, "BOTTOMLEFT", 0, -2)
  f.supply:SetPoint("RIGHT", -10, 0)
  f.supply:SetWordWrap(true)

  f.dismiss = Kit.SmallButton(f, "Dismiss", 60)
  f.dismiss:SetPoint("BOTTOMRIGHT", -8, 8)
  F:Script(f.dismiss, "OnClick", Dismiss)
  f.snooze = Kit.SmallButton(f, "Snooze", 60)
  f.snooze:SetPoint("RIGHT", f.dismiss, "LEFT", -4, 0)
  F:Script(f.snooze, "OnClick", Snooze)
  f.picker = Kit.SmallButton(f, "Food", 50)
  f.picker:SetPoint("RIGHT", f.snooze, "LEFT", -4, 0)
  F:Script(f.picker, "OnClick", function()
    OpenMenu("picker")
  end)
  f:Hide()
  alert = f
end

local function ShowAlert(message, bags)
  if InCombatLockdown() then
    return
  end
  if not alert then
    BuildAlert()
  end
  local food = SelectedFood(bags)
  alert.message = message
  Layout()
  AttachUseButton()
  SetFoodAttribute(food)
  alert.icon:SetTexture(food and Items.GetIcon(food.itemID) or FOOD_ICON)
  alert.icon:SetDesaturated(food == nil)
  alert.text:SetText(message)
  alert.food:SetText(FoodLine(food))
  alert.supply:SetText(SupplyText(bags) .. (lowLine and ("\n|cffff8040" .. lowLine .. "|r") or ""))
  alert.snooze:SetText("Snooze " .. (F.db.snoozeMinutes or 1) .. "m")
  alert:Show()
  local x, y = alert:GetCenter()
  F:Debug("alert: visible %s, centre %s,%s, size %dx%d, scale %.2f, alpha %.2f", tostring(alert:IsVisible()),
    tostring(x and math.floor(x)), tostring(y and math.floor(y)), alert:GetWidth(), alert:GetHeight(),
    alert:GetEffectiveScale(), alert:GetEffectiveAlpha())
end

function F:OnResetPosition()
  if alert then
    PlaceAlert()
  end
end

-------------------------------------------------------------------------------
-- Evaluation
-------------------------------------------------------------------------------

local function Flying()
  return (IsFlying and IsFlying()) or (UnitOnTaxi and UnitOnTaxi("player")) or false
end

local function ResetState()
  currentKey, dismissedKey, lastFire, snoozeUntil = nil, nil, nil, nil
  lowNotified, lowLine = false, nil
end

-- "Only when a fight starts without an XP buff": on PLAYER_REGEN_DISABLED
-- (just before the lockdown), the shared alert bar (ARLE.UI.Alert, a plain
-- frame, fine in combat; XP Food's own alert holds a secure button and can't
-- show in a fight, and food can't be eaten there anyway). At most once a
-- minute, so chain pulls don't repeat it.
local COMBAT_ALERT_GAP = 60
local lastCombatAlert

function F:CombatCheck()
  local level = UnitLevel("player")
  if type(level) == "number" and level >= MAX_LEVEL then
    return
  end
  local now = GetTime()
  if lastCombatAlert and now - lastCombatAlert < COMBAT_ALERT_GAP then
    self:Debug("fight: warned %ds ago", now - lastCombatAlert)
    return
  end
  ResetCaches(now)
  local bags, buff = ScanBags(), ScanBuff()
  lastBags, lastBuff = bags, buff
  local best = SelectedFood(bags)
  if not best then
    self:Debug("fight: no XP food in your bags")
    return
  end
  if buff.unknown and buff.percent < best.percent then
    self:Debug("fight: a buff isn't readable, maybe the food's: no warning")
    return
  end
  if buff.percent >= best.percent then
    self:Debug("fight: XP buff %d%% is up", buff.percent)
    return
  end
  lastCombatAlert = now
  local text = buff.percent > 0 and string.format("Your XP buff is only %d%%", buff.percent)
    or "Fighting without your XP buff"
  self:Debug("fight: warning (%s)", text)
  self:Alert({
    text = text,
    sub = string.format("Eat %s (%d%%) after this fight", tostring(best.name), best.percent),
    icon = Items.GetIcon(best.itemID) or FOOD_ICON,
    warning = "NO XP BUFF",
    color = { 1, 0.6, 0.2 },
    pulse = true,
    duration = 6,
  })
  if self.db.chat then
    self:Print(text .. ". Eat " .. tostring(best.name) .. " after this fight.")
  end
end

function F:CheckExpiry(buff, now)
  local lead = (self.db.expiryMinutes or 0) * 60
  if not self.db.chat or lead <= 0 or buff.percent <= 0 or buff.expires <= 0 then
    return
  end
  local key = tostring(buff.spellID) .. ":" .. buff.expires
  local remaining = buff.expires - now
  if remaining <= 0 then
    return
  end
  if remaining <= lead then
    if warnedKey ~= key and not (snoozeUntil and now < snoozeUntil) then
      warnedKey = key
      self:Print(string.format("your %d%% XP buff ends in %d min.", buff.percent, math.ceil(remaining / 60)))
    end
  elseif scheduledKey ~= key then
    scheduledKey = key
    self:After(remaining - lead + 0.5, self.Evaluate)
  end
end

function F:Evaluate()
  local now = GetTime()
  if testUntil then
    if now < testUntil and not InCombatLockdown() then
      return
    end
    testUntil = nil
  end
  local level = UnitLevel("player")
  if type(level) == "number" and level >= MAX_LEVEL then
    self:Debug("off: level %d", level)
    ResetState()
    HideAlert()
    return
  end
  if self.db.combatOnly then
    -- Only CombatCheck reminds (as a fight starts).
    ResetState()
    HideAlert()
    return
  end
  if (not self.db.whileResting and IsResting()) or UnitAffectingCombat("player") or InCombatLockdown() then
    self:Debug("waiting: %s", IsResting() and "resting" or "in combat")
    HideAlert()
    return
  end
  if not self.db.chat and not self.db.screen then
    ResetState()
    HideAlert()
    return
  end
  ResetCaches(now)
  local bags, buff = ScanBags(), ScanBuff()
  lastBags, lastBuff = bags, buff
  self:CheckExpiry(buff, now)
  self:Debug("bags: %d XP food(s), best %s, %d serving(s)%s · buff %d%%%s", #bags.foods,
    bags.foods[1] and (bags.foods[1].percent .. "% " .. tostring(bags.foods[1].name)) or "none", bags.servings,
    bags.complete and "" or " (some not readable yet)", buff.percent, buff.unknown and " (a buff not readable yet)" or "")

  -- Low stock: once, until the stock goes back above the threshold.
  local low = self.db.lowStock or 0
  if low <= 0 or not bags.complete or bags.servings > low then
    lowNotified, lowLine = false, nil
  elseif not lowNotified and buff.percent == 0 and not (bags.servings == 0 and self.db.noFood) then
    lowNotified = true
    lowLine = string.format("Low stock: %d XP food serving%s left.", bags.servings, bags.servings == 1 and "" or "s")
    if self.db.chat then
      self:Print(lowLine)
    end
  end

  local key, message
  -- (the food the icon eats: your pick while you carry it, else the best)
  local best = SelectedFood(bags)
  if best then
    if buff.unknown and buff.percent < best.percent then
      self:Debug("waiting: a buff isn't readable yet and might be the food's")
      HideAlert() -- (you may have just eaten: no "Eat it!" left up meanwhile)
      return
    end
    if buff.percent < best.percent then
      key = "missing:" .. best.percent
      message = buff.percent > 0
        and string.format("You have %d%% XP food, but your XP buff is only %d%%.", best.percent, buff.percent)
        or string.format("You have %d%% XP food and no XP buff. Eat it!", best.percent)
    end
  elseif bags.complete then
    if self.db.noFood and buff.percent == 0 and not buff.unknown then
      key = "nofood"
      message = "You have no XP food left in your bags."
    end
  else
    self:Debug("waiting: food tooltips still loading")
    return -- bags still loading
  end

  -- The buff is about to end and you have food to eat again: the alert too,
  -- not just CheckExpiry's chat line (which already said it, so no second line).
  local quiet = false
  local lead = (self.db.expiryMinutes or 0) * 60
  if not key and best and lead > 0 and buff.percent > 0 and buff.expires > now and buff.expires - now <= lead then
    key = "ending:" .. tostring(buff.spellID) .. ":" .. buff.expires
    message = string.format("Your %d%% XP buff ends in %d min. Eat again to keep it going.", buff.percent,
      math.ceil((buff.expires - now) / 60))
    quiet = true
  end

  if not key then
    self:Debug("nothing to remind")
    currentKey, dismissedKey, lastFire = nil, nil, nil
    HideAlert()
    return
  end
  if key ~= currentKey then
    currentKey, lastFire = key, nil
    if dismissedKey ~= key then
      dismissedKey = nil
    end
  end
  if dismissedKey == key or (snoozeUntil and now < snoozeUntil) then
    self:Debug("%s: %s", key, dismissedKey == key and "dismissed" or "snoozed")
    HideAlert()
    return
  end
  snoozeUntil = nil
  local repeatSec = (self.db.repeatMinutes or 0) * 60
  if not lastFire or (repeatSec > 0 and now - lastFire >= repeatSec) then
    lastFire = now
    self:Debug("%s: reminding", key)
    if self.db.chat and not quiet then
      self:Print(message)
    end
  end
  if self.db.screen and not UnitIsDeadOrGhost("player") and not Flying() then
    self:Debug("%s: alert on screen", key)
    ShowAlert(message, bags)
  else
    self:Debug("%s: no alert (%s)", key, not self.db.screen and "on-screen alert is off"
      or (UnitIsDeadOrGhost("player") and "dead") or "flying or on a flight path")
    HideAlert()
  end
end

function F:Test()
  if InCombatLockdown() then
    return
  end
  testUntil = GetTime() + 20
  ResetCaches(GetTime())
  lastBags, lastBuff = ScanBags(), ScanBuff()
  ShowAlert("Test: drag this alert to move it. It closes in 20 seconds.", lastBags)
end

-- /arl food debug. (Not "Debug": that's the framework's trace helper, and a
-- feature's own method of the same name would replace it.)
function F:DebugDump()
  local out = {}
  ScanBags(out)
  ScanBuff(out)
  if #out == 0 then
    self:Print("no food in your bags and no buffs to read.")
  end
  for _, line in ipairs(out) do
    self:Print(line)
  end
  local rank = Gourmand()
  self:Print("Gourmand: " .. (rank and ("rank " .. rank) or "not found")
    .. string.format(" (a serving lasts %d min)", ServingMinutes()))
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

local function Schedule(self)
  self:Debounce("eval", 0.5, self.Evaluate)
end

function F:OnEnable()
  wipe(foodCache)
  wipe(auraCache)
  gourmandKnown = false
  for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_LEVEL_UP", "PLAYER_UPDATE_RESTING", "PLAYER_REGEN_ENABLED",
    "PLAYER_ALIVE", "PLAYER_UNGHOST", "BAG_UPDATE_DELAYED" }) do
    self:On(e, Schedule)
  end
  self:On("GET_ITEM_INFO_RECEIVED", function(def, _, itemID)
    if itemID then
      foodCache[itemID] = nil
    end
    Schedule(def)
  end)
  for _, e in ipairs({ "TRAIT_CONFIG_UPDATED", "TRAIT_CONFIG_LIST_UPDATED" }) do
    self:On(e, function(def)
      gourmandKnown = false
      Schedule(def)
    end)
  end
  self:On("PLAYER_REGEN_DISABLED", function(def)
    HideAlert()
    if def.db.combatOnly then
      def:CombatCheck()
    end
  end)
  self:On("PLAYER_DEAD", HideAlert)
  -- (a spell's XP percent never changes, and unreadable tooltips aren't
  -- cached: the aura cache needn't be emptied on every aura change)
  self:OnUnit("UNIT_AURA", "player", Schedule)
  self:Ticker(60, self.Evaluate)
  -- Landing or leaving a flight path brings the alert back.
  wasFlying = Flying()
  self:Ticker(1, function(def)
    local now = Flying()
    if now ~= wasFlying then
      wasFlying = now
      if now then
        HideAlert()
      else
        Schedule(def)
      end
    end
  end)
  Schedule(self)
end

function F:OnDisable()
  ResetState()
  testUntil, warnedKey, scheduledKey = nil, nil, nil
  HideAlert()
  Secure:Run(DetachUseButton)
end

function F:OnOptionChanged()
  dismissedKey, lastFire = nil, nil
  if alert then
    -- The alert holds a secure button: its size and scale change after combat.
    Secure:Run(Layout, "XPFood.Layout")
  end
  self:Evaluate()
end

function F:GetStatus()
  return "Active · " .. self:StatusLine()
end

-- Forever SnackTrack keeps its settings per character
-- (ForeverSnackTrackCharDB); older versions kept them account-wide
-- (ForeverSnackTrackDB, before that ForeverExpFoodDB). Its sleeping bag
-- settings are left out (the Sleeping Bag feature does that).
function F:Import()
  local old = _G.ForeverSnackTrackCharDB
  if type(old) ~= "table" then
    old = type(_G.ForeverSnackTrackDB) == "table" and _G.ForeverSnackTrackDB or _G.ForeverExpFoodDB
  end
  if type(old) ~= "table" then
    return
  end
  local db = self.db
  local function bool(from, to)
    if type(old[from]) == "boolean" then
      db[to] = old[from]
    end
  end
  local function num(from, to, min, max)
    local v = old[from]
    if type(v) == "number" and v == v then
      db[to] = math.max(min, math.min(max, math.floor(v + 0.5)))
    end
  end
  bool("chatAlerts", "chat")
  bool("screenAlerts", "screen")
  bool("remindWhenNoFood", "noFood")
  bool("remindWhileResting", "whileResting")
  bool("screenIconMode", "iconMode")
  num("lowFoodThreshold", "lowStock", 0, 20)
  num("buffExpiryWarningMinutes", "expiryMinutes", 0, 15)
  if type(old.snoozeMinutes) == "number" then
    for _, m in ipairs(SNOOZE) do
      if m == old.snoozeMinutes then
        db.snoozeMinutes = m
      end
    end
  end
  if old.repeatReminders == false then
    db.repeatMinutes = 0
  else
    num("reminderMinutes", "repeatMinutes", 1, 60)
  end
  if type(old.screenScale) == "number" then
    db.scale = math.max(25, math.min(150, math.floor(old.screenScale * 20 + 0.5) * 5))
  end
  if type(old.selectedFoodItemID) == "number" and old.selectedFoodItemID > 0 then
    self.char.food = math.floor(old.selectedFoodItemID)
  end
  if type(old.alertOffsetX) == "number" and type(old.alertOffsetY) == "number" then
    self.char.position = { old.alertOffsetX, old.alertOffsetY }
  end
end

F.commands = {
  { name = "status", help = "your XP food, buff, Gourmand rank and supply", always = true,
    run = function(self) self:Print(self:StatusLine()) end },
  { name = "debug", help = "what each food and buff tooltip reads as", always = true,
    run = function(self) self:DebugDump() end },
  { name = "test", help = "shows the alert for 20 seconds so you can move it", run = function(self) self:Test() end },
  { name = "reset", help = "puts the alert back in its default spot", run = function(self)
    self.char.position = nil
    self:OnResetPosition()
    self:Print("alert position reset.")
  end },
}

ARLE:RegisterModule(F)
