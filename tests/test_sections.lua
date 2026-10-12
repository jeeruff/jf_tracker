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
-- одинаковый по размеру — не секция (дубль)
local _, s5 = S.split({ rg(1, 'verse', 0, 2), rg(2, 'A1', 0, 2) })
eq('same span is not a section', #s5, 0)

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

print(('%d checks, %d failed'):format(checks, fails))
os.exit(fails == 0 and 0 or 1)
