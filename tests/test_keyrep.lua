-- test_keyrep.lua — свой автоповтор: модель клавиатуры macOS (системные повторы в буфер gfx, кадры разной скорости):
-- lua tests/test_keyrep.lua
local DIR = (arg and arg[0] or ''):match('(.*)/tests/') or '.'
local KR = dofile(DIR .. '/jf_tracker_keyrep.lua')
local fails, checks = 0, 0
local function eq(n, a, b) checks = checks + 1; if a ~= b then fails = fails + 1; print('FAIL ' .. n .. ': ' .. tostring(a) .. ' vs ' .. tostring(b)) end end

-- сценарий: нажатия { {t0, t1} } клавиши vk / кода c; кадр — каждые dt (можно функцию от t: медленные кадры)
local function run(presses, c, vk, dt, T, osrep)
  KR.krep, KR.krep_stop = nil, nil
  local now = 0
  local buf = {}               -- буфер gfx: символы, что ещё не прочитаны
  local events = {}            -- (время, 'down'|'up'|'rep')
  for _, p in ipairs(presses) do
    events[#events + 1] = { p[1], 'down' }
    if osrep then local t = p[1] + 0.25; while t < p[2] do events[#events + 1] = { t, 'rep' }; t = t + 0.033 end end
    events[#events + 1] = { p[2], 'up' }
  end
  table.sort(events, function(a, b) return a[1] < b[1] end)
  local ei = 1
  local function state_at(t) for _, p in ipairs(presses) do if t >= p[1] and t < p[2] then return true end end; return false end
  local function vkstr(on) local t = {}; for i = 1, 255 do t[i] = (on and i == vk) and '\1' or '\0' end; return table.concat(t) end
  local R = {
    time_precise = function() return now end,
    JS_VKeys_GetState = function() return vkstr(state_at(now)) end,
    JS_VKeys_GetUp = function(cut) for _, p in ipairs(presses) do if p[2] > cut and p[2] <= now then return vkstr(true) end end; return vkstr(false) end,
    JS_VKeys_GetDown = function(cut) for _, p in ipairs(presses) do if p[1] > cut and p[1] <= now then return vkstr(true) end end; return vkstr(false) end,
  }
  local keyq = {}
  local env = { R = R, delay = 250, rate = 30, keyq = keyq }
  local moves, after = 0, 0
  local last_up = presses[#presses][2]
  while now < T do
    while ei <= #events and events[ei][1] <= now do
      local e = events[ei]
      if e[2] == 'down' or e[2] == 'rep' then buf[#buf + 1] = c end
      ei = ei + 1
    end
    local ch, fq = 0, false
    if #keyq > 0 then ch = table.remove(keyq, 1); fq = true elseif #buf > 0 then ch = table.remove(buf, 1) end
    local out = KR.step(ch, fq, env)
    if out > 0 then moves = moves + 1; if now > last_up + 0.001 then after = after + 1; if os.getenv("KRDBG") then print("after", now, ch, fq, #buf) end end end
    now = now + (type(dt) == 'function' and dt(now) or dt)
  end
  return moves, after
end
local J, VKJ = 106, 74
-- тапы разной длины: ровно по одному шагу, ничего после отпускания
for _, len in ipairs({ 0.05, 0.12, 0.2, 0.24 }) do
  local pr = {}
  for k = 0, 4 do pr[#pr + 1] = { 0.1 + k * 0.4, 0.1 + k * 0.4 + len } end
  local m, a = run(pr, J, VKJ, 0.03, 3, true)
  eq(('5 taps of %.2fs = 5 moves'):format(len), m, 5)
  eq(('5 taps of %.2fs: nothing after release'):format(len), a, 0)
end
-- удержание 2 с: 1 + (2 - 0.25) * 30 ≈ 53 шага, после отпускания — ни одного (и при медленных кадрах прокрутки)
for _, dt in ipairs({ 0.03, 0.06, 0.12 }) do
  local m, a = run({ { 0.1, 2.1 } }, J, VKJ, dt, 4, true)
  eq(('hold 2s, frame %.2fs: no moves after release'):format(dt), a, 0)
  eq(('hold 2s, frame %.2fs: moves at most 30/s'):format(dt), m <= 55, true)
  eq(('hold 2s, frame %.2fs: keeps going'):format(dt), m >= math.min(50, math.floor(1.75 / dt)), true)
end
-- медленный кадр среди быстрых (прокрутка дорисовывает 0.2 с): буфер копит системные повторы — после отпускания тишина
do
  local m, a = run({ { 0.1, 1.6 } }, J, VKJ, function(t) return (t > 1.4 and t < 1.6) and 0.2 or 0.03 end, 3, true)
  eq('slow frame at release: nothing after release', a, 0)
end
-- быстрые повторные нажатия той же клавиши после удержания — каждое считается
do
  local m = run({ { 0.1, 1.1 }, { 1.3, 1.35 }, { 1.6, 1.65 } }, J, VKJ, 0.03, 2.5, true)
  local hold = run({ { 0.1, 1.1 } }, J, VKJ, 0.03, 2.5, true)
  eq('two taps after a hold = +2', m, hold + 2)
end
-- 30 окт: кадры медленнее системного повтора (45 мс, каждый пятый 90): буфер копит повторы ОС, их читают после
-- отпускания — раньше каждый сдвигал срез GetUp за отпускание, и повтор шёл ещё до 0.5 с (3-5 лишних шагов)
do
  local i = 0
  local slow = function() i = i + 1; return (i % 5 == 0) and 0.09 or 0.045 end
  for _, hold in ipairs({ 0.6, 1.0, 1.7 }) do
    i = 0
    local _, a = run({ { 0.1, 0.1 + hold } }, J, VKJ, slow, 3.5, true)
    eq(('slow frames, hold %.1fs: nothing after release'):format(hold), a, 0)
  end
end
print(('%d checks, %d failed'):format(checks, fails)); os.exit(fails == 0 and 0 or 1)
