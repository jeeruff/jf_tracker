-- test_orca.lua — ядро Orca (чистый Lua): lua tests/test_orca.lua
package.path = './?.lua;' .. package.path
local O = dofile('jf_tracker_orca.lua')
local n, bad = 0, 0
local function eq(name, got, want)
  n = n + 1
  if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end
end
local function field(rows)
  local f = O.new(#rows[1], #rows)
  for y, r in ipairs(rows) do for x = 1, #r do O.set(f, x - 1, y - 1, r:sub(x, x)) end end
  return f
end
local function row(f, y) local t = {}; for x = 0, f.w - 1 do t[#t + 1] = f.cells[y][x] end; return table.concat(t) end

-- base-36, ноты
eq('b36 a', O.b36('a'), 10); eq('b36 Z', O.b36('Z'), 35); eq('b36 .', O.b36('.'), nil)
eq('chr 35 upper', O.chr(35, true), 'Z')
eq('C4 = 60', O.note_pitch('4', 'C'), 60); eq('c4 = C#4', O.note_pitch('4', 'c'), 61)
eq('e = F', O.note_pitch('3', 'e'), 53); eq('b = next C', O.note_pitch('4', 'b'), 72)

-- roundtrip
do local f = field({ '1A2.', '....' }); local g = O.parse(O.serialize(f)); eq('roundtrip', row(g, 0), '1A2.') end

-- арифметика
do local f = field({ '1A2', '...' }); O.tick(f); eq('1A2 -> 3', f.cells[1][1], '3') end
do local f = field({ '5B2', '...' }); O.tick(f); eq('5B2 -> 3', f.cells[1][1], '3') end
do local f = field({ '3M4', '...' }); O.tick(f); eq('3M4 -> c', f.cells[1][1], 'c') end
do local f = field({ '3L4', '...' }); O.tick(f); eq('3L4 -> 3', f.cells[1][1], '3') end
do local f = field({ '1AB', '...' }); O.tick(f); eq('case follows right', f.cells[1][1], 'C') end

-- C clock
do local f = field({ '.C4', '...' }); local seq = {}
  for _ = 1, 6 do O.tick(f); seq[#seq + 1] = f.cells[1][1] end
  eq('C counts mod 4', table.concat(seq), '012301') end
do local f = field({ '2C4', '...' }); local seq = {}
  for _ = 1, 6 do O.tick(f); seq[#seq + 1] = f.cells[1][1] end
  eq('2C4 half speed', table.concat(seq), '001122') end

-- D delay: банг на кадрах 0, 4, 8
do local f = field({ '.D4', '...' }); local seq = {}
  for _ = 1, 9 do O.tick(f); seq[#seq + 1] = f.cells[1][1] == '*' and 'x' or '.' end
  eq('D4 bangs every 4', table.concat(seq), 'x...x...x') end

-- U uclid 3/8
do local f = field({ '3U8', '...' }); local cnt = 0
  for _ = 1, 8 do O.tick(f); if f.cells[1][1] == '*' then cnt = cnt + 1 end end
  eq('U 3/8 -> 3 bangs', cnt, 3) end

-- F if
do local f = field({ '3F3', '...' }); O.tick(f); eq('F equal bangs', f.cells[1][1], '*') end
do local f = field({ '3F4', '...' }); O.tick(f); eq('F not equal', f.cells[1][1], '.') end

-- E mover, взрыв у края
do local f = field({ 'E..' }); O.tick(f); eq('E moves', row(f, 0), '.E.'); O.tick(f); eq('E moves again', row(f, 0), '..E')
  O.tick(f); eq('E explodes at edge', row(f, 0), '..*'); O.tick(f); eq('bang erased', row(f, 0), '...') end

-- строчный оператор без банга молчит
do local f = field({ '1a2', '...' }); O.tick(f); eq('lowercase silent', f.cells[1][1], '.') end
do local f = field({ '.*.', '1a2', '...' }); O.tick(f); eq('lowercase runs on bang', f.cells[2][1], '3') end

-- H halt
do local f = field({ '.H.', '1A2', '...' }); O.tick(f); eq('H halts op below', f.cells[2][1], '.') end

-- I increment
do local f = field({ '1I4', '...' }); local seq = {}
  for _ = 1, 5 do O.tick(f); seq[#seq + 1] = f.cells[1][1] end
  eq('I counts mod 4', table.concat(seq), '12301') end

-- J jumper / Y yumper
do local f = field({ '.5.', '.J.', '...' }); O.tick(f); eq('J passes down', f.cells[2][1], '5') end
do local f = field({ '7Y.' }); O.tick(f); eq('Y passes right', f.cells[0][2], '7') end

-- V variable, K konkat
do local f = field({ 'aV5....', '..Va...', '.......' }); O.tick(f); eq('V write then read', f.cells[2][2], '5') end
do local f = field({ 'aV7..', '1Ka..', '.....' }); O.tick(f); eq('K reads var', f.cells[2][2], '7') end

-- O read, X write
do local f = field({ '10O.9', '.....' }); O.tick(f); eq('O reads offset', f.cells[1][2], '9') end
do local f = field({ '01X5', '....', '....' }); O.tick(f); eq('X writes at offset', f.cells[2][2], '5') end

-- P push, T track, Q query, G generator
do local f = field({ '13P7', '....' }); O.tick(f); eq('P pushes at key%len', f.cells[1][3], '7') end
do local f = field({ '13Tabc', '......' }); O.tick(f); eq('T picks key', f.cells[1][2], 'b') end
do local f = field({ '002Q34', '......' }); O.tick(f); eq('Q copies left of origin', f.cells[1][2] .. f.cells[1][3], '34') end
do local f = field({ '002G9z', '......' }); O.tick(f); eq('G writes below', f.cells[1][3] .. f.cells[1][4], '9z') end

-- R random (подменённый rand)
do O.rand = function() return 0.5 end; local f = field({ '0R8', '...' }); O.tick(f); eq('R with rand 0.5', f.cells[1][1], '4'); O.rand = math.random end

-- Z lerp
do local f = field({ '1Z3', '...' }); O.tick(f); O.tick(f); eq('Z moves toward target', f.cells[1][1], '2') end

-- # комментарий: внутри не исполняется
do local f = field({ '#1A2#', '.....' }); O.tick(f); eq('comment not run', f.cells[1][2], '.') end

-- аргумент-буква не исполняется (заблокирован)
do local f = field({ '.:014C81', '........' }); O.tick(f); eq('C as argument not run', f.cells[1][4], '.') end

-- : посадка по бангу
do local f = field({ 'D1......', '.:014C81', '........' })
  local outs = O.tick(f)
  eq(': fires on bang', #outs, 1)
  eq(': op', outs[1] and outs[1].op, ':')
  eq(': args', outs[1] and table.concat(outs[1].args), '014C81')
  eq(': pitch', O.note_pitch(outs[1].args[3], outs[1].args[4]), 60)
  local outs2 = O.tick(f)
  eq(': fires again next tick (D1)', #outs2, 1)
end
do local f = field({ '.:014C81' }); eq(': without bang silent', #O.tick(f), 0) end
do local f = field({ '*;03' }); local o = O.tick(f); eq('; queue', o[1] and (o[1].op .. table.concat(o[1].args)), ';03') end
do local f = field({ '*=1209' }); local o = O.tick(f); eq('= param', o[1] and (o[1].op .. table.concat(o[1].args)), '=1209') end

-- targets
do local f = field({ '.:214C81', '$3a28...' }); local t = O.targets(f); eq('targets 2', t[2], true); eq('targets 3', t[3], true) end

print(('%d checks, %d failed'):format(n, bad))
