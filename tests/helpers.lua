-- tests/helpers.lua
local M = {}

-- Deep equality for tables (order-sensitive for arrays).
local function deep_equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  local seen = {}
  for k, v in pairs(a) do
    if not deep_equal(v, b[k]) then return false end
    seen[k] = true
  end
  for k, _ in pairs(b) do
    if not seen[k] then return false end
  end
  return true
end

local function show(v)
  if type(v) ~= "table" then return tostring(v) end
  local parts = {}
  for k, x in pairs(v) do
    parts[#parts+1] = tostring(k) .. "=" .. show(x)
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

function M.assert_deep_equal(actual, expected, msg)
  if not deep_equal(actual, expected) then
    error((msg or "values differ") ..
      "\n  expected: " .. show(expected) ..
      "\n  actual:   " .. show(actual), 2)
  end
end

-- Fake UCI cursor matching the subset of the API we use:
-- cursor:get(config, section, option) -> string|nil
-- cursor:get_list(config, section, option) -> array (possibly empty)
function M.fake_cursor(data)
  local cur = {}
  function cur:get(config, section, option)
    local s = (data[config] or {})[section] or {}
    local v = s[option]
    if type(v) == "table" then return nil end
    return v
  end
  function cur:get_list(config, section, option)
    local s = (data[config] or {})[section] or {}
    local v = s[option]
    if type(v) == "table" then return v end
    if v == nil then return {} end
    return { v }
  end
  return cur
end

local _passed, _failed = 0, 0
function M.test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    _passed = _passed + 1
    io.write("  ok    " .. name .. "\n")
  else
    _failed = _failed + 1
    io.write("  FAIL  " .. name .. "\n")
    io.write("        " .. tostring(err) .. "\n")
  end
end

function M.summary()
  io.write(string.format("# %d passed, %d failed\n", _passed, _failed))
  os.exit(_failed == 0 and 0 or 1)
end

return M
