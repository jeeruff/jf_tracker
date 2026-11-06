-- test_keys_sync.lua (6 ноя) — один источник клавиш: keyhelp. lua tests/test_keys_sync.lua
-- 1) раздел All keys мануала совпадает со сгенерированным из keyhelp (иначе: lua tools/gen_keys.lua)
-- 2) каждая клавиша строки подсказок под модулем (KH.BARS) есть в keyhelp (любой странице) — бары не врут
local DIR = (arg and arg[0] or ''):match('(.*)/tests/') or '.'
local fails, n = 0, 0
local ok = os.execute('cd "' .. DIR .. '" && lua tools/gen_keys.lua check')
n = n + 1; if not ok then fails = fails + 1; print('FAIL All keys out of date - run lua tools/gen_keys.lua') end
local KH = dofile(DIR .. '/jf_tracker_keyhelp.lua')
local known = {}
for _, pg in pairs(KH.PAGES) do
  for _, e in ipairs(pg.e or {}) do
    if type(e) == 'table' and e.k then
      for t in tostring(e.k):gmatch('%S+') do known[t] = true end
      known[e.k] = true
    end
  end
end
-- клавиши, названные в описаниях (Opt+X у slixer и т. п.)
for _, pg in pairs(KH.PAGES) do
  for _, e in ipairs(pg.e or {}) do
    if type(e) == 'table' and e.d then for t in tostring(e.d):gmatch('[%w%+%-%[%]%.\'"!@#$%%^&*/=<>~`,;:|?_]+') do known[t] = true end end
  end
end
-- сокращения баров: hjkl / jk / hl — буквы подряд, S+ = Shift+, C- = Ctrl+; заглушки — разрешены
local ALLOW = { letter = true, q2w3e = true, ['zsx q2w'] = true }
local function norm(k)
  k = k:gsub('^S%+', 'Shift+'):gsub('C%-S%-', 'Ctrl+Shift+'):gsub('C%-', 'Ctrl+')
  return k
end
local function ok_tok(t)
  if known[t] or known[norm(t)] or ALLOW[t] then return true end
  local base = norm(t)
  local pre, letters = base:match('^(.-%+?)(%l+)$')
  if letters and #letters > 1 and letters:match('^[hjkl]+$') then
    for ch in letters:gmatch('.') do if not (known[ch] or known[pre .. ch] or known[pre .. ch:upper()]) then return false end end
    return true
  end
  if known[base:gsub('%+(%l)$', function(c) return '+' .. c:upper() end)] then return true end
  if base:match("^'") and known["'1..9"] then return true end
  return false
end
local miss = {}
for bar, list in pairs(KH.BARS or {}) do
  for _, it in ipairs(list) do
    local k = it[1]
    n = n + 1
    local okk = ALLOW[k] or known[k]
    if not okk then okk = true; for t in tostring(k):gmatch('%S+') do if not ok_tok(t) then okk = false end end end
    if not okk then miss[#miss + 1] = bar .. ': ' .. k end
  end
end
table.sort(miss)
for _, m in ipairs(miss) do fails = fails + 1; print('FAIL bar key not in keyhelp - ' .. m) end
print(('%d checks, %d failed'):format(n, fails))
os.exit(fails == 0 and 0 or 1)
