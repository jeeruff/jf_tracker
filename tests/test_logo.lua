-- test_logo.lua — логотипы about: lua tests/test_logo.lua
package.path = './?.lua;' .. package.path
local LG = dofile('jf_tracker_logo.lua')
local n, bad = 0, 0
local function eq(name, got, want)
  n = n + 1
  if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end
end
eq('at least ten logos', #LG.LOGOS >= 10, true)
local KNOWN = { [' '] = 1, ['#'] = 1, ['+'] = 1, ['-'] = 1, [':'] = 1, ['_'] = 1, ['╱'] = 1, ['╲'] = 1, ['▀'] = 1, ['▄'] = 1, ['█'] = 1, ['░'] = 1, ['▌'] = 1, ['▐'] = 1, ['▒'] = 1, ['▓'] = 1, ['■'] = 1, ['▬'] = 1, ['·'] = 1, ['.'] = 1, ['═'] = 1 }
local SIZES = { alligator = { 101, 7 }, drip = { 63, 10 }, slant = { 91, 5 }, shade = { 90, 5 }, bloody = { 75, 10 }, rubble = { 98, 12 }, ansi_rust = { 90, 7 }, ansi_small = { 50, 3 }, ansi_stone = { 99, 7 }, ansi_pipes = { 110, 6, ansi_wire = { 81, 6 }, ansi_magenta = { 63, 5 }, ansi_flagbar = { 75, 7 }, ansi_rings = { 71, 7 }, native_blocks = { 103, 5 }, ansi_white = { 88, 6 }, box_dots = { 92, 6 }, ansi_plum = { 95, 7 }, ansi_moss = { 100, 8 }, ansi_jungle = { 87, 8 }, ansi_marquee = { 152, 7 } } }
for _, lg in ipairs(LG.LOGOS) do
  local w, h = LG.size(lg)
  if SIZES[lg.name] then eq(lg.name .. ' size', w .. 'x' .. h, SIZES[lg.name][1] .. 'x' .. SIZES[lg.name][2])
  else eq(lg.name .. ' has size', w > 10 and h > 2, true) end
  local ok, trail = true, false
  for _, row in ipairs(LG.cells(lg)) do
    for _, cell in ipairs(row) do if not (KNOWN[cell.c] or LG.BOX[cell.c]) then ok = false end end
  end
  for _, l in ipairs(lg.lines) do if l:find('%s$') then trail = true end end
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
eq('pick never repeats', same, false); eq('pick covers all', cnt, #LG.LOGOS)
-- ячейка: ужимается под ширину, сохраняет пропорцию; слишком узко — nil
local cw, ch = LG.cell(LG.LOGOS[1], 1000, 8, 16)
eq('cell fits wide', cw, 8); eq('cell aspect', ch, 16)
cw, ch = LG.cell(LG.LOGOS[1], 404, 8, 16)
eq('cell shrinks', cw, 4); eq('cell shrinks h', ch, 8)
eq('cell too narrow', LG.cell(LG.LOGOS[1], 150, 8, 16), nil)
-- раскраска: у каждого логотипа схема, все цвета из палитры
for _, lg in ipairs(LG.LOGOS) do
  local sc, ok = LG.SCHEME[lg.name], true
  if lg.ansi then sc = sc or {} elseif not sc then ok = false else for _, st in ipairs(sc) do if not LG.PAL[st[2]] or (st[3] and not LG.PAL[st[3]]) then ok = false end end end
  eq(lg.name .. ' scheme', ok, true)
end
local rub = LG.LOGOS[6]
local f1 = LG.row_colour(rub, 1); local f3 = LG.row_colour(rub, 3); local f9, s9 = LG.row_colour(rub, 9)
eq('rubble edge lightgrey', f1, LG.PAL.lightgrey); eq('rubble top darkgrey', f3, LG.PAL.darkgrey)
eq('rubble bottom brown', f9, LG.PAL.brown); eq('rubble dither yellow', s9, LG.PAL.yellow)
-- дизеринг: доля горящих точек 1/4, 1/2, 3/4
for c, want in pairs({ ['░'] = 1, ['▒'] = 2, ['▓'] = 3 }) do
  local on = 0
  for x = 0, 1 do for y = 0, 1 do if LG.DITHER[c](x, y) then on = on + 1 end end end
  eq('dither ' .. c, on, want)
end
-- ANSI: коды разобраны, цвета клеток из палитры, фон клетки
local an = LG.cells(LG.LOGOS[7])
eq('ansi first ink cell', an[1][6].c .. an[1][6].fg, '█lightred')
local bgc
for _, cell in ipairs(an[1]) do if cell.bg then bgc = cell.bg; break end end
eq('ansi background parsed', bgc, 'red')
-- отрисовка со стабом gfx не падает
local rects = 0
gfx = { set = function() end, rect = function() rects = rects + 1 end, line = function() end }
for _, lg in ipairs(LG.LOGOS) do LG.draw(lg, 0, 0, 4, 8, { 1, 0.7, 0 }) end
eq('draw makes rects', rects > 500, true)
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
