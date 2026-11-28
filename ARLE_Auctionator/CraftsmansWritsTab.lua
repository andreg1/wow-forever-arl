-- Craftsman's Writs: the Writs tab on the auction house (see CraftsmansWrits.lua
-- for the data, the scan and the costs; this file only draws them).
--
-- The tab is added through LibAHTab-1-0 (the LibStub library Auctionator ships
-- for other addons' tabs: CreateTab / GetButton), the first time the auction
-- house opens with the feature on; it can't be taken out again, so turning the
-- feature off hides its button and frame. Our frame sits on AuctionHouseFrame
-- by its own anchors; nothing is written on Blizzard's frames.
local ADDON, ns = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local Lib, Items, Kit, Skin = ARLE.Lib, ARLE.Lib.Items, ARLE.UI.Kit, ARLE.Skin
local AH = ARLE.Bridge.Auctionator

local TAB_ID = "ARLCraftsmansWrits"
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

local T = {}
ns.Writs = ns.Writs or {}
ns.WritsTab = T
local W = ns.Writs

local frame, rows = nil, {}
local list, plan = {}, nil

local function F()
  return W.F
end

local function Money(c)
  return c and Lib.FormatMoney(c) or "|cff707070--|r"
end

local function ItemName(id)
  local name, _, quality = Items.GetInfo(id)
  if not name then
    Items.Name(id)
    return "item " .. id, 1
  end
  return name, quality or 1
end

local function Icon(id)
  return Items.GetIcon and Items.GetIcon(id) or 134400
end

local function Colored(id)
  local name, quality = ItemName(id)
  local r, g, b = Lib.QualityColor(quality)
  return ("|cff%s%s|r"):format(Lib.Hex(r, g, b), name)
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

local function Age(e)
  if e.writSrc == "scan" then
    return ("scanned %s ago%s"):format(Lib.FormatDuration(e.writAge or 0), e.writQty and (", " .. e.writQty .. " for sale") or "")
  elseif e.writSrc == "auctionator" then
    return e.writAge and e.writAge > 0 and ("Auctionator, %d day%s old"):format(e.writAge, e.writAge == 1 and "" or "s")
      or "Auctionator, today"
  elseif e.writSrc == "old" then
    return "an old scan"
  end
  return "nobody is selling it"
end

local function ShowTip(row)
  local e = row.entry
  if not e then
    return
  end
  local w = e.w
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:SetText(Colored(w.id))
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
    GameTooltip:AddDoubleLine("The writ", ("%s |cff909090(%s)|r"):format(Money(e.writPrice), Age(e)), 1, 0.82, 0,
      1, 1, 1)
  end
  GameTooltip:AddLine("Its quest asks for:", 1, 0.82, 0)
  if e.haveItem > 0 then
    GameTooltip:AddLine(("   you have %d of %d%s"):format(e.haveItem, w.count, e.need == 0 and " (free)" or ""),
      0.6, 1, 0.6)
  end
  if e.need > 0 then
    AddNode(e.node, e.need, 1)
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddDoubleLine("Total", Money(e.total), 1, 0.82, 0, 1, 1, 1)
  GameTooltip:AddDoubleLine("Per reputation", Money(e.perRep), 1, 0.82, 0, 1, 1, 1)
  if w.pouch then
    GameTooltip:AddDoubleLine("Coin Pouch back (usual)", Money(w.pouch), 0.7, 0.7, 0.7, 0.7, 0.7, 0.7)
  end
  if e.plan then
    GameTooltip:AddLine(QUALITY_STAR .. " In the plan: among the cheapest to your next standing.", 1, 0.82, 0, true)
  end
  GameTooltip:AddLine("Click: look the writ and what to buy up in Auctionator · Shift-click: link", 0.5, 0.5, 0.5, true)
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
    if e.writCost and e.writCost > 0 then
      ids[e.w.id] = true
    end
    if e.need > 0 then
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
      local _, link = Items.GetInfo(e.w.id)
      if link and ChatEdit_InsertLink then
        ChatEdit_InsertLink(link)
      end
    else
      Shop({ e })
    end
  end)
  return r
end

local function SourceWord(e)
  if e.need == 0 then
    return "|cff80ff80you have it|r"
  end
  local n = e.node
  if not (n and n.src) then
    return "|cffff6060no price|r"
  elseif n.src == "craft" then
    return n.known and "|cff80c0ffcraft|r" or "|cffc080ffcraft (someone else)|r"
  elseif n.src == "vendor" then
    return "vendor"
  end
  return "auction"
end

local function PaintRow(r, e, i, band)
  r.entry = e
  local w = e.w
  r.mark:SetShown(e.plan == true)
  r.rank:SetText(e.plan and ("|cffffd100" .. i .. "|r") or tostring(i))
  r.writIcon:SetTexture(Icon(w.id))
  r.writIcon:SetDesaturated(e.done)
  local name = ItemName(w.id)
  name = name:gsub("^.-[:%-]%s+", "", 1)
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
  r.itemIcon:SetTexture(Icon(w.item))
  r.itemIcon:SetDesaturated(e.done)
  r.item:SetText((w.count > 1 and (w.count .. " x ") or "") .. Colored(w.item))
  r.itemSub:SetText(SourceWord(e))
  r.price:SetText(e.writCost == 0 and "|cff80ff80free|r" or Money(e.writPrice))
  r.fill:SetText(e.need == 0 and "|cff80ff80free|r" or Money(e.fill))
  r.total:SetText(Money(e.total))
  local color = band == 1 and "|cff40ff40" or band == 2 and "|cffffff40" or band == 3 and "|cffff9040" or "|cffb0b0b0"
  r.perRep:SetText(e.perRep and (color .. Lib.FormatMoney(e.perRep):gsub("|r", "|r" .. color) .. "|r") or Money(nil))
  r.rep:SetText(w.rep .. " rep")
  r:SetAlpha(e.done and 0.6 or 1)
  r:Show()
end

local function Shown(e)
  local db = F().db
  if e.done and db.hideDone ~= false then
    return false
  end
  if not e.listed and e.haveWrit == 0 and not db.showUnlisted then
    return false
  end
  return true
end

local function RealRefresh()
  if not (frame and frame:IsVisible()) then
    return
  end
  local db = F().db
  frame.bagsCB:SetChecked(db.useBags ~= false)
  frame.anyCB:SetChecked(db.anyCraft == true)
  frame.doneCB:SetChecked(db.hideDone ~= false)
  frame.unlistedCB:SetChecked(db.showUnlisted == true)

  -- standing
  local st = W.Standing()
  if st then
    local text = ("%s · |cffffffff%s|r"):format(st.name or "?", st.label or "?")
    frame.camp:SetText(text)
    if st.into and st.size and st.size > 0 then
      frame.bar:SetMinMaxValues(0, st.size)
      frame.bar:SetValue(st.into)
      frame.bar:Show()
      frame.barText:SetText(st.toNext and ("%d / %d · %d to %s"):format(st.into, st.size, st.toNext,
        st.nextLabel or "the next standing") or ("%d / %d"):format(st.into, st.size))
    else
      frame.bar:Hide()
      frame.barText:SetText("")
    end
  else
    frame.camp:SetText("Supply camp: no standing yet")
    frame.bar:Hide()
    frame.barText:SetText("")
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
    frame.empty:SetText("The writ data comes from ItemTree: install it or turn it on, then /reload.")
    frame.empty:Show()
    frame.plan:SetText("")
    frame.shopBtn:Hide()
    return
  end

  local all = W.Evaluate()
  plan = W.Plan(all, st)
  wipe(list)
  for _, e in ipairs(all) do
    if Shown(e) then
      list[#list + 1] = e
    end
  end
  -- per reputation bands: thirds of what's priced and not done
  local priced = {}
  for _, e in ipairs(list) do
    if e.perRep and not e.done then
      priced[#priced + 1] = e
    end
  end
  local cut1 = priced[math.max(1, math.floor(#priced / 3))]
  local cut2 = priced[math.max(1, math.floor(#priced * 2 / 3))]
  local child = frame.child
  child:SetWidth(frame.scroll:GetWidth())
  for i, e in ipairs(list) do
    local r = rows[i] or MakeRow(child, i)
    rows[i] = r
    local band
    if e.perRep and not e.done then
      band = (cut1 and e.perRep <= cut1.perRep) and 1 or (cut2 and e.perRep <= cut2.perRep) and 2 or 3
    end
    PaintRow(r, e, i, band)
  end
  for i = #list + 1, #rows do
    rows[i]:Hide()
    rows[i].entry = nil
  end
  child:SetHeight(math.max(1, #list * ROW_H))

  if #list == 0 then
    frame.empty:SetText(W.ScanStore().at > 0 and "No writs to show with these filters."
      or "Click Scan to price every Craftsman's Writ for sale and what their quests ask for.")
    frame.empty:Show()
  else
    frame.empty:Hide()
  end
  if plan.count > 0 then
    local goal = plan.toNext and ("to %s (%d rep)"):format(st.nextLabel or "the next standing", plan.toNext)
      or ("the cheapest %d"):format(plan.count)
    frame.plan:SetText(("%s Plan %s: |cffffffff%d writ%s|r for |cffffffff%s|r · %d rep · %s per rep%s"):format(
      QUALITY_STAR, goal, plan.count, plan.count == 1 and "" or "s", Lib.FormatMoney(plan.cost), plan.rep,
      Lib.FormatMoney(plan.cost / math.max(plan.rep, 1)),
      plan.toNext and plan.rep < plan.toNext and " |cffff9040(not enough for sale today)|r" or ""))
    frame.shopBtn:Show()
  else
    frame.plan:SetText(W.ScanStore().at > 0 and "No priced writs left for today." or "")
    frame.shopBtn:Hide()
  end
end

function T.Refresh()
  if frame and frame:IsVisible() then
    F():Debounce("writs.refresh", 0.15, RealRefresh)
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

local function Create()
  local f = CreateFrame("Frame", "ARLECraftsmansWritsTab", AuctionHouseFrame)
  f:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPLEFT", 4, -62)
  f:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -4, 27)
  f:Hide() -- (LibAHTab shows it when the tab is picked)
  Skin:Panel(f)

  -- top: the camp and its bar, the scan
  f.camp = Kit.Text(f, "GameFontNormal")
  f.camp:SetPoint("TOPLEFT", 10, -8)
  f.bar = CreateFrame("StatusBar", nil, f)
  f.bar:SetSize(260, 10)
  f.bar:SetPoint("TOPLEFT", 10, -28)
  f.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  f.bar:SetStatusBarColor(0, 0.7, 0.2)
  local barBg = f.bar:CreateTexture(nil, "BACKGROUND")
  barBg:SetAllPoints()
  barBg:SetColorTexture(0, 0, 0, 0.5)
  f.barText = Kit.Text(f, "GameFontHighlightSmall")
  f.barText:SetPoint("LEFT", f.bar, "RIGHT", 8, 0)

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
  F():Script(f.scanBtn, "OnEnter", function(self)
    Kit.SimpleTooltip(self, "Scan", "Looks up every Craftsman's Writ for sale, then what their quests ask for and "
      .. "the materials to craft it. Takes a little while: the auction house answers one search at a time.")
  end)
  F():Script(f.scanBtn, "OnLeave", GameTooltip_Hide)
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
  F():Script(f.shopBtn, "OnEnter", function(self)
    Kit.SimpleTooltip(self, "Shop the plan", "Searches Auctionator's Shopping tab for the writs in the plan and "
      .. "what to buy for them (the items, or the materials of the ones you craft).")
  end)
  F():Script(f.shopBtn, "OnLeave", GameTooltip_Hide)
  f.plan = Kit.Text(f, "GameFontNormal")
  f.plan:SetPoint("TOPLEFT", 10, -46)
  f.plan:SetPoint("RIGHT", f.shopBtn, "LEFT", -8, 0)
  f.plan:SetWordWrap(false)

  -- column headers
  local header = CreateFrame("Frame", nil, f)
  header:SetPoint("TOPLEFT", 6, -68)
  header:SetPoint("RIGHT", -28, 0)
  header:SetHeight(16)
  local labels = { rank = "#", writ = "Writ", item = "Asks for", price = "Writ", fill = "Items", total = "Total",
    perRep = "Per rep" }
  local tips = {
    price = "The writ's lowest price for sale.",
    fill = "What its quest asks for: the cheapest of buying it, a vendor, or crafting it from materials.",
    total = "The writ and the items together.",
    perRep = "Total over the reputation it gives. Green: the cheapest third.",
  }
  local ar, ag, ab = Skin:Accent()
  for col, label in pairs(labels) do
    local fs = Text(header, col, "GameFontNormalSmall")
    fs:SetText(label)
    fs:SetTextColor(ar, ag, ab)
    if tips[col] then
      local hit = CreateFrame("Frame", nil, header)
      hit:SetAllPoints(fs)
      F():Script(hit, "OnEnter", function(self)
        Kit.SimpleTooltip(self, label, tips[col])
      end)
      F():Script(hit, "OnLeave", GameTooltip_Hide)
    end
  end
  local rule = Kit.Rule(f, 0.15)
  rule:SetPoint("TOPLEFT", 6, -85)
  rule:SetPoint("TOPRIGHT", -6, -85)

  -- the list
  f.scroll, f.child = Kit.Scroll(f)
  f.scroll:SetPoint("TOPLEFT", 6, -88)
  f.scroll:SetPoint("BOTTOMRIGHT", -28, 30)
  f.empty = Kit.Text(f, "GameFontDisable")
  f.empty:SetPoint("CENTER", f.scroll, "CENTER")
  f.empty:SetWidth(420)
  f.empty:SetJustifyH("CENTER")

  -- the switches
  local cb1, t1 = Check(f, "useBags", "Use what I have", "Writs and items in your bags and bank count as free.", 6)
  local cb2, t2 = Check(f, "anyCraft", "Crafts I don't know",
    "Price crafts from recipes you don't know too, for when someone crafts it for you.", 0)
  cb2:ClearAllPoints()
  cb2:SetPoint("LEFT", t1, "RIGHT", 16, 0)
  local cb3, t3 = Check(f, "hideDone", "Hide done today", "Writ quests are daily: hide the ones you did today.", 0)
  cb3:ClearAllPoints()
  cb3:SetPoint("LEFT", t2, "RIGHT", 16, 0)
  local cb4 = Check(f, "showUnlisted", "Show unlisted writs", "Also show writs nobody is selling right now.", 0)
  cb4:ClearAllPoints()
  cb4:SetPoint("LEFT", t3, "RIGHT", 16, 0)
  f.bagsCB, f.anyCB, f.doneCB, f.unlistedCB = cb1, cb2, cb3, cb4

  F():Script(f, "OnShow", function()
    local db = F().db
    local at = W.ScanStore().at or 0
    if db.scanOnOpen and not W.scan.running and time() - at > 900 then
      W.StartScan()
    end
    RealRefresh()
  end)
  frame = f
  return f
end

-- The first time the auction house opens with the feature on: the tab.
function T.Attach()
  if frame or not F()._active then
    return
  end
  local lib = LibStub and LibStub("LibAHTab-1-0", true)
  if not (lib and AuctionHouseFrame) then
    F():Debug("no LibAHTab-1-0 (Auctionator's) or no AuctionHouseFrame: no tab")
    return
  end
  local f = Create()
  local ok, err = pcall(lib.CreateTab, lib, TAB_ID, f, "Writs", "Craftsman's Writs")
  if not ok then
    F():Debug("LibAHTab CreateTab failed: %s", tostring(err))
    return
  end
  F():Debug("Writs tab added")
end

local function Button()
  local lib = LibStub and LibStub("LibAHTab-1-0", true)
  if lib and lib.DoesIDExist and lib:DoesIDExist(TAB_ID) then
    return lib:GetButton(TAB_ID)
  end
end

function T.Enable()
  local b = Button()
  if b then
    b:Show()
  elseif AuctionHouseFrame and AuctionHouseFrame:IsShown() then
    T.Attach()
  end
end

function T.Disable()
  local b = Button()
  if b then
    b:Hide()
  end
  if frame then
    frame:Hide()
  end
end
