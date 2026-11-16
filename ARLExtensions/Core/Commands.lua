-- /arl commands.
--
-- One grammar for every feature, generated from its definition:
--   /arl <feature>                    its main action (def.main), or its status and settings
--   /arl <feature> on | off           turns it on or off
--   /arl <feature> set                lists its settings and their values
--   /arl <feature> set <key> [value]  changes one (a switch flips with no value)
--   /arl <feature> <key> [value]      the same, when <key> isn't one of its actions
--   /arl <feature> <action> [args]    its own actions (def.commands)
--   /arl <feature> help               all of the above for that feature
-- A feature declares command = "fish" (plus commandAliases, commands = {...},
-- commandUsage, main) and gets all of it. Other commands are registered with
-- ARLE:RegisterCommand(name, fn, help) or ARLE:RegisterCommand({ ... }).
local _, ns = ...
local ARLE = ns.ARLE
local O = ARLE.Options
local L = ARLE.Lib

ARLE.commands = {}  -- name -> command
local aliases = {}  -- alias -> name
local order = 0

function ARLE:RegisterCommand(name, fn, help)
  local c = type(name) == "table" and name or { name = name, fn = fn, help = help }
  c.name = c.name:lower()
  order = order + 1
  c.order = c.order or order
  self:UnregisterCommand(c.name)
  self.commands[c.name] = c
  for _, alias in ipairs(c.aliases or {}) do
    aliases[alias:lower()] = c.name
  end
  return c
end

function ARLE:UnregisterCommand(name)
  name = name:lower()
  local c = self.commands[name]
  self.commands[name] = nil
  if c then
    for _, alias in ipairs(c.aliases or {}) do
      if aliases[alias:lower()] == name then
        aliases[alias:lower()] = nil
      end
    end
  end
end

function ARLE:FindCommand(word)
  word = (word or ""):lower()
  return self.commands[word] or (aliases[word] and self.commands[aliases[word]])
end

function ARLExtensions_OnAddonCompartmentClick()
  if ARLE.Toggle then
    ARLE:Toggle()
  end
end

local THEMES = { "arl", "auto", "ellesmere", "elvui", "blizzard" }

local C_CMD, C_ARG, C_DIM = "|cffffd100", "|cff8fc8ff", "|cff9d9d9d"
ARLE.CMD_COLOR, ARLE.ARG_COLOR, ARLE.DIM_COLOR = C_CMD, C_ARG, C_DIM

local function CommandLine(c, args)
  local text = C_CMD .. "/arl" .. (c.name ~= "" and (" " .. c.name) or "") .. "|r"
  args = args or c.args
  if args and args ~= "" then
    text = text .. " " .. C_ARG .. args .. "|r"
  end
  return text
end
ARLE.CommandLine = CommandLine

local Key = L.Key

-- Finds a feature (installed or loaded) by id, title, or one of its commands:
-- exact first, then the start of a word, then anywhere in the title.
function ARLE:FindModule(query)
  local q = Key(query)
  if q == "" then
    return nil
  end
  local c = self:FindCommand(query)
  if c and c.module and self:GetInfo(c.module) then
    return self:GetInfo(c.module)
  end
  local all = {}
  for _, group in ipairs(self.ready and self:GetGroups() or {}) do
    for _, info in ipairs(group.modules) do
      all[#all + 1] = info
    end
  end
  for _, test in ipairs({
    function(info) return Key(info.id) == q or Key(info.title) == q or (info.command and Key(info.command) == q) end,
    function(info) return Key(info.title):sub(1, #q) == q or Key(info.id):sub(1, #q) == q end,
    function(info) return Key(info.title):find(q, 1, true) ~= nil end,
  }) do
    for _, info in ipairs(all) do
      if test(info) then
        return info
      end
    end
  end
end

-- "/arl open dh quests": the feature, then optionally one of its pages.
local function ModuleAndPage(rest)
  local info = ARLE:FindModule(rest)
  if info then
    return info
  end
  local head, last = rest:match("^(.-)%s+(%S+)$")
  info = head and ARLE:FindModule(head)
  local def = info and ARLE.modules[info.id]
  for _, page in ipairs(def and def.pages or {}) do
    if Key(page.key) == Key(last) or Key(page.label):sub(1, #Key(last)) == Key(last) then
      return info, page.key
    end
  end
end

local function NeedModule(rest, verb)
  if rest == "" then
    ARLE:Print("Which feature? " .. CommandLine({ name = verb }, "<feature>") .. "  (" .. CommandLine({ name = "list" })
      .. " shows them)")
    return
  end
  local info, page = ModuleAndPage(rest)
  if not info then
    ARLE:Print("No feature matches \"" .. rest .. "\". " .. CommandLine({ name = "list" }) .. " shows them.")
  end
  return info, page
end

local function Switch(info, on)
  if info.builtin then
    ARLE:Print(info.title .. " is always on.")
    return
  end
  if info.enabled == on then
    ARLE:Print(info.title .. " is already " .. (on and "on" or "off") .. ".")
    return
  end
  ARLE:SetModuleEnabled(info.id, on)
  local now = ARLE:GetInfo(info.id)
  if now.enabled == on then
    ARLE:Print(info.title .. (on and " |cff73e673enabled|r." or " |cff999999disabled|r.")
      .. ((on and not now.active and now.state ~= "pending") and (" " .. now.status) or ""))
  end
end

-------------------------------------------------------------------------------
-- Generated feature commands
-------------------------------------------------------------------------------

local function FindAction(def, word)
  for _, a in ipairs(def.commands or {}) do
    if a.name == word then
      return a
    end
    for _, alias in ipairs(a.aliases or {}) do
      if alias == word then
        return a
      end
    end
  end
end

local function FindSetting(def, word)
  word = (word or ""):lower()
  for _, opt in ipairs(def.options or {}) do
    if O.IsValue(opt) and O.CmdWord(opt) == word then
      return opt
    end
  end
  for _, opt in ipairs(def.options or {}) do
    if O.IsValue(opt) and opt.key:lower() == word then
      return opt
    end
  end
end

local function Visible(def, opt)
  if opt.hidden then
    local ok, hide = pcall(opt.hidden, def)
    if ok and hide then
      return false
    end
  end
  return true
end

local function ListSettings(def)
  local any = false
  for _, opt in ipairs(def.options or {}) do
    if O.IsValue(opt) and Visible(def, opt) then
      any = true
      print("   " .. C_ARG .. O.CmdWord(opt) .. "|r  " .. O.Describe(opt, ARLE:GetOption(def.id, opt))
        .. "  " .. C_DIM .. "- " .. (opt.label or opt.key) .. "|r")
    end
  end
  if not any then
    print("   " .. C_DIM .. "(no settings)|r")
  end
end

local function SetSetting(def, opt, text)
  local current = ARLE:GetOption(def.id, opt)
  local value, why = O.Parse(opt, text, current)
  if value == nil then
    def:Print((opt.label or opt.key) .. " " .. why .. ".")
    return
  end
  ARLE:SetOption(def.id, opt.key, value)
  def:Print((opt.label or opt.key) .. ": " .. O.Describe(opt, ARLE:GetOption(def.id, opt)))
end

function ARLE:PrintStatus(def)
  local info = self:GetInfo(def.id)
  def:Print((info.enabled and "" or "off · ") .. info.status)
  ListSettings(def)
  print("   " .. C_DIM .. "/arl " .. def.command .. " help for its commands, /arl open " .. def.command
    .. " for the panel.|r")
end

function ARLE:PrintFeatureHelp(def)
  local c = { name = def.command }
  self:Print(C_CMD .. (def.title or def.id) .. "|r  " .. C_DIM .. (def.commandHelp or "") .. "|r")
  local function line(args, text)
    print("   " .. CommandLine(c, args) .. "  " .. C_DIM .. "- " .. text .. "|r")
  end
  line("", def.mainHelp or (def.main and "its main action" or "status and settings"))
  line("on | off", "turns it on or off")
  for _, u in ipairs(def.commandUsage or {}) do
    print("   " .. C_CMD .. "/arl " .. u[1] .. "|r  " .. C_DIM .. "- " .. u[2] .. "|r")
  end
  for _, a in ipairs(def.commands or {}) do
    line(a.name .. (a.args and (" " .. a.args) or ""), a.help or "")
  end
  line("set", "lists its settings")
  for _, opt in ipairs(def.options or {}) do
    if O.IsValue(opt) and Visible(def, opt) then
      local hint = opt.type == "boolean" and "[on|off]" or (opt.type == "select" and ("<" .. O.ValuesText(opt):gsub(", ", "/") .. ">"))
        or (opt.type == "string" and "<text>") or ("<n" .. O.RangeText(opt):gsub("^ ", " ") .. ">")
      line(O.CmdWord(opt) .. " " .. hint, opt.label or opt.key)
    end
  end
  if def.commandAliases and #def.commandAliases > 0 then
    local list = {}
    for _, a in ipairs(def.commandAliases) do
      list[#list + 1] = "/arl " .. a
    end
    print("   " .. C_DIM .. "Same as: " .. table.concat(list, ", ") .. "|r")
  end
end

local function Dispatch(def, rest, raw)
  rest, raw = rest or "", raw or rest or ""
  local word, tail = rest:match("^(%S*)%s*(.-)$")
  local rawTail = raw:match("^%S*%s*(.-)$") or ""
  local info = ARLE:GetInfo(def.id)
  if word == "on" or word == "off" then
    Switch(info, word == "on")
    return
  elseif word == "help" or word == "?" then
    ARLE:PrintFeatureHelp(def)
    return
  elseif word == "set" then
    if tail == "" then
      def:Print("settings")
      ListSettings(def)
      return
    end
    local key, value = tail:match("^(%S+)%s*(.-)$")
    local rawValue = rawTail:match("^%S+%s*(.-)$") or ""
    local opt = FindSetting(def, key)
    if not opt then
      def:Print("no setting \"" .. key .. "\". /arl " .. def.command .. " set lists them.")
      return
    end
    SetSetting(def, opt, opt.type == "string" and rawValue or value)
    return
  end
  local action = word ~= "" and FindAction(def, word)
  if action then
    if not def._active and not action.always then
      def:Print("is off. /arl " .. def.command .. " on turns it on.")
      return
    end
    ARLE.Debug.Call(def, action.run, def, tail, rawTail)
    return
  end
  local opt = word ~= "" and FindSetting(def, word)
  if opt then
    SetSetting(def, opt, opt.type == "string" and rawTail or tail)
    return
  end
  if not def._active then
    if word == "" then
      ARLE:PrintStatus(def)
    else
      def:Print("is off. /arl " .. def.command .. " on turns it on.")
    end
    return
  end
  if def.main then
    ARLE.Debug.Call(def, def.main, def, rest, raw)
  elseif word == "" then
    ARLE:PrintStatus(def)
  else
    def:Print("no command \"" .. word .. "\". /arl " .. def.command .. " help lists them.")
  end
end
ARLE.DispatchFeature = Dispatch

function ARLE:RegisterFeatureCommand(def)
  self:RegisterCommand({
    name = def.command,
    aliases = def.commandAliases,
    args = def.commandArgs or "[on|off|set|help]",
    help = def.commandHelp or def.title,
    section = def.commandSection,
    module = def.id,
    feature = def,
    usage = def.commandUsage,
    fn = function(rest, raw)
      Dispatch(def, rest, raw)
    end,
  })
end

-------------------------------------------------------------------------------
-- Help
-------------------------------------------------------------------------------

local function SectionOf(c)
  if c.section then
    return c.section
  end
  if c.module then
    return ARLE:GroupLabel(ARLE:GroupOf(c.module))
  end
  return "Other"
end

-- Features whose pack isn't loaded (all of its features off) still answer
-- "/arl <cmd> on" and show in help, dimmed.
local function UnloadedFeatures()
  local list = {}
  for id, cat in pairs(ARLE.catalog) do
    if cat.cmd and not ARLE.modules[id] and not ARLE:FindCommand(cat.cmd) then
      list[#list + 1] = cat
    end
  end
  return list
end

local function Sections()
  local bySection, names = {}, {}
  local function put(section, c)
    if not bySection[section] then
      bySection[section] = {}
      names[#names + 1] = section
    end
    table.insert(bySection[section], c)
  end
  for _, c in pairs(ARLE.commands) do
    put(SectionOf(c), c)
  end
  for _, cat in ipairs(UnloadedFeatures()) do
    put(ARLE:GroupLabel(ARLE:GroupOf(cat.id)), { name = cat.cmd, args = "on", help = cat.title, order = 1e6,
      offline = true })
  end
  table.sort(names, function(a, b)
    if (a == "General") ~= (b == "General") then
      return a == "General"
    end
    return a < b
  end)
  for _, list in pairs(bySection) do
    table.sort(list, function(a, b)
      if a.order ~= b.order then
        return a.order < b.order
      end
      return a.name < b.name
    end)
  end
  return names, bySection
end

function ARLE:PrintHelp(word)
  if word and word ~= "" then
    local c = self:FindCommand(word)
    if c and c.feature then
      self:PrintFeatureHelp(c.feature)
      return
    end
    if not c then
      self:Print("No command \"" .. word .. "\". " .. CommandLine({ name = "help" }) .. " lists them.")
      return
    end
    self:Print(CommandLine(c) .. "  " .. (c.help or ""))
    for _, u in ipairs(c.usage or {}) do
      print("   " .. C_CMD .. "/arl " .. u[1] .. "|r  " .. C_DIM .. "- " .. u[2] .. "|r")
    end
    if c.aliases and #c.aliases > 0 then
      local list = {}
      for _, a in ipairs(c.aliases) do
        list[#list + 1] = "/arl " .. a
      end
      print("   " .. C_DIM .. "Same as: " .. table.concat(list, ", ") .. "|r")
    end
    return
  end
  self:Print("v" .. tostring(self.version or "?") .. " commands  " .. C_DIM .. "(/arl help <command> for details)|r")
  local names, bySection = Sections()
  for _, section in ipairs(names) do
    print("  " .. "|cff7fd4ff" .. section .. "|r")
    for _, c in ipairs(bySection[section]) do
      if not c.hidden then
        local off = c.offline or (c.feature and not c.feature._active)
        if off then
          print("   " .. C_DIM .. "/arl " .. c.name .. (c.feature and "" or " on") .. "  - " .. (c.help or "")
            .. " (off)|r")
        else
          print("   " .. CommandLine(c) .. "  " .. C_DIM .. "- " .. (c.help or "") .. "|r")
        end
      end
    end
  end
  if self:GuildState() ~= "member" then
    print("   " .. C_DIM .. "Only help, list and version work outside " .. self.guildName .. ".|r")
  end
end

-------------------------------------------------------------------------------
-- Built-in commands, listed first under "General".
-------------------------------------------------------------------------------

local function Builtin(def)
  def.section, def.builtin = "General", true
  return ARLE:RegisterCommand(def)
end

Builtin({ name = "", help = "opens or closes the panel", open = true, fn = function()
  if ARLE.Toggle then
    ARLE:Toggle()
  end
end })

Builtin({ name = "help", aliases = { "?", "commands" }, args = "[command]", open = true,
  help = "this list, or one command in detail", fn = function(rest)
    ARLE:PrintHelp(rest)
  end })

Builtin({ name = "list", aliases = { "ls", "modules", "features" }, open = true,
  help = "every feature and its status", fn = function()
    if not ARLE.ready then
      ARLE:Print("Still loading.")
      return
    end
    for _, group in ipairs(ARLE:GetGroups()) do
      ARLE:Print("|cffffd100" .. group.label .. "|r")
      for _, info in ipairs(group.modules) do
        local mark = info.builtin and "" or (info.enabled and "|cff73e673on|r  " or "|cff999999off|r  ")
        local cmd = info.command and (C_DIM .. "  /arl " .. info.command .. "|r") or ""
        print("   " .. mark .. info.title .. C_DIM .. " - " .. info.status .. "|r" .. cmd)
      end
    end
  end })

Builtin({ name = "open", aliases = { "config", "options" }, args = "<feature> [page]",
  help = "opens the panel on a feature's settings",
  usage = { { "open dungeon helper", "the Dungeon Helper entry" }, { "open dh quests", "its Quests settings" } },
  fn = function(rest)
    local info, page = NeedModule(rest, "open")
    if info then
      ARLE:Open(info.id, page)
    end
  end })

Builtin({ name = "enable", aliases = { "on" }, args = "<feature>", help = "turns a feature on", fn = function(rest)
  local info = NeedModule(rest, "enable")
  if info then
    Switch(info, true)
  end
end })
Builtin({ name = "disable", aliases = { "off" }, args = "<feature>", help = "turns a feature off", fn = function(rest)
  local info = NeedModule(rest, "disable")
  if info then
    Switch(info, false)
  end
end })

Builtin({ name = "theme", args = "[" .. table.concat(THEMES, "|") .. "]",
  help = "shows or sets the window theme (applies after /reload)", fn = function(rest)
    for _, t in ipairs(THEMES) do
      if t == rest then
        ARLE.db.theme = rest
        ARLE:Print("Theme set to " .. rest .. ". /reload to apply.")
        return
      end
    end
    ARLE:Print("Theme is " .. tostring(ARLE.db and ARLE.db.theme) .. ". "
      .. CommandLine({ name = "theme" }, table.concat(THEMES, " | ")))
  end })

Builtin({ name = "version", aliases = { "v" }, open = true, help = "the version of ARL Extensions and its features",
  fn = function()
    ARLE:Print("v" .. tostring(ARLE.version or "?"))
    for _, group in ipairs(ARLE.ready and ARLE:GetGroups() or {}) do
      for _, info in ipairs(group.modules) do
        if not info.builtin then
          print("   " .. info.title .. C_DIM .. "  v" .. tostring(info.version or "?") .. "|r")
        end
      end
    end
  end })

-- Suggestions for a mistyped command: names and aliases starting with it,
-- or containing it.
local function Suggest(word)
  local found = {}
  local function consider(name)
    if name ~= "" and (name:sub(1, #word) == word or (#word >= 3 and name:find(word, 1, true))) then
      found[#found + 1] = "/arl " .. name
    end
  end
  for name in pairs(ARLE.commands) do
    consider(name)
  end
  for alias in pairs(aliases) do
    consider(alias)
  end
  for _, cat in ipairs(UnloadedFeatures()) do
    consider(cat.cmd)
  end
  table.sort(found)
  return found
end

SLASH_ARLEXTENSIONS1 = "/arl"
SlashCmdList.ARLEXTENSIONS = function(message)
  message = (message or ""):match("^%s*(.-)%s*$")
  local cmd, raw = message:match("^(%S*)%s*(.-)$")
  cmd = cmd:lower()
  local rest = raw:lower()
  local c = ARLE:FindCommand(cmd)
  if c then
    -- Outside the guild only the read-only commands answer.
    if c.open or ARLE:Allowed() then
      -- Errors go on the feature the command belongs to (or ARL's own).
      ARLE.Debug.Call(c.feature or (c.module and ARLE.modules[c.module]) or nil, c.fn, rest, raw)
    end
    return
  end
  -- A feature whose pack isn't loaded: "/arl <cmd> on" loads it.
  for _, cat in ipairs(UnloadedFeatures()) do
    if cat.cmd == cmd then
      if not ARLE:Allowed() then
        return
      end
      if rest == "on" then
        Switch(ARLE:GetInfo(cat.id), true)
      else
        ARLE:Print(cat.title .. " is off. /arl " .. cmd .. " on turns it on.")
      end
      return
    end
  end
  local maybe = Suggest(cmd)
  if #maybe > 0 then
    ARLE:Print("Unknown command \"" .. cmd .. "\". Did you mean " .. table.concat(maybe, ", ", 1, math.min(#maybe, 4))
      .. "?  " .. CommandLine({ name = "help" }) .. " lists them all.")
  else
    ARLE:Print("Unknown command \"" .. cmd .. "\". " .. CommandLine({ name = "help" }) .. " lists them all.")
  end
end
