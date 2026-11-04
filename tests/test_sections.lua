-- test_sections.lua — коды паттернов и секции. Запуск: lua tests/test_sections.lua
local DIR = (arg and arg[0] or ''):match('(.*)/tests/') or '.'
local S = dofile(DIR .. '/jf_tracker_sections.lua')
local fails, checks = 0, 0
local function eq(name, got, want)
  checks = checks + 1
  if got ~= want then fails = fails + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end
end
local function rg(idx, name, pos, rgnend) return { idx = idx, name = name, pos = pos, rgnend = rgnend } end

-- коды
local l, n, rest = S.code_of('D12 verse')
eq('code letter', l, 'D'); eq('code number', n, 12); eq('code rest', rest, 'verse')
eq('bare code', select(2, S.code_of('A1')), 1)
eq('not a code: A1b', S.code_of('A1b'), nil)
eq('not a code: lower', S.code_of('a1'), nil)
eq('not a code: word', S.code_of('verse'), nil)
eq('not a code: number', S.code_of('01'), nil)

-- следующее семейство / вариант
local R1 = { rg(1, 'A1', 0, 2), rg(2, 'A2 brk', 2, 4), rg(3, 'C1', 4, 6), rg(4, 'test', 6, 8) }
eq('next family skips used letters', S.next_family(R1), 'B1')
eq('next family empty project', S.next_family({}), 'A1')
eq('clone: next number of the letter', S.next_variant(R1, 'A1'), 'A3')
eq('clone keeps the rest of the name', S.next_variant(R1, 'A2 brk'), 'A3 brk')
eq('clone of C', S.next_variant(R1, 'C1'), 'C2')
eq('clone of an uncoded name: nil (old naming)', S.next_variant(R1, 'test'), nil)
local all = {}
for b = 65, 90 do all[#all + 1] = rg(b, string.char(b) .. '1', b, b + 1) end
eq('all letters used: Z grows', S.next_family(all), 'Z2')

-- деление: verse поверх A1 A2 — секция; test без вложенных — паттерн (старый проект)
local R2 = { rg(10, 'verse', 0, 4), rg(1, 'A1', 0, 2), rg(2, 'A2', 2, 4), rg(3, 'test', 4, 6), rg(4, 'old', 6, 8) }
local pats, secs = S.split(R2)
eq('one section', #secs, 1); eq('section name', secs[1].name, 'verse'); eq('section flag', R2[1].section, true)
eq('patterns: A1 A2 test old', #pats, 4)
eq('uncoded leaf stays a pattern', pats[3].name, 'test')
-- кодированный регион поверх другого — всё равно паттерн
local _, s3 = S.split({ rg(1, 'B1', 0, 4), rg(2, 'x', 0, 2) })
eq('coded region is never a section', #s3, 0)
-- служебные имена
local _, s4 = S.split({ { idx = 1, name = '=SESSION', pos = 0, rgnend = 8, session = true }, rg(2, 'A1', 0, 2) })
eq('session zone is not a section', #s4, 0)
-- 19 окт: одинаковый по размеру поверх паттерна с кодом — секция из одного паттерна (два паттерна в одной точке запрещены)
local _, s5 = S.split({ rg(1, 'verse', 0, 2), rg(2, 'A1', 0, 2) })
eq('same span over a coded pattern: a one-pattern section', #s5, 1)

-- census / resync: A2 вырос на 2 → конец verse за ним
local c = S.census(pats, secs)
eq('census members', #c[1].members, 2)
local P2 = { rg(1, 'A1', 0, 2), rg(2, 'A2', 2, 6), rg(3, 'test', 6, 8), rg(4, 'old', 8, 10) }
local fix = S.resync(c, P2, { rg(10, 'verse', 0, 4) })
eq('resync: one fix', #fix, 1); eq('resync: end follows A2', fix[1] and fix[1].rgnend, 6); eq('resync: start stays', fix[1] and fix[1].pos, 0)
-- первый паттерн удалён → начало секции на втором
fix = S.resync(c, { rg(2, 'A2', 0, 2) }, { rg(10, 'verse', 0, 2) })
eq('resync: nothing to fix when equal', #fix, 0)
fix = S.resync(c, { rg(2, 'A2', 2, 4) }, { rg(10, 'verse', 0, 4) })
eq('resync: first deleted - start on the second', fix[1] and fix[1].pos, 2)
-- всё удалено — секцию не трогаем
fix = S.resync(c, {}, { rg(10, 'verse', 0, 4) })
eq('resync: no members left - untouched', #fix, 0)
-- сдвиг всей песни: края едут вместе
fix = S.resync(c, { rg(1, 'A1', 1, 3), rg(2, 'A2', 3, 5) }, { rg(10, 'verse', 1, 5) })
eq('resync: shifted together - nothing', #fix, 0)

-- hex / dec: два знака по умолчанию, оба вида распознаются
eq('hex code AB = variant 11', select(2, S.code_of('AB')), 11)
eq('hex code AF verse', select(2, S.code_of('AF verse')), 15)
eq('decimal A12 = 12', select(2, S.code_of('A12')), 12)
eq('word ADD is not a code', S.code_of('ADD'), nil)
eq('word FADE is not a code', S.code_of('FADE'), nil)
S.style = 'hex'
local H = { rg(1, 'A1', 0, 1), rg(2, 'A9', 1, 2) }
eq('hex: after A9 comes AA', S.next_variant(H, 'A1'), 'AA')
eq('hex: after AE comes AF', S.next_variant({ rg(1, 'AE', 0, 1) }, 'AE'), 'AF')
eq('hex: after AF - decimal A16', S.next_variant({ rg(1, 'AF', 0, 1) }, 'AF'), 'A16')
S.style = 'dec'
eq('dec: after A9 comes A10', S.next_variant(H, 'A1'), 'A10')
eq('dec: after AB (11) comes A12', S.next_variant({ rg(1, 'AB', 0, 1) }, 'AB'), 'A12')
S.style = 'hex'
-- конвертер
local C = { rg(1, 'A12 x', 0, 1), rg(2, 'AB', 1, 2), rg(3, 'intro', 2, 3), rg(4, 'intro', 3, 4), rg(5, 'B1', 4, 5) }
local m = S.convert(C, 'hex')
eq('to hex: A12 x -> AC x', m['A12 x'], 'AC x'); eq('to hex: AB stays', m['AB'], nil)
m = S.convert(C, 'dec')
eq('to dec: AB -> A11', m['AB'], 'A11'); eq('to dec: B1 stays', m['B1'], nil)
m = S.convert(C, 'codes')
eq('codes: intro gets the next free letter', m['intro'], 'C1 intro')
eq('codes: coded names untouched', m['AB'], nil)
local cnt = 0; for _ in pairs(m) do cnt = cnt + 1 end
eq('codes: aliases (same name) - one code', cnt, 1)

-- 4 ноя: перенумеровать по порядку
do
  local Q = { rg(1, 'A1', 0, 1), rg(2, 'B4 x', 1, 2), rg(3, 'C2', 2, 3), rg(7, '', 3, 4), rg(5, 'D7', 4, 5), rg(6, 'B4 x', 5, 6), rg(8, 'C3', 6, 7), rg(9, 'intro', 7, 8) }
  local m = S.renumber(Q)
  eq('renumber: A1 stays', m[1], nil); eq('renumber: B4 x -> B1 x', m[2], 'B1 x'); eq('renumber: C2 -> C1', m[3], 'C1')
  eq('renumber: unnamed -> D1', m[7], 'D1'); eq('renumber: D7 -> E1', m[5], 'E1'); eq('renumber: repeat B4 x -> B1 x', m[6], 'B1 x')
  eq('renumber: C3 -> C2 (same family)', m[8], 'C2'); eq('renumber: intro -> F1 intro', m[9], 'F1 intro')
  local big = {}
  for k = 1, 28 do big[k] = rg(k, '', k, k + 1) end
  local mb = S.renumber(big)
  eq('renumber: 26th -> Z1', mb[26], 'Z1'); eq('renumber: 27th -> Z2', mb[27], 'Z2'); eq('renumber: 28th -> Z3', mb[28], 'Z3')
end

-- 17 окт: сценарии вечера — секция drop над A1..D1 (:section drop), вставка A2..D2 за ней, зона session
do
  local R2 = { rg(1, 'A1', 0, 1), rg(2, 'B1', 1, 2), rg(3, 'C1', 2, 3), rg(4, 'D1', 3, 4), rg(6, 'drop', 0, 4), rg(5, '=SESSION', 4.3, 8) }
  R2[6].session = true
  local pats, secs = S.split(R2)
  eq(':section drop - a section', #secs, 1); eq('section name', secs[1] and secs[1].name, 'drop')
  eq('patterns stay slots (4 + session)', #pats, 5)
  eq('=SESSION is never a section', R2[6].section, nil)
  eq(':section with a code is refused (A1 verse is a pattern code)', S.code_of('A1 verse') ~= nil, true)
  eq(':section drop has no code', S.code_of('drop'), nil)
  -- вставка A2..D2 после секции: края секции не растут (новые паттерны не её)
  local cen = S.census(pats, secs)
  local R3 = { rg(1, 'A1', 0, 1), rg(2, 'B1', 1, 2), rg(3, 'C1', 2, 3), rg(4, 'D1', 3, 4), rg(6, 'drop', 0, 4),
               rg(7, 'A2', 4, 5), rg(8, 'B2', 5, 6), rg(9, 'C2', 6, 7), rg(10, 'D2', 7, 8) }
  local p3, s3 = S.split(R3)
  eq('after paste: still one section', #s3, 1)
  eq('after paste: no section edge fix', #S.resync(cen, p3, s3), 0)
  -- удалили D1 из секции — её конец подтягивается к C1
  local R4 = { rg(1, 'A1', 0, 1), rg(2, 'B1', 1, 2), rg(3, 'C1', 2, 3), rg(6, 'drop', 0, 4) }
  local p4, s4 = S.split(R4)
  local fx = S.resync(cen, p4, s4)
  eq('slot deleted: the section shrinks to its patterns', fx[1] and fx[1].rgnend, 3)
  -- стопка двух C1 в одном месте (баг :unstack) — оба паттерны, не секции
  local R5 = { rg(1, 'C1', 2, 3), rg(2, 'C1', 2, 3) }
  local p5, s5 = S.split(R5)
  eq('stacked C1: not a section', #s5, 0); eq('stacked C1: two slots', #p5, 2)
  -- 19 окт: секция ровно в один паттерн — секция, паттерн — слот
  local R6 = { rg(1, 'C2', 8, 9), rg(2, 'breakdown', 8, 9) }
  local p6, s6 = S.split(R6)
  eq('one-pattern section: a section', #s6, 1); eq('…the pattern is the slot', p6[1] and p6[1].name, 'C2')
end

print(('%d checks, %d failed'):format(checks, fails))
os.exit(fails == 0 and 0 or 1)
