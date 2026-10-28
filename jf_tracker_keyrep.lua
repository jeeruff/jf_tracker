-- jf_tracker_keyrep.lua — свой автоповтор зажатой клавиши (27 окт; вынесен для тестов tests/test_keyrep.lua).
-- KR.step(c, from_q, env) → код клавиши для кадра. env: { R = reaper API (JS_VKeys_*, time_precise),
-- delay = мс, rate = раз/с, keyq = очередь клавиш трекера, is_note = function(c) → клавиша играет ноту, log = function(msg) }
local KR = {}
KR.ARROW = { [1818584692] = 37, [30064] = 38, [1919379572] = 39, [1685026670] = 40 }
KR.krep, KR.krep_stop = nil, nil
function KR.step(c, from_q, env)
  local reaper = env.R
  local d = env.delay or 250
  if d <= 0 or not reaper.JS_VKeys_GetState then KR.krep = nil; return c end
  local now = reaper.time_precise()
  local R = KR.krep
  local function held(r)
    local up = reaper.JS_VKeys_GetUp and reaper.JS_VKeys_GetUp((r.evt or r.t0) - 0.005)
    local why
    if up and up:byte(r.vk) ~= 0 then why = 'key up'
    else
      local st = reaper.JS_VKeys_GetState(r.t0 - 0.5)
      if st and st:byte(r.vk) ~= 0 then r.up_t = nil; return true end
      r.up_t = r.up_t or now
      if now - r.up_t < 0.5 or (r.evt and now - r.evt < 0.5) then return true end
      why = 'state up 0.5s, no os repeat'
    end
    if env.log then env.log(('stop c=%d vk=%d after %.2fs n=%d (%s)'):format(r.c, r.vk, now - r.t0, r.n or 0, why)) end
    return false
  end
  -- после остановки системные повторы из буфера gfx — не новые нажатия (нет события нажатия с момента остановки)
  local LS = KR.krep_stop
  if c > 0 and not from_q and not R and LS and LS.c == c then
    local dn = reaper.JS_VKeys_GetDown and reaper.JS_VKeys_GetDown(LS.t - 0.005)
    if dn and dn:byte(LS.vk) ~= 0 then KR.krep_stop = nil
    elseif dn or now - LS.t < 1.5 then return 0   -- есть GetDown — ждать настоящего нажатия сколько угодно (буфер бывает длинным)
    else KR.krep_stop = nil end
  end
  if c > 0 and not from_q and R and R.c == c then
    -- новое нажатие — только если было физическое нажатие (KEYDOWN, повторы macOS не считаются) после прошлого
    -- нажатия этой клавиши; иначе это системный повтор из буфера gfx (даже прочитанный уже после отпускания) — поглощён
    local dn = reaper.JS_VKeys_GetDown and reaper.JS_VKeys_GetDown((R.down or R.t0) + 0.001)
    if dn and dn:byte(R.vk) ~= 0 then R = nil; KR.krep = nil
    else
      if not held(R) then KR.krep = nil; KR.krep_stop = { c = R.c, vk = R.vk, t = now }; return 0 end
      R.evt = now; c = 0
    end
  end
  if c > 0 and not from_q then
    -- Enter / Tab / Backspace — свои vk (13 9 8), не Ctrl+M / I / H; Esc — без повтора
    local vk = (c >= 97 and c <= 122) and (c - 32) or ((c >= 65 and c <= 90) or (c >= 48 and c <= 57)) and c
      or ((c == 13 or c == 9 or c == 8) and c) or (c >= 1 and c <= 26) and (c + 64) or KR.ARROW[c]
    if c == 27 then vk = nil end
    local note = env.is_note and env.is_note(c)
    if vk and not note then KR.krep = { c = c, vk = vk, t0 = now, down = now, nxt = now + d / 1000 } else KR.krep = nil end
    KR.krep_stop = nil
    return c
  end
  if R and c <= 0 then
    if not held(R) then
      KR.krep = nil
      KR.krep_stop = { c = R.c, vk = R.vk, t = now }
      local q = env.keyq or {}
      for i = #q, 1, -1 do if q[i] == R.c then table.remove(q, i) end end
      return c
    end
    if now >= R.nxt then
      local step = 1 / math.max(1, env.rate or 30)
      R.nxt = R.nxt + step
      if now >= R.nxt then R.nxt = now + step end   -- без догонялок: медленный кадр не копит шаги
      R.n = (R.n or 0) + 1
      return R.c
    end
  end
  return c
end
return KR
