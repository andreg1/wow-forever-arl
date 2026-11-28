-- Logistics: its panel in the ARL tab on the auction house (ARLTab.lua holds
-- the tab and switches panels; see Logistics.lua for the data, the scan and the
-- costs, LogisticsCrates.lua for the crates; this file only draws them). Two
-- views in the panel: Writs (reputation) and Crates (Merchant's Favor),
-- switched at the top left; one Scan prices both.
local ADDON, ns = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local Lib, Items, Kit, Skin = ARLE.Lib, ARLE.Lib.Items, ARLE.UI.Kit, ARLE.Skin
local AH = ARLE.Bridge.Auctionator

local ROW_H = 32
local COLS = { -- x, width, justify
  rank = { 2, 20, "RIGHT" },
  writ = { 54, 196, "LEFT" },
  item = { 286, 150, "LEFT" },
  price = { 440, 80, "RIGHT" },
  fill = { 524, 80, "RIGHT" },
  total = { 608, 80, "RIGHT" },
  perRep = { 692, 66, "RIGHT" },
}
local QUALITY_STAR = "|TInterface\\COMMON\\ReputationStar:12:12:0:0:32:32:0:16:0:16|t"
local TIER_NAMES = { [1] = "Apprentice", [2] = "Journeyman", [3] = "Expert", [4] = "Artisan", [5] = "Elite" }
local FAVOR_ICON = 135725 -- (when the currency info gives none)

local HEADERS = {
  writs = {
    labels = { rank = "#", writ = "Writ", item = "Asks for", price = "Writ", fill = "Items", total = "Total",
      perRep = "Per rep" },
    tips = {
      price = "The writ's lowest price for sale (for a receipt: its 15 Favor at the cheapest crate's gold per Favor).",
      fill = "What its quest asks for: the cheapest of buying it, a vendor, or crafting it from materials.",
      total = "The writ and the items together.",
      perRep = "Total over the reputation it gives. Green: the cheapest third.",
    },
  },
  crates = {
    labels = { rank = "#", writ = "Crate", item = "Fill with", price = "Crate", fill = "Materials", total = "Total",
      perRep = "Per Favor" },
    tips = {
      price = "The crate's lowest price for sale.",
      fill = "The cheapest of its bundles (a crate takes one): bought, from a vendor, or crafted from materials.",
      total = "The crate and its bundle together.",
      perRep = "Total over the Merchant's Favor its sealed crate pays. Green: the cheapest third.",
    },
  },
}

local T = {}
ns.LogisticsTab = T
local W = ns.Logistics

local frame, rows = nil, {}
local list, plan = {}, nil

local function F()
  return W.F
end

local function View()
  return F().db.view == "crates" and "crates" or "writs"
end

local function Money(c)
  return c and Lib.FormatMoney(math.floor(c + 0.5)) or "|cff707070--|r"
end

local function ItemName(id)
  local name, _, quality = Items.GetInfo(id)
  if not name then
    Items.Name(id)
    return "item " .. tostring(id), 1
  end
  return name, quality or 1
end

local function Icon(id)
  return Items.GetIcon and id and Items.GetIcon(id) or 134400
end

local function Colored(id)
  local name, quality = ItemName(id)
  local r, g, b = Lib.QualityColor(quality)
  return ("|c%s%s|r"):format(Lib.Hex(r, g, b), name)
end

-- "Craftsman's Writ: Heavy Linen Gloves" -> "Heavy Linen Gloves"
local function Short(id)
  local name = ItemName(id)
  return (name:gsub("^.-[:%-]%s+", "", 1))
end

-------------------------------------------------------------------------------
-- Tooltip: the whole path, step by step
-------------------------------------------------------------------------------

local SRC_WORD = { buy = "auction", vendor = "vendor", craft = "craft" }

local function AddNode(node, count, depth)
  if not node then
    return
  end
  local pad = ("   "):rep(depth)
  local how = node.src and SRC_WORD[node.src] or "no price"
  if node.src == "craft" and not node.known then
    how = "craft, a recipe you don't know"
  end
  GameTooltip:AddDoubleLine(("%s%d x %s"):format(pad, count, Colored(node.id)),
    ("%s |cff909090(%s)|r"):format(node.cost and Money(node.cost * count) or "|cffff6060?|r", how), 1, 1, 1, 1, 1, 1)
  local other = {}
  if node.buy and node.src ~= "buy" then
    other[#other + 1] = "auction " .. Money(node.buy)
  end
  if node.craft and node.src ~= "craft" then
    other[#other + 1] = "craft " .. Money(node.craft)
  end
  if #other > 0 then
    GameTooltip:AddLine(pad .. "   |cff909090each: " .. table.concat(other, ", ") .. "|r", 1, 1, 1)
  end
  if node.src == "craft" and node.parts and depth < 4 then
    for _, part in ipairs(node.parts) do
      AddNode(part.node, part.count * count / (node.yield or 1), depth + 1)
    end
  end
end

local function Age(src, age, qty)
  if src == "scan" then
    return ("scanned %s ago%s"):format(Lib.FormatDuration(age or 0), qty and (", " .. qty .. " for sale") or "")
  elseif src == "auctionator" then
    return age and age > 0 and ("Auctionator, %d day%s old"):format(age, age == 1 and "" or "s") or "Auctionator, today"
  elseif src == "old" then
    return "an old scan"
  end
  return "nobody is selling it"
end

local function ReceiptTip(e)
  GameTooltip:AddLine(("Forged Delivery Receipt · %d reputation, as often as you like"):format(e.w.rep), 0.6, 0.9, 1)
  GameTooltip:AddLine("Bought from the camp's vendor for 15 Merchant's Favor, used on any empty Waylaid Crate. "
    .. "From Friendly up to Revered. ItemTree hasn't confirmed it in game yet.", 0.8, 0.8, 0.8, true)
  GameTooltip:AddLine(" ")
  local from = e.favorFrom
  GameTooltip:AddDoubleLine(("%d Favor"):format(W.RECEIPT_FAVOR), Money(e.writPrice), 1, 0.82, 0, 1, 1, 1)
  if from then
    GameTooltip:AddLine(("   at %s per Favor, from %s"):format(Money(from.perFavor), Colored(from.c.id)), 0.7, 0.7,
      0.7, true)
  else
    GameTooltip:AddLine("   no crate priced yet: scan first", 1, 0.4, 0.4)
  end
  GameTooltip:AddLine("An empty crate:", 1, 0.82, 0)
  if e.need == 0 then
    GameTooltip:AddLine(("   you have %s (free)"):format(Colored(e.w.item)), 0.6, 1, 0.6)
  else
    AddNode(e.node, 1, 1)
  end
end

local function WritTip(e)
  local w = e.w
  GameTooltip:AddLine(("%s writ · %d reputation%s"):format(W.RANK_NAMES[w.rank] or "Writ", w.rep,
    w.repGuess and " |cff909090(expected)|r" or ""), 0.6, 0.9, 1)
  if e.done then
    GameTooltip:AddLine("Done today: the quest comes back after the daily reset.", 1, 0.4, 0.4, true)
  end
  GameTooltip:AddLine(" ")
  if e.haveWrit > 0 then
    GameTooltip:AddDoubleLine("The writ", ("|cff80ff80you have %d%s|r |cff909090(for sale: %s)|r"):format(e.haveWrit,
      e.writCost == 0 and ", free" or "", Money(e.writPrice)), 1, 0.82, 0, 1, 1, 1)
  else
    GameTooltip:AddDoubleLine("The writ", ("%s |cff909090(%s)|r"):format(Money(e.writPrice),
      Age(e.writSrc, e.writAge, e.writQty)), 1, 0.82, 0, 1, 1, 1)
  end
  GameTooltip:AddLine("Its quest asks for:", 1, 0.82, 0)
  if e.haveItem > 0 then
    GameTooltip:AddLine(("   you have %d of %d%s"):format(e.haveItem, w.count, e.need == 0 and " (free)" or ""),
      0.6, 1, 0.6)
  end
  if e.need > 0 then
    AddNode(e.node, e.need, 1)
  end
end

local function CrateTip(e)
  local c = e.c
  local what = c.kind == "label" and "Shipping Label" or c.kind == "sealed" and "Sealed crate: turn it in"
    or ((TIER_NAMES[c.tier] or "") .. " crate")
  GameTooltip:AddLine(("%s · %s"):format(what, c.favor and (c.favor .. " Merchant's Favor"
    .. (c.favorGuess and " |cff909090(expected)|r" or "")) or "Favor not known yet"), 0.6, 0.9, 1)
  GameTooltip:AddLine(" ")
  if e.held > 0 then
    GameTooltip:AddDoubleLine("The crate", ("|cff80ff80you have %d%s|r |cff909090(for sale: %s)|r"):format(e.held,
      e.crateCost == 0 and ", free" or "", Money(e.price)), 1, 0.82, 0, 1, 1, 1)
  else
    GameTooltip:AddDoubleLine(c.kind == "label" and "The label" or "The crate", ("%s |cff909090(%s)|r"):format(
      Money(e.price), Age(e.src, e.age, e.qty)), 1, 0.82, 0, 1, 1, 1)
  end
  if e.bundles then
    GameTooltip:AddLine("Fill it with one of:", 1, 0.82, 0)
    for _, b in ipairs(e.bundles) do
      local best = b == e.bundle
      local have = b.have > 0 and (" |cff80ff80(have %d)|r"):format(b.have) or ""
      GameTooltip:AddDoubleLine(("   %s%d x %s%s"):format(best and "|cffffd100>|r " or "", b.count, Colored(b.item),
        have), b.need == 0 and "|cff80ff80free|r" or Money(b.fill), 1, 1, 1, 1, 1, 1)
    end
    if e.bundle and e.need > 0 and e.node and e.node.src == "craft" then
      GameTooltip:AddLine("The cheapest, step by step:", 1, 0.82, 0)
      AddNode(e.node, e.need, 1)
    end
  end
end

local function ShowTip(row)
  local e = row.entry
  if not e then
    return
  end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:SetText(Colored(e.c and e.c.id or e.w.id))
  if e.c then
    CrateTip(e)
  elseif e.receipt then
    ReceiptTip(e)
  else
    WritTip(e)
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddDoubleLine("Total", Money(e.total), 1, 0.82, 0, 1, 1, 1)
  if e.c then
    GameTooltip:AddDoubleLine("Per Favor", Money(e.perFavor), 1, 0.82, 0, 1, 1, 1)
  else
    GameTooltip:AddDoubleLine("Per reputation", Money(e.perRep), 1, 0.82, 0, 1, 1, 1)
    if e.w.pouch then
      GameTooltip:AddDoubleLine("Coin Pouch back (usual)", Money(e.w.pouch), 0.7, 0.7, 0.7, 0.7, 0.7, 0.7)
    end
  end
  if e.plan then
    local n = e.planCount and e.planCount > 1 and (" (x" .. e.planCount .. ")") or ""
    GameTooltip:AddLine(QUALITY_STAR .. " In the plan" .. n .. ": among the cheapest to your goal.", 1, 0.82, 0, true)
  end
  GameTooltip:AddLine("Click: look it and what to buy up in Auctionator · Shift-click: link", 0.5, 0.5, 0.5, true)
  GameTooltip:Show()
end

-------------------------------------------------------------------------------
-- Shopping through Auctionator
-------------------------------------------------------------------------------

local function ToBuy(node, into)
  if not node then
    return
  end
  if node.src == "buy" then
    into[node.id] = true
  elseif node.src == "craft" then
    for _, part in ipairs(node.parts or {}) do
      ToBuy(part.node, into)
    end
  end
end

local function Shop(entries)
  local ids, names, seen = {}, {}, {}
  for _, e in ipairs(entries) do
    if e.c then
      if e.crateCost and e.crateCost > 0 then
        ids[e.c.id] = true
      end
    elseif e.writCost and e.writCost > 0 and not e.receipt then
      ids[e.w.id] = true
    end
    if e.need and e.need > 0 then
      ToBuy(e.node, ids)
    end
  end
  for id in pairs(ids) do
    local name = Items.GetInfo(id)
    if name and not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  if #names == 0 then
    F():Print("nothing to buy there.")
    return
  end
  table.sort(names)
  local ok, err = AH.SearchExact(names)
  if not ok then
    F():Print("Auctionator couldn't search: " .. tostring(err or "?"))
  end
end

-------------------------------------------------------------------------------
-- The Favor goal: something the camp's vendors sell
-------------------------------------------------------------------------------

local function SetGoal(item, favor)
  ARLE:SetOption(F().id, "favorGoalItem", item or 0)
  ARLE:SetOption(F().id, "favorGoal", favor or 0)
end

local function GoalMenu(owner)
  local shop = W.Shop()
  local st = W.Standing()
  local current = tonumber(F().db.favorGoalItem) or 0
  for _, o in ipairs(shop) do
    Items.Name(o.item)
  end
  if not (MenuUtil and MenuUtil.CreateContextMenu) then
    -- (no menu on this client: each click steps to the next item)
    local nextIndex = 1
    for i, o in ipairs(shop) do
      if o.item == current then
        nextIndex = i % #shop + 1
      end
    end
    local o = shop[nextIndex]
    if o then
      SetGoal(o.item, o.favor)
    end
    return
  end
  -- grouped by the name's first word before ":" (Recipe, Plans, Pattern...), the rest under "Other"
  local groups, order = {}, {}
  for _, o in ipairs(shop) do
    local name = ItemName(o.item)
    local head = name:match("^(.-):%s") or "Other"
    if not groups[head] then
      groups[head] = {}
      order[#order + 1] = head
    end
    groups[head][#groups[head] + 1] = { o = o, name = name }
  end
  table.sort(order, function(a, b)
    if (a == "Other") ~= (b == "Other") then
      return a == "Other"
    end
    return a < b
  end)
  MenuUtil.CreateContextMenu(owner, function(_, root)
    root:CreateTitle("Save Merchant's Favor up for")
    root:CreateRadio("No goal", function()
      return current == 0
    end, function()
      SetGoal(0, 0)
    end)
    for _, head in ipairs(order) do
      local sub = root:CreateButton(("%s (%d)"):format(head, #groups[head]))
      for _, x in ipairs(groups[head]) do
        local o = x.o
        local need = o.standing and st and st.reaction and o.standing > st.reaction
          and (" |cffff6060needs %s|r"):format(_G["FACTION_STANDING_LABEL" .. o.standing] or ("rank " .. o.standing))
          or ""
        sub:CreateRadio(("%s  |cffffd100%d|r%s"):format(Colored(o.item), o.favor, need), function()
          return current == o.item
        end, function()
          SetGoal(o.item, o.favor)
        end)
      end
    end
  end)
end

-------------------------------------------------------------------------------
-- The frame
-------------------------------------------------------------------------------

local function Text(parent, col, font)
  local c = COLS[col]
  local fs = Kit.Text(parent, font or "GameFontHighlightSmall")
  fs:SetPoint("LEFT", parent, "LEFT", c[1], 0)
  fs:SetWidth(c[2])
  fs:SetJustifyH(c[3])
  fs:SetWordWrap(false)
  return fs
end

local function MakeRow(parent, i)
  local r = CreateFrame("Button", nil, parent)
  r:SetHeight(ROW_H)
  r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
  r:SetPoint("RIGHT", parent, "RIGHT")
  r.bg = r:CreateTexture(nil, "BACKGROUND")
  r.bg:SetAllPoints()
  r.bg:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.04 or 0)
  r.hl = r:CreateTexture(nil, "HIGHLIGHT")
  r.hl:SetAllPoints()
  r.hl:SetColorTexture(1, 1, 1, 0.08)
  r.mark = r:CreateTexture(nil, "ARTWORK")
  r.mark:SetPoint("TOPLEFT")
  r.mark:SetPoint("BOTTOMLEFT")
  r.mark:SetWidth(3)
  r.mark:SetColorTexture(1, 0.82, 0, 0.9)
  r.rank = Text(r, "rank")
  r.writIcon = r:CreateTexture(nil, "ARTWORK")
  r.writIcon:SetSize(26, 26)
  r.writIcon:SetPoint("LEFT", 26, 0)
  r.writIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  r.writ = Text(r, "writ", "GameFontHighlight")
  r.writ:ClearAllPoints()
  r.writ:SetPoint("TOPLEFT", COLS.writ[1], -3)
  r.writSub = Text(r, "writ", "GameFontDisableSmall")
  r.writSub:ClearAllPoints()
  r.writSub:SetPoint("BOTTOMLEFT", COLS.writ[1], 4)
  r.itemIcon = r:CreateTexture(nil, "ARTWORK")
  r.itemIcon:SetSize(26, 26)
  r.itemIcon:SetPoint("LEFT", COLS.item[1] - 30, 0)
  r.itemIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  r.item = Text(r, "item", "GameFontHighlightSmall")
  r.item:ClearAllPoints()
  r.item:SetPoint("TOPLEFT", COLS.item[1], -4)
  r.itemSub = Text(r, "item", "GameFontDisableSmall")
  r.itemSub:ClearAllPoints()
  r.itemSub:SetPoint("BOTTOMLEFT", COLS.item[1], 4)
  r.price, r.fill, r.total = Text(r, "price"), Text(r, "fill"), Text(r, "total", "GameFontHighlight")
  r.perRep = Text(r, "perRep", "GameFontNormal")
  r.perRep:ClearAllPoints()
  r.perRep:SetPoint("TOPRIGHT", r, "TOPLEFT", COLS.perRep[1] + COLS.perRep[2], -4)
  r.rep = Text(r, "perRep", "GameFontDisableSmall")
  r.rep:ClearAllPoints()
  r.rep:SetPoint("BOTTOMRIGHT", r, "BOTTOMLEFT", COLS.perRep[1] + COLS.perRep[2], 4)
  F():Script(r, "OnEnter", ShowTip)
  F():Script(r, "OnLeave", GameTooltip_Hide)
  F():Script(r, "OnClick", function(self)
    local e = self.entry
    if not e then
      return
    end
    if IsModifiedClick("CHATLINK") then
      local _, link = Items.GetInfo(e.c and e.c.id or e.w.id)
      if link and ChatEdit_InsertLink then
        ChatEdit_InsertLink(link)
      end
    else
      Shop({ e })
    end
  end)
  return r
end

local function SourceWord(need, node)
  if need == 0 then
    return "|cff80ff80you have it|r"
  end
  if not (node and node.src) then
    return "|cffff6060no price|r"
  elseif node.src == "craft" then
    return node.known and "|cff80c0ffcraft|r" or "|cffc080ffcraft (someone else)|r"
  elseif node.src == "vendor" then
    return "vendor"
  end
  return "auction"
end

local function BandText(value, band)
  local color = band == 1 and "|cff40ff40" or band == 2 and "|cffffff40" or band == 3 and "|cffff9040" or "|cffb0b0b0"
  return value and (color .. Lib.FormatMoney(math.floor(value + 0.5)):gsub("|r", "|r" .. color) .. "|r") or Money(nil)
end

local function PaintCommon(r, e, i)
  r.entry = e
  r.mark:SetShown(e.plan == true)
  r.rank:SetText(e.plan and ("|cffffd100" .. i .. "|r") or tostring(i))
end

local function PaintWrit(r, e, i, band)
  PaintCommon(r, e, i)
  local w = e.w
  r.writIcon:SetTexture(Icon(w.id))
  r.writIcon:SetDesaturated(e.done)
  if e.receipt then
    r.writ:SetText(ItemName(w.id))
    r.writSub:SetText(("|cffffd100%d Favor|r · as often as you like"):format(W.RECEIPT_FAVOR)
      .. (e.planCount and e.planCount > 1 and (" · |cffffd100x" .. e.planCount .. "|r") or ""))
    r.item:SetText("an empty " .. Colored(w.item))
  else
    local name = Short(w.id)
    r.writ:SetText(e.done and ("|cff808080" .. name .. "|r") or name)
    local sub = W.RANK_NAMES[w.rank] or "Writ"
    if e.done then
      sub = sub .. " · |cffff6060done today|r"
    elseif e.haveWrit > 0 then
      sub = sub .. " · |cff80ff80you have " .. e.haveWrit .. "|r"
    elseif not e.listed then
      sub = sub .. " · nobody is selling it"
    end
    r.writSub:SetText(sub)
    r.item:SetText((w.count > 1 and (w.count .. " x ") or "") .. Colored(w.item))
  end
  r.itemIcon:SetTexture(Icon(w.item))
  r.itemIcon:SetDesaturated(e.done)
  r.itemSub:SetText(SourceWord(e.need, e.node))
  r.price:SetText(e.writCost == 0 and "|cff80ff80free|r" or Money(e.writPrice))
  r.fill:SetText(e.need == 0 and "|cff80ff80free|r" or Money(e.fill))
  r.total:SetText(Money(e.total))
  r.perRep:SetText(BandText(e.perRep, band))
  r.rep:SetText(w.rep .. " rep")
  r:SetAlpha(e.done and 0.6 or 1)
  r:Show()
end

local function PaintCrate(r, e, i, band)
  PaintCommon(r, e, i)
  local c = e.c
  r.writIcon:SetTexture(Icon(c.id))
  r.writIcon:SetDesaturated(false)
  r.writ:SetText(c.kind == "crate" and Short(c.id) or ItemName(c.id))
  local sub = c.kind == "crate" and ((TIER_NAMES[c.tier] or "Crate") .. (c.quality >= 2 and " · |cff1eff00crafted goods|r"
    or "")) or c.kind == "sealed" and "ready to turn in" or "Shipping Label"
  if e.held > 0 then
    sub = sub .. " · |cff80ff80you have " .. e.held .. "|r"
  elseif not e.listed then
    sub = sub .. " · nobody is selling it"
  end
  if e.planCount and e.planCount > 1 then
    sub = sub .. " · |cffffd100x" .. e.planCount .. "|r"
  end
  r.writSub:SetText(sub)
  if e.bundle then
    r.itemIcon:SetTexture(Icon(e.bundle.item))
    r.itemIcon:Show()
    r.item:SetText(e.bundle.count .. " x " .. Colored(e.bundle.item))
    r.itemSub:SetText(SourceWord(e.need, e.node))
  elseif e.bundles then
    r.itemIcon:Hide()
    r.item:SetText("|cffff6060no bundle priced|r")
    r.itemSub:SetText("")
  else
    r.itemIcon:Hide()
    r.item:SetText("|cff909090nothing: already filled|r")
    r.itemSub:SetText("")
  end
  r.price:SetText(e.crateCost == 0 and "|cff80ff80free|r" or Money(e.price))
  r.fill:SetText((e.fill == 0) and (e.bundles and "|cff80ff80free|r" or "") or Money(e.fill))
  r.total:SetText(Money(e.total))
  r.perRep:SetText(BandText(e.perFavor, band))
  r.rep:SetText(c.favor and (c.favor .. " Favor") or "Favor ?")
  r:SetAlpha(1)
  r:Show()
end

local function ShownWrit(e)
  local db = F().db
  if e.done and db.hideDone ~= false then
    return false
  end
  if not e.listed and e.haveWrit == 0 and not db.showUnlisted then
    return false
  end
  return true
end

local function ShownCrate(e)
  if F().db.showUnlisted then
    return true
  end
  return (e.listed or e.held > 0) and e.c.favor ~= nil
end

-- per-unit bands: thirds of what's priced (and not done)
local function Cuts(entries, key)
  local priced = {}
  for _, e in ipairs(entries) do
    if e[key] and not e.done then
      priced[#priced + 1] = e[key]
    end
  end
  table.sort(priced)
  return priced[math.max(1, math.floor(#priced / 3))], priced[math.max(1, math.floor(#priced * 2 / 3))]
end

local function PaintStanding(st)
  frame.goalBtn:Hide()
  if st then
    frame.camp:SetText(("%s · |cffffffff%s|r"):format(st.name or "?", st.label or "?"))
    if st.into and st.size and st.size > 0 then
      frame.bar:SetMinMaxValues(0, st.size)
      frame.bar:SetValue(st.into)
      frame.bar:SetStatusBarColor(0, 0.7, 0.2)
      frame.bar:Show()
      frame.barText:SetText(st.toNext and ("%d / %d · %d to %s"):format(st.into, st.size, st.toNext,
        st.nextLabel or "the next standing") or ("%d / %d"):format(st.into, st.size))
      return
    end
  else
    frame.camp:SetText("Supply camp: no standing yet")
  end
  frame.bar:Hide()
  frame.barText:SetText("")
end

local function PaintFavor(goal)
  local have, name, icon = W.Favor()
  frame.camp:SetText(("|T%d:14:14:0:0|t %s: |cffffffff%s|r"):format(icon or FAVOR_ICON, name or "Merchant's Favor",
    have and tostring(have) or "?"))
  frame.goalBtn:Show()
  if goal then
    frame.goalBtn:SetText("Goal: " .. (goal.item > 0 and Short(goal.item) or (goal.favor .. " Favor")))
    frame.bar:SetMinMaxValues(0, goal.favor)
    frame.bar:SetValue(math.min(goal.favor, have or 0))
    frame.bar:SetStatusBarColor(0.9, 0.7, 0.1)
    frame.bar:Show()
    frame.barText:SetText(goal.need > 0 and ("%d / %d · %d to go"):format(have or 0, goal.favor, goal.need)
      or "|cff80ff80You have enough|r")
  else
    frame.goalBtn:SetText("Save up for...")
    frame.bar:Hide()
    frame.barText:SetText("")
  end
  frame.bar:ClearAllPoints()
  frame.bar:SetPoint("LEFT", frame.goalBtn, "RIGHT", 8, 0)
end

local function PlaceBar()
  frame.bar:ClearAllPoints()
  frame.bar:SetPoint("TOPLEFT", 10, -36)
end

local function BudgetKey()
  return View() == "crates" and "crateBudget" or "writBudget"
end

-- The end of the plan line: why it stops short of the goal.
local function PlanNote(p, short)
  if not short then
    return ""
  elseif p.capped then
    return (" |cffff9040(budget %s reached)|r"):format(Lib.FormatMoney(p.budget))
  end
  return " |cffff9040(not enough for sale today)|r"
end

local function RealRefresh()
  if not (frame and frame:IsVisible()) then
    return
  end
  local db = F().db
  local view = View()
  frame.views.Paint()
  frame.bagsCB:SetChecked(db.useBags ~= false)
  frame.anyCB:SetChecked(db.anyCraft == true)
  frame.doneCB:SetChecked(db.hideDone ~= false)
  frame.doneCB:SetShown(view == "writs")
  frame.doneText:SetShown(view == "writs")
  frame.unlistedCB:SetChecked(db.showUnlisted == true)
  if not frame.budget:HasFocus() then
    local gold = tonumber(db[BudgetKey()]) or 0
    frame.budget:SetText(gold > 0 and tostring(gold) or "")
  end
  local h = HEADERS[view]
  for col, fs in pairs(frame.headers) do
    fs:SetText(h.labels[col] or "")
  end

  -- scan status
  local scan = W.scan
  if scan.running then
    frame.scanBtn:SetText("Stop")
    frame.scanText:SetText(("Scanning %d / %d"):format(scan.done or 0, math.max(scan.total or 0, 1)))
  else
    frame.scanBtn:SetText("Scan")
    local at = W.ScanStore().at
    frame.scanText:SetText(at and at > 0 and ("Scanned %s ago"):format(Lib.FormatDuration(time() - at))
      or "|cffff9040Not scanned yet|r")
  end

  if not W.Load() then
    for _, r in ipairs(rows) do
      r:Hide()
    end
    PlaceBar()
    PaintStanding(nil)
    frame.empty:SetText("The writ and crate data comes from ItemTree: install it or turn it on, then /reload.")
    frame.empty:Show()
    frame.plan:SetText("")
    frame.shopBtn:Hide()
    return
  end

  W.ResetCosts()
  local all, key, Shown, Paint
  local st = W.Standing()
  local goal
  if view == "crates" then
    goal = ns.LogisticsCrates.Goal()
    PaintFavor(goal)
    all = ns.LogisticsCrates.Evaluate()
    plan = ns.LogisticsCrates.Plan(all, goal, W.Budget("crateBudget"))
    key, Shown, Paint = "perFavor", ShownCrate, PaintCrate
  else
    PlaceBar()
    PaintStanding(st)
    all = W.Evaluate()
    plan = W.Plan(all, st, W.Budget("writBudget"))
    key, Shown, Paint = "perRep", ShownWrit, PaintWrit
  end
  wipe(list)
  for _, e in ipairs(all) do
    if Shown(e) then
      list[#list + 1] = e
    end
  end
  local cut1, cut2 = Cuts(list, key)
  local child = frame.child
  child:SetWidth(frame.scroll:GetWidth())
  for i, e in ipairs(list) do
    local r = rows[i] or MakeRow(child, i)
    rows[i] = r
    local band
    if e[key] and not e.done then
      band = (cut1 and e[key] <= cut1) and 1 or (cut2 and e[key] <= cut2) and 2 or 3
    end
    Paint(r, e, i, band)
  end
  for i = #list + 1, #rows do
    rows[i]:Hide()
    rows[i].entry = nil
  end
  child:SetHeight(math.max(1, #list * ROW_H))

  local scanned = W.ScanStore().at > 0
  if #list == 0 then
    frame.empty:SetText(scanned and "Nothing to show with these filters."
      or "Click Scan to price every Craftsman's Writ and Waylaid Crate for sale and what they need.")
    frame.empty:Show()
  else
    frame.empty:Hide()
  end

  if view == "crates" then
    if plan.count > 0 then
      local to = goal and ("to %s (%d Favor)"):format(goal.item > 0 and Short(goal.item) or "your goal", goal.need)
        or plan.budget and "within your budget" or ("the cheapest %d"):format(plan.count)
      frame.plan:SetText(("%s Plan %s: |cffffffff%d crate%s|r for about |cffffffff%s|r · %d Favor · %s per Favor%s")
        :format(QUALITY_STAR, to, plan.count, plan.count == 1 and "" or "s", Lib.FormatMoney(math.floor(plan.cost)),
          plan.favor, Lib.FormatMoney(math.floor(plan.cost / math.max(plan.favor, 1))),
          PlanNote(plan, plan.short)))
      frame.shopBtn:Show()
    else
      frame.plan:SetText(goal and goal.need == 0 and "|cff80ff80You have the Favor for your goal.|r"
        or plan.capped and "|cffff9040Nothing fits your budget.|r" or scanned and "No priced crates for sale." or "")
      frame.shopBtn:Hide()
    end
  elseif plan.count + plan.receipts > 0 then
    local goalText = plan.toNext and ("to %s (%d rep)"):format(st.nextLabel or "the next standing", plan.toNext)
      or plan.budget and "within your budget" or ("the cheapest %d"):format(plan.count)
    local what = ("%d writ%s"):format(plan.count, plan.count == 1 and "" or "s")
    if plan.receipts > 0 then
      what = (plan.count > 0 and (what .. " + ") or "") .. ("%d receipt%s"):format(plan.receipts,
        plan.receipts == 1 and "" or "s")
    end
    frame.plan:SetText(("%s Plan %s: |cffffffff%s|r for |cffffffff%s|r · %d rep · %s per rep%s"):format(
      QUALITY_STAR, goalText, what, Lib.FormatMoney(math.floor(plan.cost)), plan.rep,
      Lib.FormatMoney(math.floor(plan.cost / math.max(plan.rep, 1))),
      PlanNote(plan, plan.toNext and plan.rep < plan.toNext)))
    frame.shopBtn:Show()
  else
    frame.plan:SetText(plan.capped and "|cffff9040Nothing fits your budget.|r"
      or scanned and "No priced writs left for today." or "")
    frame.shopBtn:Hide()
  end
end

function T.Refresh()
  if frame and frame:IsVisible() then
    F():Debounce("logistics.refresh", 0.15, RealRefresh)
  end
end

local function Check(parent, key, label, tip, x)
  local cb = Kit.Check(parent)
  cb:SetPoint("BOTTOMLEFT", x, 2)
  local text = Kit.Text(parent, "GameFontHighlightSmall")
  text:SetPoint("LEFT", cb, "RIGHT", 2, 0)
  text:SetText(label)
  F():Script(cb, "OnClick", function(self)
    ARLE:SetOption(F().id, key, self:GetChecked() and true or false)
  end)
  F():Script(cb, "OnEnter", function(self)
    Kit.SimpleTooltip(self, label, tip)
  end)
  F():Script(cb, "OnLeave", GameTooltip_Hide)
  return cb, text
end

local function Tip(widget, title, text)
  F():Script(widget, "OnEnter", function(self)
    Kit.SimpleTooltip(self, title, text)
  end)
  F():Script(widget, "OnLeave", GameTooltip_Hide)
end

local function Create(parent)
  local f = CreateFrame("Frame", "ARLELogisticsPanel", parent)
  frame = f

  -- top left: the two views
  local bar = CreateFrame("Frame", nil, f)
  bar:SetPoint("TOPLEFT", 10, -8)
  bar:SetSize(220, 18)
  f.views = Kit.FilterButtons(bar, {
    { key = "writs", label = "Writs: reputation", width = 110,
      tip = "Craftsman's Writs (and Forged Delivery Receipts) by gold per reputation with your supply camp." },
    { key = "crates", label = "Crates: Favor", width = 96,
      tip = "Waylaid Crates by gold per Merchant's Favor, the camp's coin for its vendors." },
  }, View, function(key)
    ARLE:SetOption(F().id, "view", key)
    RealRefresh()
  end)
  f.camp = Kit.Text(f, "GameFontNormal")
  f.camp:SetPoint("LEFT", bar, "LEFT", 220, 0)

  -- row 2: the standing bar, or the Favor goal
  f.bar = CreateFrame("StatusBar", nil, f)
  f.bar:SetSize(260, 10)
  f.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  local barBg = f.bar:CreateTexture(nil, "BACKGROUND")
  barBg:SetAllPoints()
  barBg:SetColorTexture(0, 0, 0, 0.5)
  f.barText = Kit.Text(f, "GameFontHighlightSmall")
  f.barText:SetPoint("LEFT", f.bar, "RIGHT", 8, 0)
  f.goalBtn = Kit.Button(f, "Save up for...", 170)
  f.goalBtn:SetPoint("TOPLEFT", 10, -30)
  F():Script(f.goalBtn, "OnClick", function(self)
    GoalMenu(self)
  end)
  Tip(f.goalBtn, "Favor goal", "Pick something the camp's vendors sell: the plan then counts the cheapest crates "
    .. "to the Favor it costs.")
  PlaceBar()

  f.scanBtn = Kit.Button(f, "Scan", 90)
  f.scanBtn:SetPoint("TOPRIGHT", -10, -8)
  F():Script(f.scanBtn, "OnClick", function()
    if W.scan.running then
      W.Stop("stopped")
    else
      local ok, err = W.StartScan()
      if not ok then
        F():Print("can't scan: " .. tostring(err) .. ".")
      end
    end
    RealRefresh()
  end)
  Tip(f.scanBtn, "Scan", "Looks up every Craftsman's Writ and Waylaid Crate for sale, then what they need and the "
    .. "materials to craft it. Takes a little while: the auction house answers one search at a time.")
  f.scanText = Kit.Text(f, "GameFontHighlightSmall")
  f.scanText:SetPoint("RIGHT", f.scanBtn, "LEFT", -8, 0)

  -- the plan
  f.shopBtn = Kit.Button(f, "Shop the plan", 110)
  f.shopBtn:SetPoint("TOPRIGHT", -10, -40)
  F():Script(f.shopBtn, "OnClick", function()
    local picked = {}
    for _, e in ipairs(list) do
      if e.plan then
        picked[#picked + 1] = e
      end
    end
    Shop(picked)
  end)
  Tip(f.shopBtn, "Shop the plan", "Searches Auctionator's Shopping tab for what the plan buys (writs or crates, and "
    .. "the items, or the materials of the ones you craft).")
  f.plan = Kit.Text(f, "GameFontNormal")
  f.plan:SetPoint("TOPLEFT", 10, -54)
  f.plan:SetPoint("RIGHT", f.shopBtn, "LEFT", -8, 0)
  f.plan:SetWordWrap(false)

  -- column headers (their words follow the view)
  local header = CreateFrame("Frame", nil, f)
  header:SetPoint("TOPLEFT", 6, -72)
  header:SetPoint("RIGHT", -28, 0)
  header:SetHeight(16)
  f.headers = {}
  local ar, ag, ab = Skin:Accent()
  for col in pairs(COLS) do
    local fs = Text(header, col, "GameFontNormalSmall")
    fs:SetTextColor(ar, ag, ab)
    f.headers[col] = fs
    local hit = CreateFrame("Frame", nil, header)
    hit:SetAllPoints(fs)
    F():Script(hit, "OnEnter", function(self)
      local h = HEADERS[View()]
      if h.tips[col] then
        Kit.SimpleTooltip(self, h.labels[col], h.tips[col])
      end
    end)
    F():Script(hit, "OnLeave", GameTooltip_Hide)
  end
  local rule = Kit.Rule(f, 0.15)
  rule:SetPoint("TOPLEFT", 6, -89)
  rule:SetPoint("TOPRIGHT", -6, -89)

  -- the list
  f.scroll, f.child = Kit.Scroll(f)
  f.scroll:SetPoint("TOPLEFT", 6, -92)
  f.scroll:SetPoint("BOTTOMRIGHT", -28, 30)
  f.empty = Kit.Text(f, "GameFontDisable")
  f.empty:SetPoint("CENTER", f.scroll, "CENTER")
  f.empty:SetWidth(420)
  f.empty:SetJustifyH("CENTER")

  -- the switches
  local cb1, t1 = Check(f, "useBags", "Use what I have",
    "Writs, crates and items in your bags and bank count as free.", 6)
  local cb2, t2 = Check(f, "anyCraft", "Crafts I don't know",
    "Price crafts from recipes you don't know too, for when someone crafts it for you.", 0)
  cb2:ClearAllPoints()
  cb2:SetPoint("LEFT", t1, "RIGHT", 16, 0)
  local cb4 = Check(f, "showUnlisted", "Show unlisted",
    "Also show writs and crates nobody is selling right now (and crates whose Favor isn't known yet).", 0)
  cb4:ClearAllPoints()
  cb4:SetPoint("LEFT", t2, "RIGHT", 16, 0)
  local cb3, t3 = Check(f, "hideDone", "Hide done today", "Writ quests are daily: hide the ones you did today.", 0)
  cb3:ClearAllPoints()
  cb3:SetPoint("LEFT", cb4, "RIGHT", 100, 0)
  f.bagsCB, f.anyCB, f.doneCB, f.doneText, f.unlistedCB = cb1, cb2, cb3, t3, cb4

  -- the budget: how much to spend in one go, per view (gold; empty = no limit)
  local gold = Kit.Text(f, "GameFontHighlightSmall")
  gold:SetPoint("BOTTOMRIGHT", -10, 8)
  gold:SetText("g")
  f.budget = Kit.EditBox(f, 64)
  f.budget:SetPoint("RIGHT", gold, "LEFT", -4, 0)
  f.budget:SetNumeric(false)
  f.budget:SetMaxLetters(9)
  local budgetLabel = Kit.Text(f, "GameFontNormalSmall")
  budgetLabel:SetPoint("RIGHT", f.budget, "LEFT", -8, 0)
  budgetLabel:SetText("Spend up to")
  local function SaveBudget(box)
    local n = tonumber((box:GetText() or ""):gsub(",", "."):match("[%d%.]+") or "") or 0
    n = math.max(0, math.floor(n * 100 + 0.5) / 100)
    box:ClearFocus()
    ARLE:SetOption(F().id, BudgetKey(), n)
    RealRefresh()
  end
  F():Script(f.budget, "OnEnterPressed", SaveBudget)
  F():Script(f.budget, "OnEditFocusLost", function(box)
    local gold2 = tonumber(F().db[BudgetKey()]) or 0
    local typed = tonumber((box:GetText() or ""):gsub(",", "."):match("[%d%.]+") or "") or 0
    if typed ~= gold2 then
      SaveBudget(box)
    end
  end)
  F():Script(f.budget, "OnEscapePressed", function(box)
    box:ClearFocus()
    RealRefresh()
  end)
  Tip(f.budget, "Spend up to", "How much gold to spend in one go (each view keeps its own). The plan stops at your "
    .. "goal or at this, whichever comes first, passing over what doesn't fit for something cheaper. Empty: no limit.")

  F():Script(f, "OnShow", function()
    local db = F().db
    local at = W.ScanStore().at or 0
    if db.scanOnOpen and not W.scan.running and time() - at > 900 then
      W.StartScan()
    end
    RealRefresh()
  end)
  return f
end

ns.ARLTab.Register({ id = "logistics", title = "Logistics", order = 1, width = 90, feature = W.F,
  settings = "logistics",
  tip = "Your supply camp: Craftsman's Writs by gold per reputation, Waylaid Crates by gold per Merchant's Favor.",
  build = Create })

function T.Attach()
  ns.ARLTab.Attach()
end

function T.Enable()
  ns.ARLTab.Update()
end

function T.Disable()
  ns.ARLTab.Update(W.F)
end
