-- test_logo.lua — логотипы about: lua tests/test_logo.lua
package.path = './?.lua;' .. package.path
local LG = dofile('jf_tracker_logo.lua')
local n, bad = 0, 0
local function eq(name, got, want)
  n = n + 1
  if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end
end
eq('five logos', #LG.LOGOS, 5)
local KNOWN = { [' '] = 1, ['#'] = 1, ['+'] = 1, ['-'] = 1, [':'] = 1, ['_'] = 1, ['╱'] = 1, ['╲'] = 1, ['▀'] = 1, ['▄'] = 1, ['█'] = 1, ['░'] = 1, ['▒'] = 1, ['▓'] = 1 }
local SIZES = { alligator = { 101, 7 }, drip = { 63, 10 }, slant = { 91, 5 }, shade = { 90, 5 }, bloody = { 75, 10 } }
for _, lg in ipairs(LG.LOGOS) do
  local w, h = LG.size(lg)
  eq(lg.name .. ' size', w .. 'x' .. h, SIZES[lg.name][1] .. 'x' .. SIZES[lg.name][2])
  local ok, trail = true, false
  for _, l in ipairs(lg.lines) do
    for _, c in ipairs(LG.chars(l)) do if not KNOWN[c] then ok = false end end
    if l:find('%s$') then trail = true end
  end
  eq(lg.name .. ' glyphs drawable', ok, true)
  eq(lg.name .. ' no trailing spaces', trail, false)
end
-- колонки не съехали
local al = LG.LOGOS[1].lines
eq('alligator J top', al[1]:sub(1, 11), ':::::::::::')
eq('alligator R leg', al[2]:sub(-3) .. al[7]:sub(-3), ':+:###')
-- выбор: никогда не тот же подряд, покрывает все
local seen, prev, same = {}, nil, false
for i = 1, 40 do
  local k = LG.pick(prev, function(a, b) return a + (i % (b - a + 1)) end)
  if k == prev then same = true end
  seen[k] = true; prev = k
end
local cnt = 0; for _ in pairs(seen) do cnt = cnt + 1 end
eq('pick never repeats', same, false); eq('pick covers all', cnt, 5)
-- с картинками из logos/: n = текстовые + картинки
seen, prev, same = {}, nil, false
for i = 1, 200 do
  local k = LG.pick(prev, function(a, b) return a + ((i * 7) % (b - a + 1)) end, 17)
  if k == prev then same = true end
  seen[k] = true; prev = k
end
cnt = 0; for k in pairs(seen) do if k >= 1 and k <= 17 then cnt = cnt + 1 end end
eq('pick with images never repeats', same, false); eq('pick with images covers all 17', cnt, 17)
-- ячейка: ужимается под ширину, сохраняет пропорцию; слишком узко — nil
local cw, ch = LG.cell(LG.LOGOS[1], 1000, 8, 16)
eq('cell fits wide', cw, 8); eq('cell aspect', ch, 16)
cw, ch = LG.cell(LG.LOGOS[1], 404, 8, 16)
eq('cell shrinks', cw, 4); eq('cell shrinks h', ch, 8)
eq('cell too narrow', LG.cell(LG.LOGOS[1], 150, 8, 16), nil)
-- отрисовка со стабом gfx не падает
local rects = 0
gfx = { set = function() end, rect = function() rects = rects + 1 end, line = function() end }
for _, lg in ipairs(LG.LOGOS) do LG.draw(lg, 0, 0, 4, 8, { 1, 0.7, 0 }, { 0, 0, 0 }) end
eq('draw makes rects', rects > 500, true)
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
