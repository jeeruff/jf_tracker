-- test_logo.lua — граффити-логотип: lua tests/test_logo.lua
package.path = './?.lua;' .. package.path
local LG = dofile('jf_tracker_logo.lua')
local n, bad = 0, 0
local function eq(name, got, want)
  n = n + 1
  if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end
end
for _, st in ipairs(LG.STYLE_NAMES) do
  local lines, name = LG.make(st)
  eq(st .. ': name', name, st)
  eq(st .. ': has lines', #lines >= 5, true)
  local ascii, maxw, ink = true, 0, 0
  for _, l in ipairs(lines) do
    if l:find('[^\32-\126]') then ascii = false end
    if #l > maxw then maxw = #l end
    ink = ink + #l:gsub('%s', '')
  end
  eq(st .. ': ascii only (bitmap font)', ascii, true)
  eq(st .. ': fits 72 columns', maxw <= 72, true)
  eq(st .. ': has ink', ink > 50, true)
end
-- случайный стиль — из списка
local seen = {}
for i = 1, 60 do local _, s = LG.make(nil, function(a, b) return a + (i % (b - a + 1)) end); seen[s] = true end
local cnt = 0; for _ in pairs(seen) do cnt = cnt + 1 end
eq('random covers every style', cnt, #LG.STYLE_NAMES)
-- сетка: 9 букв по 5 + 8 промежутков
local _, w = LG.grid()
eq('grid width', w, 9 * 5 + 8)
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
