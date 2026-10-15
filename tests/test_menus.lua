-- test_menus.lua — меню which-key и подсказка статуса не отстают от обработчика (15 окт):
-- каждая клавиша ветки p == 'z' / 'g' в jf_tracker_vim.lua есть в меню и наоборот; подсказка z — без устаревших
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local WK = dofile(DIR .. '/jf_tracker_whichkey.lua')
local src = io.open(DIR .. '/jf_tracker_vim.lua'):read('a')
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end
local function branch(p, nextp)
  local a = src:find("p == '" .. p .. "' then", 1, true)
  local b = src:find("elseif p == '" .. nextp .. "' then", a, true)
  local keys = {}
  for ch in src:sub(a, b):gmatch("c == %('(.)'%)") do keys[ch] = true end
  return keys
end
local function menu(p)
  local keys = {}
  for _, it in ipairs(WK.get(p).items) do for k in it[1]:gmatch('%S+') do if #k == 1 then keys[k] = true end end end
  return keys
end
local hints = src:match("\n  z = 'z: ([^']*)'")
for _, pr in ipairs({ { 'z', 'r' }, { 'g', 'z' } }) do
  local h, m = branch(pr[1], pr[2]), menu(pr[1])
  for k in pairs(h) do eq(pr[1] .. k .. ' in the menu', m[k], true) end
  for k in pairs(m) do eq(pr[1] .. k .. ' handled', h[k], true) end
end
-- подсказка статуса короткая (влезает строкой), но без устаревших клавиш: каждая — в обработчике
local zh = branch('z', 'r')
for seg in hints:gmatch('[^|]+') do
  local ks = seg:match('^%s*(.-)%s+%l%l') or ''
  for k in ks:gmatch('%S+') do if #k == 1 then eq('status hint z' .. k .. ' handled', zh[k], true) end end
end
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
