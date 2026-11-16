-- Debug commands and the report window (the data is kept by Core/Debug.lua).
--
--   /arl errors [clear]     errors recorded on this character, per feature
--   /arl report             a window with copyable text: versions, every
--                           feature's state, the errors with their stacks, and
--                           the trace; paste it to whoever is fixing things
--   /arl debug [feature]    turns tracing on or off for a feature (saved per
--                           character); with no feature, lists what's traced
local _, ns = ...
local ARLE = ns.ARLE
local D = ARLE.Debug
local Skin, Kit = ARLE.Skin, ARLE.UI.Kit

local C_DIM = ARLE.DIM_COLOR or "|cff9d9d9d"

local function Plain(text)
  return (tostring(text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function When(t)
  return type(t) == "number" and date("%Y-%m-%d %H:%M", t) or "?"
end

-- { { id, title, entries = {...} } } newest first.
local function SavedErrors()
  local d = D.Store()
  local out = {}
  for id, list in pairs(d and d.errors or {}) do
    if type(list) == "table" and #list > 0 then
      local last = 0
      for _, e in ipairs(list) do
        last = math.max(last, e.last or 0)
      end
      out[#out + 1] = { id = id, title = D.Title(id, ARLE.modules[id]), entries = list, last = last }
    end
  end
  table.sort(out, function(a, b)
    return a.last > b.last
  end)
  return out
end

-------------------------------------------------------------------------------
-- The report
-------------------------------------------------------------------------------

function ARLE:ReportText()
  local lines = {}
  local function add(s)
    lines[#lines + 1] = s
  end
  local version, build, _, iface = GetBuildInfo()
  add("ARL Extensions v" .. tostring(self.version or "?") .. "   " .. date("%Y-%m-%d %H:%M"))
  add(string.format("Client %s (%s), interface %s, %s; level %s %s; guild check: %s", tostring(version),
    tostring(build), tostring(iface), GetLocale(), tostring(UnitLevel("player")),
    tostring(select(2, UnitClass("player"))), tostring(self.GuildState and self:GuildState() or "?")))
  add("")
  add("== Features")
  for _, group in ipairs(self.ready and self:GetGroups() or {}) do
    for _, info in ipairs(group.modules) do
      if not info.builtin then
        add(string.format("  [%s] %s (%s) v%s: %s", info.state or "?", info.title, info.id,
          tostring(info.version or "?"), Plain(info.status)))
      end
    end
  end
  -- Features that keep their own record (def:ReportDetails() -> lines).
  for id, def in pairs(self.modules or {}) do
    if def._active and type(def.ReportDetails) == "function" then
      local ok, extra = pcall(def.ReportDetails, def)
      if ok and type(extra) == "table" and #extra > 0 then
        add("")
        add("== " .. tostring(def.title or id))
        for _, l in ipairs(extra) do
          add("  " .. tostring(l))
        end
      end
    end
  end
  add("")
  add("== Errors (kept on this character; /arl errors clear empties them)")
  local saved = SavedErrors()
  if #saved == 0 then
    add("  none")
  end
  for _, f in ipairs(saved) do
    add("  " .. f.title .. " (" .. f.id .. ")")
    for _, e in ipairs(f.entries) do
      add(string.format("    x%d, first %s, last %s, ARL v%s", e.count or 0, When(e.first), When(e.last),
        tostring(e.version or "?")))
      add("    " .. tostring(e.msg))
      for s in tostring(e.stack or ""):gmatch("[^\n]+") do
        add("      " .. s)
      end
    end
  end
  add("")
  local traced = D:TracedIds()
  add("== Trace (this session" .. (#traced > 0 and ("; tracing " .. table.concat(traced, ", ")) or "; nothing traced")
    .. ")")
  local from = math.max(1, #D.trace - 150)
  for i = from, #D.trace do
    add("  " .. D.trace[i])
  end
  return table.concat(lines, "\n")
end

local report

local function BuildReport()
  local w = ARLE.UI.Window:New({
    name = "ARLExtensionsReportFrame", title = "ARL Extensions report", width = 640, height = 460,
    store = ARLE.db, key = "reportPos", escClose = true, strata = "DIALOG",
  })
  local hint = Kit.Text(w.content, "GameFontDisableSmall")
  hint:SetPoint("TOPLEFT", 2, -4)
  hint:SetText("Select all, then Ctrl+C to copy.")

  local scroll = CreateFrame("ScrollFrame", nil, w.content, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 0, -26)
  scroll:SetPoint("BOTTOMRIGHT", -24, 0)
  Skin:ScrollBar(scroll)
  local box = CreateFrame("EditBox", nil, scroll)
  box:SetMultiLine(true)
  box:SetAutoFocus(false)
  box:SetFontObject(ChatFontNormal)
  box:SetWidth(590)
  box:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
  end)
  -- Read only: typing puts the report back.
  box:SetScript("OnTextChanged", function(self, userInput)
    if userInput then
      self:SetText(w.text or "")
    end
  end)
  scroll:SetScrollChild(box)
  w.box = box

  local selectAll = Kit.SmallButton(w.content, "Select all", 80)
  selectAll:SetPoint("TOPRIGHT", 0, -2)
  selectAll:SetScript("OnClick", function()
    box:SetFocus()
    box:HighlightText()
  end)
  local refresh = Kit.SmallButton(w.content, "Refresh", 70)
  refresh:SetPoint("RIGHT", selectAll, "LEFT", -4, 0)
  refresh:SetScript("OnClick", function()
    w:Fill()
  end)
  local clear = Kit.SmallButton(w.content, "Clear errors", 90)
  clear:SetPoint("RIGHT", refresh, "LEFT", -4, 0)
  clear:SetScript("OnClick", function()
    D:Clear()
    ARLE:Changed()
    w:Fill()
  end)

  function w:Fill()
    self.text = ARLE:ReportText()
    self.box:SetText(self.text)
    self.box:SetCursorPosition(0)
  end
  report = w
end

function ARLE:ShowReport()
  if not report then
    BuildReport()
  end
  report:Fill()
  report:Show()
end

-------------------------------------------------------------------------------
-- Commands
-------------------------------------------------------------------------------

local function Builtin(c)
  c.section, c.builtin = "General", true
  return ARLE:RegisterCommand(c)
end

Builtin({ name = "errors", aliases = { "err" }, args = "[clear]", open = true,
  help = "errors ARL caught on this character, per feature", fn = function(rest)
    if rest == "clear" then
      D:Clear()
      ARLE:Changed()
      ARLE:Print("errors cleared.")
      return
    end
    local saved = SavedErrors()
    if #saved == 0 then
      ARLE:Print("no errors recorded on this character.")
      return
    end
    ARLE:Print("errors on this character (/arl report for the full text with stacks, /arl errors clear to empty):")
    for _, f in ipairs(saved) do
      print("   |cffffd100" .. f.title .. "|r")
      for i, e in ipairs(f.entries) do
        if i > 3 then
          print("      " .. C_DIM .. "... " .. (#f.entries - 3) .. " more in /arl report|r")
          break
        end
        print(string.format("      |cffff6060x%d|r %s%s|r  %s", e.count or 0, C_DIM, When(e.last),
          (tostring(e.msg):gsub("^Interface[/\\]AddOns[/\\]", ""))))
      end
    end
  end })

Builtin({ name = "report", aliases = { "bug" }, open = true,
  help = "a copyable report (versions, feature states, errors, trace) to paste to whoever fixes it",
  fn = function()
    ARLE:ShowReport()
  end })

Builtin({ name = "debug", args = "[feature | off]", open = true,
  help = "traces what a feature decides, in chat and in /arl report",
  fn = function(rest)
    if rest == "" then
      local traced = D:TracedIds()
      ARLE:Print(#traced > 0 and ("tracing: " .. table.concat(traced, ", ") .. ". /arl debug <feature> turns one off, "
        .. "/arl debug off turns all off.") or "nothing traced. /arl debug <feature> turns tracing on for one.")
      return
    end
    if rest == "off" then
      for _, id in ipairs(D:TracedIds()) do
        D:SetTracing(id, false)
      end
      ARLE:Print("tracing off.")
      return
    end
    local info = ARLE:FindModule(rest)
    if not info then
      ARLE:Print("No feature matches \"" .. rest .. "\". /arl list shows them.")
      return
    end
    local on = not D:Tracing(info.id)
    D:SetTracing(info.id, on)
    ARLE:Print(info.title .. ": tracing " .. (on and "|cff73e673on|r (lines in chat and in /arl report)" or "off") .. ".")
  end })
