-- ARLE.Macro: macros a feature makes and keeps up to date, without ever
-- touching the player's own. A feature remembers the names it made (in its
-- char table) and only edits or deletes a macro by that name whose text still
-- looks like its own (isOurs(body)): a macro you renamed or rewrote is yours.
-- Macros can't be changed in combat: callers wrap changes in
-- feature:OutOfCombat or check ARLE.Secure:InCombat().
local _, ns = ...
local ARLE = ns.ARLE
local Mac = ARLE.Macro

Mac.NAME_LIMIT = 16  -- characters a macro name may hold
Mac.ICON = 134400    -- question mark: #showtooltip shows the spell's icon

function Mac:Index(name)
  if not name or not GetMacroIndexByName then
    return nil
  end
  local index = GetMacroIndexByName(name)
  if index and index > 0 then
    return index
  end
end

function Mac:Body(index)
  if not index or not GetMacroInfo then
    return nil
  end
  return (select(3, GetMacroInfo(index)))
end

-- Free character (perChar) or account slots.
function Mac:FreeSlots(perChar)
  if not GetNumMacros then
    return 0
  end
  local account, char = GetNumMacros()
  if perChar then
    return (MAX_CHARACTER_MACROS or 18) - (char or 0)
  end
  return (MAX_ACCOUNT_MACROS or 120) - (account or 0)
end

-- base cut to fit; if one of your macros already has that name, a "+" marks
-- ours apart. nil when both are taken.
function Mac:FreeName(base)
  local name = base:sub(1, self.NAME_LIMIT)
  if self:Index(name) then
    name = base:sub(1, self.NAME_LIMIT - 1) .. "+"
    if self:Index(name) then
      return nil
    end
  end
  return name
end

-- The index of the macro a feature made, if it still exists and is still ours.
function Mac:Ours(name, isOurs)
  local index = self:Index(name)
  if index and (not isOurs or isOurs(self:Body(index))) then
    return index
  end
end

-- Macros are protected in combat (pcall doesn't stop the "blocked" popup).
local function InCombat()
  return InCombatLockdown and InCombatLockdown()
end

-- Creates a macro; returns its name, or nil (no slot, or the game refused).
function Mac:Create(base, body, perChar, icon)
  if InCombat() then
    return nil, "macros can't be changed in combat"
  end
  if self:FreeSlots(perChar) <= 0 then
    return nil, "no free " .. (perChar and "character" or "account") .. " macro slot"
  end
  local name = self:FreeName(base)
  if not name then
    return nil, "both \"" .. base .. "\" and \"" .. base .. "+\" are taken"
  end
  local ok = pcall(CreateMacro, name, icon or self.ICON, body, perChar and true or nil)
  if ok and self:Index(name) then
    return name
  end
  return nil, "the game refused to create it"
end

-- Keeps one macro of ours up to date: store[key] holds its name.
-- Returns "created" | "updated" | "same" | nil, why.
function Mac:Ensure(store, key, base, body, perChar, isOurs)
  if InCombat() then
    return nil, "macros can't be changed in combat"
  end
  local index = self:Ours(store[key], isOurs)
  if index then
    if self:Body(index) == body then
      return "same"
    end
    local name, icon = GetMacroInfo(index)
    EditMacro(index, name, icon, body)
    return "updated"
  end
  local name, why = self:Create(base, body, perChar)
  if not name then
    return nil, why
  end
  store[key] = name
  return "created"
end

function Mac:Delete(name, isOurs)
  if InCombat() then
    return false
  end
  local index = self:Ours(name, isOurs)
  if index then
    DeleteMacro(index)
    return true
  end
  return false
end
