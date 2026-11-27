-- Auto Mail: sends chosen bag items to chosen characters at a mailbox.
--
-- Our own code, against Blizzard's mail API only (no other addon needed).
-- Settings are account-wide (shared.mailSettings, through the options'
-- get/set): every character uses the same rules. The on/off switch stays per
-- character (the host's). A rule naming the character you're on is skipped
-- on that character, so one list can say "everything goes to the bank alt"
-- and the bank alt keeps its own. A rule is "<item> = <character>" where <item>
-- is an item ID, an exact item name, or a name with * wildcards ("* Cloth").
--
-- Names: Forever's mail needs "First Surname" (EllesmereUI's mail alts note
-- this too). Every character that runs Auto Mail records its full name in
-- shared.alts; with EllesmereUI, its character roster (EllesmereUI.Chars(),
-- read through ARLE.Bridge.EUI.Characters) adds every character played since.
-- Those fill the pane's "Send to" dropdown, and let a typed rule name just the
-- first name of one of them.
--
-- The pane (panePage "rules"): pick a character, then pick up an item in the
-- bags and click (or drop it on) the slot: an "<itemID> = <name>" rule. Each
-- rule's row changes its character from a menu, or removes it. Name and
-- wildcard rules ("* Cloth") are still typed with /arl mail add.
--
-- Sending: on MAIL_SHOW (auto, Shift skips) or the card's Send button, the
-- bags are scanned; per recipient, up to ATTACHMENTS_MAX_SEND stacks go into
-- one mail (PickupContainerItem + ClickSendMailItemButton, SendMail), and the
-- next mail only after MAIL_SEND_SUCCESS. MAIL_FAILED, a mail error or a
-- timeout stops that recipient and clears what we attached. Never mailed:
-- soulbound items, items Item Lock protects (its padlocks and gear sets),
-- items the cursor holds. If the Send Mail tab already holds attachments the
-- player put there, nothing is touched. Nothing protected is called.
local ADDON = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local Lib = ARLE.Lib
local Items = Lib.Items
local Kit = ARLE.UI.Kit

local MAX_ATTACH = 12      -- stacks per mail when the client has no ATTACHMENTS_MAX_SEND
local SEND_GAP = 0.6       -- seconds between one mail's success and the next
local SEND_TIMEOUT = 15    -- seconds to wait for the server's answer
local AUTO_DELAY = 0.4     -- seconds after the mailbox opens before an auto run
local ALT_DAYS = 120       -- a character's name is forgotten after this many days unseen
local SUBJECT_MAX = 60
local SETTINGS_KEY = "mailSettings" -- self.shared key (in SHARED_ONLY)
local DEFAULTS = { rules = {}, auto = true, card = true, chat = true }

-- The account-wide settings table.
local function Store(def)
  local shared = def and def.shared
  if type(shared) ~= "table" then
    return {}
  end
  local t = shared[SETTINGS_KEY]
  if type(t) ~= "table" then
    t = {}
    shared[SETTINGS_KEY] = t
  end
  return t
end

-- An option whose value lives in the account-wide table.
local function Account(opt)
  opt.default = DEFAULTS[opt.key]
  opt.get = function(def)
    local v = Store(def)[opt.key]
    if v == nil then
      return DEFAULTS[opt.key]
    end
    return v
  end
  opt.set = function(value, def)
    Store(def)[opt.key] = value
  end
  return opt
end

local F = {
  id = "AutoMail",
  addon = ADDON,
  title = "Auto Mail",
  group = "QualityOfLife",
  command = "mail",
  commandHelp = "mails chosen items to chosen characters at a mailbox",
  description = "Sends the items you pick to the characters you pick as soon as you open a mailbox "
    .. "(hold Shift to skip), or with the card's Send button. Soulbound and locked items stay. "
    .. "The same on all your characters; nothing is mailed to the one you're on.",
  pages = {
    { key = "rules", label = "What goes where",
      notes = "Pick a character, then pick up an item in your bags and click the slot." },
    { key = "send", label = "Sending" },
  },
  panePage = "rules",
  options = {
    { type = "info", text = function(def) return def:GetStatus() end, page = "send" },
    Account({ key = "auto", type = "boolean", label = "Send as soon as I open a mailbox", page = "send" }),
    Account({ key = "card", type = "boolean", label = "Show a card at the mailbox with what goes where",
      page = "send" }),
    Account({ key = "chat", type = "boolean", label = "Say in chat what was sent", page = "send" }),
    { type = "info", text = "These settings are the same on all your characters.", page = "send" },
  },
}

local mailOpen = false
local plan = {}         -- { { to = "First Surname", stacks = { { bag, slot, itemID, count } } } }
local run = nil         -- { queue = plan, i = recipient index, pending = { to, slots, at }, sent = {} }
local runGen = 0        -- bumped to drop the timers of a finished or stopped run
local closedCard = false
local card
local lastRun = {}      -- lines for /arl report
local MAIL_ERRORS = {}

-- An account-wide setting.
local function Get(key)
  local v = Store(F)[key]
  if v == nil then
    return DEFAULTS[key]
  end
  return v
end

local function MaxAttach()
  return tonumber(_G.ATTACHMENTS_MAX_SEND) or MAX_ATTACH
end

local function Log(fmt, ...)
  local line = string.format(fmt, ...)
  lastRun[#lastRun + 1] = date("%H:%M:%S ") .. line
  if #lastRun > 40 then
    table.remove(lastRun, 1)
  end
  F:Debug("%s", line)
end

-------------------------------------------------------------------------------
-- Names
-------------------------------------------------------------------------------

local function Alts()
  local t = F.shared.alts
  if type(t) ~= "table" then
    t = {}
    F.shared.alts = t
  end
  return t
end

local function NoteMe()
  local me = ARLE:MyName()
  if type(me) == "string" and me:find(" ") then
    local _, class = UnitClass("player")
    Alts()[me] = { class = class, seen = time() }
  end
  local cutoff = time() - ALT_DAYS * 86400
  for name, info in pairs(Alts()) do
    if type(info) ~= "table" or (tonumber(info.seen) or 0) < cutoff then
      Alts()[name] = nil
    end
  end
end

-- The character you're on: by full name, or by first name when the rule
-- gave no surname.
local function IsMe(name)
  name = Lib.Trim(name):lower()
  local me = (ARLE:MyName() or ""):lower()
  if name == me then
    return true
  end
  return not name:find(" ") and name == (me:match("^(%S+)") or "")
end

-- Your characters with full names (Auto Mail's record + EllesmereUI's roster),
-- the one you're on left out: { [lower name] = { name, class } }.
local function KnownCharacters()
  local out = {}
  for name, info in pairs(Alts()) do
    if type(name) == "string" and name:find(" ") then
      out[name:lower()] = { name = name, class = type(info) == "table" and info.class or nil }
    end
  end
  for _, c in ipairs(ARLE.Bridge.EUI.Characters()) do
    if c.name:find(" ") and not out[c.name:lower()] then
      out[c.name:lower()] = { name = c.name, class = c.class }
    end
  end
  for key, c in pairs(out) do
    if IsMe(c.name) then
      out[key] = nil
    end
  end
  return out
end

-- The full name mail needs: as typed when it has a surname, else the one
-- known character whose first name it is.
local function Resolve(name)
  name = Lib.Trim(name)
  if name == "" or name:find(" ") then
    return name, true
  end
  local want, found = name:lower(), nil
  local me = ARLE:MyName()
  local all = KnownCharacters()
  if type(me) == "string" then
    all[me:lower()] = { name = me }
  end
  for _, c in pairs(all) do
    if (c.name:match("^(%S+)") or ""):lower() == want then
      if found then
        return name, false -- two characters share that first name
      end
      found = c.name
    end
  end
  if found then
    return found, true
  end
  return name, false
end

-------------------------------------------------------------------------------
-- Rules
-------------------------------------------------------------------------------

local function Pattern(text)
  local escaped = text:lower():gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0")
  return "^" .. escaped:gsub("%*", ".*") .. "$"
end

-- "<item> = <character>" (also "->" or " to ") -> rule, or nil + why.
local function ParseRule(text)
  text = Lib.Trim(text)
  local item, to = text:match("^(.-)%s*=%s*(.+)$")
  if not item then
    item, to = text:match("^(.-)%s*%->%s*(.+)$")
  end
  if not item then
    item, to = text:match("^(.-)%s+[Tt][Oo]%s+(.+)$")
  end
  item, to = Lib.Trim(item), Lib.Trim(to)
  if item == "" or to == "" then
    return nil, "write it as item = character"
  end
  local rule = { text = text, typed = to, itemText = item }
  rule.to, rule.known = Resolve(to)
  local id = Items.IDFromLink(item) or tonumber(item:match("^item:(%d+)$") or item:match("^#?(%d+)$") or "")
  if id then
    rule.id = id
  elseif item:find("%*") then
    rule.pattern = Pattern(item)
    rule.label = item
  else
    rule.name = (item:match("%[(.-)%]") or item):lower()
    rule.label = item:match("%[(.-)%]") or item
  end
  return rule
end

local function Rules()
  local list = {}
  for _, text in ipairs(Get("rules") or {}) do
    local rule = ParseRule(text)
    if rule then
      list[#list + 1] = rule
    end
  end
  return list
end

-- Saves the rule texts (account-wide) and redraws.
local function SetRules(list)
  Store(F).rules = list
  if F.OnOptionChanged then
    F:OnOptionChanged("rules")
  end
  ARLE:Changed()
end

-- Adds "<itemID> = <name>", replacing an earlier rule for that same item.
local function SetItemRule(itemID, name)
  local list = {}
  for _, text in ipairs(Get("rules") or {}) do
    local rule = ParseRule(text)
    if not (rule and rule.id == itemID) then
      list[#list + 1] = text
    end
  end
  list[#list + 1] = itemID .. " = " .. name
  SetRules(list)
end

local function Matches(rule, itemID, name)
  if rule.id then
    return rule.id == itemID
  end
  if not name then
    return false
  end
  name = name:lower()
  if rule.pattern then
    return name:match(rule.pattern) ~= nil
  end
  return rule.name == name
end

function F:FormatRule(text)
  local rule, why = ParseRule(text)
  if not rule then
    return "|cffff6060" .. tostring(text) .. "|r  |cff888888(" .. why .. ")|r"
  end
  local item = rule.id and Items.Link(rule.id) or ("|cffffffff" .. rule.label .. "|r")
  local to = rule.to
  if IsMe(to) then
    to = to .. " |cff888888(this character: skipped here)|r"
  elseif not rule.known then
    to = to .. " |cffffd100(add the surname: mail needs \"First Surname\")|r"
  end
  return item .. "  |cff888888->|r  " .. to
end

-------------------------------------------------------------------------------
-- Bags
-------------------------------------------------------------------------------

local function Protected(itemID)
  local lock = ARLE.modules and ARLE.modules.ItemLock
  return lock and lock.IsProtected and lock:IsProtected(itemID) or false
end

local function SlotInfo(bag, slot)
  local info = Lib.Call(C_Container.GetContainerItemInfo, bag, slot)
  if not Lib.Readable(info) then
    return nil
  end
  return info
end

-- Builds the plan from the bags: recipients in rule order, each with its stacks.
local function BuildPlan()
  plan = {}
  if not (C_Container and C_Container.GetContainerNumSlots) then
    return plan
  end
  local rules = Rules()
  if #rules == 0 then
    return plan
  end
  local byName = {}
  for bag = 0, (NUM_BAG_SLOTS or 4) do
    for slot = 1, Lib.Call(C_Container.GetContainerNumSlots, bag) or 0 do
      local info = SlotInfo(bag, slot)
      local itemID = info and Lib.Plain(info.itemID)
      if itemID and not info.isBound and not info.isLocked and not Protected(itemID) then
        local name = Items.GetInfo(itemID)
        for _, rule in ipairs(rules) do
          if Matches(rule, itemID, name) then
            if not IsMe(rule.to) then
              local key = rule.to:lower()
              local entry = byName[key]
              if not entry then
                entry = { to = rule.to, stacks = {} }
                byName[key] = entry
                plan[#plan + 1] = entry
              end
              entry.stacks[#entry.stacks + 1] = { bag = bag, slot = slot, itemID = itemID,
                count = Lib.Plain(info.stackCount) or 1 }
            end
            break -- the first rule that matches decides
          end
        end
      end
    end
  end
  return plan
end

local function PlanCounts(list)
  local stacks = 0
  for _, entry in ipairs(list) do
    stacks = stacks + #entry.stacks
  end
  return stacks, #list
end

-- "20x Linen Cloth, 3x Wool Cloth" for one recipient.
local function Summary(entry, limit)
  local totals, order = {}, {}
  for _, s in ipairs(entry.stacks) do
    if not totals[s.itemID] then
      order[#order + 1] = s.itemID
      totals[s.itemID] = 0
    end
    totals[s.itemID] = totals[s.itemID] + s.count
  end
  local parts = {}
  for i, id in ipairs(order) do
    if limit and i > limit then
      parts[#parts + 1] = "+" .. (#order - limit) .. " more"
      break
    end
    parts[#parts + 1] = totals[id] .. "x " .. Items.Name(id)
  end
  return table.concat(parts, ", ")
end

-------------------------------------------------------------------------------
-- The card
-------------------------------------------------------------------------------

local function Paint()
  if not card then
    return
  end
  if not (mailOpen and Get("card") and not closedCard) then
    card:Hide()
    return
  end
  local stacks, people = PlanCounts(plan)
  if run then
    local entry = run.queue[run.i]
    card:SetLines("Mailing...", entry and ("To " .. entry.to .. ": " .. Summary(entry, 3)) or nil,
      string.format("%d mail%s sent", #run.sent, #run.sent == 1 and "" or "s"))
    card.send:SetText("Stop")
  elseif stacks == 0 then
    if #lastRun == 0 or not F.sentHere then
      card:Hide()
      return
    end
    card:SetLines("Auto Mail: all sent", F.sentHere, nil)
    card.send:SetText("Send")
  else
    local lines = {}
    for i, entry in ipairs(plan) do
      if i > 3 then
        lines[#lines + 1] = "+" .. (#plan - 3) .. " more"
        break
      end
      lines[#lines + 1] = entry.to .. ": " .. Summary(entry, 2)
    end
    card:SetLines(string.format("%s for %s", Lib.Plural(stacks, "stack"), Lib.Plural(people, "character")),
      table.concat(lines, "\n"), Get("auto") and "Hold Shift at the mailbox to skip sending" or nil)
    card.send:SetText("Send")
  end
  local first = plan[1] and plan[1].stacks[1]
  card.icon:SetTexture(first and Items.GetIcon(first.itemID) or "Interface\\Icons\\INV_Letter_15")
  card.place()
  card:Show()
end

local function MakeCard()
  if card then
    return
  end
  card = Kit.Card(F, { icon = true, move = { y = 120 } })
  card:AddButton("Close", 48, function()
    closedCard = true
    Paint()
  end)
  card.send = card:AddButton("Send", 48, function()
    if run then
      F:Stop("stopped")
    else
      F:Start("button")
    end
  end)
  card:Hide()
end

-------------------------------------------------------------------------------
-- Sending
-------------------------------------------------------------------------------

local function HasAttachments()
  for i = 1, MaxAttach() do
    if Lib.Call(HasSendMailItem, i) then
      return true
    end
  end
  return false
end

local function ClearAttachments()
  for i = 1, MaxAttach() do
    if Lib.Call(HasSendMailItem, i) then
      Lib.Call(ClickSendMailItemButton, i, true)
    end
  end
end

local function ShowSendTab()
  local frame = _G.SendMailFrame
  if frame and not frame:IsVisible() and _G.MailFrameTab2 then
    _G.MailFrameTab2:Click()
  end
end

function F:Stop(why)
  if not run then
    return
  end
  runGen = runGen + 1
  if run.pending then
    ClearAttachments()
  end
  ClearCursor()
  local sent = run.sent
  run = nil
  Log("run ended: %s (%d mail(s))", why, #sent)
  if #sent > 0 then
    local per, order = {}, {}
    for _, s in ipairs(sent) do
      if not per[s.to] then
        per[s.to] = 0
        order[#order + 1] = s.to
      end
      per[s.to] = per[s.to] + s.stacks
    end
    local parts = {}
    for _, to in ipairs(order) do
      parts[#parts + 1] = to .. " (" .. Lib.Plural(per[to], "stack") .. ")"
    end
    self.sentHere = "Sent to " .. table.concat(parts, ", ")
    if Get("chat") then
      self:Print(self.sentHere .. ".")
    end
  end
  BuildPlan()
  Paint()
end

-- Sends the next mail of the run, or ends it.
function F:Next()
  if not run then
    return
  end
  if not mailOpen then
    self:Stop("the mailbox closed")
    return
  end
  local entry = run.queue[run.i]
  -- Stacks that are no longer where the plan saw them are left out.
  local batch = {}
  while entry do
    while #entry.stacks > 0 and #batch < MaxAttach() do
      local s = table.remove(entry.stacks, 1)
      local info = SlotInfo(s.bag, s.slot)
      if info and Lib.Plain(info.itemID) == s.itemID and not info.isLocked and not info.isBound then
        batch[#batch + 1] = s
      end
    end
    if #batch > 0 then
      break
    end
    run.i = run.i + 1
    entry = run.queue[run.i]
  end
  if not entry then
    self:Stop("done")
    return
  end
  if HasAttachments() then
    self:Print("the Send Mail tab already holds items: send or clear them, then press Send again.")
    self:Stop("attachments already there")
    return
  end
  ShowSendTab()
  ClearCursor()
  for i, s in ipairs(batch) do
    Lib.Call(C_Container.PickupContainerItem, s.bag, s.slot)
    Lib.Call(ClickSendMailItemButton, i)
    if CursorHasItem() then
      ClearCursor()
      Log("couldn't attach %s from bag %d slot %d", Items.Name(s.itemID), s.bag, s.slot)
      self:Print("couldn't attach " .. Items.Link(s.itemID) .. "; stopped.")
      ClearAttachments()
      self:Stop("attach failed")
      return
    end
  end
  local price = Lib.Call(GetSendMailPrice) or 0
  if price > (GetMoney() or 0) then
    ClearAttachments()
    self:Print("not enough money for the postage (" .. Lib.FormatMoney(price) .. ").")
    self:Stop("no money")
    return
  end
  Lib.Call(SetSendMailCOD, 0)
  Lib.Call(SetSendMailMoney, 0)
  local first = batch[1].itemID
  local one = true
  local total = 0
  for _, s in ipairs(batch) do
    one = one and s.itemID == first
    total = total + s.count
  end
  local subject = one and (Items.Name(first) .. " x" .. total) or ("Items (" .. #batch .. " stacks)")
  subject = subject:sub(1, SUBJECT_MAX)
  run.pending = { to = entry.to, stacks = #batch, subject = subject }
  Log("sending \"%s\" to %s (%d stack(s), %s postage)", subject, entry.to, #batch, Lib.FormatMoney(price))
  local gen = runGen
  local ok = pcall(SendMail, entry.to, subject, "")
  if not ok then
    self:OnSendFailed("SendMail refused")
    return
  end
  self:After(SEND_TIMEOUT, function()
    if run and runGen == gen and run.pending then
      self:Print("no answer from the mail server; stopped.")
      self:Stop("timeout")
    end
  end)
  Paint()
end

function F:Start(via)
  if run or not mailOpen then
    return
  end
  closedCard = false
  BuildPlan()
  if PlanCounts(plan) == 0 then
    self:Debug("%s: nothing to send", via)
    Paint()
    return
  end
  runGen = runGen + 1
  lastRun = {}
  self.sentHere = nil
  run = { queue = plan, i = 1, sent = {} }
  Log("run started (%s): %d stack(s) for %d character(s)", via, PlanCounts(plan))
  self:Next()
end

function F:OnSendSuccess()
  if not (run and run.pending) then
    return
  end
  local p = run.pending
  run.pending = nil
  run.sent[#run.sent + 1] = p
  Log("sent to %s", p.to)
  runGen = runGen + 1
  local gen = runGen
  self:After(SEND_GAP, function()
    if runGen == gen then
      self:Next()
    end
  end)
  Paint()
end

-- This recipient's remaining stacks are dropped; the next one goes on.
function F:OnSendFailed(why)
  if not (run and run.pending) then
    return
  end
  local p = run.pending
  run.pending = nil
  ClearAttachments()
  Log("failed to %s: %s", p.to, tostring(why))
  self:Print("couldn't mail " .. p.to .. ": " .. tostring(why))
  run.queue[run.i].stacks = {}
  run.i = run.i + 1
  runGen = runGen + 1
  local gen = runGen
  self:After(SEND_GAP, function()
    if runGen == gen then
      self:Next()
    end
  end)
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

function F:OnMailShow()
  mailOpen = true
  closedCard = false
  self.sentHere = nil
  BuildPlan()
  Paint()
  if Get("auto") then
    if IsShiftKeyDown() then
      self:Debug("auto: skipped (Shift held)")
      return
    end
    self:After(AUTO_DELAY, function()
      self:Start("auto")
    end)
  end
end

function F:OnMailClosed()
  mailOpen = false
  self:Stop("the mailbox closed")
  Paint()
end

function F:OnBags()
  if mailOpen and not run then
    BuildPlan()
    Paint()
  end
end

function F:OnUIError(_, _, message)
  if run and run.pending and MAIL_ERRORS[message] then
    self:OnSendFailed(message)
  end
end

function F:OnEnable()
  mailOpen = _G.MailFrame and _G.MailFrame:IsShown() or false
  run, closedCard, plan = nil, false, {}
  runGen = runGen + 1
  MAIL_ERRORS = {}
  for key, text in pairs(_G) do
    if type(key) == "string" and type(text) == "string" and key:find("^ERR_MAIL_") then
      MAIL_ERRORS[text] = true
    end
  end
  for _, key in ipairs({ "ERR_NOT_ENOUGH_MONEY", "ERR_PLAYER_WRONG_FACTION" }) do
    if type(_G[key]) == "string" then
      MAIL_ERRORS[_G[key]] = true
    end
  end
  NoteMe()
  self:MoveOldRules()
  MakeCard()
  self:On("MAIL_SHOW", self.OnMailShow)
  self:On("MAIL_CLOSED", self.OnMailClosed)
  self:On("MAIL_SEND_SUCCESS", self.OnSendSuccess)
  self:On("MAIL_FAILED", function()
    self:OnSendFailed("the mail failed")
  end)
  self:On("UI_ERROR_MESSAGE", self.OnUIError)
  self:On("BAG_UPDATE_DELAYED", self.OnBags)
  refreshQueued = false
  self:On("GET_ITEM_INFO_RECEIVED", self.OnItemInfo)
  if mailOpen then
    BuildPlan()
    Paint()
  end
end

-- 0.18.0 kept the rules per character: they're merged into the
-- account-wide list once, and the old copy is dropped.
function F:MoveOldRules()
  local old = self.db.rules
  if type(old) ~= "table" then
    return
  end
  local list, have = { unpack(Get("rules")) }, {}
  for _, v in ipairs(list) do
    have[Lib.Key(v)] = true
  end
  local moved = 0
  for _, v in ipairs(old) do
    if type(v) == "string" and not have[Lib.Key(v)] then
      list[#list + 1] = v
      have[Lib.Key(v)] = true
      moved = moved + 1
    end
  end
  Store(self).rules = list
  for _, key in ipairs({ "auto", "card", "chat" }) do
    if Store(self)[key] == nil and self.db[key] ~= nil then
      Store(self)[key] = self.db[key]
    end
    self.db[key] = nil
  end
  self.db.rules = nil
  if moved > 0 then
    self:Print(Lib.Plural(moved, "rule") .. " from this character now apply to all your characters.")
  end
end

function F:OnDisable()
  if run then
    self:Stop("turned off")
  end
  mailOpen = false
  if card then
    card:Hide()
  end
end

-------------------------------------------------------------------------------
-- The pane: "Send to" + item slot + the rule list
-------------------------------------------------------------------------------

local ROW_H = 24
local QUESTION_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local paneFrame
local refreshQueued = false

-- Everyone the menu offers: known characters, names typed in the pane, and
-- the characters rules already name (not the one you're on), sorted.
local function MenuNames()
  local byKey = KnownCharacters()
  local function add(name)
    name = Lib.Trim(name)
    if name ~= "" and not IsMe(name) and not byKey[name:lower()] then
      byKey[name:lower()] = { name = name }
    end
  end
  for _, name in ipairs(Store(F).extra or {}) do
    add(name)
  end
  for _, rule in ipairs(Rules()) do
    add(rule.to)
  end
  local list = {}
  for _, c in pairs(byKey) do
    list[#list + 1] = c
  end
  table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
  return list
end

local function Colored(c)
  return c.class and Lib.ColorName(c) or c.name
end

-- A menu of characters under owner; onPick(name) runs on a choice.
function F:TargetMenu(owner, current, onPick)
  local names = MenuNames()
  local function pick(name)
    ARLE.Debug.Call(F, onPick, name)
  end
  if not (MenuUtil and MenuUtil.CreateContextMenu) then
    -- No menu on this client: each click steps to the next name.
    if #names == 0 then
      return
    end
    local nextIndex = 1
    for i, c in ipairs(names) do
      if current and c.name:lower() == current:lower() then
        nextIndex = i % #names + 1
      end
    end
    pick(names[nextIndex].name)
    return
  end
  MenuUtil.CreateContextMenu(owner, function(_, root)
    if #names == 0 then
      root:CreateTitle("No characters known yet: type a name")
      return
    end
    for _, c in ipairs(names) do
      root:CreateRadio(Colored(c), function()
        return current ~= nil and c.name:lower() == current:lower()
      end, function()
        pick(c.name)
      end)
    end
  end)
end

local function ChangeTarget(index, name)
  local list = { unpack(Get("rules") or {}) }
  local rule = list[index] and ParseRule(list[index])
  if rule then
    list[index] = rule.itemText .. " = " .. name
    SetRules(list)
  end
end

local function RemoveRule(index)
  local list = {}
  for i, text in ipairs(Get("rules") or {}) do
    if i ~= index then
      list[#list + 1] = text
    end
  end
  SetRules(list)
end

-- The item on the cursor becomes a rule for the picked character.
function F:DropItem()
  local kind, itemID = GetCursorInfo()
  if kind ~= "item" or type(itemID) ~= "number" then
    self:Print("pick up an item in your bags first, then click the slot.")
    return
  end
  ClearCursor()
  local target = Store(self).target
  if not target or target == "" then
    self:Print("pick a character in \"Send to\" first.")
    return
  end
  SetItemRule(itemID, target)
  self:Print(Items.Link(itemID) .. " now goes to " .. target .. ".")
end

local function Row(pane, i)
  local row = pane.rows[i]
  if row then
    return row
  end
  row = CreateFrame("Frame", nil, pane.child)
  row:SetHeight(ROW_H)
  row.icon = Kit.Icon(row, 20)
  row.icon:SetPoint("LEFT", 2, 0)
  F:Script(row.icon, "OnEnter", function(btn)
    if row.itemID then
      GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(row.itemID)
      GameTooltip:Show()
    end
  end)
  F:Script(row.icon, "OnLeave", function()
    GameTooltip:Hide()
  end)
  row.remove = Kit.SmallButton(row, "x", 18)
  row.remove:SetPoint("RIGHT", -2, 0)
  F:Script(row.remove, "OnClick", function()
    if ARLE:Allowed() then
      RemoveRule(row.index)
    end
  end)
  row.to = Kit.SmallButton(row, "", 140)
  row.to:SetPoint("RIGHT", row.remove, "LEFT", -4, 0)
  F:Script(row.to, "OnClick", function(btn)
    F:TargetMenu(btn, row.toName, function(name)
      ChangeTarget(row.index, name)
    end)
  end)
  Kit.Tip(row.to, "Send to", "Click to pick another character for this item.")
  row.text = Kit.Text(row, "GameFontHighlightSmall")
  row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
  row.text:SetPoint("RIGHT", row.to, "LEFT", -6, 0)
  row.text:SetJustifyH("LEFT")
  row.text:SetWordWrap(false)
  pane.rows[i] = row
  return row
end

function F:CreatePane(pane)
  paneFrame = pane
  pane.rows = {}

  local label = Kit.Text(pane, "GameFontNormal")
  label:SetPoint("TOPLEFT", 0, -8)
  label:SetText("Send to")

  -- The dropdown: a flat button showing the pick, the game's menu on click
  -- (the panel's own "select" fields look the same).
  local dd = Kit.Button(pane, "", 170)
  dd:SetPoint("TOPLEFT", 60, -2)
  local fs = dd:GetFontString()
  if fs then
    fs:ClearAllPoints()
    fs:SetPoint("LEFT", 8, 0)
    fs:SetPoint("RIGHT", -18, 0)
    fs:SetJustifyH("LEFT")
  end
  local arrow = Kit.Text(dd, "GameFontDisableSmall", "OVERLAY")
  arrow:SetPoint("RIGHT", -6, 0)
  arrow:SetText("v")
  ARLE.Skin:Dropdown(dd)
  self:Script(dd, "OnClick", function(btn)
    self:TargetMenu(btn, Store(self).target, function(name)
      Store(self).target = name
      ARLE:Changed()
    end)
  end)
  pane.dd = dd

  -- Someone the menu doesn't know: typed once, then in the menu too.
  local box = Kit.EditBox(pane, 120)
  box:SetPoint("LEFT", dd, "RIGHT", 10, 0)
  local placeholder = Kit.Text(box, "GameFontDisableSmall", "OVERLAY")
  placeholder:SetPoint("LEFT", 2, 0)
  placeholder:SetText("or type a name")
  local function Placeholder()
    placeholder:SetShown(not box:HasFocus() and (box:GetText() or "") == "")
  end
  self:Script(box, "OnEditFocusGained", Placeholder)
  self:Script(box, "OnEditFocusLost", Placeholder)
  self:Script(box, "OnTextChanged", Placeholder)
  self:Script(box, "OnEscapePressed", function()
    box:SetText("")
    box:ClearFocus()
  end)
  self:Script(box, "OnEnterPressed", function()
    local name, known = Resolve(box:GetText())
    box:SetText("")
    box:ClearFocus()
    if name == "" then
      return
    end
    if not known then
      self:Print("mail needs the full name, \"First Surname\": " .. name .. " may not arrive.")
    end
    local extra = { unpack(Store(self).extra or {}) }
    extra[#extra + 1] = name
    Store(self).extra = extra
    Store(self).target = name
    ARLE:Changed()
  end)
  Kit.Tip(box, "Another character", "Type \"First Surname\" and press Enter to send to someone not in the list.")

  -- The slot: click it (or drop on it) with an item on the cursor.
  local slot = CreateFrame("Button", nil, pane)
  slot:SetSize(37, 37)
  slot:SetPoint("TOPLEFT", 0, -34)
  slot:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  local bg = slot:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
  local plus = Kit.Text(slot, "GameFontNormalLarge", "ARTWORK")
  plus:SetPoint("CENTER")
  plus:SetText("+")
  local hl = slot:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.15)
  self:Script(slot, "OnClick", function()
    self:DropItem()
  end)
  self:Script(slot, "OnReceiveDrag", function()
    self:DropItem()
  end)
  Kit.Tip(slot, "Add an item", "Pick up an item in your bags, then click here: it's mailed to the character "
    .. "in \"Send to\". The item goes back to your bags.")

  pane.hint = Kit.Text(pane, "GameFontHighlightSmall")
  pane.hint:SetPoint("LEFT", slot, "RIGHT", 10, 0)
  pane.hint:SetPoint("RIGHT", pane, "RIGHT", -4, 0)
  pane.hint:SetJustifyH("LEFT")
  pane.hint:SetWordWrap(true)

  local head = Kit.Text(pane, "GameFontNormalSmall")
  head:SetPoint("TOPLEFT", 0, -82)
  head:SetText("Rules · the first one that matches an item decides")

  pane.scroll, pane.child = Kit.Scroll(pane)
  pane.scroll:SetPoint("TOPLEFT", 0, -98)
  pane.scroll:SetPoint("BOTTOMRIGHT", -24, 0)
  -- Laid out after this: the rows follow the scroll area's width.
  self:Script(pane.scroll, "OnSizeChanged", function(_, width)
    if width and width > 0 then
      pane.child:SetWidth(width)
    end
  end)
end

function F:RefreshPane(pane)
  local target = Store(self).target
  if target and target ~= "" then
    local c = KnownCharacters()[target:lower()]
    pane.dd:SetText(c and Colored(c) or target)
  else
    pane.dd:SetText("|cff888888Pick a character|r")
  end
  if not target or target == "" then
    pane.hint:SetText("Pick a character in \"Send to\" first.")
  elseif IsMe(target) then
    pane.hint:SetText("Pick up an item, click the slot: it goes to " .. target
      .. ". |cff888888(That's you: skipped on this character, sent from the others.)|r")
  else
    pane.hint:SetText("Pick up an item in your bags and click the slot: it goes to " .. target .. ".")
  end

  local width = pane.scroll:GetWidth()
  pane.child:SetWidth(width and width > 0 and width or 300)
  local rules = Get("rules") or {}
  for i, text in ipairs(rules) do
    local row = Row(pane, i)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    row:SetPoint("RIGHT", pane.child, "RIGHT")
    row.index = i
    local rule, why = ParseRule(text)
    row.itemID = rule and rule.id or nil
    row.icon:Show()
    row.to:Show()
    row.remove:Show()
    if not rule then
      row.icon.icon:SetTexture(QUESTION_ICON)
      row.text:SetText("|cffff6060" .. text .. "|r |cff888888(" .. why .. ")|r")
      row.toName = nil
      row.to:SetText("?")
    else
      row.icon.icon:SetTexture(rule.id and Items.GetIcon(rule.id) or QUESTION_ICON)
      if rule.id then
        row.text:SetText(Items.Link(rule.id))
      else
        row.text:SetText("|cffffffff" .. rule.label .. "|r |cff888888(" .. (rule.pattern and "any match" or "by name")
          .. ")|r")
      end
      row.toName = rule.to
      local c = KnownCharacters()[rule.to:lower()]
      local shown = c and Colored(c) or rule.to
      if IsMe(rule.to) then
        shown = "|cff888888" .. rule.to .. " (you)|r"
      elseif not rule.known then
        shown = "|cffffd100" .. rule.to .. "?|r"
      end
      row.to:SetText(shown)
    end
    row:Show()
  end
  local count = #rules
  if count == 0 then
    local row = Row(pane, 1)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 0, 0)
    row:SetPoint("RIGHT", pane.child, "RIGHT")
    row.itemID = nil
    row.icon:Hide()
    row.to:Hide()
    row.remove:Hide()
    row.text:SetText("|cff888888No rules yet. Wildcards by chat: /arl mail add * Cloth = Name|r")
    row:Show()
    count = 1
  end
  for i = count + 1, #pane.rows do
    pane.rows[i]:Hide()
  end
  pane.child:SetHeight(count * ROW_H)
end

-- Item names arrive after the first look: one redraw for a burst of them.
function F:OnItemInfo()
  if refreshQueued or not (paneFrame and paneFrame:IsVisible()) then
    return
  end
  refreshQueued = true
  self:After(0.3, function()
    refreshQueued = false
    ARLE:Changed()
  end)
end

function F:OnOptionChanged()
  if mailOpen and not run then
    BuildPlan()
  end
  Paint()
end

function F:GetStatus()
  local n = #(Get("rules") or {})
  if n == 0 then
    return "Active · no rules yet: pick a character and an item on the \"What goes where\" page"
  end
  if run then
    return "Active · mailing (" .. #run.sent .. " sent so far)"
  end
  local list = mailOpen and plan or {}
  if not mailOpen then
    local saved = plan
    list = BuildPlan()
    plan = saved
  end
  local stacks, people = PlanCounts(list)
  local mode = Get("auto") and "sends when you open a mailbox" or "press Send at a mailbox"
  if stacks == 0 then
    return "Active · " .. Lib.Plural(n, "rule") .. ", nothing in your bags to send · " .. mode
  end
  return string.format("Active · %s, %s for %s waiting · %s", Lib.Plural(n, "rule"),
    Lib.Plural(stacks, "stack"), Lib.Plural(people, "character"), mode)
end

function F:ReportDetails()
  local lines = { "Rules:" }
  for _, text in ipairs(Get("rules") or {}) do
    local rule, why = ParseRule(text)
    lines[#lines + 1] = "  " .. text .. (rule and (" -> " .. rule.to .. (rule.known and "" or " (no surname)"))
      or (" (bad: " .. why .. ")"))
  end
  lines[#lines + 1] = "Last run:"
  for _, line in ipairs(lastRun) do
    lines[#lines + 1] = "  " .. line
  end
  return lines
end

F.commands = {
  { name = "add", args = "<item> = <character>", help = "adds a rule (Shift-click an item into chat for its link)",
    run = function(self, _, raw)
      local rule, why = ParseRule(raw)
      if not rule then
        self:Print("usage: /arl mail add <item> = <character> (" .. why .. ")")
        return
      end
      -- A link is kept as its item ID, so the rule reads the same in any locale.
      local text = raw
      if rule.id then
        text = rule.id .. " = " .. rule.typed
      end
      local list = { unpack(Get("rules") or {}) }
      list[#list + 1] = text
      SetRules(list)
      self:Print("rule added: " .. self:FormatRule(text))
    end },
  { name = "remove", args = "<number>", help = "removes rule number <n> (see /arl mail list)", run = function(self, rest)
    local n = tonumber(rest)
    local list = {}
    for i, v in ipairs(Get("rules") or {}) do
      if i ~= n then
        list[#list + 1] = v
      end
    end
    if not n or #list == #(Get("rules") or {}) then
      self:Print("usage: /arl mail remove <number> (see /arl mail list)")
      return
    end
    SetRules(list)
    self:Print("rule " .. n .. " removed.")
  end },
  { name = "list", help = "your rules, and what in your bags would go to whom", run = function(self)
    self:Print("rules (the first that matches an item decides):")
    for i, text in ipairs(Get("rules") or {}) do
      print("   " .. i .. ". " .. self:FormatRule(text))
    end
    if #(Get("rules") or {}) == 0 then
      print("   (none)")
    end
    local saved = plan
    local list = BuildPlan()
    if not mailOpen then
      plan = saved
    end
    for _, entry in ipairs(list) do
      print("   -> " .. entry.to .. ": " .. Summary(entry))
    end
  end },
  { name = "send", help = "sends now (at an open mailbox)", run = function(self)
    if not mailOpen then
      self:Print("open a mailbox first.")
      return
    end
    self:Start("command")
  end },
  { name = "alts", help = "the characters' full names ARL knows (a rule may use just the first name)",
    run = function(self)
      self:Print("characters seen with ARL:")
      for name in pairs(Alts()) do
        print("   " .. name)
      end
    end },
}

ARLE:RegisterModule(F)
