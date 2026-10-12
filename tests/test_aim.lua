-- test_aim.lua — математика прицела: место в файле на строке курсора, окно инструмента, точка реза,
-- привязки (транзиент, ноль). Запуск: lua tests/test_aim.lua
local DIR = (arg and arg[0] or ''):match('(.*)/tests/') or '.'
local A = dofile(DIR .. '/jf_tracker_aim.lua')
local fails, checks = 0, 0
local function near(name, got, want, eps)
  checks = checks + 1
  if got == nil or math.abs(got - want) > (eps or 1e-9) then fails = fails + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end
end
local function eq(name, got, want)
  checks = checks + 1
  if got ~= want then fails = fails + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end
end

-- строки: 180 BPM, LPB 4 → строка 1/12 с; LPB 12 → 1/36 с
local function row(r, lpb, bpm) return r * 60 / (bpm or 180) / lpb end

-- 1. нота с начала файла, скорость 1, инструмент — весь файл
local n = { pos = 1.0, offs = 0, rate = 1, len = 2 }
local e = { offs = 0, rate = 1 }
near('rate 1: src at the note start', A.src_at(n, 1.0), 0)
near('rate 1: src half a second in', A.src_at(n, 1.5), 0.5)
near('rate 1: e time = src', A.e_time(n, e, 1.5), 0.5)
near('rate 1: back to the project', A.proj_of(n, e, 0.5), 1.5)

-- 2. скорость ноты 1.122 (amen песочницы), инструмент с тем же rate
n = { pos = 0, offs = 0, rate = 1.122, len = 2 }
e = { offs = 0, rate = 1.122 }
near('rate 1.122: row 5 (120 BPM LPB 4) in the window = 0.625 s', A.e_time(n, e, row(5, 4, 120)), 0.625, 1e-9)
near('rate 1.122: +10.5 ms in the window -> project', A.proj_of(n, e, 0.625 + 0.0105), 0.6355, 1e-9)
near('rate 1.122: src of the cut point', A.src_at(n, 0.6355), 0.6355 * 1.122, 1e-9)

-- 3. короткий слайс-инструмент (offs 2.999, len 0.5), нота из другого куска того же файла (offs 2.833)
n = { pos = 1.1667, offs = 2.833, rate = 1, len = 0.1666 }
e = { offs = 2.999, rate = 1 }
local t15 = row(15, 4)
near('other piece: e time is left of the instrument (window reads the file there)', A.e_time(n, e, t15), (2.833 + (t15 - 1.1667)) - 2.999, 1e-9)
eq('other piece: the cursor row is inside the note', A.inside(n, t15), true)
near('other piece: round trip project -> e -> project', A.proj_of(n, e, A.e_time(n, e, t15)), t15, 1e-9)

-- 4. LPB 12: каждая строка — своя точка, шаг строки 1/36 с при rate 1
n = { pos = 0, offs = 3.0, rate = 1, len = 1 }
e = { offs = 3.0, rate = 1 }
for r = 1, 6 do near(('LPB 12 row %d moves the aim by 1/36 s'):format(r), A.e_time(n, e, row(r, 12)), r / 36, 1e-9) end

-- 5. разные скорости ноты и инструмента: точка окна → проект → файл — то же место файла
for _, rr in ipairs({ { 0.5, 1 }, { 2, 1 }, { 1, 0.75 }, { 1.5, 1.25 } }) do
  n = { pos = 0.4, offs = 1.0, rate = rr[1], len = 3 }
  e = { offs = 0.8, rate = rr[2] }
  for _, te in ipairs({ 0.3, 0.71, 1.2345 }) do
    local tp = A.proj_of(n, e, te)
    near(('rates %.2f / %.2f: the file place survives the round trip (te %.4f)'):format(rr[1], rr[2], te), A.src_at(n, tp), e.offs + te * e.rate, 1e-9)
  end
end

-- 6. рез только внутри ноты
n = { pos = 1, offs = 0, rate = 1, len = 0.5 }
eq('inside: the start is not a cut', A.inside(n, 1.0), false)
eq('inside: the end is not a cut', A.inside(n, 1.5), false)
eq('inside: the middle is', A.inside(n, 1.25), true)
eq('ends_at: a note ending on the row top', A.ends_at(n, 1.5), true)
eq('ends_at: not a row in the middle', A.ends_at(n, 1.25), false)

-- 7. t-snap: ближайший транзиент
near('nearest transient', A.nearest({ 0.1, 0.42, 0.755, 1.3 }, 0.625), 0.755)
near('nearest transient (left)', A.nearest({ 0.1, 0.6, 0.755 }, 0.62), 0.6)
eq('nearest: none', A.nearest({}, 0.5), nil)

-- 8. 0-cross: переход через ноль ближайший к середине окна
local s = {}
for i = 1, 100 do s[i] = math.sin((i - 1) / 100 * 2 * math.pi * 3 + 0.4) end   -- три периода, сдвиг
local zi = A.zero_index(s, 100)
eq('zero cross found', zi ~= nil, true)
eq('zero cross: signs differ there', (s[zi - 1] * s[zi]) <= 0, true)
local best = 1e9
for i = 2, 100 do if s[i - 1] * s[i] <= 0 then best = math.min(best, math.abs(i - 51)) end end
eq('zero cross: the one nearest to the middle', math.abs(zi - 51), best)
eq('zero cross: silence counts as zero', A.zero_index({ 0, 0, 0, 0 }, 4) ~= nil, true)
eq('zero cross: none in a positive run', A.zero_index({ 1, 2, 3, 4, 5 }, 5), nil)

print(('%d checks, %d failed'):format(checks, fails))
os.exit(fails == 0 and 0 or 1)
