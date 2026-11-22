-- Soulstone Reminder: for warlocks in dungeons and raids, a card that shows
-- who wears your soulstone, and when none is up, puts one on the healer with
-- one click.
--
-- The card can't be dismissed or snoozed (the user's choice, 2026-11-22): it
-- shows in an instance this is on for, combat included, except while the
-- stone is on cooldown with none of yours to be seen (spent, or unreadable).
-- The way out is the In dungeons / In raids switches.
--
-- Own code, no other addon needed. Out of combat, alive, in a party or raid
-- instance (each one an option), it reads the group's auras for a Soulstone
-- Resurrection you cast (sourceUnit "player"). When there's none, the stone's
-- shared item cooldown is over and one is in your bags, the card asks to put
-- it up; with no stone in your bags (and none in use), it asks to make one.
-- The cooldown is the main test: auras can come back secret in an instance,
-- and a stone used within the cooldown is still up or was spent.
--
-- The card's icon is the host's secure button "Soulstone" (a clickable macro,
-- also bound as a key). Its macro is armed out of combat, and again in
-- PreClick: /targetexact <name>, /use [help,nodead] item:<id>, then your
-- target is handed back, as Buff Back does it ([@unit] doesn't resolve on
-- Forever). Making a stone is /cast Create Soulstone (<rank>)(): the trailing
-- "()" keeps the client from reading "(Major)" as a rank. Who gets it: your
-- friendly target in the group (option), else the group's healer by assigned
-- role, else a healing class (priest, druid, shaman, paladin), else you.
-- The card holds a secure button, so it's shown, hidden, painted (its height
-- follows its lines) and moved only out of combat (ARLE.Secure:Run, one key,
-- the latest paint wins). In a fight it stays as it was, and nothing is read
-- (40 people's buffs on every aura change); it catches up as the fight ends.
local ADDON = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local Lib, Kit, Secure = ARLE.Lib, ARLE.UI.Kit, ARLE.Secure
local Items = Lib.Items

local KEY = "Soulstone" -- the host's secure button (Secure/Secure.lua)
local SHARD = 6265 -- Soul Shard
local PAINT = "SoulstoneReminder.card" -- Secure:Run key for every show / hide / paint
local FALLBACK_ICON = 134336 -- Major Soulstone's icon
local SCAN_AURAS = 40 -- buffs read per group member

-- Highest rank first: the Create Soulstone spell, the stone it makes and the
-- buff that stone gives (Soulstone Resurrection, one id per rank).
local STONES = {
  { spell = 20757, item = 16896, buff = 20765 }, -- Major (level 60)
  { spell = 20756, item = 16895, buff = 20764 }, -- Greater (50)
  { spell = 20755, item = 16893, buff = 20763 }, -- Soulstone (40)
  { spell = 20752, item = 16892, buff = 20762 }, -- Lesser (30)
  { spell = 693, item = 5232, buff = 20707 }, -- Minor (18)
}
local IS_BUFF = {}
for _, s in ipairs(STONES) do
  IS_BUFF[s.buff] = true
end

local HEALER_CLASSES = { "PRIEST", "DRUID", "SHAMAN", "PALADIN" }

local F = {
  id = "SoulstoneReminder",
  addon = ADDON,
  title = "Soulstone Reminder",
  group = "QualityOfLife",
  command = "soulstone",
  commandHelp = "warlocks: soulstone reminder in dungeons and raids",
  description = "For warlocks in dungeons and raids: a card showing who wears your soulstone. When none is up "
    .. "and it's off cooldown, one click puts it on the healer (or your target), or makes one first.",
  options = {
    { type = "info", text = function(def) return def:StatusLine() end },
    { key = "dungeons", type = "boolean", label = "In dungeons", default = true },
    { key = "raids", type = "boolean", label = "In raids", default = true },
    { key = "who", type = "select", label = "Put it on", default = "healer",
      values = {
        { value = "healer", label = "The healer (else me)" },
        { value = "self", label = "Me" },
      } },
    { key = "preferTarget", type = "boolean", label = "My friendly target in the group gets it instead",
      default = true, cmd = "target" },
    { key = "chat", type = "boolean", label = "Chat message", default = true },
    { type = "keybind", binding = Secure:Binding(KEY), label = "Soulstone key" },
    { type = "button", label = "Show a test alert", desc = "for 20 seconds, so you can move it", nocmd = true,
      run = function(def) def:Test() end },
    ARLE.Options.Preset.ResetPosition(),
  },
}

local alert, placeAlert
local lastChatKey  -- one chat line per reminder
local testUntil
local armedText
local lastPlan     -- the last plan, for the status line

-------------------------------------------------------------------------------
-- Reading the game
-------------------------------------------------------------------------------

local function IsWarlock()
  return select(2, UnitClass("player")) == "WARLOCK"
end

local function Known(spellID)
  return (Lib.Call(_G.IsPlayerSpell, spellID) or Lib.Call(_G.IsSpellKnown, spellID)) and true or false
end

-- "party" or "raid" while inside one, else nil.
local function InstanceKind()
  local inside, kind = Lib.Call(IsInInstance)
  if inside and (kind == "party" or kind == "raid") then
    return kind
  end
end

local function InstanceID()
  return select(8, Lib.Call(GetInstanceInfo)) or 0
end

local function Cooldown(itemID)
  local getCooldown = (C_Container and C_Container.GetItemCooldown) or _G.GetItemCooldown
  local start, duration, enable = Lib.Call(getCooldown, itemID)
  if enable == 0 or enable == false then
    return math.huge -- (counts down once the effect ends)
  end
  if type(start) ~= "number" or type(duration) ~= "number" or start <= 0 or duration <= 1.5 then
    return 0
  end
  return math.max(0, start + duration - GetTime())
end

local function OwnedStone()
  for _, s in ipairs(STONES) do
    if Items.Count(s.item) > 0 then
      return s
    end
  end
end

local function BestCreate()
  for _, s in ipairs(STONES) do
    if Known(s.spell) then
      return s
    end
  end
end

local function Alive(unit)
  return Lib.Call(UnitExists, unit) and not Lib.Call(UnitIsDeadOrGhost, unit)
    and Lib.Call(UnitIsConnected, unit) ~= false
end

-- Your soulstone on a group member: { name, remaining }, or nil. Also says
-- whether some buffs couldn't be read, and who wears another warlock's stone.
local function FindOurs()
  if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then
    return nil, true
  end
  local ssName = Lib.SpellName(STONES[#STONES].buff)
  local hidden, other = false, nil
  for _, m in ipairs(Lib.Members()) do
    for index = 1, SCAN_AURAS do
      local aura = Lib.Call(C_UnitAuras.GetAuraDataByIndex, m.unit, index, "HELPFUL")
      if not aura then
        break
      end
      if not Lib.Readable(aura) then
        hidden = true
      else
        local id, name = Lib.Plain(aura.spellId), Lib.Str(aura.name)
        if (id and IS_BUFF[id]) or (ssName and name == ssName) then
          local source = Lib.Plain(aura.sourceUnit)
          if source and Lib.Call(UnitIsUnit, source, "player") then
            local ends = Lib.Plain(aura.expirationTime)
            return { name = m.name, remaining = type(ends) == "number" and ends > 0 and ends - GetTime() or nil },
              hidden, other
          end
          other = other or m.name
        end
      end
    end
  end
  return nil, hidden, other
end

-- Your friendly, living target, when it's in your group (or you).
local function GroupTarget()
  if not (Lib.Call(UnitIsPlayer, "target") and Lib.Call(UnitCanAssist, "player", "target") and Alive("target")) then
    return nil
  end
  if Lib.Call(UnitIsUnit, "target", "player") or Lib.Call(UnitInParty, "target") or Lib.Call(UnitInRaid, "target") then
    return "target"
  end
end

-- Who gets the stone: { name, why }.
local function PickTarget()
  local me = { name = Lib.UnitFullName("player"), why = "you" }
  if F.db.who == "self" then
    return me
  end
  if F.db.preferTarget then
    local unit = GroupTarget()
    if unit then
      return { name = Lib.UnitFullName(unit), why = Lib.Call(UnitIsUnit, unit, "player") and "you" or "your target" }
    end
  end
  local members = Lib.Members()
  for _, m in ipairs(members) do
    if m.unit ~= "player" and Alive(m.unit) and Lib.Call(_G.UnitGroupRolesAssigned, m.unit) == "HEALER" then
      return { name = Lib.UnitFullName(m.unit) or m.name, why = "healer", class = m.class }
    end
  end
  for _, class in ipairs(HEALER_CLASSES) do
    for _, m in ipairs(members) do
      if m.unit ~= "player" and m.class == class and Alive(m.unit) then
        return { name = Lib.UnitFullName(m.unit) or m.name, why = "healing class", class = m.class }
      end
    end
  end
  return me
end

local function Minutes(seconds)
  return math.max(1, math.ceil(seconds / 60)) .. " min"
end

-------------------------------------------------------------------------------
-- The plan: what's due now, and the macro that does it
-------------------------------------------------------------------------------

local function UseMacro(stone, who)
  local lines = { "/targetexact " .. who.name, "/use [help,nodead] item:" .. stone.item }
  -- Your target back: only a friendly one (the one we just picked) is undone.
  if not Lib.Call(UnitExists, "target") then
    lines[#lines + 1] = "/targetlasttarget [help]"
    lines[#lines + 1] = "/cleartarget [help]"
  elseif Lib.UnitFullName("target") ~= who.name then
    lines[#lines + 1] = "/targetlasttarget [help]"
  end
  return table.concat(lines, "\n")
end

local GREEN, RED = { 0.3, 0.85, 0.35 }, { 0.95, 0.25, 0.2 }

-- The card for a state that needs nothing from you: shown, not due.
local function Quiet(state, why, message, sub, color, note)
  return { state = state, why = why, show = true, message = message, sub = sub, note = note, color = color,
    icon = Items.GetIcon and Items.GetIcon((OwnedStone() or BestCreate() or STONES[1]).item),
    tip = message .. (sub and (" " .. sub .. ".") or "") }
end

-- { state, why, show, key (when something is due), message, sub, note,
-- color, icon, macro, tip }. why is the status line's; show = the card is up.
local function Plan()
  if not IsWarlock() then
    return { state = "idle", why = "only for warlocks" }
  end
  local kind = InstanceKind()
  if not kind then
    return { state = "idle", why = "waiting for a dungeon or raid" }
  end
  if (kind == "party" and not F.db.dungeons) or (kind == "raid" and not F.db.raids) then
    return { state = "idle", why = "off in " .. (kind == "party" and "dungeons" or "raids") }
  end
  local ours, hidden, other = FindOurs()
  local note = other and (other .. " has another warlock's soulstone.") or nil
  if ours then
    local left = ours.remaining and (Minutes(ours.remaining) .. " left") or nil
    return Quiet("up", "your soulstone is on " .. ours.name .. (left and (" (" .. left .. ")") or ""),
      "Soulstone on " .. ours.name, left, GREEN, note)
  end
  local owned = OwnedStone()
  local stone = owned or BestCreate()
  if not stone then
    return { state = "idle", why = "you don't know Create Soulstone yet" }
  end
  local cooldown = Cooldown(stone.item)
  if cooldown > 0 then
    -- (no card while the stone is on cooldown with none of ours to be seen: user's choice 2026-11-22)
    local ready = cooldown == math.huge and "once it's spent or ends" or ("in " .. Minutes(cooldown))
    return { state = "cooldown", why = "soulstone on cooldown, ready again " .. ready
      .. (hidden and " (some buffs can't be read here)" or "") .. "; no card meanwhile" }
  end
  local here = kind .. ":" .. InstanceID()
  if owned then
    local who = PickTarget()
    if not who.name then
      return { state = "idle", why = "can't read who to put it on" }
    end
    local to = who.why == "you" and "yourself" or who.name
    return {
      state = "use", key = "use:" .. here, show = true, color = RED,
      message = "No soulstone up. Put one on " .. to .. ".",
      sub = who.why ~= "you" and ("→ " .. who.name .. " (" .. who.why .. ")") or "→ you",
      note = note,
      icon = Items.GetIcon and Items.GetIcon(owned.item),
      macro = UseMacro(owned, who),
      tip = "Click to put " .. Items.Name(owned.item) .. " on " .. to .. ".",
      why = "no soulstone up: put it on " .. to,
    }
  end
  local spellName = Lib.SpellName(stone.spell)
  local shards = Items.Count(SHARD)
  return {
    state = "make", key = (shards > 0 and "make:" or "noshard:") .. here, show = true, color = RED,
    message = shards > 0 and "No soulstone up, and none in your bags. Make one."
      or "No soulstone up, and no Soul Shard to make one.",
    sub = shards > 0 and (spellName or "Create Soulstone") or "Drain Soul a mob as it dies to get a shard.",
    note = note,
    icon = Items.GetIcon and Items.GetIcon(stone.item),
    macro = shards > 0 and spellName and ("/cast " .. spellName .. "()") or nil,
    tip = shards > 0 and ("Click to cast " .. (spellName or "Create Soulstone") .. ".") or "You need a Soul Shard.",
    why = shards > 0 and "no soulstone in your bags: make one" or "no soulstone and no Soul Shard",
  }
end

-- Puts the plan's macro on the host button (out of combat only).
function F:Arm(plan)
  local button = Secure:Button(KEY)
  if not button or InCombatLockdown() then
    return
  end
  plan = plan or Plan()
  local text = plan.macro
  if text ~= armedText then
    armedText = text
    button:SetAttribute("type", "macro")
    button:SetAttribute("macrotext", text)
    self:Debug("armed: %s", text and text:gsub("\n", " | ") or "nothing")
  end
end

-------------------------------------------------------------------------------
-- The card (a Kit.Card; its icon is the host's secure button)
-------------------------------------------------------------------------------

local function PlaceAlert()
  if placeAlert then
    placeAlert()
  end
end

-- Every show, hide and paint goes through one Secure:Run key: in a fight the
-- card (protected: it holds a secure button) stays as it was, and only the
-- latest change runs once the fight is over.
local function HideNow()
  if alert then
    alert:Hide()
  end
end

local function HideAlert()
  if alert and alert:IsShown() then
    Secure:Run(HideNow, PAINT)
  end
end

local tipText = "Click to put your soulstone up."

local function AttachButton()
  local C = Kit.CARD
  local b = Secure:Attach(KEY, alert, { "TOPLEFT", C.pad + C.edge, -C.pad }, C.icon)
  if not b then
    return
  end
  F:Script(b, "OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(F.title)
    GameTooltip:AddLine(tipText, 0.5, 0.84, 1, true)
    local bound = Secure:BoundKey(KEY)
    if bound then
      GameTooltip:AddLine("Key: " .. bound, 0.7, 0.7, 0.7)
    end
    GameTooltip:Show()
  end)
  F:Script(b, "OnLeave", GameTooltip_Hide)
end

-- No Dismiss or Snooze (the user's choice): the card is the instance's.
local function BuildAlert()
  local f = Kit.Card(F, { icon = true, move = { y = 160, secure = true } })
  placeAlert = f.place
  alert = f
end

local function Paint(plan)
  if not alert then
    BuildAlert()
  end
  AttachButton()
  tipText = plan.tip or ""
  alert.icon:SetTexture(plan.icon or FALLBACK_ICON)
  if plan.color then
    alert:SetAccent(plan.color[1], plan.color[2], plan.color[3])
  else
    alert:SetAccent()
  end
  alert:SetLines(plan.message, plan.sub, plan.note)
  alert:Show()
end

local function ShowAlert(plan)
  Secure:Run(function()
    Paint(plan)
  end, PAINT)
end

function F:OnResetPosition()
  PlaceAlert()
end

-------------------------------------------------------------------------------
-- Evaluation
-------------------------------------------------------------------------------

function F:Evaluate()
  if InCombatLockdown() or UnitAffectingCombat("player") then
    -- (no reading of 40 people's buffs in a fight; the card stays as it was,
    -- and PLAYER_REGEN_ENABLED brings it up to date)
    return
  end
  if testUntil then
    if GetTime() < testUntil then
      return
    end
    testUntil = nil
  end
  local plan = Plan()
  if lastPlan and lastPlan.state ~= plan.state then
    self:Debug("%s -> %s: %s", lastPlan.state, plan.state, plan.why)
  end
  lastPlan = plan
  self:Arm(plan)
  if not plan.key then
    lastChatKey = nil
  elseif self.db.chat and lastChatKey ~= plan.key and not UnitIsDeadOrGhost("player") then
    lastChatKey = plan.key
    local bound = plan.macro and Secure:BoundKey(KEY)
    self:Print(plan.message .. (bound and (" Press " .. bound .. ".") or (plan.macro and " Click the card's icon." or "")))
  end
  if plan.show then
    ShowAlert(plan)
  else
    HideAlert()
  end
end

function F:Test()
  if InCombatLockdown() then
    return
  end
  testUntil = GetTime() + 20
  armedText = nil
  local button = Secure:Button(KEY)
  if button then
    button:SetAttribute("macrotext", nil) -- (re-armed when the test ends)
  end
  ShowAlert({ message = "Test: drag this card to move it.", sub = "Back to normal in 20 seconds.",
    tip = "A test: clicking does nothing now." })
  self:After(20.2, self.Evaluate)
end

function F:StatusLine()
  local plan = InCombatLockdown() and lastPlan or Plan()
  return plan and plan.why or "waiting"
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

local function Schedule(self)
  self:Debounce("eval", 0.5, self.Evaluate)
end

local function SetupButton()
  local b = Secure:Button(KEY)
  if not b then
    F:Print("its button is missing: restart the game (a /reload isn't enough) after this update.")
    return
  end
  b:SetAttribute("type", "macro")
  b:SetAttribute("macrotext", nil)
  armedText = nil
  -- Re-armed at the last moment, so the stone goes to whoever is best now.
  F:Script(b, "PreClick", function()
    if F._active and not InCombatLockdown() then
      F:Arm()
    end
  end)
  F:Script(b, "PostClick", function()
    if F._active then
      F:Debounce("eval", 1, F.Evaluate)
    end
  end)
end

function F:OnEnable()
  lastChatKey, testUntil, lastPlan = nil, nil, nil
  Secure:Run(SetupButton, "SoulstoneReminder.button")
  for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "GROUP_ROSTER_UPDATE", "PLAYER_ROLES_ASSIGNED",
    "PLAYER_REGEN_ENABLED", "PLAYER_ALIVE", "PLAYER_UNGHOST", "BAG_UPDATE_DELAYED", "BAG_UPDATE_COOLDOWN",
    "PLAYER_TARGET_CHANGED", "SPELLS_CHANGED" }) do
    self:On(e, Schedule)
  end
  -- (no hiding as a fight starts or on death: the card stays up in the instance)
  -- A stone spent or ended on anybody in the group (only read in an instance).
  self:On("UNIT_AURA", function(s)
    if IsWarlock() and InstanceKind() and not InCombatLockdown() then
      s:Debounce("eval", 1, s.Evaluate)
    end
  end)
  -- Cooldown ends and buffs running out.
  self:Ticker(10, self.Evaluate)
  Schedule(self)
end

local function ReleaseButton()
  local b = Secure:Button(KEY)
  if not b or F._active then
    return
  end
  if alert then
    Secure:Detach(KEY, alert, { "macrotext" })
  end
  b:SetAttribute("macrotext", nil)
  F:Script(b, "PreClick", nil)
  F:Script(b, "PostClick", nil)
  b:Hide()
  armedText = nil
end

function F:OnDisable()
  lastChatKey, testUntil, lastPlan = nil, nil, nil
  HideAlert()
  -- (Secure:Run, not OutOfCombat: OutOfCombat drops work once the feature is off.)
  Secure:Run(ReleaseButton)
end

function F:OnOptionChanged()
  lastChatKey = nil
  self:Evaluate()
end

function F:GetStatus()
  return "Active · " .. self:StatusLine()
end

function F:ReportDetails()
  local plan = lastPlan or {}
  return {
    "state: " .. tostring(plan.state) .. " · " .. tostring(plan.why),
    "armed: " .. (armedText and armedText:gsub("\n", " | ") or "nothing"),
    "button: " .. (Secure:Button(KEY) and "made" or "missing (restart the game)")
      .. " · key: " .. (Secure:BoundKey(KEY) or "none"),
  }
end

F.commands = {
  { name = "test", help = "shows the card for 20 seconds so you can move it", run = function(self) self:Test() end },
  { name = "status", help = "whether your soulstone is up, and what's next", always = true,
    run = function(self) self:Print(self:StatusLine()) end },
}

ARLE:RegisterModule(F)
