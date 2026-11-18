-- LFG Role Filter: a side panel next to the Looking For Group window's Group
-- Browser that lists the same search results filtered by role, with Whisper
-- and Invite buttons, and auto-invite for tanks and healers.
-- Based on LFGRoleFilter by andreg1 (MIT),
-- https://github.com/andreg1/wow-forever-addons
--
--   a solo player is kept when they listed one of the checked roles;
--   a group is kept when it still misses one (5-player activities: 1 tank,
--   1 healer, 3 damage; larger ones: any role while the group isn't full).
-- No role checked = no filter.
--
-- Taint: when addon code calls into the LFG window (opening it, picking an
-- activity, touching its list), the window gets tainted and searches hang or
-- return secret values until /reload. So this never calls the window's
-- methods, never hooks its scripts and never anchors to its frames. It only
-- listens for LFG_LIST_SEARCH_RESULTS_RECEIVED / _RESULT_UPDATED (after
-- Blizzard's own search), reads C_LFGList getters (pcall'd, secret values
-- dropped), reads LFGBrowseFrame:IsVisible() and LFGParentFrame's screen rect,
-- and places its own UIParent-child panel by coordinates. The theme is applied
-- to our panel only. The panel hides when combat starts.
local ADDON = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local Skin, Kit, Lib = ARLE.Skin, ARLE.UI.Kit, ARLE.Lib

local ROW_H = 36
local PANEL_W = 270
local ROLES = { "tank", "healer", "dps" }
local ROLE_LABEL = { tank = "Tank", healer = "Healer", dps = "DPS" }
local ROLE_TOKEN = { tank = "TANK", healer = "HEALER", dps = "DAMAGER" }
local ROLE_KEY = { tank = "roleTank", healer = "roleHealer", dps = "roleDps" }
local INVITE_WAIT = 60 -- seconds before a pending invite counts as declined

local F = {
  id = "LFGRoleFilter",
  addon = ADDON,
  title = "LFG Role Filter",
  group = "QualityOfLife",
  command = "lfg",
  commandHelp = "filters the Looking For Group browser by role",
  description = "Filters the Group Browser by role, with whisper, invite and auto-invite.",
  options = {
    { type = "header", label = "Show" },
    { key = "roleTank", type = "boolean", label = "Tanks (and groups that need one)", default = false, cmd = "tank" },
    { key = "roleHealer", type = "boolean", label = "Healers (and groups that need one)", default = false,
      cmd = "healer" },
    { key = "roleDps", type = "boolean", label = "Damage (and groups that need it)", default = false, cmd = "dps" },
    { key = "showPlayers", type = "boolean", label = "Solo players", default = true, cmd = "players" },
    { key = "showGroups", type = "boolean", label = "Groups", default = true, cmd = "groups" },
  },
}

local panel, rows, content, scroll, countText, statusText
local roleButtons = {}
local results = {} -- built entries, all of them
local shown = {}   -- entries that pass the filter
local anySecret = false

-- Auto-invite (session only, so it never starts on its own after a relog).
local auto = { tank = false, healer = false }
local invited = {} -- name -> time we invited them (never invited twice per session)
local pending = {} -- role -> { name, t }: our invite still waiting for an answer
local noListingWarned = false

local function Say(msg)
  F:Print(msg)
end

-------------------------------------------------------------------------------
-- Safe reads
-------------------------------------------------------------------------------

-- A value, or nil when it's secret (and remember we saw one).
local function P(v)
  if Lib.IsSecret(v) then
    anySecret = true
    return nil
  end
  return v
end

local function Call(fn, ...)
  if type(fn) ~= "function" then
    return nil
  end
  local ok, a, b = pcall(fn, ...)
  if not ok then
    return nil
  end
  -- (a hidden table says "table" to type() but throws when read)
  return P(a), P(b)
end

local function LFG(name)
  return C_LFGList and C_LFGList[name]
end

local function ResultIDs()
  local a, b = Call(LFG("GetFilteredSearchResults"))
  if type(a) ~= "table" and type(b) ~= "table" then
    a, b = Call(LFG("GetSearchResults"))
  end
  if type(a) == "table" then
    return a
  end
  if type(b) == "table" then
    return b
  end
  return {}
end

-- Roles from a player-info table, whatever this client calls the fields.
local function RolesFrom(info, out)
  out = out or {}
  if type(info) ~= "table" then
    return out
  end
  local r = P(info.lfgRoles) or P(info.roles)
  if type(r) == "table" then
    if P(r.tank) or P(r.TANK) then
      out.tank = true
    end
    if P(r.healer) or P(r.HEALER) then
      out.healer = true
    end
    if P(r.dps) or P(r.damage) or P(r.DAMAGER) then
      out.dps = true
    end
  end
  if P(info.isTank) then
    out.tank = true
  end
  if P(info.isHealer) then
    out.healer = true
  end
  if P(info.isDamage) or P(info.isDPS) then
    out.dps = true
  end
  local a = P(info.assignedRole) or P(info.role)
  if a == "TANK" then
    out.tank = true
  elseif a == "HEALER" then
    out.healer = true
  elseif a == "DAMAGER" then
    out.dps = true
  end
  return out
end

-- Info for member 1..n as a table (PlayerInfo / LeaderInfo / MemberInfo).
local function MemberInfo(id, i)
  local t = Call(LFG("GetSearchResultPlayerInfo"), id, i)
  if type(t) == "table" then
    return t
  end
  if i == 1 then
    t = Call(LFG("GetSearchResultLeaderInfo"), id)
    if type(t) == "table" then
      return t
    end
  end
  local fn = LFG("GetSearchResultMemberInfo")
  if type(fn) == "function" then
    local ok, role, class, classLoc, level, area = pcall(fn, id, i)
    if ok and (role or class) then
      if type(role) == "table" then
        return role
      end
      return { assignedRole = role, classFilename = class, className = classLoc, level = level, areaName = area }
    end
  end
  return nil
end

local function ActivityInfo(aid)
  if not aid then
    return nil
  end
  local t = Call(LFG("GetActivityInfoTable"), aid)
  return type(t) == "table" and t or nil
end

-------------------------------------------------------------------------------
-- Building entries
-------------------------------------------------------------------------------

local function BuildEntry(id)
  local info = Call(LFG("GetSearchResultInfo"), id)
  if type(info) ~= "table" then
    return nil
  end
  if P(info.isDelisted) then
    return nil
  end
  local e = { id = id }
  e.leader = P(info.leaderName)
  e.members = P(info.numMembers) or 1
  e.comment = P(info.comment)
  e.title = P(info.name)
  local aids = P(info.activityIDs)
  local aid = (type(aids) == "table" and P(aids[1])) or P(info.activityID)
  e.activityIDs = {}
  if type(aids) == "table" then
    for _, a in ipairs(aids) do
      a = P(a)
      if a then
        e.activityIDs[#e.activityIDs + 1] = a
      end
    end
  elseif aid then
    e.activityIDs[1] = aid
  end
  local act = ActivityInfo(aid)
  e.activity = act and (P(act.fullName) or P(act.shortName))
  e.maxPlayers = act and P(act.maxNumPlayers)
  if type(aids) == "table" and #aids > 1 then
    e.activity = (e.activity or "?") .. " (+" .. (#aids - 1) .. ")"
  end

  local lead = MemberInfo(id, 1)
  if lead then
    e.leader = e.leader or P(lead.name)
    e.class = P(lead.classFilename)
    e.className = P(lead.className)
    e.level = P(lead.level)
    e.area = P(lead.areaName)
  end

  if e.members <= 1 then
    e.solo = true
    e.roles = RolesFrom(lead)
  else
    -- Filled roles: member counts, else each member's assigned/only role.
    local filled = { tank = 0, healer = 0, dps = 0 }
    local counts = Call(LFG("GetSearchResultMemberCounts"), id)
    local counted = false
    if type(counts) == "table" then
      filled.tank = P(counts.TANK) or 0
      filled.healer = P(counts.HEALER) or 0
      filled.dps = P(counts.DAMAGER) or 0
      counted = (filled.tank + filled.healer + filled.dps) > 0
    end
    if not counted then
      filled = { tank = 0, healer = 0, dps = 0 }
      for i = 1, e.members do
        local r = RolesFrom(MemberInfo(id, i))
        local n = (r.tank and 1 or 0) + (r.healer and 1 or 0) + (r.dps and 1 or 0)
        if n == 1 then
          if r.tank then
            filled.tank = filled.tank + 1
          elseif r.healer then
            filled.healer = filled.healer + 1
          else
            filled.dps = filled.dps + 1
          end
        else
          filled.dps = filled.dps + 1 -- unknown / flexible counts as damage
        end
      end
    else
      -- Members with no role (NOROLE) count as damage.
      local assigned = filled.tank + filled.healer + filled.dps
      if e.members > assigned then
        filled.dps = filled.dps + (e.members - assigned)
      end
    end
    e.filled = filled
    -- (an activity can report 0 or nothing: a 5-player group then)
    local max = type(e.maxPlayers) == "number" and e.maxPlayers > 0 and e.maxPlayers or 5
    e.maxPlayers = max
    local need = {}
    if e.members < max then
      if max <= 5 then
        need.tank = filled.tank < 1
        need.healer = filled.healer < 1
        need.dps = filled.dps < (max - 2)
      else
        need.tank, need.healer, need.dps = true, true, true
      end
    end
    e.roles = need
  end
  return e
end

local function RoleOn(role)
  return F.db[ROLE_KEY[role]] == true
end

local function AnyRoleChecked()
  return RoleOn("tank") or RoleOn("healer") or RoleOn("dps")
end

local function Passes(e)
  if e.solo and F.db.showPlayers == false then
    return false
  end
  if not e.solo and F.db.showGroups == false then
    return false
  end
  if not AnyRoleChecked() then
    return true
  end
  for _, r in ipairs(ROLES) do
    if RoleOn(r) and e.roles[r] then
      return true
    end
  end
  return false
end

-------------------------------------------------------------------------------
-- Panel (our own frame, themed)
-------------------------------------------------------------------------------

local function ClassColor(class)
  local c = class and ((C_ClassColor and C_ClassColor.GetClassColor and C_ClassColor.GetClassColor(class))
    or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]))
  if c then
    return c.r, c.g, c.b
  end
  return 1, 0.82, 0
end

local function SetRoleIcon(tex, role)
  tex:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-ROLES")
  local token = ROLE_TOKEN[role]
  if GetTexCoordsForRole then
    local ok, l, r, t, b = pcall(GetTexCoordsForRole, token)
    if ok and l then
      tex:SetTexCoord(l, r, t, b)
      return
    end
  end
  if role == "tank" then
    tex:SetTexCoord(0, 0.2617, 0.2617, 0.5234)
  elseif role == "healer" then
    tex:SetTexCoord(0.2617, 0.5234, 0, 0.2617)
  else
    tex:SetTexCoord(0.2617, 0.5234, 0.2617, 0.5234)
  end
end

local function Whisper(name)
  if not name then
    return
  end
  if ChatFrame_SendTell then
    ChatFrame_SendTell(name)
    return
  end
  if ChatFrameUtil and ChatFrameUtil.SendTell then
    ChatFrameUtil.SendTell(name)
    return
  end
  if ChatFrame_OpenChat then
    ChatFrame_OpenChat("/w " .. name .. " ")
  end
end

local function Invite(name)
  if not name then
    return
  end
  if C_PartyInfo and C_PartyInfo.InviteUnit then
    C_PartyInfo.InviteUnit(name)
  elseif InviteUnit then
    InviteUnit(name)
  end
end

local function RowTooltip(row)
  local e = row.entry
  if not e then
    return
  end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:AddLine(e.leader or "?", ClassColor(e.class))
  local line = {}
  if e.level then
    line[#line + 1] = "Level " .. e.level
  end
  if e.className then
    line[#line + 1] = e.className
  end
  if #line > 0 then
    GameTooltip:AddLine(table.concat(line, " "), 1, 1, 1)
  end
  if e.area then
    GameTooltip:AddLine(e.area, 0.7, 0.7, 0.7)
  end
  if e.activity then
    GameTooltip:AddLine(e.activity, 1, 0.82, 0)
  end
  local r = {}
  for _, k in ipairs(ROLES) do
    if e.roles[k] then
      r[#r + 1] = ROLE_LABEL[k]
    end
  end
  if e.solo then
    GameTooltip:AddLine("Listed as: " .. (#r > 0 and table.concat(r, ", ") or "unknown"), 0.6, 0.9, 1)
  else
    local f = e.filled
    GameTooltip:AddLine(("Group %d/%d  (T %d, H %d, D %d)"):format(e.members, e.maxPlayers, f.tank, f.healer, f.dps),
      0.6, 0.9, 1)
    GameTooltip:AddLine("Needs: " .. (#r > 0 and table.concat(r, ", ") or "nothing (full)"), 0.6, 0.9, 1)
  end
  if e.title and e.title ~= "" then
    GameTooltip:AddLine(e.title, 1, 1, 1, true)
  end
  if e.comment and e.comment ~= "" then
    GameTooltip:AddLine(e.comment, 0.9, 0.9, 0.9, true)
  end
  GameTooltip:Show()
end

local function CreateRow(i)
  local row = CreateFrame("Frame", nil, content)
  row:SetSize(PANEL_W - 30, ROW_H)
  row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
  row:EnableMouse(true)
  F:Script(row, "OnEnter", RowTooltip)
  F:Script(row, "OnLeave", GameTooltip_Hide)
  row.bg = row:CreateTexture(nil, "BACKGROUND")
  row.bg:SetAllPoints()
  row.bg:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.04 or 0.0)
  row.name = Kit.Text(row, "GameFontNormal")
  row.name:SetPoint("TOPLEFT", 4, -3)
  row.name:SetWidth(120)
  row.name:SetWordWrap(false)
  row.sub = Kit.Text(row, "GameFontHighlightSmall")
  row.sub:SetPoint("BOTTOMLEFT", 4, 4)
  row.sub:SetWidth(150)
  row.sub:SetWordWrap(false)
  row.icons = {}
  for k = 1, 3 do
    local t = row:CreateTexture(nil, "ARTWORK")
    t:SetSize(16, 16)
    t:SetPoint("TOPLEFT", 126 + (k - 1) * 17, -2)
    row.icons[k] = t
  end
  row.whisper = Kit.SmallButton(row, "W", 22)
  row.whisper:SetPoint("RIGHT", -2, 0)
  F:Script(row.whisper, "OnClick", function()
    Whisper(row.entry and row.entry.leader)
  end)
  Kit.Tip(row.whisper, "Whisper")
  row.invite = Kit.SmallButton(row, "+", 22)
  row.invite:SetPoint("RIGHT", row.whisper, "LEFT", -2, 0)
  F:Script(row.invite, "OnClick", function()
    Invite(row.entry and row.entry.leader)
  end)
  Kit.Tip(row.invite, "Invite to group")
  return row
end

local function FillRow(row, e)
  row.entry = e
  row.name:SetText(e.leader or "...")
  row.name:SetTextColor(ClassColor(e.class))
  local sub
  if e.solo then
    sub = (e.level and ("Lv " .. e.level) or "") .. (e.activity and ("  " .. e.activity) or "")
  else
    sub = ("%d/%d  "):format(e.members, e.maxPlayers) .. (e.activity or "")
  end
  row.sub:SetText(sub)
  local k = 0
  for _, r in ipairs(ROLES) do
    if e.roles[r] then
      k = k + 1
      SetRoleIcon(row.icons[k], r)
      row.icons[k]:Show()
    end
  end
  for j = k + 1, 3 do
    row.icons[j]:Hide()
  end
  -- Groups show needed roles dimmed a little, so they read as "wanted".
  for j = 1, k do
    row.icons[j]:SetAlpha(e.solo and 1 or 0.75)
  end
  row.invite:SetShown(e.solo and true or false)
  row:Show()
end

local function Redraw()
  if not panel then
    return
  end
  wipe(shown)
  for _, e in ipairs(results) do
    if Passes(e) then
      shown[#shown + 1] = e
    end
  end
  rows = rows or {}
  for i, e in ipairs(shown) do
    rows[i] = rows[i] or CreateRow(i)
    FillRow(rows[i], e)
  end
  for i = #shown + 1, #rows do
    rows[i]:Hide()
    rows[i].entry = nil
  end
  content:SetHeight(math.max(1, #shown * ROW_H))
  countText:SetText(("%d of %d"):format(#shown, #results))
  if anySecret then
    statusText:SetText("Some results are hidden here (secret values).")
  elseif #results == 0 then
    statusText:SetText("Search in the Group Browser to see results.")
  elseif #shown == 0 then
    statusText:SetText("No one matches the ticked roles.")
  else
    statusText:SetText("")
  end
  local ar, ag, ab = Skin:Accent()
  for _, r in ipairs(ROLES) do
    local b = roleButtons[r]
    if b then
      b.icon:SetDesaturated(not RoleOn(r))
      b.icon:SetAlpha(RoleOn(r) and 1 or 0.45)
      b.mark:SetColorTexture(ar, ag, ab, 1)
      b.mark:SetShown(RoleOn(r))
    end
  end
  if panel.playersCB then
    panel.playersCB:SetChecked(F.db.showPlayers ~= false)
    panel.groupsCB:SetChecked(F.db.showGroups ~= false)
    panel.autoCB.tank:SetChecked(auto.tank)
    panel.autoCB.healer:SetChecked(auto.healer)
  end
end

-------------------------------------------------------------------------------
-- Auto-invite: solo tanks / healers listed for the same activity as your own
-- listing, one per role at a time, while you lead and have room. Runs when
-- search results arrive (the search itself stays manual).
-------------------------------------------------------------------------------

local function Short(name)
  return (Ambiguate and Ambiguate(name, "none")) or name
end

local function InGroupWith(name)
  local n = Short(name)
  if n == UnitName("player") then
    return true
  end
  local ok, r = pcall(UnitInParty, n)
  if ok and r then
    return true
  end
  ok, r = pcall(UnitInRaid, n)
  return ok and r and true or false
end

-- True when someone in the group has this role assigned (if the client tracks it).
local function GroupHasRole(token)
  if not UnitGroupRolesAssigned then
    return false
  end
  local units = { "player" }
  for i = 1, 4 do
    units[#units + 1] = "party" .. i
  end
  for _, u in ipairs(units) do
    if UnitExists(u) then
      local ok, r = pcall(UnitGroupRolesAssigned, u)
      if ok and P(r) == token then
        return true
      end
    end
  end
  return false
end

-- Your own listing's activities as a set, plus the first one.
local function MyListing()
  local has = LFG("HasActiveEntryInfo")
  if has and not Call(has) then
    return nil
  end
  local info = Call(LFG("GetActiveEntryInfo"))
  if type(info) ~= "table" then
    return nil
  end
  local set, first = {}, nil
  local aids = P(info.activityIDs)
  if type(aids) == "table" then
    for _, a in ipairs(aids) do
      a = P(a)
      if a then
        set[a] = true
        first = first or a
      end
    end
  end
  local a = P(info.activityID)
  if a then
    set[a] = true
    first = first or a
  end
  if not first then
    return nil
  end
  return set, first
end

local function RoleFilled(role, who)
  auto[role] = false
  pending[role] = nil
  Say(("%s joined as %s. Auto-invite %s is now off."):format(who or "Someone", ROLE_LABEL[role],
    ROLE_LABEL[role]:lower()))
  Redraw()
end

local function CheckJoined()
  for role, p in pairs(pending) do
    if InGroupWith(p.name) then
      RoleFilled(role, Short(p.name))
    end
  end
end

local function AutoInvite()
  if not (auto.tank or auto.healer) then
    return
  end
  if IsInGroup() and not UnitIsGroupLeader("player") then
    return
  end
  local set, first = MyListing()
  if not set then
    if not noListingWarned then
      noListingWarned = true
      Say("auto-invite is waiting: list your group in the Looking For Group window first.")
    end
    return
  end
  noListingWarned = false
  CheckJoined()
  local now = GetTime()
  local act = ActivityInfo(first)
  local max = act and P(act.maxNumPlayers)
  max = type(max) == "number" and max > 0 and max or 5
  local members = math.max(1, GetNumGroupMembers() or 0)
  local waiting = 0
  for role, p in pairs(pending) do
    if now - p.t > INVITE_WAIT then
      -- Unanswered: the invite is taken back before the next one goes out,
      -- so a late accept can't bring a second tank or healer.
      pending[role] = nil
      if UninviteUnit then
        pcall(UninviteUnit, p.name)
      end
      Say(("no answer from %s: invite withdrawn."):format(Short(p.name)))
    else
      waiting = waiting + 1
    end
  end
  for _, role in ipairs({ "tank", "healer" }) do
    if auto[role] and not pending[role] and members + waiting < max then
      if GroupHasRole(ROLE_TOKEN[role]) then
        RoleFilled(role, "A group member")
      else
        for _, e in ipairs(results) do
          if e.solo and e.roles[role] and e.leader and not invited[e.leader] and not InGroupWith(e.leader) then
            local match = false
            for _, a in ipairs(e.activityIDs) do
              if set[a] then
                match = true
                break
              end
            end
            if match then
              invited[e.leader] = now
              pending[role] = { name = e.leader, t = now }
              waiting = waiting + 1
              Invite(e.leader)
              Say(("auto-invited %s (%s%s)."):format(Short(e.leader), ROLE_LABEL[role],
                e.level and (", level " .. e.level) or ""))
              break
            end
          end
        end
      end
    end
  end
end

local function Rebuild()
  anySecret = false
  wipe(results)
  for _, id in ipairs(ResultIDs()) do
    id = P(id)
    if id then
      local e = BuildEntry(id)
      if e then
        results[#results + 1] = e
      end
    end
  end
  -- Solo players first, then groups; each by name.
  table.sort(results, function(a, b)
    if a.solo ~= b.solo then
      return a.solo and true or false
    end
    return (a.leader or "~") < (b.leader or "~")
  end)
  Redraw()
  AutoInvite()
end

function F:SetAuto(role, on)
  auto[role] = on and true or false
  if auto[role] then
    noListingWarned = false
    Say(("auto-invite %s on: solo %ss listed for your activity are invited when search results come in. Refresh "
      .. "the search yourself."):format(ROLE_LABEL[role]:lower(), ROLE_LABEL[role]:lower()))
    AutoInvite()
  else
    pending[role] = nil
    Say("auto-invite " .. ROLE_LABEL[role]:lower() .. " off.")
  end
  Redraw()
end

local function CreatePanel()
  panel = Skin:CreateTooltipWindow(nil, UIParent)
  panel:SetSize(PANEL_W, 420)
  panel:SetFrameStrata("HIGH")
  panel:SetClampedToScreen(true)
  panel:Hide()

  local title = Kit.Text(panel, "GameFontNormal")
  title:SetPoint("TOPLEFT", 10, -10)
  title:SetText("Filter by role")
  title:SetTextColor(Skin:Accent())
  countText = Kit.Text(panel, "GameFontHighlightSmall")
  countText:SetPoint("TOPRIGHT", -10, -12)

  for i, r in ipairs(ROLES) do
    local b = CreateFrame("Button", nil, panel)
    b:SetSize(30, 30)
    b:SetPoint("TOPLEFT", 10 + (i - 1) * 36, -28)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    SetRoleIcon(b.icon, r)
    b.mark = b:CreateTexture(nil, "OVERLAY") -- an accent bar under a ticked role
    b.mark:SetHeight(2)
    b.mark:SetPoint("TOPLEFT", b, "BOTTOMLEFT", 0, -2)
    b.mark:SetPoint("TOPRIGHT", b, "BOTTOMRIGHT", 0, -2)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.12)
    F:Script(b, "OnClick", function()
      ARLE:SetOption(F.id, ROLE_KEY[r], not RoleOn(r))
    end)
    Kit.Tip(b, ROLE_LABEL[r], "Players listed as " .. ROLE_LABEL[r] .. ", and groups that still need one.")
    roleButtons[r] = b
  end

  local function Check(label, x, y, onClick, tip)
    local cb = Kit.Check(panel)
    cb:SetPoint("TOPLEFT", x, y)
    local fs = Kit.Text(panel, "GameFontHighlightSmall")
    fs:SetPoint("LEFT", cb, "RIGHT", 2, 1)
    fs:SetText(label)
    F:Script(cb, "OnClick", function(self)
      onClick(self:GetChecked() and true or false)
    end)
    if tip then
      Kit.Tip(cb, label, tip)
    end
    return cb
  end
  panel.playersCB = Check("Players", 122, -30, function(v)
    ARLE:SetOption(F.id, "showPlayers", v)
  end)
  panel.groupsCB = Check("Groups", 190, -30, function(v)
    ARLE:SetOption(F.id, "showGroups", v)
  end)
  local AUTO_TIP = "When search results come in, invite one solo %s listed for the same dungeon as your group's "
    .. "listing (you must lead and have room). One invite at a time; nobody is invited twice. Turns itself off when a "
    .. "%s joins. Refresh the search yourself. Off again after a relog."
  panel.autoCB = {
    tank = Check("Auto-invite tank", 6, -60, function(v)
      F:SetAuto("tank", v)
    end, AUTO_TIP:format("tank", "tank")),
    healer = Check("Auto-invite healer", 136, -60, function(v)
      F:SetAuto("healer", v)
    end, AUTO_TIP:format("healer", "healer")),
  }

  statusText = Kit.Text(panel, "GameFontDisableSmall")
  statusText:SetPoint("TOPLEFT", 10, -86)
  statusText:SetPoint("TOPRIGHT", -10, -86)

  scroll = CreateFrame("ScrollFrame", nil, panel)
  scroll:SetPoint("TOPLEFT", 8, -102)
  scroll:SetPoint("BOTTOMRIGHT", -8, 8)
  scroll:EnableMouseWheel(true)
  content = CreateFrame("Frame", nil, scroll)
  content:SetSize(PANEL_W - 16, 1)
  scroll:SetScrollChild(content)
  F:Script(scroll, "OnMouseWheel", function(self, delta)
    local max = math.max(0, content:GetHeight() - self:GetHeight())
    local v = math.min(max, math.max(0, self:GetVerticalScroll() - delta * ROW_H * 2))
    self:SetVerticalScroll(v)
  end)
end

-------------------------------------------------------------------------------
-- Watcher: follows the Group Browser by reading its state, never hooking it
-------------------------------------------------------------------------------

local function Place()
  local parent = _G.LFGParentFrame
  local r, t = parent and parent:GetRight(), parent and parent:GetTop()
  if not (r and t) then
    return false
  end
  -- The side tabs stick out past the window's right edge: start after the
  -- rightmost one (read only).
  local tabsFound = false
  for _, key in ipairs({ "ListingTab", "BrowsingTab", "WhoListingTab" }) do
    local tab = parent[key]
    local tr = tab and tab.IsShown and tab:IsShown() and tab:GetRight()
    if tr then
      tabsFound = true
      if tr > r then
        r = tr
      end
    end
  end
  if not tabsFound then
    r = r + 34
  end
  local scale = parent:GetEffectiveScale() / UIParent:GetEffectiveScale()
  local h = (parent:GetHeight() or 420) * scale
  panel:ClearAllPoints()
  panel:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", r * scale + 4, t * scale)
  panel:SetHeight(math.max(240, h))
  return true
end

local function Watch()
  local browse = _G.LFGBrowseFrame
  local want = browse and browse:IsVisible() and not InCombatLockdown()
  if want then
    if not panel then
      CreatePanel()
    end
    if Place() and not panel:IsShown() then
      panel:Show()
      Rebuild()
    end
  elseif panel and panel:IsShown() then
    panel:Hide()
  end
end

-------------------------------------------------------------------------------
-- Probe: dumps the raw result shape so field names can be checked
-------------------------------------------------------------------------------

local function Dump(label, t, depth)
  depth = depth or 0
  if type(t) ~= "table" then
    print("   " .. label .. " = " .. (Lib.IsSecret(t) and "<secret>" or tostring(t)))
    return
  end
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, k in ipairs(keys) do
    local v = t[k]
    if type(v) == "table" and depth < 1 then
      Dump(label .. "." .. tostring(k), v, depth + 1)
    else
      print("   " .. label .. "." .. tostring(k) .. " = " .. (Lib.IsSecret(v) and "<secret>" or tostring(v)))
    end
  end
end

local function Probe()
  local ids = ResultIDs()
  Say(("%d result(s). APIs: PlayerInfo=%s LeaderInfo=%s MemberInfo=%s MemberCounts=%s Filtered=%s"):format(#ids,
    tostring(LFG("GetSearchResultPlayerInfo") ~= nil), tostring(LFG("GetSearchResultLeaderInfo") ~= nil),
    tostring(LFG("GetSearchResultMemberInfo") ~= nil), tostring(LFG("GetSearchResultMemberCounts") ~= nil),
    tostring(LFG("GetFilteredSearchResults") ~= nil)))
  local soloDone, groupDone = false, false
  for _, id in ipairs(ids) do
    local info = Call(LFG("GetSearchResultInfo"), id)
    local n = type(info) == "table" and P(info.numMembers) or 0
    local solo = (n or 0) <= 1
    if (solo and not soloDone) or (not solo and not groupDone) then
      print(("   --- %s, result %s ---"):format(solo and "solo" or "group", tostring(id)))
      Dump("info", info)
      Dump("player1", MemberInfo(id, 1))
      if not solo then
        Dump("counts", Call(LFG("GetSearchResultMemberCounts"), id))
      end
      if solo then
        soloDone = true
      else
        groupDone = true
      end
    end
    if soloDone and groupDone then
      break
    end
  end
  local _, first = MyListing()
  Say("your listing: " .. (first and ("activity " .. tostring(first)) or "none found"))
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function F:OnEnable()
  self:On("PLAYER_REGEN_DISABLED", function()
    if panel then
      -- Hide the tooltip only when one of our rows/buttons owns it.
      local o = GameTooltip:GetOwner()
      while o do
        if o == panel then
          GameTooltip:Hide()
          break
        end
        o = o.GetParent and o:GetParent()
      end
      panel:Hide()
    end
  end)
  self:On("GROUP_ROSTER_UPDATE", CheckJoined)
  pcall(self.On, self, "LFG_LIST_SEARCH_FAILED", function()
    wipe(results)
    Redraw()
  end)
  local function Results()
    -- Rebuilt even with the panel hidden: auto-invite needs fresh results.
    if (panel and panel:IsShown()) or auto.tank or auto.healer then
      self:Debounce("rebuild", 0.1, Rebuild)
    end
  end
  pcall(self.On, self, "LFG_LIST_SEARCH_RESULTS_RECEIVED", Results)
  pcall(self.On, self, "LFG_LIST_SEARCH_RESULT_UPDATED", Results)
  self:Ticker(0.25, Watch)
end

function F:OnDisable()
  auto.tank, auto.healer = false, false
  wipe(pending)
  if panel then
    panel:Hide()
  end
end

function F:OnOptionChanged()
  Redraw()
end

-- LFGRoleFilterDB (per character): roles = { tank, healer, dps },
-- showPlayers, showGroups. Auto-invite is session-only (nothing saved), and
-- its "enabled" is left out: turning this feature on is the player's choice.
function F:Import()
  local old = _G.LFGRoleFilterDB
  if type(old) ~= "table" then
    return
  end
  if type(old.roles) == "table" then
    for _, r in ipairs(ROLES) do
      if type(old.roles[r]) == "boolean" then
        self.db[ROLE_KEY[r]] = old.roles[r]
      end
    end
  end
  if type(old.showPlayers) == "boolean" then
    self.db.showPlayers = old.showPlayers
  end
  if type(old.showGroups) == "boolean" then
    self.db.showGroups = old.showGroups
  end
end

function F:GetStatus()
  local r = {}
  for _, k in ipairs(ROLES) do
    if RoleOn(k) then
      r[#r + 1] = ROLE_LABEL[k]
    end
  end
  return "Active · roles: " .. (#r > 0 and table.concat(r, ", ") or "any")
    .. ((auto.tank or auto.healer) and " · auto-invite on" or "")
end

F.commands = {
  { name = "clear", help = "unticks every role", run = function(self)
    for _, r in ipairs(ROLES) do
      ARLE:SetOption(self.id, ROLE_KEY[r], false)
    end
    self:Print("all roles unticked: everyone is shown.")
  end },
  { name = "auto", args = "tank|healer [on|off]", help = "auto-invites that role (this session)",
    run = function(self, rest)
      local role, onoff = rest:match("^(%S+)%s*(%S*)$")
      if role ~= "tank" and role ~= "healer" then
        self:Print("usage: /arl lfg auto tank|healer [on|off]")
        return
      end
      self:SetAuto(role, (onoff == "" and not auto[role]) or onoff == "on")
    end },
  { name = "probe", help = "prints the raw data of one result and your listing (troubleshooting)",
    run = function() Probe() end },
}

ARLE:RegisterModule(F)
