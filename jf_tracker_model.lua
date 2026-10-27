-- jf_tracker_model.lua — снимок проекта REAPER в трекерных строках.
--
-- Единственный модуль трекера, который ЧИТАЕТ reaper.*. Не пишет ничего:
-- трекер — вид таймлайна, а не движок (см. README). Все reaper.* тут — Get*.
--
-- Модель строится по всему проекту в абсолютных строках (строка 0 = QN 0),
-- сетка задаётся LPB (строк на четверть). Вид потом берёт срез. Строка —
-- только масштаб отображения: смена LPB ничего в проекте не меняет.
--
-- Кеш: снимок пересобирается при смене GetProjectStateChangeCount, LPB или
-- хеша MIDI (MIDI_GetTrackHash по трекам, опрос 4 Гц: правка нот в
-- MIDI-редакторе не всегда двигает счётчик состояния проекта).
--
-- Регионы (этап 3): EnumProjectMarkers3 в 7.81 помечен discouraged —
-- брать GetNumRegionsOrMarkers / GetRegionOrMarker / GetSetRegionOrMarkerInfo_String.

local M = {}
local R = reaper

M.DEPOT = 'LIB'          -- 8 окт: библиотека — заглушённый трек LIB (fixed lanes: инструмент — свой лейн с нуля); в колонках не показываем
M.LIB_NAMES = { LIB = true, DEPOT = true }   -- DEPOT — старое имя того же трека
function M.is_lib_name(name) return M.LIB_NAMES[name or ''] == true end
M.BASE_NOTE = 60         -- «C-4 = оригинал»: MIDI 60 показываем как C-4
M.MAX_UNROLL = 256       -- предел разворота зацикленного MIDI-item (повторов)

-- ── ноты и числа ──────────────────────────────────────────────────────────
local NAMES = { 'C-', 'C#', 'D-', 'D#', 'E-', 'F-', 'F#', 'G-', 'G#', 'A-', 'A#', 'B-' }

-- имя ноты трекера от MIDI-номера: 60 → C-4, 61 → C#4, 48 → C-3
function M.note_name(n)
  n = math.floor(n + 0.5)
  -- научная нотация: 60 → 4; BASE_NOTE=60 даёт «C-4 = оригинал»
  local o = math.floor(n / 12) - 1
  if o < 0 then o = 0 elseif o > 9 then o = 9 end
  return NAMES[n % 12 + 1] .. tostring(o)
end

-- 16 окт: микротоны — 72-EDO, ступень ^ / v = 1/6 тона (16.7 ц); m = −3..+3 ступени от ноты 12-EDO.
-- Метка после октавы: C-4^ C-4^^ C-4^3, вниз — v (буквами, без значков); 0 — пусто
M.MICRO_STEP = 100 / 6
function M.micro_of_cents(c) local m = math.floor((c or 0) / M.MICRO_STEP + 0.5); if m == 0 then return nil end; return math.max(-3, math.min(3, m)) end
function M.micro_tag(m)
  if not m or m == 0 then return '' end
  local a = math.abs(m)
  return (m > 0 and '^' or 'v') .. (a == 2 and (m > 0 and '^' or 'v') or (a == 3 and '3' or ''))
end
-- MTS: real-time single note tuning change (F0 7F 7F 08 02 prog n [kk xx yy zz] F7); центы ноты kk
function M.mts_bytes(key, cents)
  local c = math.max(0, math.min(12799.99, cents))
  local xx = math.floor(c / 100)
  local fr = math.floor((c - xx * 100) / 100 * 16384 + 0.5); if fr > 16383 then fr = 16383 end
  return string.char(0xF0, 0x7F, 0x7F, 0x08, 0x02, 0x00, 0x01, key & 0x7F, xx, fr >> 7, fr & 0x7F, 0xF7)
end
function M.mts_parse(msg)
  local b = { msg:byte(1, -1) }
  local i = (b[1] == 0xF0) and 2 or 1
  if b[i] ~= 0x7F or b[i + 2] ~= 0x08 or b[i + 3] ~= 0x02 then return nil end
  local n = b[i + 5] or 0
  local out = {}
  for k = 0, n - 1 do
    local j = i + 6 + k * 4
    local kk, xx, yy, zz = b[j], b[j + 1], b[j + 2], b[j + 3]
    if not zz then break end
    out[kk] = xx * 100 + ((yy << 7) | zz) / 16384 * 100 - kk * 100   -- центы от 12-EDO ноты kk
  end
  return out
end

-- две hex-цифры, 0..255
function M.hex2(v)
  v = math.floor(v + 0.5)
  if v < 0 then v = 0 elseif v > 255 then v = 255 end
  return string.format('%02X', v)
end

-- строка и доля строки (xx/256) от позиции в QN
function M.row_of_qn(qn, lpb)
  local x = qn * lpb
  -- 23 окт: допуск в 1/50 строки — округление PPQ (1024 отсчёта на четверть: строка LPB 12 = 85⅓) ставило ноту
  -- на 541.992 вместо 542: она показывалась строкой раньше, в чужой подколонке
  local row = math.floor(x + 0.02)
  local frac = x - row
  if frac < 0 then frac = 0 end
  local d = math.floor(frac * 256 + 0.5)
  if d >= 256 then row, d = row + 1, 0 end
  return row, d
end

-- полутоны от аудио-take: pitch shift (D_PITCH) либо resample (rate при
-- выключенном preserve pitch). Оба сразу — суммируем, так и звучит.
function M.take_semitones(pitch, rate, ppitch)
  local s = pitch or 0
  if not ppitch and rate and rate > 0 and math.abs(rate - 1) > 1e-9 then
    s = s + 12 * math.log(rate, 2)
  end
  return s
end

-- громкость take*item (линейная) → hex, 0x80 = 0 dB (как в Renoise)
function M.vol_hex(vol)
  return M.hex2((vol or 1) * 128)
end

-- ── разбор MIDI ───────────────────────────────────────────────────────────
-- Поток MIDI_GetAllEvts: события подряд, каждое <offset:i4><flag:u8><msg:s4>,
-- offset — в PPQ от предыдущего события. flag &1 selected, &2 muted.
-- Возвращает ноты {ppq, ppq_end, pitch, vel, ch, muted} в порядке потока.
function M.parse_midi(buf)
  local notes, active = {}, {}
  local soff = nil   -- 19 окт: 0Sxx нот кита — notation-событие «NOTE ch pitch text jf_soff=XX» у ноты
  local tune
  local pos, ppq = 1, 0
  local n = #buf
  while pos <= n do
    local ok, offset, flag, msg, np = pcall(string.unpack, '<i4Bs4', buf, pos)
    if not ok then break end
    pos = np
    ppq = ppq + offset
    if #msg >= 3 then
      local b1 = msg:byte(1)
      local st, ch = b1 & 0xF0, b1 & 0x0F
      local pitch, vel = msg:byte(2), msg:byte(3)
      local key = ch * 128 + pitch
      if b1 == 0xFF and msg:byte(2) == 0x0F then
        local nch, np2, xx = msg:match('^..NOTE (%d+) (%d+) .-jf_soff=(%x%x)')
        if nch then soff = soff or {}; soff[#soff + 1] = { ppq = ppq, key = tonumber(nch) * 128 + tonumber(np2), xx = tonumber(xx, 16) } end
        -- 26 окт: команды ноты slixer — «NOTE ch pitch text jf_nx=0S80,0P40» (CC 102..108 трекер строит по ним)
        local xch, xp, xs = msg:match('^..NOTE (%d+) (%d+) .-jf_nx=([%w,]+)')
        if xch then soff = soff or {}; soff[#soff + 1] = { ppq = ppq, key = tonumber(xch) * 128 + tonumber(xp), nx = xs } end
      elseif b1 == 0xF0 then   -- 16 окт: MTS — подстройка следующих нот этой клавиши
        local t = M.mts_parse(msg)
        if t then tune = tune or {}; for kk, c in pairs(t) do tune[kk] = { ppq = ppq, c = c } end end
      elseif st == 0x90 and vel > 0 then
        -- две ноты одной высоты на одном канале одновременно невозможны:
        -- повторный note-on закрывает предыдущую
        local a = active[key]
        if a then a.ppq_end = ppq; notes[#notes + 1] = a end
        local tu = tune and tune[pitch]
        active[key] = { ppq = ppq, pitch = pitch, vel = vel, ch = ch, muted = (flag & 2) == 2, cents = tu and tu.ppq >= ppq - 4 and tu.c or nil }
      elseif st == 0x80 or (st == 0x90 and vel == 0) then
        local a = active[key]
        if a then a.ppq_end = ppq; a.rel = st == 0x80 and vel or 0; notes[#notes + 1] = a; active[key] = nil end   -- 24 окт: rel 1 — явный OFF трекера
      end
    end
  end
  for _, a in pairs(active) do a.ppq_end = ppq; notes[#notes + 1] = a end
  if soff then
    for _, nt in ipairs(notes) do
      local k = nt.ch * 128 + nt.pitch
      for _, so in ipairs(soff) do if so.key == k and math.abs(so.ppq - nt.ppq) <= 60 then if so.nx then nt.nx = so.nx else nt.soff = so.xx end end end
    end
  end
  table.sort(notes, function(a, b)
    if a.ppq ~= b.ppq then return a.ppq < b.ppq end
    return a.pitch < b.pitch
  end)
  return notes
end

-- ── раскладка по подколонкам ──────────────────────────────────────────────
-- Lane = список подколонок (sub); sub = карта строка → ячейка. Нота занимает
-- строки [r0, r1] в первой подколонке, где они свободны. Это и полифония
-- MIDI, и перекрывающиеся items на одном треке — один механизм.
-- 9 окт: стык внутри строки (свинг / задержка) — хвост item, кончающийся
-- на end_d/256 строки, не занимает её для головы с задержкой ≥ end_d (иначе
-- обрубленный item уносил следующую ноту в соседнюю подколонку). d0 — задержка
-- головы, e1 — где в строке r1 кончается событие (nil — до конца строки)
local function sub_free(sub, r0, r1, d0, e1)
  for r = r0, r1 do
    local c = sub[r]
    if c then
      local ok = (r == r0 and d0 and c.end_d and c.end_d <= d0)
              or (r == r1 and e1 and c.kind ~= 'cont' and (c.delay or 0) >= e1)
              -- 24 окт: OFF прошлой ноты в строке, где начинается новая (конец = начало), — место новой ноты, как
              -- в трекере (новая нота обрывает прошлую); было: новая уезжала в соседнюю подколонку, и OFF курсором
              -- в первой её не находил («OFF игнорирует»)
              or (r == r0 and c.kind == 'off' and (c.delay or 0) <= (d0 or 0))
      if not ok then return false end
    end
  end
  return true
end

-- 12 окт: команды «до отмены» (как в Furnace) — род: до следующей того же рода, 00 — стоп.
-- run = { [род] = токен }; на строке — то, что действует, кроме родов, записанных в ней самой
M.RUN_KIND = { ['0U'] = 1, ['0D'] = 1, ['0V'] = 2, ['0A'] = 3, ['0I'] = 4, ['0O'] = 4, ['0R'] = 5 }
local function run_put(run, list)
  for _, t in ipairs(list or {}) do
    local k = M.RUN_KIND[t:sub(1, 2)]
    if k then if t:sub(3, 4) == '00' then run[k] = nil else run[k] = t end end
  end
end
function M.run_start(fx, rf)
  if not rf and (not fx or #fx == 0) then return nil end
  local run = {}
  run_put(run, fx)
  return run
end
function M.run_step(run, own)
  local mine = {}
  for _, t in ipairs(own or {}) do local k = M.RUN_KIND[t:sub(1, 2)]; if k then mine[k] = true end end
  run_put(run, own)
  local out
  for k = 1, 5 do if run[k] and not mine[k] then out = out or {}; out[#out + 1] = run[k] end end
  return out
end

-- 19 окт: fold (опция) — быстрая MIDI-нота в строку, которой нет свободной подколонки, не плодит лейн: ложится
-- в ячейку строки списком cell.fold (рисуется линией в своё время внутри строки); зумом (LPB) — своей строкой
M.FOLD = false
-- 20 окт: take FX у ноты — значок fx рядом с нотой; лейн с такими нотами получает под него место (lane.has_tfx)
M.tfx_memo = {}
local function place(lane, r0, r1, head, cont, tail, e1)
  if r1 < r0 then r1 = r0; e1 = nil end
  if head.take and R and R.TakeFX_GetCount then
    local n = M.tfx_memo[head.take]
    if n == nil then n = R.TakeFX_GetCount(head.take) or 0; M.tfx_memo[head.take] = n end
    if n > 0 then head.tfx = true; lane.has_tfx = true end
  end
  local sub
  for _, s in ipairs(lane.subs) do
    if sub_free(s, r0, r1, head.delay, e1) then sub = s; break end
  end
  if not sub and M.FOLD and r1 == r0 and head.kind == 'midi' and lane.subs[1] then
    for _, s in ipairs(lane.subs) do
      local c = s[r0]
      if c then c.fold = c.fold or {}; c.fold[#c.fold + 1] = head; head.rows = 1; head.folded = true; lane.has_fold = true; return s end   -- 20 окт: has_fold — колонка +N только этому лейну
    end
  end
  if not sub then sub = {}; lane.subs[#lane.subs + 1] = sub end
  sub[r0] = head
  local rf = head.rowfx                -- 12 окт: команды своих строк внутри ноты
  local run = M.run_start(head.fx, rf) -- 12 окт: действующие команды (бледно на строках, где своей нет)
  for r = r0 + 1, r1 - 1 do sub[r] = { kind = 'cont', of = head, i = r - r0, fx = rf and rf[r - r0] }; if run then sub[r].run = M.run_step(run, sub[r].fx) end end
  if r1 > r0 and not (sub[r1] and sub[r1].kind ~= 'cont') then
    sub[r1] = tail or { kind = 'cont', of = head, i = r1 - r0, fx = rf and rf[r1 - r0] }
    if run and sub[r1].kind == 'cont' then sub[r1].run = M.run_step(run, sub[r1].fx) end
    if e1 then sub[r1].end_d = e1 end
  end
  head.rows = r1 - r0 + 1
  if lane.last_row == nil or r1 > lane.last_row then lane.last_row = r1 end
  for i, s in ipairs(lane.subs) do
    if s == sub then
      -- подколонка с аудио — полной ширины; только MIDI-ноты — узкая
      -- «нота + velocity» (2 окт: аккорд не раздувается в лейны)
      if head.kind == 'audio' then lane.audio_sub = lane.audio_sub or {}; lane.audio_sub[i] = true end
      return sub, i
    end
  end
  return sub
end
M._place = place

-- Колонки команд аудио-item (этап 5, пока только показ): двухсимвольные коды
-- Renoise (12 окт), значения из свойств item/take, доли — от строки. Только
-- не-дефолтные. Свойства самого сэмпла (в Renoise — настройки сэмпла) — на S:
--   0Sxx слайс (P_EXT:jf_slice) / смещение xx/256 источника   0Pxx pan (80 = центр)
--   SIxx / SOxx fade in/out (строки × 16, >20 мс)   SL00 loop source ВЫКЛ
--   SM0x канал   SBxx beatsync на xx строк   SFxx подстройка в центах (80 = 0)
function M.audio_fx(it, take, src, lpb, qn0, qn1, pitch, rate, ppitch)
  local fx = {}
  if not take then return fx end
  local offs = R.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS')
  -- слайс (P_EXT:jf_slice): Sxx = номер слайса в исходнике (3 окт) — инструмент
  -- один, номер у ноты общий, а какой кусок — эта команда
  local _, slk = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slice', '', false)
  slk = tonumber(slk)
  -- слайс (4 окт, вечер): номер — командой Sxx (hex, как в Renoise); нота — высота
  -- 13 окт: номер слайса — своё поле ячейки (Sxx); командой 0S не дублируется
  if slk then offs = 0 end
  if offs > 1e-6 and src then
    local slen = R.GetMediaSourceLength(src)
    -- смещение — Sxx, как в Renoise (3 окт; ввод 9xx тоже понимается): xx/256 источника
    if slen and slen > 0 then fx[#fx + 1] = '0S' .. M.hex2(offs / slen * 256) end
  end
  local pan = R.GetMediaItemTakeInfo_Value(take, 'D_PAN')
  if math.abs(pan) > 1e-6 and not M.PANCOL then fx[#fx + 1] = '0P' .. M.hex2((pan + 1) / 2 * 255) end
  local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
  local len = R.GetMediaItemInfo_Value(it, 'D_LENGTH')
  -- штатные фейды REAPER (10 мс) — не команда, а шум: порог 20 мс
  local fi = R.GetMediaItemInfo_Value(it, 'D_FADEINLEN')
  if fi > 0.02 then fx[#fx + 1] = 'SI' .. M.hex2((R.TimeMap2_timeToQN(0, pos + fi) - qn0) * lpb * 16) end
  local fo = R.GetMediaItemInfo_Value(it, 'D_FADEOUTLEN')
  if fo > 0.02 then fx[#fx + 1] = 'SO' .. M.hex2((qn1 - R.TimeMap2_timeToQN(0, pos + len - fo)) * lpb * 16) end
  -- loop source в REAPER включён по умолчанию — показываем только ВЫКЛЮЧЕННЫЙ
  -- 13 окт: голова ноты с лупом удержания — B_LOOPSRC снят нарочно (P_EXT:jf_sushead), не показываем
  if not slk and R.GetMediaItemInfo_Value(it, 'B_LOOPSRC') ~= 1 then fx[#fx + 1] = 'SL00' end   -- 13 окт: у слайса луп выкл — норма, не показывать
  local cm = R.GetMediaItemTakeInfo_Value(take, 'I_CHANMODE')
  if cm and cm ~= 0 then fx[#fx + 1] = 'SM' .. M.hex2(math.floor(cm)) end
  -- слайс (P_EXT:jf_slice) командой не показывается (2 окт): как в Renoise,
  -- ячейка — нота и номер инструмента, а у каждого слайса свой номер в пуле
  if not slk and ppitch and rate and math.abs(rate - 1) > 1e-9 then fx[#fx + 1] = 'SB' .. M.hex2((qn1 - qn0) * lpb) end
  if not slk and pitch and math.abs(pitch - math.floor(pitch + 0.5)) > 0.005 then fx[#fx + 1] = 'SF' .. M.hex2(128 + (pitch - math.floor(pitch + 0.5)) * 100) end
  -- команды-огибающие и генераторы (P_EXT:jf_cmds) — как записаны
  -- 12 окт: токен со смещением (0U08@0.75, четверти от начала ноты) — команда своей строки: rowfx[строка от головы]
  local _, cm = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_cmds', '', false)
  local rowfx
  if cm and cm ~= '' then
    for tok in cm:gmatch('[^,]+') do
      local t0, off = tok:match('^(%w%w%x%x)@([%d%.]+)$')
      if t0 then
        local r = math.floor(tonumber(off) * lpb + 0.5)
        if r <= 0 then fx[#fx + 1] = t0
        else rowfx = rowfx or {}; rowfx[r] = rowfx[r] or {}; table.insert(rowfx[r], t0) end
      else fx[#fx + 1] = tok end
    end
  end
  return fx, rowfx
end

-- Аудио-item: голова в строке старта, «|» до предпоследней строки конца.
-- Конец item, попавший ровно на границу строки, эту строку не занимает.
-- длина источника для периода лупа: секция (PCM_Source_GetSectionInfo), иначе файл
function M.src_period(src)
  if not src then return 0 end
  if R.PCM_Source_GetSectionInfo then
    local ok, _, slen = R.PCM_Source_GetSectionInfo(src)
    if ok and slen and slen > 0 then return slen end
  end
  return R.GetMediaSourceLength(M.online_src(src) or src) or 0
end

-- 27 окт: высота сэмпла из take-маркера :pitch (свой цвет): «A3», «C#4-12» (центы) или аккорд «Am» (корень в
-- 4-й октаве); маркер — тот, что на начале проигрываемого куска (или первый внутри него). → MIDI-высота с центами
function M.pitch_mk_color() M.PITCH_MK_COLOR = M.PITCH_MK_COLOR or (R.ColorToNative(230, 150, 60) | 0x1000000); return M.PITCH_MK_COLOR end
local PCS = { C = 0, D = 2, E = 4, F = 5, G = 7, A = 9, B = 11 }
function M.marker_root(take, offs, rate, len)
  local n = R.GetNumTakeMarkers and R.GetNumTakeMarkers(take) or 0
  if type(n) ~= 'number' or n == 0 then return nil end
  M.pitch_mk_color()
  local best, bp, first, fp
  for i = 0, n - 1 do
    local sp, nm, col = R.GetTakeMarker(take, i)
    if col == M.PITCH_MK_COLOR and nm then
      if sp <= offs + 0.005 and (not bp or sp > bp) then best, bp = nm, sp end
      if sp > offs and sp < offs + len * rate and (not fp or sp < fp) then first, fp = nm, sp end
    end
  end
  local nm = best or first
  if not nm then return nil end
  local l, acc, rest = nm:match('^([A-G])([#b]?)(.*)$')
  if not l then return nil end
  local pc = PCS[l] + (acc == '#' and 1 or (acc == 'b' and -1 or 0))
  local oct, cents = rest:match('^(%-?%d+)([%+%-]%d+)$')
  if not oct then oct = rest:match('^(%-?%d+)$') end
  if oct then return pc + (tonumber(oct) + 1) * 12 + (tonumber(cents) or 0) / 100 end
  return pc % 12 + 60                                   -- аккорд: корень
end

local function place_audio(lane, lpb, it, take, qn0, qn1)
  local r0, d0 = M.row_of_qn(qn0, lpb)
  local r1, d1 = M.row_of_qn(qn1, lpb)
  if d1 == 0 then r1 = r1 - 1 end
  local src = take and R.GetMediaItemTake_Source(take)
  local pitch = take and R.GetMediaItemTakeInfo_Value(take, 'D_PITCH') or 0
  local rate = take and R.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE') or 1
  local ppitch = take and R.GetMediaItemTakeInfo_Value(take, 'B_PPITCH') == 1
  local semis = M.take_semitones(pitch, rate, ppitch)
  local vol = R.GetMediaItemInfo_Value(it, 'D_VOL') * (take and R.GetMediaItemTakeInfo_Value(take, 'D_VOL') or 1)
  local head = {
    kind = 'audio', item = it, take = take, src = src,
    name = take and R.GetTakeName(take) or '',
    -- слайс = нота (4 окт): слайс k — нота C-4 + k - 1, питч — командой Pxx
    -- нота = высота (4 окт, вечер): «слайс = нота» не давал показать питч
    -- слайса — номер слайса снова командой Sxx, нота — C-4 + полутона
    note = M.note_name(M.BASE_NOTE + semis),
    micro = M.micro_of_cents((pitch - math.floor(pitch + 0.5)) * 100),   -- 16 окт: микротон айтема — дробь D_PITCH
    frac = math.abs(semis - math.floor(semis + 0.5)) > 0.01,   -- дробный питч
    semis = semis,
    vol = M.vol_hex(vol),
    pan = (function() local p = take and R.GetMediaItemTakeInfo_Value(take, 'D_PAN') or 0; return math.abs(p) > 1e-6 and M.hex2((p + 1) / 2 * 255) or nil end)(),   -- 14 окт: колонка пана
    delay = d0,
    muted = R.GetMediaItemInfo_Value(it, 'B_MUTE_ACTUAL') == 1,
    offs = take and R.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0,
    rate = rate,
    len = R.GetMediaItemInfo_Value(it, 'D_LENGTH'),
    guid = R.BR_GetMediaItemGUID and R.BR_GetMediaItemGUID(it) or tostring(it),
    row0 = r0,
    rows_f = (qn1 - qn0) * lpb,          -- точная длина в строках (дробная) — волна строго в границах item
    smk = nil, smk_src = nil,            -- stretch-маркеры: доли длины item, и откуда удар (ниже)
    smap = nil, smap_sig = nil,          -- карта маркеров для волны (ниже)
    start_f = d0 / 256,                  -- дробное начало внутри первой строки
  }
  head.fx, head.rowfx = M.audio_fx(it, take, src, lpb, qn0, qn1, pitch, rate, ppitch)
  -- 27 окт: у сэмпла есть маркер высоты (:pitch) — нота = как звучит (маркер + транспоз), не транспоз от C-4
  local mroot = take and M.marker_root(take, head.offs, rate > 0 and rate or 1, head.len)
  if mroot then
    local abs = mroot + semis
    head.mroot, head.semis = mroot, abs - M.BASE_NOTE
    head.note = M.note_name(math.floor(abs + 0.5))
    head.micro = M.micro_of_cents((abs - math.floor(abs + 0.5)) * 100)
    head.frac = false
  end
  if head.micro then M.seen_micro = true end
  do local _, sk = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slice', '', false); head.slice = tonumber(sk) end   -- 11 окт: номер слайса — поле в ячейке
  do local _, gh = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_ghost', '', false); head.ghost = (gh ~= nil and gh ~= '') or nil end   -- 15 окт: ghost-слайс playthru + q (рисуется бледно)
  head.rgb = M.item_rgb(it)
  -- видео-лейн (9 окт): видео-item — событие как аудио (фейды Ixx / Oxx
  -- REAPER применяет и к картинке), в поле ноты — VID
  if src and R.GetMediaSourceType then
    local ps = R.GetMediaSourceParent and R.GetMediaSourceParent(src) or nil
    head.video = R.GetMediaSourceType(ps or src, ''):upper():find('VIDEO', 1, true) ~= nil
  end
  head.smap, head.smap_sig = M.stretch_map(take)
  head.smk, head.smk_src = M.stretch_fracs(take, R.GetMediaItemInfo_Value(it, 'D_LENGTH'))   -- 16 окт: два значения (and режет)
  -- луп (B_LOOPSRC): период в строках и первая граница (offset укорачивает первый проход)
  if src and R.GetMediaItemInfo_Value(it, 'B_LOOPSRC') == 1 then
    local slen = M.src_period(src)
    local r = rate > 0 and rate or 1
    local per = slen / r
    local first = math.max(0, slen - head.offs) / r
    -- stretch-маркеры (5 окт): шов там, где источник доходит до конца по карте
    -- маркеров, а не длина / rate — иначе шов стоял ровно на такте, а в REAPER раньше
    if head.smap then
      local t_end = M.item_time_of_src(head.smap, slen / r)
      local t_beg = M.item_time_of_src(head.smap, head.offs / r)
      if t_end and t_beg and t_end > t_beg + 1e-4 then first = t_end; per = t_end - t_beg end
    end
    if per > 1e-4 and per < head.len - 1e-4 then
      local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
      head.loop_rows = (R.TimeMap2_timeToQN(0, pos + per) - qn0) * lpb
      head.loop_first = (R.TimeMap2_timeToQN(0, pos + first) - qn0) * lpb
      head.loop_src = slen                     -- период в секундах источника (волна лупа — по модулю)
    end
  end
  do local _, g = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_gen', '', false); head.gen = (g ~= nil and g ~= '') or nil end
  local _, si = place(lane, r0, r1, head, nil, nil, d1 > 0 and d1 or nil)
  -- огибающая громкости take (5 окт): точки — значениями в колонке vol на
  -- строках продолжения (кроссфейд и ручные рампы видны числами, как в Renoise)
  local env = take and R.GetTakeEnvelopeByName(take, 'Volume')
  local npt = env and R.CountEnvelopePoints(env) or 0
  if npt > 0 then
    local sub = lane.subs[si]
    local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
    local mode = R.GetEnvelopeScalingMode(env)
    local base = R.GetMediaItemInfo_Value(it, 'D_VOL') * R.GetMediaItemTakeInfo_Value(take, 'D_VOL')
    local r = rate > 0 and rate or 1
    for i = 0, npt - 1 do
      local _, t, v = R.GetEnvelopePoint(env, i)
      local row = M.row_of_qn(R.TimeMap2_timeToQN(0, pos + t / r), lpb)
      local cell = sub and sub[row]
      -- 9 окт: служебные точки x-fade (пара точек у самого края item: громкость
      -- и ноль) не показываются: «00» / «80» мешали и сбивали w / y3w
      local tl, ilen = t / r, R.GetMediaItemInfo_Value(it, 'D_LENGTH')
      local edge_zero = tl <= 0.06 or tl >= ilen - 0.06   -- точки x-fade — у самого края item (≤ 60 мс)
      if cell and cell.kind == 'cont' and cell.of == head and not edge_zero then
        cell.vol = M.vol_hex(base * R.ScaleFromEnvelopeMode(mode, v))
      end
    end
  end
  return si, head
end

-- MIDI-item: ноты take → ячейки. Зацикленный item (B_LOOPSRC) разворачиваем:
-- ноты повторяются через длину источника (в QN), пока не кончится item.
local midi_n = 0   -- 20 окт: записей в кэше MIDI (сброс на 4000)
local function place_midi(lane, lpb, it, take, qn0, qn1, midi_cache)
  local guid = R.BR_GetMediaItemTakeGUID and R.BR_GetMediaItemTakeGUID(take) or tostring(take)
  local _, hash = R.MIDI_GetHash(take, false, '')
  -- 20 окт: и где тейк на таймлайне (QN двух точек: позиция / offset / rate / темп) — хеш MIDI сдвиг item не меняет:
  -- сдвинутый клип (вставка строки) отдавал ноты со старыми QN, они оказывались до начала item и пропадали
  local key = guid .. '|' .. tostring(hash) .. ('|%.6f|%.6f'):format(R.MIDI_GetProjQNFromPPQPos(take, 0), R.MIDI_GetProjQNFromPPQPos(take, 9600))
  local notes = midi_cache[key]
  if not notes then
    local ok, buf = R.MIDI_GetAllEvts(take, '')
    notes = ok and M.parse_midi(buf) or {}
    -- позиции нот — сразу в QN проекта (учитывает позицию item и offset)
    for _, nt in ipairs(notes) do
      nt.qn = R.MIDI_GetProjQNFromPPQPos(take, nt.ppq)
      nt.qn_end = R.MIDI_GetProjQNFromPPQPos(take, nt.ppq_end)
    end
    -- 20 окт: кэш не рос бесконечно (каждая правка / сдвиг — новый ключ)
    midi_n = midi_n + 1
    if midi_n > 4000 then for k in pairs(midi_cache) do midi_cache[k] = nil end; midi_n = 1 end
    midi_cache[key] = notes
  end
  local loop = R.GetMediaItemInfo_Value(it, 'B_LOOPSRC') == 1
  local period = 0
  if loop then
    local src = R.GetMediaItemTake_Source(take)
    local len, is_qn = R.GetMediaSourceLength(src)
    if is_qn then period = len
    else period = R.TimeMap2_timeToQN(0, R.TimeMap2_QNToTime(0, qn0) + len) - qn0 end
  end
  local reps = 1
  if loop and period > 1e-6 then
    reps = math.min(M.MAX_UNROLL, math.ceil((qn1 - qn0) / period))
  end
  local muted_item = R.GetMediaItemInfo_Value(it, 'B_MUTE_ACTUAL') == 1
  -- 19 окт: команды MIDI-клипа — у своей ноты: токен «0DA5@1.25» (смещение ноты от начала клипа, в четвертях);
  -- без @ — у первой ноты (так они и звучали: от начала клипа). Раньше без @ показывались на всех нотах
  local midi_cmds = {}
  do
    local _, cm = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_cmds', '', false)
    if cm and cm ~= '' then
      for tok in cm:gmatch('[^,]+') do
        local code, off = tok:match('^(%w%w%x%x)@([%d%.]+)$')
        if code then midi_cmds[#midi_cmds + 1] = { t = code, off = tonumber(off) or 0 }
        elseif tok:match('^%w%w%x%x$') then midi_cmds[#midi_cmds + 1] = { t = tok, off = 0, first = true } end
      end
    end
  end
  local first_off
  for _, nt in ipairs(notes) do local o = nt.qn - qn0; if not first_off or o < first_off then first_off = o end end
  local half = 0.5 / math.max(1, lpb)
  local function note_fx(o)
    local t
    for _, c in ipairs(midi_cmds) do
      if (c.first and first_off and math.abs(o - first_off) < half) or (not c.first and math.abs(o - c.off) < half) then t = t or {}; t[#t + 1] = c.t end
    end
    return t
  end
  local midi_fx = {}
  for k = 0, reps - 1 do
    local shift = k * period
    for _, nt in ipairs(notes) do
      local a, b = nt.qn + shift, nt.qn_end + shift
      -- нота должна начинаться внутри item; хвост режется по концу item
      if a >= qn0 - 1e-7 and a < qn1 - 1e-7 then
        if b > qn1 then b = qn1 end
        local r0, d0 = M.row_of_qn(a, lpb)
        local r1, d1 = M.row_of_qn(b, lpb)
        local head = {
          kind = 'midi', item = it, take = take,
          note = M.note_name(nt.pitch), pitch = nt.pitch, semis = nt.pitch - M.BASE_NOTE,
          micro = M.micro_of_cents(nt.cents), ppq = nt.ppq,   -- 16 окт: микротон (MTS sysex перед нотой)
          vol = M.hex2(nt.vel), delay = d0, ch = nt.ch,
          muted = muted_item or nt.muted, row0 = r0, fx = (function()
            local nf = (k == 0) and note_fx(nt.qn - qn0) or nil
            if not nt.soff and not nt.nx and not nf then return midi_fx end
            local t = nt.soff and { ('0S%02X'):format(nt.soff) } or {}   -- 19 окт: 0Sxx ноты кита
            for tok in (nt.nx or ''):gmatch('[^,]+') do t[#t + 1] = tok end   -- 26 окт: команды ноты slixer
            for _, x in ipairs(nf or {}) do t[#t + 1] = x end
            return t
          end)(),
        }
        if head.micro then M.seen_micro = true end
        -- 21 окт: команды строк внутри MIDI-ноты (токен @ смещения внутри неё) — rowfx, как у аудио
        if k == 0 and #midi_cmds > 0 then
          local o0, o1 = nt.qn - qn0, nt.qn_end - qn0
          for _, c in ipairs(midi_cmds) do
            if not c.first and c.off > o0 + 0.5 / math.max(1, lpb) and c.off < o1 - 1e-6 then
              local r = math.floor((c.off - o0) * lpb + 0.5)
              if r > 0 then head.rowfx = head.rowfx or {}; head.rowfx[r] = head.rowfx[r] or {}; table.insert(head.rowfx[r], c.t) end
            end
          end
        end
        local tail = { kind = 'off', of = head, delay = d1, explicit = nt.rel == M.OFF_REL or nil }   -- 24 окт: явный OFF (обрывает one-shot пэд)
        -- note-off ровно на границе строки — OFF стоит в этой строке с delay 0;
        -- если конец в той же строке, что и начало, OFF не помещается: нота
        -- короче строки, показываем только голову
        -- 8 окт: опция «OFF в конце строки» (M.OFF_END): конец ровно на
        -- границе строки r1 — OFF в последней звучащей строке r1 - 1 (нота
        -- звучит и на ней); строка r1 свободна для следующей ноты — короче на строку
        if M.OFF_END and d1 == 0 and r1 > r0 then r1 = r1 - 1 end
        if r1 <= r0 then place(lane, r0, r0, head) else place(lane, r0, r1, head, nil, tail) end
      end
    end
  end
end

-- ── снимок ────────────────────────────────────────────────────────────────
local cache = { key = nil, snap = nil, midi = {}, hash_t = 0, hashes = '' }
local rcache = { key = nil, list = {} }   -- регионы (см. M.regions)

local function midi_hashes()
  local parts = {}
  for ti = 0, R.CountTracks(0) - 1 do
    local tr = R.GetTrack(0, ti)
    local ok, h = R.MIDI_GetTrackHash(tr, true, '')
    parts[#parts + 1] = ok and h or ''
  end
  return table.concat(parts, ',')
end

-- Ключ кеша: state count + LPB + хеши MIDI (опрос не чаще 4 Гц).
function M.cache_key(lpb, now)
  now = now or R.time_precise()
  if now - cache.hash_t > 0.25 then
    cache.hashes = midi_hashes()
    cache.hash_t = now
  end
  return string.format('%d|%d|%s', R.GetProjectStateChangeCount(0), lpb, cache.hashes)
end

local pool_by_item = {}        -- item → gkey (все items, не только первый) — номер инструмента в ячейке
M.bprof = { envs = 0, pool = 0, mods = 0, fx = 0 }
function M.build(lpb)
  M.bprof = { envs = 0, pool = 0, mods = 0, fx = 0 }
  M.seen_micro = false   -- 16 окт: есть ноты с микротоном — трекер расширяет колонку нот
  pool_by_item = {}
  local snap = { lpb = lpb, cols = {}, last_row = 0 }
  M.tfx_memo = {}   -- 20 окт: take FX — заново на каждую сборку
  local depot_tr
  for ti = 0, R.CountTracks(0) - 1 do
    local tr = R.GetTrack(0, ti)
    local _, name = R.GetTrackName(tr)
    if M.is_lib_name(name) then depot_tr = tr end
  end
  snap.depot = depot_tr
  snap.lib_pos = nil                       -- 8 окт: маркера =LIB больше нет
  snap.end_pos = M.marker_pos(M.END_MARKER)
  snap.zone = M.session_zone()                -- зона сессии (7 окт): её items — не библиотека
  -- мастер: для вкладки master (скоп слот 31, цепь FX)
  if R.GetMasterTrack then
    local mt = R.GetMasterTrack(0)
    local ms = { track = mt, fx = M.track_fx(mt) }
    -- 9 окт: полоса master в нижнем микшере — те же поля, что у трека
    ms.guid, ms.name, ms.lanes, ms.depth = 'master', 'master', {}, 0
    ms.vol, ms.pan = R.GetMediaTrackInfo_Value(mt, 'D_VOL'), R.GetMediaTrackInfo_Value(mt, 'D_PAN')
    ms.width, ms.panmode = R.GetMediaTrackInfo_Value(mt, 'D_WIDTH'), math.floor(R.GetMediaTrackInfo_Value(mt, 'I_PANMODE'))
    ms.panL, ms.panR = R.GetMediaTrackInfo_Value(mt, 'D_DUALPANL'), R.GetMediaTrackInfo_Value(mt, 'D_DUALPANR')
    ms.muted = R.GetMediaTrackInfo_Value(mt, 'B_MUTE') == 1
    local sfx = R.TrackFX_GetByName and R.TrackFX_GetByName(mt, 'jf_tracker_scope', false)
    if sfx and sfx >= 0 then ms.scope_slot = math.floor(R.TrackFX_GetParam(mt, sfx, 0)) end
    ms.envs = M.track_envs(mt, lpb)   -- 11 окт: колонка мастера в трекере — его огибающие (темп, громкость …)
    ms.cmd = M.cmd_lane(lpb)          -- 11 окт: колонка cmd мастера — маркеры проекта
    ms.vis = M.vis_lane(lpb)          -- 11 окт: колонка visor — маркеры v:
    ms.chd = M.chord_lane(lpb)        -- 21 окт: колонка chord — маркеры ch:
    snap.master = ms
  end
  for ti = 0, R.CountTracks(0) - 1 do
    local tr = R.GetTrack(0, ti)
    local _, name = R.GetTrackName(tr)
    if not M.is_lib_name(name) then
      local freemode = R.GetMediaTrackInfo_Value(tr, 'I_FREEMODE')
      local fixed = freemode == 2
      local color = R.GetTrackColor(tr)
      local col = { track = tr, name = name, color = color, lanes = {}, fixed = fixed,
                    muted = R.GetMediaTrackInfo_Value(tr, 'B_MUTE') == 1, guid = M.track_guid(tr),
                    solo = R.GetMediaTrackInfo_Value(tr, 'I_SOLO') > 0,
                    phase = R.GetMediaTrackInfo_Value(tr, 'B_PHASE') == 1,   -- ø в шапке (8 окт)
                    sel = R.IsTrackSelected and R.IsTrackSelected(tr) or false,                       -- выделен в REAPER (Option+цифра, цели f на фейдере)
                    armed = R.GetMediaTrackInfo_Value(tr, 'I_RECARM') == 1,
                    vol = R.GetMediaTrackInfo_Value(tr, 'D_VOL'), pan = R.GetMediaTrackInfo_Value(tr, 'D_PAN'),
                    width = R.GetMediaTrackInfo_Value(tr, 'D_WIDTH'), panmode = math.floor(R.GetMediaTrackInfo_Value(tr, 'I_PANMODE')),
                    panL = R.GetMediaTrackInfo_Value(tr, 'D_DUALPANL'), panR = R.GetMediaTrackInfo_Value(tr, 'D_DUALPANR'),
                    recmon = math.floor(R.GetMediaTrackInfo_Value(tr, 'I_RECMON')),   -- 0 выкл, 1 вкл, 2 авто (tape)
                    folder = R.GetMediaTrackInfo_Value(tr, 'I_FOLDERDEPTH') == 1,
                    depth = R.GetTrackDepth and R.GetTrackDepth(tr) or 0 }
      -- цвет трека в RGB для полоски под заголовком (0 = цвета нет)
      if color ~= 0 and R.ColorFromNative then
        local r, g, b = R.ColorFromNative(color & 0xFFFFFF)
        col.rgb = { r / 255, g / 255, b / 255 }
      end
      local nl = 1
      if fixed then nl = math.max(1, math.floor(R.GetMediaTrackInfo_Value(tr, 'I_NUMFIXEDLANES'))) end
      -- 10 окт: есть аранжировки (M.ARR_PLAYING_ONLY) — видны только играющие лейны
      -- (аранжировка = какие лейны играют; clear — новый пустой лейн); список
      -- плотный, номер лейна — lane.idx, items находят свой лейн по byidx
      local byidx = {}
      for l = 0, nl - 1 do
        local lname = ''
        if fixed then
          local ok, s = R.GetSetMediaTrackInfo_String(tr, 'P_LANENAME:' .. l, '', false)
          if ok then lname = s end
        end
        local hide = fixed and M.ARR_PLAYING_ONLY and nl > 1 and R.GetMediaTrackInfo_Value(tr, 'C_LANEPLAYS:' .. l) == 0
        if not hide then
          local ln = { idx = l, name = lname, subs = { {} }, items = {} }
          col.lanes[#col.lanes + 1] = ln; byidx[l] = ln
        end
      end
      if #col.lanes == 0 then local ln = { idx = 0, name = '', subs = { {} }, items = {} }; col.lanes[1] = ln; byidx[0] = ln end
      for ii = 0, R.CountTrackMediaItems(tr) - 1 do
        local it = R.GetTrackMediaItem(tr, ii)
        local lane_i = fixed and math.floor(R.GetMediaItemInfo_Value(it, 'I_FIXEDLANE')) or 0
        local lane = byidx[lane_i]
        -- items на невидимой lane (C_LANEPLAYS = -1) в колонки не попадают;
        -- items за маркером =END (склад сэмплов, =LIB) трекер не показывает (2 окт)
        if lane and snap.end_pos then
          local ip = R.GetMediaItemInfo_Value(it, 'D_POSITION')
          -- зона сессии видна, когда сессия играет (M.SHOW_ZONE, 7 окт): каждый канал — свой клип
          local in_zone = M.SHOW_ZONE and snap.zone and ip >= snap.zone[1] - 1e-6 and ip < snap.zone[2] - 1e-6
          if ip >= snap.end_pos - 1e-6 and not in_zone then lane = nil end
        end
        -- 13 окт: хвост лупа удержания — часть ноты-головы, своей ячейки нет
        if lane and select(2, R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_susof', '', false)) ~= '' then lane = nil end
        -- 13 окт: копии ретриггера (0Rxy, P_EXT:jf_gen) — часть своей ноты: своих ячеек и подколонок нет
        if lane and select(2, R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_gen', '', false)) ~= '' then lane = nil end
        -- 19 окт: слои ноты слоёного инструмента (¥, P_EXT:jf_lof) — часть своей ноты, как копии ретриггера
        if lane and select(2, R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_lof', '', false)) ~= '' then lane = nil end
        if lane then
          local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
          local len = R.GetMediaItemInfo_Value(it, 'D_LENGTH')
          local qn0 = R.TimeMap2_timeToQN(0, pos)
          local qn1 = R.TimeMap2_timeToQN(0, pos + len)
          local take = R.GetActiveTake(it)
          local midi = take and R.TakeIsMIDI(take) or false
          local si, ahead, loop_rows
          if midi then
            place_midi(lane, lpb, it, take, qn0, qn1, cache.midi)
            -- период MIDI-лупа = длина источника (в QN) → строки
            if R.GetMediaItemInfo_Value(it, 'B_LOOPSRC') == 1 then
              local src = R.GetMediaItemTake_Source(take)
              local slen, is_qn = R.GetMediaSourceLength(src)
              local per = is_qn and slen or (R.TimeMap2_timeToQN(0, pos + (slen or 0)) - qn0)
              if per and per > 1e-6 and per < (qn1 - qn0) - 1e-6 then loop_rows = per * lpb end
            end
          else
            si, ahead = place_audio(lane, lpb, it, take, qn0, qn1)
            loop_rows = ahead and not ahead.sus and ahead.loop_rows      -- шов лупа удержания не тянется (13 окт)
          end
          -- рамка item в колонке: дробные строки начала/конца; аудио — в
          -- своей подколонке (si), MIDI — на всю lane (ноты внутри)
          lane.items[#lane.items + 1] = {
            item = it, r0 = qn0 * lpb, r1 = qn1 * lpb, midi = midi, si = si, loop_rows = loop_rows,
            loop_first = (not midi) and ahead and not ahead.sus and ahead.loop_first or nil,      -- первый стык от начала item (строки)
            rgb = M.item_rgb(it),
            empty = midi and (function() local _, nn, cc, sx = R.MIDI_CountEvts(take); return (nn or 0) + (cc or 0) + (sx or 0) == 0 end)() or nil,   -- 13 окт: пустой MIDI-клип (#)
            sel = R.IsMediaItemSelected and R.IsMediaItemSelected(it) or false,
            muted = R.GetMediaItemInfo_Value(it, 'B_MUTE_ACTUAL') == 1,
          }
        end
      end
      for _, lane in ipairs(col.lanes) do
        if lane.last_row and lane.last_row > snap.last_row then snap.last_row = lane.last_row end
        -- 26 окт: OFF в конце строки — нота встык со следующей (конец = её начало) звучит через строку OFF и не
        -- обрывается: это легато, OFF не показывать; явный OFF (скорость отпускания OFF_REL) остаётся
        if M.OFF_END then
          for _, s in ipairs(lane.subs) do
            for r, c in pairs(s) do
              local nx = s[r + 1]
              if c.kind == 'off' and not c.explicit and (c.delay or 0) == 0 and c.of and nx and (nx.kind == 'midi' or nx.kind == 'audio') and (nx.delay or 0) == 0 then
                s[r] = { kind = 'cont', of = c.of, i = r - (c.of.row0 or r), legato = true }
              end
            end
          end
        end
      end
      -- части пересборки — в M.bprof (пульс hb: что дорого на большом проекте)
      local t0 = R.time_precise()
      col.envs = M.track_envs(tr, lpb)
      col.mlanes = M.track_midilanes(tr, lpb, col.guid)   -- MIDI-лейны: CC / PC / артикуляции / SysEx (6 окт)
      local t1 = R.time_precise()
      col.pool = M.track_pool(tr, depot_tr, nil, snap.end_pos, snap.zone, col.guid, #snap.cols == 0)
      local t2 = R.time_precise()
      col.mods = M.track_mods(tr)
      local t3 = R.time_precise()
      col.fx = M.track_fx(tr)
      -- 26 окт: служебный мост скопов (jf_tracker_scope) — не эффект трека для глаз: не в шапке, не в микшере, не в DSP
      -- (сам стоит в цепи; f.i у остальных — настоящие номера, действия не сдвигаются)
      do
        local hid
        for _, f in ipairs(col.fx) do if (f.name or ''):find('jf_tracker_scope', 1, true) or (f.full or ''):find('jf_tracker_scope', 1, true) then hid = true; break end end
        if hid then
          local t = {}
          for _, f in ipairs(col.fx) do if not ((f.name or ''):find('jf_tracker_scope', 1, true) or (f.full or ''):find('jf_tracker_scope', 1, true)) then t[#t + 1] = f end end
          col.fx = t
        end
      end
      local t4 = R.time_precise()
      M.bprof.envs = M.bprof.envs + (t1 - t0); M.bprof.pool = M.bprof.pool + (t2 - t1)
      M.bprof.mods = M.bprof.mods + (t3 - t2); M.bprof.fx = M.bprof.fx + (t4 - t3)
      -- мост осциллоскопа (JSFX jf_tracker_scope): слот из slider1
      local sfx = R.TrackFX_GetByName and R.TrackFX_GetByName(tr, 'jf_tracker_scope', false)
      if sfx and sfx >= 0 then col.scope_slot = math.floor(R.TrackFX_GetParam(tr, sfx, 0)) end
      -- ретро-буфер jf_rec (экосистема jf_grid): слот = slider2
      local rfx = R.TrackFX_GetByName and R.TrackFX_GetByName(tr, 'jf_rec', false)
      if rfx and rfx >= 0 then col.rec_slot = math.floor(R.TrackFX_GetParam(tr, rfx, 1)); col.rec_fx = rfx end
      snap.cols[#snap.cols + 1] = col
    end
  end
  -- ОБЩИЙ пул инструментов (как список инструментов Renoise 3): уникальные
  -- источники всех треков + библиотека; entry.tracks — где используется
  -- (кроме библиотеки). Каждый col.pool указывает на этот же список, так что
  -- номер инструмента один для всех треков.
  local all, seen = {}, {}
  for _, col in ipairs(snap.cols) do
    for _, e in ipairs(col.pool or {}) do
      local g = seen[e.gkey]
      if not g then g = e; g.tracks = {}; g.track_set = {}; g.home = col.name; seen[e.gkey] = g; all[#all + 1] = g end
      -- 13 окт: here — нота на треке (представитель мог стать сэмплом из lib)
      if (e.here or not e.depot) and not g.track_set[col.name] then g.track_set[col.name] = true; g.tracks[#g.tracks + 1] = col.name end
    end
  end
  -- родитель: более длинный инструмент того же файла, покрывающий этот
  -- диапазон источника (слайс/кусок → исходник). Предпочтение — нарезанному,
  -- затем самому длинному. Цепочки сворачиваются к корню.
  for i, e in ipairs(all) do e._i = i end
  for _, e in ipairs(all) do
    local best, blen
    local e0, e1 = e.offs, e.offs + e.len * e.rate
    for _, p in ipairs(all) do
      if p ~= e and not p.lvar and p.fpath ~= '' and p.fpath == e.fpath then   -- вариант лупа — не родитель кусков
        local p0, p1 = p.offs, p.offs + p.len * p.rate
        if p0 <= e0 + 1e-4 and p1 >= e1 - 1e-4 and (p1 - p0) > (e1 - e0) + 1e-3 then
          local better = not best or ((p.slices ~= nil) and (best.slices == nil)) or (((p.slices ~= nil) == (best.slices ~= nil)) and (p1 - p0) > blen)
          if better then best, blen = p, p1 - p0 end
        end
      end
    end
    e.parent = best
    -- 13 окт: нота-слайс (iid «корень#k») — ребёнок корня всегда, даже во всю длину (playthru):
    -- иначе она становилась отдельным инструментом «без слайсов»
    local rb = type(e.gkey) == 'string' and e.gkey:match('^(iid:[^#@~]+)#')
    if rb then for _, p in ipairs(all) do if p ~= e and p.gkey == rb then e.parent = p; break end end end
    if e.lvar then                                          -- вариант лупа: родитель — его корень
      e.parent = nil
      for _, p in ipairs(all) do if p ~= e and p.guid == e.lvar then e.parent = p end end
    end
  end
  for _, e in ipairs(all) do
    local p = e.parent
    while p and p.parent and p.parent ~= e do p = p.parent end
    e.parent = p
    e.slice_k = nil
    if p and p.slices then
      local t0 = (e.offs - p.offs) / (p.rate ~= 0 and p.rate or 1)
      for k, st in ipairs(p.slices) do if math.abs(st - t0) < 0.01 then e.slice_k = k end end
      if not e.slice_k and t0 < 0.01 then e.slice_k = 0 end   -- начало сэмпла до первого слайса
    end
  end
  -- порядок номеров = дерево (2 окт, как список сэмплов Renoise): по трекам
  -- в порядке колонок; на треке — исходные сэмплы (корни, где лежат —
  -- хоть в библиотеке за =LIB), под каждым его слайсы/куски
  local kids = {}
  for _, e in ipairs(all) do
    if e.parent then kids[e.parent] = kids[e.parent] or {}; table.insert(kids[e.parent], e) end
  end
  for _, list in pairs(kids) do
    table.sort(list, function(x, y)
      local kx, ky = x.slice_k or (x.lvar_n and 1e6 + x.lvar_n) or 1e9, y.slice_k or (y.lvar_n and 1e6 + y.lvar_n) or 1e9   -- варианты лупа — после слайсов
      if kx ~= ky then return kx < ky end
      if x.offs ~= y.offs then return x.offs < y.offs end
      return x._i < y._i
    end)
  end
  local ordered, placed = {}, {}
  local function put(e, depth)
    if placed[e] then return end
    placed[e] = true; e.depth = depth; ordered[#ordered + 1] = e
    for _, k in ipairs(kids[e] or {}) do put(k, 1) end
  end
  -- 11 окт: номера стабильны — сначала сэмплы библиотеки в её порядке (позиция на
  -- треке LIB), потом остальные в порядке появления. Раньше порядок шёл по первому
  -- использованию на треке: смена инструмента ноты меняла номера (набрал 2 — нота
  -- стала 02, и её сэмпл тут же стал 01)
  local roots = {}
  for i, e in ipairs(all) do
    if not e.parent then
      local dp = e.depot and e.item and (not R.ValidatePtr or R.ValidatePtr(e.item, 'MediaItem*')) and R.GetMediaItemInfo_Value(e.item, 'D_POSITION') or nil
      roots[#roots + 1] = { e = e, i = i, dp = dp }
    end
  end
  table.sort(roots, function(a, b)
    if (a.dp ~= nil) ~= (b.dp ~= nil) then return a.dp ~= nil end
    if a.dp and a.dp ~= b.dp then return a.dp < b.dp end
    return a.i < b.i
  end)
  -- 11 окт: без группировки по трекам (по трекам — кнопка track в lib, только вид)
  for _, r in ipairs(roots) do put(r.e, 0) end
  for _, e in ipairs(all) do put(e, e.parent and 1 or 0) end
  -- свой порядок исходников (3 окт): перетаскивание в lib пишет P_EXT:jf_ord
  -- на item исходника; без метки — после размеченных, в порядке дерева
  local any_ord = false
  for _, e in ipairs(ordered) do if not e.parent and e.ord then any_ord = true; break end end
  if any_ord then
    local roots = {}
    for k, e in ipairs(ordered) do if not e.parent then roots[#roots + 1] = { e = e, k = k } end end
    table.sort(roots, function(a, b)
      local oa, ob = a.e.ord or 1e9, b.e.ord or 1e9
      if oa ~= ob then return oa < ob end
      return a.k < b.k
    end)
    ordered, placed = {}, {}
    for _, r in ipairs(roots) do put(r.e, 0) end
    for _, e in ipairs(all) do put(e, e.parent and 1 or 0) end
  end
  all = ordered
  snap.pool = all
  for _, col in ipairs(snap.cols) do col.pool = all end
  -- 11 окт: мастер — тот же общий пул (курсор на его Tempo / cmd: lib, swap и пр. читали nil и роняли трекер)
  if snap.master then snap.master.pool = all end
  -- номер инструмента по item (показывается в строке имени ячейки)
  local by_key = {}
  for i, e in ipairs(all) do by_key[e.gkey] = i end
  snap.inst_of = {}
  for it, key in pairs(pool_by_item) do snap.inst_of[it] = by_key[key] end
  -- номера инструментов (3 окт): только у исходных сэмплов (корней) — 01, 02…;
  -- слайс / кусок вложен в свой исходник и носит его номер (какой слайс —
  -- Sxx в колонке команд). В lib слайсы не показываются.
  local num = 0
  for _, e in ipairs(all) do if not e.parent then num = num + 1; e.num = num end end
  for _, e in ipairs(all) do if e.parent then e.num = e.parent.num end end
  snap.nroots = num
  snap.inst_num = {}
  for it, i in pairs(snap.inst_of) do snap.inst_num[it] = all[i] and all[i].num end
  -- нота относительно инструмента (6 окт): transpose инструмента (D_PITCH /
  -- rate его item в lib) — база, C-4 = как звучит инструмент; раньше нота
  -- была абсолютной и q / вставка играли без транспоза, а клик в lib — с ним
  snap.inst_semis = {}
  -- 13 окт: база — транспоз сэмпла в lib: у слайса / куска — его корня, у корня — его item в lib;
  -- инструмент без item в lib (только ноты) — без базы. Раньше база бралась у самой длинной ноты
  -- (представителя): она показывалась F-4, её копия — C-4, хотя высота у обеих одна
  local function base_of(e)
    local r = e.parent or e
    if r.depot then return M.take_semitones(r.pitch, r.rate, r.ppitch) end
    return 0
  end
  for i, e in ipairs(all) do snap.inst_semis[i] = base_of(e) end
  for _, col in ipairs(snap.cols) do
    for _, lane in ipairs(col.lanes) do
      for _, sub in ipairs(lane.subs) do
        for _, cell in pairs(sub) do
          if cell.kind == 'audio' and cell.item and not cell.mroot then   -- 27 окт: с маркером высоты — без базы
            local i = snap.inst_of[cell.item]
            local base = i and all[i] and snap.inst_semis[i] or 0
            if base ~= 0 then
              cell.semis_abs = cell.semis
              cell.semis = cell.semis - base
              cell.note = M.note_name(M.BASE_NOTE + cell.semis)
              cell.frac = math.abs(cell.semis - math.floor(cell.semis + 0.5)) > 0.01
            end
          end
        end
      end
    end
  end
  return snap
end

-- Снимок с кешем. Возвращает snap, changed.
function M.snapshot(lpb)
  local key = M.cache_key(lpb)
  if cache.key == key and cache.snap then return cache.snap, false end
  cache.key = key
  cache.snap = M.build(lpb)
  return cache.snap, true
end

function M.invalidate() cache.key = nil; rcache.key = nil end

-- ── строки вида ───────────────────────────────────────────────────────────
-- Описания видимых строк: время, такт/доля. Считаем только для окна вида.
-- 17 окт: кэш — строки меняются только от прокрутки, LPB, правки проекта (темп, размер); раньше ~2 вызова API
-- на строку каждый кадр. Раз в секунду — заново (метроном мог смениться без счётчика)
local rows_c = {}
function M.rows(row0, n, lpb)
  local sc, now = R.GetProjectStateChangeCount(0), R.time_precise()
  local c = rows_c
  if c.out and c.row0 == row0 and c.n == n and c.lpb == lpb and c.sc == sc and now - c.t < 1 then return c.out end
  local out = M.rows_build(row0, n, lpb)
  rows_c = { out = out, row0 = row0, n = n, lpb = lpb, sc = sc, t = now }
  return out
end
function M.rows_build(row0, n, lpb)
  local out, pats = {}, {}
  for i = 1, n do
    local row = row0 + i - 1
    local qn = row / lpb
    local t = R.TimeMap2_QNToTime(0, qn)
    local meas, qms = R.TimeMap_QNToMeasures(0, qn)
    local beat = math.abs(qn - math.floor(qn + 0.5)) < 1e-6
    local bar = beat and qms and math.abs(qn - qms) < 1e-6
    -- 15 окт: акцент по паттерну метронома (кэш на такт в пределах вызова)
    local acc = 5
    if row >= 0 and qms then
      local m = meas or 0
      if not pats[m] then
        local _, den = R.TimeMap_GetTimeSigAtTime(0, t)
        pats[m] = { p = select(2, R.TimeMap_GetMetronomePattern(0, t, 'EXTENDED')) or '', den = (den and den > 0) and den or 4 }
      end
      -- доля — по знаменателю размера (6/8 — восьмая); строк в доле не целое — по четвертям
      local rpb = lpb * 4 / pats[m].den
      if rpb < 1 or rpb % 1 ~= 0 then rpb = lpb end
      local rin = math.floor((qn - qms) * lpb + 0.5)
      acc = M.accent(rin % rpb, rpb, rin // rpb, pats[m].p)
    end
    out[i] = { row = row, qn = qn, t = t, bar = row >= 0 and bar, beat = row >= 0 and beat, measure = meas, acc = acc,
               label = row >= 0 and string.format('%04d', row % 10000) or string.format('-%03d', (-row) % 1000) }   -- 11 окт: до начала проекта — с минусом (было пусто)
  end
  return out
end

-- 15 окт: уровень акцента строки для яркости точек и номера: 0 — такт и сильные доли паттерна метронома
-- (A в 'ABBB'), 1 — прочие доли, 2.. — деления доли (пополам / на три, глубже — слабее), 5 — без акцента.
-- sub — строка внутри доли (0..lpb-1), bi — доля в такте (0..), pat — паттерн метронома
function M.accent(sub, lpb, bi, pat)
  if sub == 0 then
    if bi == 0 then return 0 end
    local ch = pat and pat:sub(bi + 1, bi + 1) or ''
    return ch == 'A' and 0 or 1
  end
  local d, lv = lpb, 2
  while d > 1 and lv <= 4 do
    local p = (d % 3 == 0) and 3 or ((d % 2 == 0) and 2 or d)   -- триоли первыми: lpb 12 = 3 × 4
    local step = d // p
    if step < 1 then break end
    if sub % step == 0 then return lv end
    sub = sub % step; d = step; lv = lv + 1
  end
  return 5
end

-- Строка плейхеда/курсора от времени проекта (может быть дробной).
function M.row_of_time(t, lpb)
  return R.TimeMap2_timeToQN(0, t) * lpb
end

-- 24 окт: Opt+V — конец (первая строка за ним) единицы, в которой лежит строка: 1 субдоля (четверть доли, 16-я
-- при 4/4), 2 доля, 3 такт (bar_end), 4 паттерн (pat_end); строки — QN · lpb (доля = lpb строк)
M.SEL_UNITS = { 'sub-beat', 'beat', 'bar', 'pattern' }
function M.sel_unit_end(row, lpb, lvl, bar_end, pat_end)
  local sub = math.max(1, math.floor(lpb / 4))
  if lvl == 1 then return (math.floor(row / sub + 1e-9) + 1) * sub end
  if lvl == 2 then return (math.floor(row / lpb + 1e-9) + 1) * lpb end
  if lvl == 3 then return bar_end end
  return pat_end
end

-- Границы такта, в котором лежит строка: первая строка такта и первая
-- строка следующего.
function M.bar_of_row(row, lpb)
  local qn = row / lpb
  local _, qms, qme = R.TimeMap_QNToMeasures(0, qn)
  if not qms or not qme or qme <= qms then return row, row + 4 * lpb end
  local r0 = M.row_of_qn(qms, lpb)
  local r1 = M.row_of_qn(qme, lpb)
  return r0, r1
end

function M.track_guid(tr)
  return R.GetTrackGUID and R.GetTrackGUID(tr) or tostring(tr)
end

-- ── цвет item ─────────────────────────────────────────────────────────────
-- Отображаемый цвет (свой или трека), как его рисует REAPER.
function M.item_rgb(it)
  -- 9 окт: item мог исчезнуть (Cmd+Z / удаление) раньше пересборки снимка — сетка
  -- клипов сессии спрашивала его цвет и роняла трекер
  if not (it and R.ValidatePtr and R.ValidatePtr(it, 'MediaItem*')) then return nil end
  local c = R.GetDisplayedMediaItemColor and R.GetDisplayedMediaItemColor(it) or 0
  if not c or c == 0 or not R.ColorFromNative then return nil end
  local r, g, b = R.ColorFromNative(c & 0xFFFFFF)
  return { r / 255, g / 255, b / 255 }
end

-- ── пул трека ─────────────────────────────────────────────────────────────
-- «Инструменты» для вставки на трек: items трека и депо, сгруппированные
-- в инструменты. Записи годятся для M.peaks (src/offs/len/rate/guid) —
-- превью в полоске над заголовком. Цифры 1..0 в INSERT выбирают слот.
--
-- Связь (3 окт): инструмент = метка P_EXT:jf_iid (её ставит каждая вставка
-- трекера: нота — id инструмента, слайс — id#k). Все items с одной меткой —
-- ОДИН инструмент, как бы их ни обрезали следующие ноты, какой бы питч или
-- громкость ни дали. Видоизменённая копия (растяжка, offset) получает новую
-- метку — становится уникальной (edit.make_unique). Items без метки (свои
-- или старые) — по файлу + имени + offset + rate, БЕЗ длины: обрезанный
-- кусок — тот же инструмент, а не новая «итерация».
-- Представитель инструмента — item из библиотеки, иначе самый длинный.
M.IID = 'P_EXT:jf_iid'
function M.iid(it)
  local _, v = R.GetSetMediaItemInfo_String(it, M.IID, '', false)
  return v or ''
end
local pool_add_entry                                   -- определена ниже pool_add
local function pool_key(it, take, name)
  local iid = M.iid(it)
  if iid ~= '' then return 'iid:' .. iid end
  local src = R.GetMediaItemTake_Source(take)
  local fn = src and R.GetMediaSourceFileName and R.GetMediaSourceFileName(src, '') or ''
  return string.format('%s|%s|%.3f|%.3f', tostring(fn), name,
    R.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS'),
    R.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE'))
end
M.pool_key = pool_key

local function pool_add(pool, seen, it, from_depot)
  local take = R.GetActiveTake(it)
  if not take then return end
  if select(2, R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_susof', '', false)) ~= '' then return end   -- хвост лупа удержания (13 окт)
  -- 19 окт: слой ¥ — не свой инструмент (живёт в своём корне), производный item слоя — тоже
  if select(2, R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_layerof', '', false)) ~= '' then
    local _, g = R.GetSetMediaItemInfo_String(it, 'GUID', '', false)
    M.layer_src = M.layer_src or {}
    M.layer_src[g] = { item = it, take = take, name = R.GetTakeName(take), len = R.GetMediaItemInfo_Value(it, 'D_LENGTH') }   -- 19 окт: слой ¥ по GUID — имя / прослушка
    return
  end
  if select(2, R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_lof', '', false)) ~= '' then return end
  -- MIDI-клипы (9 окт): только из зоны lib / трека LIB — MIDI-item песни это
  -- контейнеры нот трекера, не инструменты; каждый клип — свой (без склейки)
  local midi = R.TakeIsMIDI(take)
  if midi and not from_depot then return end
  local name = R.GetTakeName(take)
  local key = midi and ('midi|' .. (R.BR_GetMediaItemGUID and R.BR_GetMediaItemGUID(it) or tostring(it))) or pool_key(it, take, name)
  pool_by_item[it] = key
  local len = R.GetMediaItemInfo_Value(it, 'D_LENGTH')
  local at = seen[key]
  if at then
    local cur = pool[at]
    cur.n = (cur.n or 1) + 1
    if not cur.ord then local _, o = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_ord', '', false); cur.ord = tonumber(o) end
    -- представитель: библиотека, затем самый длинный (не обрезанная копия)
    local better = (from_depot and not cur.depot) or ((not from_depot) == (not cur.depot) and len > cur.len + 1e-6)
    local here = cur.here or not from_depot          -- 13 окт: нота этого инструмента лежит на треке
    if not better then cur.here = here; return end
    local n = cur.n
    local ord = cur.ord
    pool[at] = nil
    pool_add_entry(pool, at, it, take, name, key, from_depot)
    pool[at].n = n
    pool[at].ord = pool[at].ord or ord
    pool[at].here = here
    return
  end
  seen[key] = #pool + 1
  pool_add_entry(pool, #pool + 1, it, take, name, key, from_depot)
  pool[#pool].here = not from_depot
end

-- 11 окт: запись lib по одному item (панель properties на уровне note — значения самой ноты)
function M.entry_of(it)
  if not (it and R.ValidatePtr(it, 'MediaItem*')) then return nil end
  local tk = R.GetActiveTake(it)
  if not tk then return nil end
  local t = {}
  pool_add_entry(t, 1, it, tk, R.GetTakeName(tk), 'note', false)
  return t[1]
end
pool_add_entry = function(pool, at, it, take, name, key, from_depot)
  local gkey = key
  local src0 = R.GetMediaItemTake_Source(take)
  -- тип источника (9 окт, сортировка lib по типу): video / audio (MIDI в lib не попадает)
  local ps = src0 and R.GetMediaSourceParent and R.GetMediaSourceParent(src0) or nil
  local stype = src0 and R.GetMediaSourceType and R.GetMediaSourceType(ps or src0, '') or ''
  pool[at] = {
    item = it, take = take, name = name, src = src0,
    stype = (R.TakeIsMIDI(take) and 'midi') or (stype:upper():find('VIDEO', 1, true) and 'video') or 'audio',
    ord = tonumber((select(2, R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_ord', '', false)))),   -- порядок в lib (3 окт, перетаскивание)
    offs = R.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS'),
    len = R.GetMediaItemInfo_Value(it, 'D_LENGTH'),
    rate = R.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE'),
    guid = R.BR_GetMediaItemGUID and R.BR_GetMediaItemGUID(it) or tostring(it),
    rgb = M.item_rgb(it), depot = from_depot,
    muted = R.GetMediaItemInfo_Value(it, 'B_MUTE') == 1,
    vol = R.GetMediaItemInfo_Value(it, 'D_VOL'),
    -- свойства для панели сэмпла (2 окт): всё нативное, item/take
    tpan = R.GetMediaItemTakeInfo_Value(take, 'D_PAN'),
    pitch = R.GetMediaItemTakeInfo_Value(take, 'D_PITCH'),
    ppitch = R.GetMediaItemTakeInfo_Value(take, 'B_PPITCH') == 1,
    pmode = math.floor(R.GetMediaItemTakeInfo_Value(take, 'I_PITCHMODE')),
    loop = R.GetMediaItemInfo_Value(it, 'B_LOOPSRC') == 1,
    rev = (function() local s = R.GetMediaItemTake_Source(take); return s and R.PCM_Source_GetSectionInfo and select(4, R.PCM_Source_GetSectionInfo(s)) or false end)(),   -- 19 окт: реверс take
    fin = R.GetMediaItemInfo_Value(it, 'D_FADEINLEN'), fout = R.GetMediaItemInfo_Value(it, 'D_FADEOUTLEN'),
    nfx = R.TakeFX_GetCount and R.TakeFX_GetCount(take) or 0,
    fxnames = (function()
      local t = {}
      for k = 0, (R.TakeFX_GetCount and R.TakeFX_GetCount(take) or 0) - 1 do local _, nm = R.TakeFX_GetFXName(take, k, ''); t[#t + 1] = (nm or ''):gsub('^%w+: ', '') end
      return t
    end)(),
    -- путь файла источника (для поиска исходника слайса). НЕ `file`: это поле
    -- у редактора сэмпла значит «файл из браузера» (2 окт: ломало нарезку)
    fpath = (function() local s = R.GetMediaItemTake_Source(take); return s and R.GetMediaSourceFileName and R.GetMediaSourceFileName(s, '') or '' end)(),
    gkey = gkey,
  }
  -- 19 окт: слоёный инструмент ¥ — его слои (метка P_EXT:jf_layers); каждый слой знает свой item в LIB
  do
    local _, lt = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_layers', '', false)
    if lt and lt ~= '' and M.LY then pool[at].layers = M.LY.parse(lt) end
  end
  -- 13 окт: вариант лупа (looploom → slices): «GUID корня|номер» — ребёнок корня, не кусок по диапазону
  do
    local _, lv = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_lvar', '', false)
    local g, n = (lv or ''):match('^(.-)|(%d+)$')
    if g and g ~= '' then pool[at].lvar, pool[at].lvar_n = g, tonumber(n) end
  end
  -- мини-пиано-ролл MIDI-клипа в lib (9 окт): ноты долями длины item
  if pool[at].stype == 'midi' and R.MIDI_CountEvts then
    local _, nn = R.MIDI_CountEvts(take)
    local len = math.max(1e-6, pool[at].len)
    local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
    local notes = {}
    for k = 0, math.min(nn, 512) - 1 do
      local _, _, _, sp, ep, _, p = R.MIDI_GetNote(take, k)
      local a = (R.MIDI_GetProjTimeFromPPQPos(take, sp) - pos) / len
      local b = (R.MIDI_GetProjTimeFromPPQPos(take, ep) - pos) / len
      notes[#notes + 1] = { a, b, p }
    end
    pool[at].notes = notes
  end
  -- виртуальная нарезка (jf_tracker_slicer): тайм-коды в P_EXT
  local _, sl = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slices', '', false)
  local _, bs = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_bsync', '', false)
  if sl and sl ~= '' then
    local t = {}
    for v in sl:gmatch('[^,]+') do t[#t + 1] = tonumber(v) end
    -- 6 окт: привязка к волне — как E.item_slices: t · rate0 / rate текущий
    -- (beatsync — его rate0); старая нарезка без rate0 — оценка по длине
    local _, b = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slice_base', '', false)
    local _, l0, r0 = (b or ''):match('([^;]+);([^;]+);?([^;]*)')
    l0, r0 = tonumber(l0), tonumber(r0)
    local rn = tonumber(((bs or ''):match('^[^;]+;[^;]+;([^;]+)'))) or R.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
    if not r0 and l0 and l0 > 0 then
      local ln = R.GetMediaItemInfo_Value(it, 'D_LENGTH')
      if math.abs(ln - l0) > 1e-3 then r0 = rn * ln / l0 end
    end
    local f = (r0 and rn > 1e-9) and (r0 / rn) or 1
    if math.abs(f - 1) > 1e-9 then for i = 1, #t do t[i] = t[i] * f end end
    pool[at].slices = t
  end
  -- beatsync: «N;span;rate0;pp0» (edit.bsync_set) — долей = первое поле (5 окт:
  -- tonumber всей строки давал nil, lib и свойства показывали off)
  pool[at].bsync = bs and tonumber(bs:match('^%s*([^;]+)')) or nil
  pool[at].iid = M.iid(it)
  -- 10 окт: набор файлов (Option+двойной щелчок / Opt+Enter в браузере) — имена частей
  do local _, kit = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_kit', '', false)
    if kit and kit ~= '' then local t = {}; for nm in kit:gmatch('[^|]+') do t[#t + 1] = nm end; pool[at].kit = t end end
  do local _, pt = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_playthru', '', false); pool[at].playthru = pt == '1' end   -- 6 окт
end

-- lib_pos — позиция маркера =LIB: items трека после него — его депо
-- (библиотека инструментов, помечены *). Трек DEPOT — наследие, тоже читается.
function M.marker_pos(name)
  if not R.CountProjectMarkers then return nil end
  local n = R.CountProjectMarkers(0)
  for i = 0, n - 1 do
    local _, isrgn, pos, _, nm = R.EnumProjectMarkers3(0, i)
    if not isrgn and nm == name then return pos end
  end
  return nil
end
function M.lib_pos() return M.marker_pos(M.LIB_MARKER) end
M.END_MARKER = '=END'
M.START_MARKER = '=START'

-- Пул трека: items до маркера =END (последовательность) и после =LIB
-- (библиотека). Всё между =END и =LIB — не читается (просьба 1 окт: путаница;
-- сэмплы библиотеки реально лежат на треках за =LIB).
function M.track_pool(tr, depot_tr, lib_pos, end_pos, zone, guid, first)
  local pool, seen = {}, {}
  for i = 0, R.CountTrackMediaItems(tr) - 1 do
    local it = R.GetTrackMediaItem(tr, i)
    local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
    if zone and pos >= zone[1] - 1e-6 and pos < zone[2] - 1e-6 then goto skip_item end   -- копии клипов сессии — не инструменты
    local in_lib = lib_pos ~= nil and pos >= lib_pos - 1e-6 and (end_pos == nil or pos >= end_pos - 1e-6)
    local after_end = end_pos ~= nil and pos >= end_pos - 1e-6
    if in_lib or not after_end then pool_add(pool, seen, it, in_lib) end
    ::skip_item::
  end
  if depot_tr then
    -- 8 окт: семпл трека LIB — у трека-владельца (P_EXT:jf_home = GUID трека);
    -- без владельца — у первого трека
    -- 10 окт: владелец удалён (или трека не было — файл из браузера в пустом проекте) —
    -- тоже у первого трека: раньше такие инструменты не показывались нигде
    local live = {}
    for ti = 0, R.CountTracks(0) - 1 do live[M.track_guid(R.GetTrack(0, ti))] = true end
    for i = 0, R.CountTrackMediaItems(depot_tr) - 1 do
      local it = R.GetTrackMediaItem(depot_tr, i)
      local _, home = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_home', '', false)
      if (home ~= '' and home == guid) or ((home == '' or not live[home]) and first) then pool_add(pool, seen, it, true) end
    end
  end
  return pool
end

-- ── модуляции параметров FX трека (нативные: LFO / ACS / plink) ──────────
-- TrackFX_GetNamedConfigParm 'param.N.mod.active' и т.д. Считается в
-- снимке (не каждый кадр); до 64 параметров на FX.
M.MOD_KEYS = { 'mod.baseline', 'lfo.active', 'lfo.shape', 'lfo.speed', 'lfo.temposync', 'lfo.strength', 'lfo.phase', 'lfo.dir',   -- 15 окт: phase / dir — для холста
  'acs.active', 'acs.attack', 'acs.release', 'acs.strength', 'plink.active', 'plink.effect', 'plink.param',
  'plink.scale', 'plink.offset' }
-- адреса всех FX трека, включая детей контейнеров (0x2000000…, v7.06+:
-- container_item.X) — модуляция нативна и на них (2 окт); prefix — путь имён
function M.fx_addresses(tr)
  local out = {}
  if not R.TrackFX_GetNamedConfigParm then return out end
  local function walk(id, prefix, depth)
    out[#out + 1] = { fx = id, prefix = prefix }
    local ok, n = R.TrackFX_GetNamedConfigParm(tr, id, 'container_count')
    if ok and depth < 4 then
      local _, nm = R.TrackFX_GetFXName(tr, id, '')
      local short = (nm or ''):gsub('^[^:]*: ', ''):sub(1, 8)
      for k = 0, (tonumber(n) or 0) - 1 do
        local ok2, cid = R.TrackFX_GetNamedConfigParm(tr, id, 'container_item.' .. k)
        cid = ok2 and tonumber(cid)
        if cid then walk(cid, prefix .. short .. '>', depth + 1) end
      end
    end
  end
  for fx = 0, R.TrackFX_GetCount(tr) - 1 do walk(fx, '', 0) end
  return out
end

function M.track_mods(tr)
  local out = {}
  if not R.TrackFX_GetNamedConfigParm then return out end
  for _, fa in ipairs(M.fx_addresses(tr)) do
    local fx = fa.fx
    local _, fxname = R.TrackFX_GetFXName(tr, fx, '')
    fxname = fa.prefix .. (fxname or ''):gsub('^[^:]*: ', '')
    local np = math.min(64, R.TrackFX_GetNumParams(tr, fx))
    for pi = 0, np - 1 do
      local ok, act = R.TrackFX_GetNamedConfigParm(tr, fx, ('param.%d.mod.active'):format(pi))
      if ok and act == '1' then
        local _, pname = R.TrackFX_GetParamName(tr, fx, pi, '')
        local function flag(k) local o, v = R.TrackFX_GetNamedConfigParm(tr, fx, ('param.%d.%s'):format(pi, k)); return o and v == '1' end
        local _, lfo_speed = R.TrackFX_GetNamedConfigParm(tr, fx, ('param.%d.lfo.speed'):format(pi))
        local _, plink_fx = R.TrackFX_GetNamedConfigParm(tr, fx, ('param.%d.plink.effect'):format(pi))
        local _, plink_par = R.TrackFX_GetNamedConfigParm(tr, fx, ('param.%d.plink.param'):format(pi))
        -- все числовые поля для модуляционной матрицы (m.v['lfo.speed'] …)
        local v = {}
        for _, k in ipairs(M.MOD_KEYS) do
          local o, sv = R.TrackFX_GetNamedConfigParm(tr, fx, ('param.%d.%s'):format(pi, k))
          if o then v[k] = tonumber(sv) end
        end
        local link_name
        if v['plink.active'] and v['plink.active'] >= 0.5 and v['plink.effect'] and v['plink.effect'] >= 0 then
          local _, sfx = R.TrackFX_GetFXName(tr, math.floor(v['plink.effect']), '')
          local _, spn = R.TrackFX_GetParamName(tr, math.floor(v['plink.effect']), math.floor(v['plink.param'] or 0), '')
          link_name = ((sfx or ''):gsub('^[^:]*: ', ''):sub(1, 6)) .. '.' .. (spn or '?')
        end
        out[#out + 1] = { fx = fx, fxname = (fxname or ''):gsub('^[^:]*: ', ''), param = pi, pname = pname or ('p' .. pi),
          lfo = flag('lfo.active'), acs = flag('acs.active'), plink = flag('plink.active'),
          lfo_speed = tonumber(lfo_speed), plink_fx = tonumber(plink_fx), plink_par = tonumber(plink_par),
          value = R.TrackFX_GetParamNormalized(tr, fx, pi), v = v, link_name = link_name }
      end
    end
  end
  return out
end

-- ── FX трека для нижней DSP-панели ────────────────────────────────────────
-- Имя, bypass, первые MAXP параметров: нормализованное значение и
-- форматированная строка. Считается в снимке; значения параметров живые —
-- M.fx_values(tr, fx, n) по запросу (кадр).
M.DSP_MAXP = 8
M.dspmods = nil      -- реестр кураторских модулей (jf_tracker_dspmods.lua), ставит main
M.dsp_page = {}      -- 16 окт: страница модуля DSP с pages: имя модуля → номер
M.dsp_fold = false   -- 16 окт: zf — модули со страницами свёрнуты (одна страница) / раскрыты (все сразу)
M.DR = nil           -- 16 окт: jf_tracker_drumrack.lua (drumrs5k), ставит main; M.drum_favs — избранное слотов
-- 16 окт: индексы параметров RS5K по имени (один раз — у всех экземпляров одинаковы, не зашиваем)
local rs5k_pi
-- 18 окт: mute groups drumrs5k — JSFX перед рэком: группа на каждую ноту (слайдер ноты N — параметр N, 0..16)
M.CHOKE = 'jf_tracker_choke'
M.OFF_REL = 1          -- 24 окт: скорость отпускания явного OFF трекера (jf_tracker_choke пропускает только её)
M.CHOKE_SELF = 17      -- 24 окт: choke «сам себя» — one-shot пэд, который обрывает явный OFF
function M.choke_fx(A, tr)
  for i = 0, A.GetCount(tr) - 1 do
    local _, nm = A.GetFXName(tr, i, '')
    if (nm or ''):find(M.CHOKE, 1, true) then return i end
  end
end
function M.rs5k_pidx(A, tr, fx)
  if rs5k_pi then return rs5k_pi end
  local t = {}
  for p = 0, A.GetNumParams(tr, fx) - 1 do
    local _, pn = A.GetParamName(tr, fx, p, ''); pn = (pn or ''):lower()
    if pn == 'sample start offset' then t.start = p elseif pn == 'sample end offset' then t.stop = p
    elseif pn == 'note range start' then t.note = p elseif pn == 'note range end' then t.note_end = p
    elseif pn == 'volume' then t.vol = p elseif pn == 'obey note-offs' then t.obey = p end
  end
  if t.start then rs5k_pi = t end
  return t
end
-- ── адаптер FX (2 окт): цепочка трека или take одним кодом ────────────────
-- obj — MediaTrack* или MediaItem_Take*; M.fxapi(obj) даёт таблицу функций
-- TrackFX_* / TakeFX_* с общими именами (GetCount, GetFXName, …). Отличаются
-- только AddByName, огибающая и копирование — их разбирает edit.
local FXNAMES = { 'GetCount', 'GetFXName', 'GetNumParams', 'GetNamedConfigParm', 'GetEnabled', 'SetEnabled',
  'GetParamName', 'GetParameterStepSizes', 'GetParamEx', 'GetParamNormalized', 'SetParamNormalized',
  'GetFormattedParamValue', 'Show', 'Delete', 'GetFXGUID', 'GetOpen', 'GetParamFromIdent', 'SetNamedConfigParm',
  'GetPreset', 'GetPresetIndex', 'NavigatePresets', 'SetPreset', 'SetPinMappings', 'GetPinMappings', 'GetFloatingWindow', 'FormatParamValueNormalized', 'GetParam', 'SetParam', 'GetIOSize' }   -- 24 окт: GetIOSize — матрица пинов   -- 23 окт: GetParam / SetParam — слайдеры зон jf_tracker_zone в единицах 0..127   -- 22 окт: Format… — текст значения без записи в плагин (ноль в центре)   -- 16 окт: пины — вход RS5K в пэде drumrs5k   -- 11 окт: пресеты — и у take FX (строка < пресет > у всех)   -- Set… (6 окт): parallel / имя в контейнере
local function fx_table(prefix)
  local t = { kind = prefix == 'TakeFX_' and 'take' or 'track' }
  for _, n in ipairs(FXNAMES) do t[n] = R[prefix .. n] end
  return t
end
M.FXT, M.FXK = fx_table('TrackFX_'), fx_table('TakeFX_')
function M.is_take(obj) return obj ~= nil and R.ValidatePtr ~= nil and R.ValidatePtr(obj, 'MediaItem_Take*') end
function M.fxapi(obj) if M.is_take(obj) then return M.FXK end return M.FXT end
-- цепочка take (те же записи, что у трека)
function M.take_fx(take) return M.track_fx(take) end

-- 22 окт: параметр «ноль посередине» (pan, pitch, детюн, ±dB): по тексту крайних значений — отрицательное
-- и положительное, почти симметрично (−24 … +24 да; −inf … +12 dB нет). Имя pan / balance — всегда
function M.bipolar_of(name, s0, s1)
  local n = (name or ''):lower()
  if n:match('%f[%a]pan%f[%A]') or n:match('balance') then return true end   -- pan словом (не panic)
  local a = tonumber((s0 or ''):match('^%s*([-+]?%d+%.?%d*)'))
  local b = tonumber((s1 or ''):match('^%s*([-+]?%d+%.?%d*)'))
  return (a and b and a < 0 and b > 0 and math.abs(a + b) <= 0.1 * math.max(-a, b)) and true or false
end
local bip_cache = {}
-- key — тип плагина и номер параметра: одна и та же раскладка у всех копий
function M.param_bipolar(tr, fx, pi, name, key)
  local c = bip_cache[key]
  if c ~= nil then return c end
  local A = M.fxapi(tr)
  local s0, s1
  if A.FormatParamValueNormalized then
    local ok0, t0 = A.FormatParamValueNormalized(tr, fx, pi, 0, '')
    local ok1, t1 = A.FormatParamValueNormalized(tr, fx, pi, 1, '')
    s0, s1 = ok0 and t0 or nil, ok1 and t1 or nil
  end
  c = M.bipolar_of(name, s0, s1)
  bip_cache[key] = c
  return c
end
-- 22 окт: параметр, который плагин отдаёт непрерывным, а значений у него мало (Surge subtype: Clean / Dirty):
-- 33 точки хода по тексту (FormatParamValueNormalized — без записи); 2..8 разных подписей → ступени,
-- положение ступени — середина её участка. Чистое ядро — M.steps_from_texts (тест).
function M.steps_from_texts(texts)
  local labels, norms, cur, a = {}, {}, nil, nil
  local n = #texts
  if n < 2 then return nil end   -- 25 окт: пусто — падал на a = nil (чёрное окно трекера)
  for k = 1, n do
    local t = texts[k]
    if t == nil or t == '' then return nil end
    if t ~= cur then
      if cur then norms[#norms + 1] = ((a - 1) + (k - 2)) / 2 / (n - 1) end
      cur, a = t, k
      for _, l in ipairs(labels) do if l == t then return nil end end   -- подпись вернулась — не ступени
      labels[#labels + 1] = t
      if #labels > 8 then return nil end
    end
  end
  norms[#norms + 1] = ((a - 1) + (n - 1)) / 2 / (n - 1)
  if #labels < 2 then return nil end
  return labels, norms
end
local disc_cache = {}
function M.discretize(tr, out)
  local A = M.fxapi(tr)
  if not A.FormatParamValueNormalized then return end
  local function one(e, p)
    if p.kind ~= 'slider' or p.show or p.head then return end
    local fx = p.fx or e.i
    local key = (e.fxname or e.name or '?') .. '|' .. tostring(p.fx and 'k' or '') .. '|' .. p.i
    local c = disc_cache[key]
    if c == nil then
      local texts = {}
      for k = 0, 32 do local ok, t = A.FormatParamValueNormalized(tr, fx, p.i, k / 32, ''); texts[#texts + 1] = ok and t or nil end
      local labels, norms = M.steps_from_texts(texts)
      c = labels and { labels = labels, norms = norms } or false
      disc_cache[key] = c
    end
    if c then p.kind, p.nsteps, p.labels, p.stepnorm = 'steps', #c.labels, c.labels, c.norms end
  end
  for _, e in ipairs(out) do for _, p in ipairs(e.params or {}) do one(e, p) end end
end
-- 22 окт: макро-параметры плагина (Macro 1..8, «M1», «Macro A») — главные ручки: в конец списка с пометкой
-- mfader (раскладка не даёт им строк — их рисуют фейдеры слева в модуле), e.nmacro — сколько (≤ 8, от 2)
function M.is_macro_name(name)
  local n = (name or ''):lower()
  return n:match('^%s*macro%s*%d') ~= nil or n:match('^%s*macro%s+%a$') ~= nil or n:match('^%s*m%d%s*$') ~= nil or n:match('^%s*m%d%s*:') ~= nil or n:match('^%s*mc%s*%d') ~= nil   -- m1: имя — Surge XT
end
-- кураторский модуль (Surge) — его список без макросов: дополнить из первых 64 параметров плагина
local function macro_scan(tr, e)
  local A = M.fxapi(tr)
  local have, n = {}, 0
  for _, p in ipairs(e.params) do if not p.fx then have[p.i] = true end; if M.is_macro_name(p.name) then n = n + 1 end end
  if n >= 2 or not (A.GetNumParams and A.GetParamName) then return end
  local np = A.GetNumParams(tr, e.i) or 0
  for pi = 0, math.min(np, 64) - 1 do
    if not have[pi] then
      local _, pn = A.GetParamName(tr, e.i, pi, '')
      if M.is_macro_name(pn) then
        local nm = pn:match('^%s*[Mm]%d%s*:%s*(.-)%s*$')
        e.params[#e.params + 1] = { i = pi, name = (nm and nm ~= '' and nm ~= '-') and nm or pn:gsub(':%s*%-?%s*$', ''), kind = 'slider' }
      end
    end
  end
end
function M.macroize(out, tr)
  for _, e in ipairs(out) do
    if tr and not e.container and not e.kit and e.params and e.i then macro_scan(tr, e) end
    if not e.container and not e.kit and e.params then
      local mac, rest = {}, {}
      for _, p in ipairs(e.params) do
        if #mac < 8 and not p.head and M.is_macro_name(p.name) then mac[#mac + 1] = p else rest[#rest + 1] = p end
      end
      if #mac >= 2 then
        for _, p in ipairs(mac) do p.mfader = true; rest[#rest + 1] = p end
        -- heads (секции) — по номеру параметра: сдвиг из-за переноса макросов в конец
        if e.heads then
          local idx = {}
          for k, p in ipairs(e.params) do idx[p] = k end
          local nh = {}
          for k, p in ipairs(rest) do local h = e.heads[idx[p]]; if h and not p.mfader then nh[k] = h end end
          e.heads = next(nh) and nh or nil
        end
        e.params, e.nmacro = rest, #mac
      end
    end
  end
end
-- 22 окт: имя макроса из плагина (живое: пресет переименовывает) — «M1: Brightness» → Brightness,
-- «Macro 3» / «M2: -» / пусто — без имени (nil). Чистое: M.macro_label(имя параметра)
function M.macro_label(name)
  name = name or ''
  local lab = name:match('^%s*[Mm]%d+%s*:%s*(.-)%s*$') or name:match('^%s*[Mm]acro%s*%d+%s*:%s*(.-)%s*$')
  if not lab then
    if M.is_macro_name(name) then return nil end
    lab = name:match('^%s*(.-)%s*$')
  end
  if lab == '' or lab:match('^[%-%s]+$') then return nil end
  return lab
end
-- имена макросов модулей — заново при каждой сборке (кэш цепочки имён не ловит), 8 вызовов на модуль
function M.macro_labels(tr, out)
  local A = M.fxapi(tr)
  if not A.GetParamName then return end
  for _, e in ipairs(out) do
    if e.nmacro and not e.wrap then   -- 24 окт: у контейнера подпись — то, на что назначен (draw, по связям)
      for _, p in ipairs(e.params) do
        if p.mfader then local _, nm = A.GetParamName(tr, p.fx or e.i, p.i, ''); p.mlabel = M.macro_label(nm) end
      end
    end
  end
end
-- индекс ступени по значению 0..1: у «распознанных» — ближайшая середина участка
function M.step_index(p, v)
  if p.stepnorm then
    local best, bd = 0, nil
    for k, nv in ipairs(p.stepnorm) do local d = math.abs(nv - v); if not bd or d < bd then best, bd = k - 1, d end end
    return best
  end
  return math.floor(v * math.max(1, (p.nsteps or 2) - 1) + 0.5)
end
function M.step_value(p, k)
  if p.stepnorm then return p.stepnorm[k + 1] or 0 end
  return k / math.max(1, (p.nsteps or 2) - 1)
end
local function param_entry(tr, fx, pi, label)
  local A = M.fxapi(tr)
  local _, pname = A.GetParamName(tr, fx, pi, '')
  local kind, nsteps = 'slider', nil
  if A.GetParameterStepSizes then
    local ok, step, small, large, istoggle = A.GetParameterStepSizes(tr, fx, pi)
    if ok then
      if istoggle then kind = 'toggle'
      elseif step and step > 0 then
        local _, mn, mx = A.GetParamEx(tr, fx, pi)
        local n = (mx and mn) and math.floor((mx - mn) / step + 0.5) or 0
        if n >= 1 and n <= 16 then kind, nsteps = 'steps', n + 1 end
      end
    end
  end
  return { i = pi, name = label or pname or ('p' .. pi), kind = kind, nsteps = nsteps }
end

-- Контейнер (REAPER 7): дети по container_item.K (адреса 0x2000000+…, годятся
-- во все TrackFX_*), маршрутизация — parallel ребёнка (0 — за предыдущим,
-- 1 — параллельно ему, 2 — параллельно с суммированием). Параметры детей
-- собираются в один список с префиксом имени — виджеты и клавиши те же.
local function container_children(tr, fx)
  local A = M.fxapi(tr)
  local ok, n = A.GetNamedConfigParm(tr, fx, 'container_count')
  if not ok then return nil end
  n = tonumber(n) or 0
  local kids = {}
  for k = 0, n - 1 do
    local ok2, id = A.GetNamedConfigParm(tr, fx, 'container_item.' .. k)
    id = ok2 and tonumber(id)
    if id then
      local _, nm = A.GetFXName(tr, id, '')
      local _, par = A.GetNamedConfigParm(tr, id, 'parallel')
      local kid = { i = id, name = (nm or ''):gsub('^[^:]*: ', ''), enabled = A.GetEnabled(tr, id),
                    parallel = tonumber(par) or 0, np = A.GetNumParams(tr, id), wet_i = A.GetParamFromIdent and A.GetParamFromIdent(tr, id, ':wet') or nil }   -- 23 окт: wet — громкость цепи в списке
      local ok3 = A.GetNamedConfigParm(tr, id, 'container_count')
      if ok3 then kid.container = true end
      kids[#kids + 1] = kid
    end
  end
  return kids
end

-- ── автомодуль (3 окт) ─────────────────────────────────────────────────────
-- Классификация один раз на тип плагина (имя + число параметров): имена,
-- шаги и текст значения (единицы) первых 512 параметров → FC.auto. Пользовательский
-- модуль (M.user_mods, learn касанием) — приоритетнее; кураторский реестр — тоже.
M.fxclass = nil            -- jf_tracker_fxclass.lua (ставит main)
M.user_mods = nil          -- пользовательские модули: имя FX → { title, cols, params = { {i, label} } }
local auto_cache = {}
local function param_kind(A, tr, fx, pi)
  local kind, nsteps = 'slider', nil
  if A.GetParameterStepSizes then
    local ok, step, small, large, istoggle = A.GetParameterStepSizes(tr, fx, pi)
    if ok then
      if istoggle then kind = 'toggle'
      elseif step and step > 0 then
        local _, mn, mx = A.GetParamEx(tr, fx, pi)
        local n = (mx and mn) and math.floor((mx - mn) / step + 0.5) or 0
        if n >= 1 and n <= 16 then kind, nsteps = 'steps', n + 1 end
      end
    end
  end
  return kind, nsteps
end
M.param_kind = param_kind
-- категория параметра (для цвета) — по имени и единицам, кэш по имени FX
local cat_cache = {}
function M.param_cat(tr, fx, short, pi, pname, kind)
  local key = short .. '|' .. pi
  local c = cat_cache[key]
  if c then return c end
  local A = M.fxapi(tr)
  local ok, units = A.GetFormattedParamValue(tr, fx, pi, '')
  c = M.fxclass and M.fxclass.class(pname or '', ok and units or '', kind) or nil
  cat_cache[key] = c or false
  return c
end
function M.auto_module(tr, fx, short, np)
  local key = short .. '|' .. np
  if auto_cache[key] then return auto_cache[key] end
  local A = M.fxapi(tr)
  local FC = M.fxclass
  local list = {}
  for pi = 0, math.min(np, 512) - 1 do
    local _, pname = A.GetParamName(tr, fx, pi, '')
    local kind, nsteps = param_kind(A, tr, fx, pi)
    local ok, units = A.GetFormattedParamValue(tr, fx, pi, '')
    list[#list + 1] = { i = pi, name = pname or ('p' .. pi), units = ok and units or '', kind = kind, nsteps = nsteps }
  end
  local out
  if FC then
    out = FC.auto(list, 42)            -- до 3 колонок по 14 строк; лишние колонки срежет отрисовка
    local byi = {}
    for _, p in ipairs(list) do byi[p.i] = p end
    for _, a in ipairs(out) do a.nsteps = byi[a.i] and byi[a.i].nsteps end
    -- 22 окт: вкладки по секциям синта (osc filter env lfo mod fx) — из всех параметров, не только 42 главных
    out.pages = FC.pages and FC.pages(list, 42) or nil
    for _, pg in ipairs(out.pages or {}) do for _, a in ipairs(pg.items) do a.nsteps = byi[a.i] and byi[a.i].nsteps end end
  else
    out = {}
    for k = 1, math.min(M.DSP_MAXP, #list) do local p = list[k]; out[k] = { i = p.i, name = p.name, kind = p.kind, nsteps = p.nsteps } end
  end
  auto_cache[key] = out
  return out
end
function M.auto_reset(short) M.fx_gen = M.fx_gen + 1; for k in pairs(auto_cache) do if not short or k:sub(1, #short + 1) == short .. '|' then auto_cache[k] = nil end end end

-- кэш цепочки (3 окт, скорость): пересборка снимка на каждую правку проекта
-- собирала FX заново (90 % времени); цепочка меняется редко — кэш по подписи:
-- число FX, их GUID и bypass, состав контейнеров, счётчик правок модулей
-- (M.fx_gen). Значения параметров читаются вживую каждый кадр (fx_values);
-- файл сэмплера (FILE0) обновляется при каждом обращении.
M.fx_gen = 0
local fx_cache = setmetatable({}, { __mode = 'k' })   -- 8 окт, замер: слабый ключ MediaTrack* живёт и после GC
local build_track_fx
-- 15 окт: пометки у параметров: ~ есть огибающая (автоматизация), % модулируется (LFO / ACS / link);
-- считаются при каждом снимке (в ключ кэша FX не входят) — только у показанных параметров
local function mark_params(tr, A, out)
  for _, e in ipairs(out) do
    for _, p in ipairs(e.params or {}) do
      local fx = p.fx or e.i
      local okm, act = A.GetNamedConfigParm and A.GetNamedConfigParm(tr, fx, ('param.%d.mod.active'):format(p.i))
      p.auto = (R.GetFXEnvelope and not M.is_take(tr) and R.GetFXEnvelope(tr, fx, p.i, false) ~= nil) or false
      p.mod = (okm and act == '1') or false
      p.mk = (p.auto and ' ~' or '') .. (p.mod and ' ≈' or '')   -- 18 окт: модулирован — ≈ (просьба), автоматизирован — ~
    end
  end
end
function M.track_fx(tr)
  local A = M.fxapi(tr)
  if not A.GetCount then return {} end
  local n = A.GetCount(tr)
  local parts = { M.fx_gen, n }
  for fx = 0, n - 1 do
    parts[#parts + 1] = A.GetFXGUID and A.GetFXGUID(tr, fx) or fx
    parts[#parts + 1] = A.GetEnabled(tr, fx) and 1 or 0
    if A.GetNamedConfigParm then
      local ok, cc = A.GetNamedConfigParm(tr, fx, 'container_count')
      if ok then
        parts[#parts + 1] = 'c' .. tostring(cc)
        -- дети (6 окт): bypass / parallel / порядок видны в рамке — в ключ кэша
        for k = 0, (tonumber(cc) or 0) - 1 do
          local ok2, id = A.GetNamedConfigParm(tr, fx, 'container_item.' .. k)
          id = ok2 and tonumber(id)
          if id then
            local _, par = A.GetNamedConfigParm(tr, id, 'parallel')
            parts[#parts + 1] = (A.GetFXGUID and A.GetFXGUID(tr, id) or id) .. (A.GetEnabled(tr, id) and '+' or '-') .. (par or '')
          end
        end
      end
    end
  end
  local key = table.concat(parts, '|')
  local c = fx_cache[tr]
  if c and c.key == key then
    M.bprof.fxhit = (M.bprof.fxhit or 0) + 1
    for _, e in ipairs(c.out) do
      if e.wave and A.GetNamedConfigParm then
        local ok, file = A.GetNamedConfigParm(tr, e.i, 'FILE0')
        e.file = ok and file ~= '' and file or nil
      end
    end
    local view = M.expand_inner(tr, c.out)
    mark_params(tr, A, view)
    M.macro_labels(tr, view)
    return view
  end
  local out = build_track_fx(tr)
  M.discretize(tr, out)   -- 22 окт: «непрерывные» с 2..8 подписями (Surge subtype) — ступени
  M.macroize(out, tr)    -- 22 окт: Macro 1..8 — фейдерами слева в модуле, в конце списка
  -- 23 окт: эффекты полос ÷N — полноценными модулями (так же ступени и макросы)
  for _, e in ipairs(out) do
    if e.bands or e.kit then   -- 23 окт: и эффекты пэдов drumrs5k (и их цепей chain N)
      for _, b in ipairs(e.kids or {}) do
        local lst = {}
        for gi, g in ipairs(b.entry and b.entry.kids or {}) do
          if gi > 1 and g.entry then
            lst[#lst + 1] = g.entry
            for _, g2 in ipairs(g.container and g.entry.kids or {}) do if g2.entry then lst[#lst + 1] = g2.entry end end
          end
        end
        if #lst > 0 then M.discretize(tr, lst); M.macroize(lst, tr) end
      end
    end
  end
  -- 24 окт: эффекты внутри обычного контейнера (вид рэка) — тоже: макросы синта (Surge M1..M8) — колонкой слева,
  -- первыми, а не секцией в конце; без этого Surge в контейнере показывал их страницей MACRO 1-6
  local function deep(e, d)
    for _, kd in ipairs(e.kids or {}) do
      local en = kd.entry
      if en then
        M.discretize(tr, { en }); M.macroize({ en }, tr)
        if en.container and not en.kit and not en.bands and d < 4 then deep(en, d + 1) end
      end
    end
  end
  for _, e in ipairs(out) do if e.container and not e.kit and not e.bands then deep(e, 1) end end
  M.bprof.fxmiss = (M.bprof.fxmiss or 0) + 1
  fx_cache[tr] = { key = key, out = out }
  local view = M.expand_inner(tr, out)
  mark_params(tr, A, view)
  M.macro_labels(tr, view)
  return view
end
-- 23 окт: как Ableton — за контейнером ÷N bands его выбранная полоса: её эффекты (без сплиттера) полноценными
-- модулями DSP (страницы, макросы, огибающие), с пометкой inner = { parent, band }. Адрес эффекта (0x2000000+…)
-- годится во все TrackFX_*; перестановки / щели верхнего уровня их не касаются. Выбор полосы — M.inner_sel(tr, e)
-- 23 окт: drumrs5k — эффекты выбранного пэда (за сэмплером) так же; есть цепи chain N — эффекты выбранной цепи
-- (M.inner_chain(tr, e, ki) — номер строки списка цепей), подпись «пэд > цепь»
local function pad_inner(tr, e, view)
  local ki = M.inner_sel and M.inner_sel(tr, e) or 0
  e._isel = (ki or 0) .. ':' .. tostring(M.inner_chain and M.inner_chain(tr, e, ki) or '')   -- по нему трекер видит смену выбора
  local pad = ki and ki > 0 and e.kids[ki]
  local gk = pad and pad.entry and pad.entry.kids or {}
  if #gk < 2 then return end
  local chains = false
  for gi = 2, #gk do if gk[gi].container and (gk[gi].name or ''):match('^chain') then chains = true end end
  local function push(en, lbl) if en then en.inner = { parent = e, band = lbl, bi = ki }; view[#view + 1] = en end end
  if not chains then
    for gi = 2, #gk do push(gk[gi].entry, pad.name or 'pad') end
    return
  end
  local r = math.max(1, math.min(#gk - 1, (M.inner_chain and M.inner_chain(tr, e, ki)) or 1))
  local sl = gk[r + 1]
  if sl.container and (sl.name or ''):match('^chain') then
    for _, g2 in ipairs(sl.entry and sl.entry.kids or {}) do push(g2.entry, (pad.name or 'pad') .. ' > ' .. (sl.name or 'chain')) end
  else push(sl.entry, pad.name or 'pad') end
end
-- 24 окт: обычный контейнер — обёртка (папка) вокруг полноразмерных модулей: у блока — шапка, макросы, XY;
-- дети — модулями следом (inner.wrap), вложенный контейнер — так же. Плотная пачка — когда детей 2..5 и у
-- каждого не больше 6 параметров (несколько мелких эффектов). Вид руками — M.cont_view(tr, e): 'wrap' | 'pack' | 'list'
function M.cont_mode(tr, e)
  local m = M.cont_view and M.cont_view(tr, e)
  if m then return m end
  local kids = {}
  for _, kd in ipairs(e.kids or {}) do   -- ручки макросов (jf_tracker_macro) — не эффект: в счёт не идут
    if not (kd.entry and (kd.entry.name or ''):find('jf_tracker_macro', 1, true)) then kids[#kids + 1] = kd end
  end
  if #kids < 2 or #kids > 5 then return 'wrap' end
  for _, kd in ipairs(kids) do
    local en = kd.entry
    if not en or en.kids or #(en.params or {}) > 6 then return 'wrap' end
  end
  return 'pack'
end
local function wrap_kids(tr, e, view, depth)
  e.wrap = true
  e.params_all = e.params_all or e.params    -- запись из кеша: полный список — на случай вида pack / list
  -- 25 окт: шапка — ★-параметры (выведенные container_map); снятые ★ — список скрытых в P_EXT трека (REAPER вывод не снимает)
  local macros = {}
  local hid = {}
  local hs = tr and e.fguid and R.GetSetMediaTrackInfo_String and select(2, R.GetSetMediaTrackInfo_String(tr, 'P_EXT:jf_pinhide:' .. e.fguid, '', false)) or ''
  for v in (hs or ''):gmatch('%d+') do hid[tonumber(v)] = true end
  for _, p in ipairs(e.params_all or {}) do if p.macro and not hid[p.i] then macros[#macros + 1] = p end end
  e.macro_n = #macros
  e.params = macros
  if e.xy_own == nil then e.xy_own = { e.xy or false, e.xy_x, e.xy_y } end
  e.xy, e.xy_x, e.xy_y = nil, nil, nil
  -- 24 окт: отделы вертикально, как у модуля с макросами: вкладки macro N / xy (XY на M1 / M2), справа — цепи
  for _, p in ipairs(macros) do p.mfader = true end
  e.nmacro = #macros > 0 and #macros or nil
  for ki, kd in ipairs(e.kids or {}) do
    local en = kd.entry
    if en and (en.name or ''):find('jf_tracker_macro', 1, true) then en = nil end   -- 24 окт: ручки макросов — в шапке контейнера
    if en then
      en.inner = { parent = e, wrap = true, ki = ki, par = kd.parallel or 0, depth = depth }
      en.cend = nil
      view[#view + 1] = en
      if en.container and en.kids and not en.kit and not en.bands and depth < 4 and M.cont_mode(tr, en) == 'wrap' then wrap_kids(tr, en, view, depth + 1) end
    end
  end
  -- 24 окт: параллельные ветки — свой номер (lane) у каждого участника группы: первый (последовательный) и все
  -- следующие за ним с parallel; одиночный последовательный — без номера. Под модулем — скобка цветом ветки
  local grp, lane = {}, 0
  for i = 1, #view do
    local en = view[i]
    if en.inner and en.inner.parent == e then grp[#grp + 1] = en end
  end
  for i, en in ipairs(grp) do
    local par = (en.inner.par or 0) > 0
    local nxt = grp[i + 1] and (grp[i + 1].inner.par or 0) > 0
    if par then lane = lane + 1 elseif nxt then lane = 1 else lane = 0 end
    en.inner.lane = lane > 0 and lane or nil
  end
  -- 24 окт: контейнер — рэк из трёх частей (шапка, эффекты, замыкание): после последнего потомка — колонка «out»
  -- (cend — контейнеры, которые тут кончаются, внутренний первым; пустой контейнер замыкается сам за собой)
  local last = view[#view]
  last.cend = last.cend or {}
  last.cend[#last.cend + 1] = e
end
M.wrap_kids = wrap_kids
function M.expand_inner(tr, out)
  local has = false
  for _, e in ipairs(out) do if e.bands or e.kit or (e.container and e.kids) then has = true; break end end
  if not has then for _, e in ipairs(out) do e.cend = nil end; return out end
  local view = {}
  for _, e in ipairs(out) do
    e.cend = nil
    view[#view + 1] = e
    if e.container and e.kids and not e.kit and not e.bands then
      if M.cont_mode(tr, e) == 'wrap' then wrap_kids(tr, e, view, 1)
      elseif e.wrap then   -- вид pack / list: вернуть полный список параметров
        e.wrap = nil; e.params = e.params_all or e.params
        if e.xy_own then e.xy, e.xy_x, e.xy_y = e.xy_own[1] or nil, e.xy_own[2], e.xy_own[3] end
        for _, p in ipairs(e.params) do if p.macro then p.mfader = nil end end   -- 24 окт: в пачке — обычные параметры
        e.nmacro = nil
      end
    end
    if e.kit and e.kids then pad_inner(tr, e, view) end
    if e.bands and e.kids and #e.kids > 0 then
      local bi = math.max(1, math.min(#e.kids, (M.inner_sel and M.inner_sel(tr, e)) or 1))
      e._isel = tostring(M.inner_sel and M.inner_sel(tr, e) or '')
      local b = e.kids[bi]
      for gi, g in ipairs(b.entry and b.entry.kids or {}) do
        if gi > 1 and g.entry then
          g.entry.inner = { parent = e, band = b.name or ('band ' .. bi), bi = bi }
          view[#view + 1] = g.entry
        end
      end
    end
  end
  return view
end

-- один эффект по адресу fx (верхний уровень или ребёнок контейнера) → в out;
-- 6 окт: вынесено из цикла, чтобы дети контейнера строились тем же модулем
local build_one
function build_track_fx(tr)
  local out = {}
  local A = M.fxapi(tr)
  if not A.GetCount then return out end
  for fx = 0, A.GetCount(tr) - 1 do
    local _, nm = A.GetFXName(tr, fx, '')
    -- 18 окт: измерители роутера и mute groups пэдов (jf_tracker_choke) — не эффекты списка
    if not ((nm or ''):find('jf_tracker_probe', 1, true) or (nm or ''):find(M.CHOKE, 1, true)) then build_one(tr, fx, out) end
  end
  return out
end
function build_one(tr, fx, out)
  local A = M.fxapi(tr)
  do
    local _, name = A.GetFXName(tr, fx, '')
    local np = A.GetNumParams(tr, fx)
    local params = {}
    local short = (name or ''):gsub('^[^:]*: ', '')
    local um = M.user_mods and M.user_mods[short]
    local lay = (not um) and M.dspmods and M.dspmods.match(short)
    -- 10 окт: переименованный плагин (RS5K берёт имя сэмпла) — раскладка по original_name, имя — своё
    local renamed
    if not lay and not um and M.dspmods and A.GetNamedConfigParm then
      local okn, orig = A.GetNamedConfigParm(tr, fx, 'original_name')
      if okn and orig and orig ~= '' then lay = M.dspmods.match((orig:gsub('^[^:]*: ', ''))); renamed = lay and short end
    end
    local kids = A.GetNamedConfigParm and container_children(tr, fx)
    if kids then
      -- контейнер: сначала его макросы (нативные container_map — параметры
      -- детей, выведенные наружу; на них работает обычная модуляция), затем
      -- дети + их первые параметры (по 4 на ребёнка), 2 колонки
      for pi = 0, np - 1 do
        local _, pn = A.GetParamName(tr, fx, pi, '')
        -- 25 окт: выведенные параметры детей (★ в шапке контейнера); ручки старого jf_tracker_macro — не показываем
        if pn and pn ~= '' and pn ~= 'Bypass' and pn ~= 'Wet' and pn ~= 'Delta' and not pn:find('jf_tracker_macro', 1, true) then
          local e = param_entry(tr, fx, pi)
          local fxn, prn = pn:match('^(.-):%s*(.+)$')
          e.pinfx, e.pinname = fxn, prn or pn
          e.name = prn or pn
          e.macro = true
          params[#params + 1] = e
        end
      end
      -- 6 окт: дети — полным модулем (кураторский / свой / автомодуль), как на
      -- верхнем уровне; e.kid — колонка ребёнка в развёрнутой рамке
      local has_m = #params > 0
      for ki, kid in ipairs(kids) do
        local one = {}
        build_one(tr, kid.i, one)
        kid.entry = one[1]
        for _, e0 in ipairs(one[1] and one[1].params or {}) do
          local e = {}
          for k2, v2 in pairs(e0) do e[k2] = v2 end
          e.fx = e0.fx or kid.i      -- адрес ребёнка (внука — свой): fx_values / fx_param идут по нему
          e.ggkid = e0.gkid          -- 23 окт: третий уровень (цепь chain N внутри пэда): номер эффекта в цепи
          e.gkid = e0.kid            -- 23 окт: ребёнок-контейнер — номер внука в нём (полосы ÷N: цепь полосы)
          e.kid = ki
          params[#params + 1] = e
        end
      end
      -- 11 окт: кит — все дети RS5K (конвертация слайсов): две колонки — список
      -- слайсов и свойства выбранного (draw.kit_sel), а не колонка на каждого
      local kit = #kids > 1
      for _, kid in ipairs(kids) do if not (kid.entry and kid.entry.rs5k) then kit = false; break end end
      -- 20 окт: мультисэмпл bouncer («multisample …») — не кит: ноты хроматикой, RS5K по зонам и слоям velocity
      local multi = short:lower():find('^multisample') ~= nil
      if multi then kit = false end
      -- 16 окт: drumrs5k — пэд и подконтейнером [RS5K, эффекты пэда]; у пэда — его RS5K,
      -- файл, кусок a..b (доли файла), нота и категории эффектов (слоты)
      if not multi and M.DR and M.DR.is_rack(kids) then
        kit = true
        local chi = M.choke_fx(A, tr)
        for _, kid in ipairs(kids) do
          local re, rid = M.DR.pad_rs5k(kid)
          kid.rs5k_i, kid.file = rid, re and re.file
          local pi = M.rs5k_pidx(A, tr, rid)
          kid.pad_a = pi.start and A.GetParamNormalized(tr, rid, pi.start) or 0
          kid.pad_b = pi.stop and A.GetParamNormalized(tr, rid, pi.stop) or 1
          kid.note = pi.note and math.floor(A.GetParamNormalized(tr, rid, pi.note) * 127 + 0.5) or nil
          kid.obey = pi.obey and A.GetParamNormalized(tr, rid, pi.obey) >= 0.5 or false   -- 19 окт: волна пэда на треке — до OFF (obey) / до конца сэмпла
          -- 18 окт: mute group пэда — слайдер его ноты в jf_tracker_choke (0 — без группы)
          kid.choke = (chi and kid.note) and math.floor((A.GetParam and A.GetParam(tr, chi, kid.note) or A.GetParamNormalized(tr, chi, kid.note) * 16) + 0.5) or 0   -- 24 окт: значение слайдера (0..17), не доля
          -- 19 окт: group (слайдер 129+ноты) — пэды группы звучат вместе (слой прямо в рэке)
          kid.group = (chi and kid.note and A.GetNumParams(tr, chi) > 128 + kid.note) and math.floor(A.GetParamNormalized(tr, chi, 128 + kid.note) * 16 + 0.5) or 0
          kid.slots = {}
          if kid.entry and kid.entry.container then
            for gi, g in ipairs(kid.entry.kids or {}) do
              if gi > 1 then
                local cat = M.DR.cat_of(g.name, M.drum_favs) or ('x' .. gi)
                kid.slots[#kid.slots + 1] = { cat = cat, i = g.i, name = M.DR.short(g.name), enabled = g.enabled, gi = gi,
                                              wet_i = g.wet_i, parallel = g.parallel,
                                              chain = (g.container and (g.name or ''):match('^chain')) and (g.entry and g.entry.kids or {}) or nil }   -- 23 окт: цепь пэда — её эффекты
              end
            end
          end
        end
      end
      out[#out + 1] = { i = fx, name = short, enabled = A.GetEnabled(tr, fx), np = np, params = params,
                        cols = kit and 2 or math.max(1, (has_m and 1 or 0) + #kids), container = true, kids = kids, has_macros = has_m, kit = kit or nil,
                        bands = (not kit and short:match('^÷%d')) and true or nil,   -- 23 окт: ÷N bands — список полос + кроссовер + цепь полосы
                        fguid = A.GetFXGUID and A.GetFXGUID(tr, fx) or nil }   -- 19 окт: ключ курсора рэка (номер едет, когда чок встаёт первым)
    elseif um then
      -- пользовательский модуль (learn касанием): параметры по номерам
      for _, sp in ipairs(um.params or {}) do
        if sp.i < np then
          local e = param_entry(tr, fx, sp.i, sp.label)
          e.cat = M.param_cat(tr, fx, short, sp.i, e.name, e.kind)
          params[#params + 1] = e
        end
      end
      local ue = { i = fx, name = um.title or short, enabled = A.GetEnabled(tr, fx), np = np, params = params, cols = um.cols or 2, user = true, fxname = short }
      -- XY-пэд своего модуля (5 окт): оси — параметры плагина из learn (X / Y)
      if um.xy_x and um.xy_y then
        for k, e in ipairs(params) do if e.i == um.xy_x then ue.xy_x = k end; if e.i == um.xy_y then ue.xy_y = k end end
        if ue.xy_x and ue.xy_y then ue.xy = true; ue.cols = math.max(2, ue.cols) end   -- пэд — первая колонка, параметры — правее
      end
      out[#out + 1] = ue
    elseif lay then
      -- кураторский модуль: параметры по подстроке имени, в порядке реестра
      -- 16 окт: страницы (pages — вкладки модуля: своё имя, группы, параметры); номер — M.dsp_page[имя]
      local lay_pages, lay_page
      -- 16 окт (вечер): по умолчанию раскрыто — все страницы одним пейном (группы подряд); zf в DSP —
      -- свернуть: одна страница, вертикальные вкладки справа у блока
      if lay.pages then
        lay_pages = {}
        for k2, p2 in ipairs(lay.pages) do lay_pages[k2] = p2.name end
        -- группа страницы → заголовок секции перед своими rows параметрами: пропавший параметр не
        -- сдвигает соседние группы, колонки текут по высоте блока (секции потоком, 13 окт)
        local function sections(p2, ps)
          local per = p2.rows or lay.rows or 6
          for gi, g in ipairs(p2.groups or {}) do
            ps[#ps + 1] = { head = g }
            for k2 = (gi - 1) * per + 1, math.min(#p2.params, gi * per) do ps[#ps + 1] = p2.params[k2] end
          end
        end
        local ps = {}
        if M.dsp_fold then
          lay_page = math.max(1, math.min(#lay.pages, M.dsp_page[lay.title or short] or 1))
          sections(lay.pages[lay_page], ps)
        else
          for _, p2 in ipairs(lay.pages) do sections(p2, ps) end
        end
        lay = setmetatable({ params = ps, groups = false, cols = lay.cols, rows = false }, { __index = lay })
      end
      local names = {}
      local np_all = np
      np = lay.scan and math.min(np, lay.scan) or np          -- 16 окт: Surge — 2858 параметров, сцена A — в первых 700
      for pi = 0, np - 1 do local _, pn = A.GetParamName(tr, fx, pi, ''); names[pi] = (pn or ''):lower() end
      local wa, wb, e_xy_x, e_xy_y, e_view_p
      -- ReaEQ (7 окт): полосы по именам параметров, в порядке появления
      local dyn = {}
      if lay.dyn_eq then
        local order, by = {}, {}
        for pi = 0, np - 1 do
          local _, raw = A.GetParamName(tr, fx, pi, '')
          local kind, band = (raw or ''):match('^(%a+)%-(.+)$')
          local bk = ({ Freq = 'f', Gain = 'g', BW = 'q' })[kind or '']
          if bk then
            if not by[band] then by[band] = {}; order[#order + 1] = band end
            by[band][bk] = pi
          end
        end
        for k, band in ipairs(order) do
          local lb = band:lower()
          local bt = lb:find('low shelf') and 'ls' or (lb:find('high shelf') and 'hs') or (lb:find('low pass') and 'lp') or (lb:find('high pass') and 'hp')
            or (lb:find('notch') and 'nt') or (lb:find('band pass') and 'bp') or 'pk'
          for _, bk in ipairs({ 'f', 'g', 'q' }) do
            local pi = by[band][bk]
            if pi then
              local e = param_entry(tr, fx, pi, k .. ' ' .. bk)
              e.band, e.bk, e.btype = k, bk, bt
              e.cat = M.param_cat(tr, fx, short, pi, names[pi], e.kind)
              params[#params + 1] = e
            end
          end
        end
        if #params > 0 then
          for pi = 0, np - 1 do if names[pi] == 'global gain' then params[#params + 1] = param_entry(tr, fx, pi, 'gain') end end
          dyn = { done = true }
        end
      end
      local heads, phead = {}, nil                 -- 13 окт: заголовки секций ({ head = 'DRIVE' } в списке): перед параметром
      for _, spec in ipairs(dyn.done and {} or lay.params) do
        if spec.head then phead = spec.head; goto next_spec end
        local want = spec[1]:lower()
        for pi = 0, np - 1 do
          -- exact (5 окт): имя целиком (Amigo: «Loop» иначе находит «Loop Start»)
          if (spec.exact and names[pi] == want) or (not spec.exact and names[pi]:find(want, 1, true)) then
            params[#params + 1] = param_entry(tr, fx, pi, spec[2])
            params[#params].cat = M.param_cat(tr, fx, short, pi, names[pi], params[#params].kind)
            params[#params].labels = spec.labels                     -- 9 окт: подписи положений (пульт slixer)
            params[#params].show = spec.show                         -- 10 окт: вид значения (RS5K: note / root / chan)
            if lay.wave and want == lay.wave.start then wa = #params end
            if lay.wave and want == lay.wave.stop then wb = #params end
            if lay.view_param and spec[2] == lay.view_param then e_view_p = #params end
            if lay.xy and want == lay.xy.x then e_xy_x = #params end
            if lay.xy and want == lay.xy.y then e_xy_y = #params end
            if phead then heads[#params] = phead; phead = nil end
            break
          end
        end
        ::next_spec::
      end
      local e = { i = fx, name = renamed or lay.title or short, enabled = A.GetEnabled(tr, fx), np = np, params = params, cols = lay.cols or 1, rs5k = lay.rs5k,
                  groups = lay.groups, rows = lay.rows,                -- 9 окт: колонка = группа с заголовком
                  heads = next(heads) and heads or nil, colw = lay.colw }   -- 13 окт: секции потоком, ширина колонки (знаков)
      e.np = np_all
      if lay_pages then e.pages, e.page = lay_pages, lay_page end   -- 16 окт: вкладки модуля
      -- живой вид модуля (гранулятор): какой и какой параметр тянется по нему
      if lay.view then e.view, e.view_p = lay.view, e_view_p end
      -- XY-пэд (TG33 vector): индексы параметров X / Y
      if lay.xy and e_xy_x and e_xy_y then e.xy, e.xy_x, e.xy_y = true, e_xy_x, e_xy_y end
      -- волна сэмплера (RS5K): файл FILE0, индексы start / end в params
      if lay.wave and A.GetNamedConfigParm then
        local ok, file = A.GetNamedConfigParm(tr, fx, 'FILE0')
        e.wave, e.file, e.wave_a, e.wave_b = true, ok and file ~= '' and file or nil, wa, wb
        -- 10 окт: RS5K — режим (named config MODE: 0 freely, 1 sample, 2 note) и число файлов FILE0..n
        if lay.rs5k then
          local okm, m = A.GetNamedConfigParm(tr, fx, 'MODE'); e.rs5k_mode = okm and tonumber(m) or nil
          local nf = 0
          for fi = 0, 127 do local okf, fl = A.GetNamedConfigParm(tr, fx, 'FILE' .. fi); if okf and fl ~= '' then nf = fi + 1 else break end end
          e.rs5k_n = nf
        end
      end
      out[#out + 1] = e
    else
      -- автомодуль (3 окт): любой эффект — параметры по категориям и
      -- подгруппам (jf_tracker_fxclass.lua), кэш на тип плагина
      local am = M.auto_module(tr, fx, short, np)
      local apages, apage, aheads
      if am.pages and M.dsp_fold then   -- 22 окт: zP свёрнуто — одна страница, вкладки (main + секции); страница — M.dsp_page[имя]
        apages = {}
        for k2, pg in ipairs(am.pages) do apages[k2] = pg.name end
        apage = math.max(1, math.min(#am.pages, M.dsp_page[short] or 1))
        am = am.pages[apage].items
      elseif am.pages then
        -- 22 окт: zP развёрнуто (по умолчанию) — все секции одним пейном, заголовками: сначала главное вне секций, потом osc filter …
        local insec, list = {}, {}
        aheads = {}
        for k2 = 2, #am.pages do for _, a in ipairs(am.pages[k2].items) do insec[a.i] = true end end
        local first = true
        for _, a in ipairs(am.pages[1].items) do if not insec[a.i] then if first then aheads[#list + 1] = 'main'; first = false end; list[#list + 1] = a end end
        for k2 = 2, #am.pages do
          aheads[#list + 1] = am.pages[k2].name
          for _, a in ipairs(am.pages[k2].items) do list[#list + 1] = a end
        end
        am = list
      end
      for _, a in ipairs(am) do
        params[#params + 1] = { i = a.i, name = a.name, kind = a.kind, nsteps = a.nsteps, cat = a.cat, group = a.group }
      end
      local cols = math.max(1, math.min(3, math.ceil(#params / 8)))
      -- Airwindows (4 окт): имя без «(airwindows)» — по нему категория и описание (Airwindopedia)
      local aw = short:match('^(.-)%s*%([Aa]irwindows%)')
      out[#out + 1] = { i = fx, name = short, enabled = A.GetEnabled(tr, fx), np = np, params = params, cols = cols, auto = true, airwin = aw,
                        vproc = short:lower():find('video processor', 1, true) ~= nil,   -- 11 окт: Video processor — строка code / редактор кода
                        pages = apages, page = apage, heads = aheads }
    end
  end
end

function M.fx_values(tr, f)
  local A = M.fxapi(tr)
  local v = {}
  for k, p in ipairs(f.params) do
    local id = p.fx or f.i
    local ok, str = A.GetFormattedParamValue(tr, id, p.i, '')
    v[k] = { n = A.GetParamNormalized(tr, id, p.i), s = ok and str or '' }
  end
  return v
end

-- ── огибающие трека (показ, вертикально) ──────────────────────────────────
-- Видимые и активные огибающие трека; диапазон — из BR_EnvGetProperties (SWS),
-- без SWS — 0..1 и все огибающие. Точки и значения не кешируются: считаются
-- только для видимых строк (M.env_values), это дёшево.
-- lpb — для automation items (дробные строки начала/конца, цвет темы env_item_*)
-- ключ темы огибающей — как у аранжировки (пары «Envelope: …» / ключ из
-- бинарника REAPER): громкость col_env2 (pre-FX col_env1), панорама col_env4
-- (pre-FX col_env3), ширина и громкость посыла col_env7, панорама посыла
-- col_env8, playrate / tempo мастера col_env5 / 6, параметры FX — по кругу
-- col_env13..16 (nfx — сколько FX-огибающих уже было на треке).
function M.env_key(name, nfx)
  local nm = (name or ''):lower()
  local pre = nm:find('pre%-fx') ~= nil
  if nm:find('/') then return 'col_env' .. (13 + (nfx or 0) % 4) end   -- «Параметр / FX»
  if nm:find('trim') then return 'env_trim_vol' end
  if nm:find('send') then
    if nm:find('mute') then return 'env_sends_mute' end
    if nm:find('pan') then return 'col_env8' end
    return 'col_env7'
  end
  if nm:find('volume') then return pre and 'col_env1' or 'col_env2' end
  if nm:find('pan') then return pre and 'col_env3' or 'col_env4' end
  if nm:find('width') then return 'col_env7' end
  if nm:find('mute') then return 'env_track_mute' end
  if nm:find('playrate') then return 'col_env5' end
  if nm:find('tempo') then return 'col_env6' end
  return 'col_env' .. (13 + (nfx or 0) % 4)
end

-- MIDI-лейны трека (6 окт): события MIDI items, не огибающие. Лейн — CC по
-- номеру, pc (program change), tx (текст / нотация REAPER: артикуляции), sx
-- (SysEx). ev[row] = { v = значение, text = подпись, n = событий в строке }.
-- M.extra_lanes[guid] = { 74, 'pc', … } — пустые лейны, добавленные :cc N / :pc
M.extra_lanes = {}
function M.track_midilanes(tr, lpb, guid)
  local by = {}
  local function lane(key, kind, num)
    local l = by[key]
    if not l then l = { key = key, kind = kind, num = num, ev = {} }; by[key] = l end
    return l
  end
  local function put(l, row, v, text)
    local e = l.ev[row]
    if e then e.n = e.n + 1; e.v = v; e.text = text or e.text else l.ev[row] = { v = v, text = text, n = 1 } end
  end
  for i = 0, R.CountTrackMediaItems(tr) - 1 do
    local it = R.GetTrackMediaItem(tr, i)
    local tk = R.GetActiveTake(it)
    if tk and R.TakeIsMIDI(tk) then
      local _, _, ccn, txn = R.MIDI_CountEvts(tk)
      for k = 0, (ccn or 0) - 1 do
        local _, _, _, ppq, chanmsg, _, m2, m3 = R.MIDI_GetCC(tk, k)
        local row = math.floor(M.row_of_time(R.MIDI_GetProjTimeFromPPQPos(tk, ppq), lpb) + 1e-6)
        if chanmsg == 0xB0 then put(lane('cc' .. m2, 'cc', m2), row, m3)
        elseif chanmsg == 0xC0 then put(lane('pc', 'pc'), row, m2)
        -- 11 окт: aftertouch (канальный / полифонический) и pitch bend — тоже лейны (записывались, но не были видны)
        elseif chanmsg == 0xD0 then put(lane('at', 'at'), row, m2)
        elseif chanmsg == 0xA0 then put(lane('pat', 'pat'), row, m3)
        elseif chanmsg == 0xE0 then put(lane('pb', 'pb'), row, ((m3 or 0) * 128 + (m2 or 0)) // 128) end
      end
      for k = 0, (txn or 0) - 1 do
        local _, _, _, ppq, typ, msg = R.MIDI_GetTextSysexEvt(tk, k)
        local row = math.floor(M.row_of_time(R.MIDI_GetProjTimeFromPPQPos(tk, ppq), lpb) + 1e-6)
        if typ == -1 then put(lane('sx', 'sx'), row, #(msg or ''), ('%02X'):format((msg or ''):byte(1) or 0))
        elseif typ == 15 and ((msg or ''):find('jf_soff=', 1, true) or (msg or ''):find('jf_nx=', 1, true)) then
          -- 19 окт: служебная метка 0Sxx ноты кита — видна командой у ноты, не текстом в лейне
        elseif typ and typ >= 1 then
          -- нотация REAPER: «NOTE ch pitch articulation staccato …» — слово после articulation
          local t = msg or ''
          t = t:match('articulation%s+(%S+)') or t:match('text%s+(%S+)') or t
          put(lane('tx', 'tx'), row, 0, t)
        end
      end
    end
  end
  for _, x in ipairs(M.extra_lanes[guid] or {}) do
    if type(x) == 'number' then lane('cc' .. x, 'cc', x) elseif x == 'pc' then lane('pc', 'pc') end
  end
  local out = {}
  for _, l in pairs(by) do
    -- 11 окт: poly AT только с нулями (контроллер шлёт 0 при отпускании) — не лейн: курсор туда не встаёт
    local zero = l.kind == 'pat'
    if zero then for _, e in pairs(l.ev) do if (e.v or 0) > 0 then zero = false; break end end end
    if not zero then out[#out + 1] = l end
  end
  local ORD = { at = 0, pat = 0.5, pb = 0.7, cc = 1, pc = 2, tx = 3, sx = 4 }
  table.sort(out, function(a, b) if ORD[a.kind] ~= ORD[b.kind] then return ORD[a.kind] < ORD[b.kind] end return (a.num or 0) < (b.num or 0) end)
  for _, l in ipairs(out) do
    l.name = l.kind == 'cc' and ('CC' .. l.num) or ({ pc = 'PC', tx = 'art', at = 'AT', pat = 'PAT', pb = 'PB' })[l.kind] or 'SX'
    l.rows = {}
    for r in pairs(l.ev) do l.rows[#l.rows + 1] = r end
    table.sort(l.rows)
  end
  return out
end

-- 11 окт: колонка cmd мастера — маркеры проекта по строкам (не регионы и не
-- служебные «=…» трекера). Тот же вид, что MIDI-лейн: ev[row] = { text, n, idx },
-- rows — по порядку. Маркер «!<действие>» REAPER сам исполняет при проигрывании
function M.cmd_lane(lpb)
  local ml = { kind = 'cmd', name = 'cmd', ev = {}, rows = {} }
  local i = 0
  while true do
    local ret, isrgn, pos, _, name, idx = R.EnumProjectMarkers3(0, i)
    if not ret or ret == 0 then break end
    name = name or ''
    if not isrgn and not name:match('^=') and not name:match('^v:') and not name:match('^ch:') then   -- 11 окт: v: — колонка visor; 21 окт: ch: — аккорды
      local r = M.row_of_qn(R.TimeMap2_timeToQN(0, pos), lpb)
      local e = ml.ev[r]
      if e then e.n = e.n + 1; e.text = e.text .. ' ' .. name; e.idx[#e.idx + 1] = idx
      else ml.ev[r] = { text = name, n = 1, idx = { idx }, pos = pos }; ml.rows[#ml.rows + 1] = r end
    end
    i = i + 1
  end
  table.sort(ml.rows)
  return ml
end

-- 11 окт: колонка visor мастера — маркеры «v:<сцена или пресет ReaVisor>»: в строке
-- маркера visor переключается на эту сцену (игра проходит строку)
-- 21 окт: колонка chord мастера — маркеры «ch:Am7»: аккорды песни (chord lane), читают chordfollow и harmonizer
function M.chord_lane(lpb)
  local ml = { kind = 'chd', name = 'chord', ev = {}, rows = {} }
  local i = 0
  while true do
    local ret, isrgn, pos, _, name, idx = R.EnumProjectMarkers3(0, i)
    if not ret or ret == 0 then break end
    local nm = not isrgn and (name or ''):match('^ch:%s*(.-)%s*$')
    if nm then
      local r = M.row_of_qn(R.TimeMap2_timeToQN(0, pos), lpb)
      if not ml.ev[r] then ml.ev[r] = { text = nm, n = 1, idx = { idx }, pos = pos }; ml.rows[#ml.rows + 1] = r
      else ml.ev[r].n = ml.ev[r].n + 1; ml.ev[r].idx[#ml.ev[r].idx + 1] = idx end
    end
    i = i + 1
  end
  table.sort(ml.rows)
  return ml
end
function M.vis_lane(lpb)
  local ml = { kind = 'vis', name = 'visor', ev = {}, rows = {} }
  local i = 0
  while true do
    local ret, isrgn, pos, _, name, idx = R.EnumProjectMarkers3(0, i)
    if not ret or ret == 0 then break end
    local nm = not isrgn and (name or ''):match('^v:%s*(.-)%s*$')
    if nm then
      local r = M.row_of_qn(R.TimeMap2_timeToQN(0, pos), lpb)
      if not ml.ev[r] then ml.ev[r] = { text = nm, n = 1, idx = { idx }, pos = pos }; ml.rows[#ml.rows + 1] = r
      else ml.ev[r].n = ml.ev[r].n + 1; ml.ev[r].idx[#ml.ev[r].idx + 1] = idx end
    end
    i = i + 1
  end
  table.sort(ml.rows)
  return ml
end

function M.track_envs(tr, lpb)
  local out = {}
  local nfx = 0
  if not R.CountTrackEnvelopes then return out end
  for i = 0, R.CountTrackEnvelopes(tr) - 1 do
    local env = R.GetTrackEnvelope(tr, i)
    local _, name = R.GetEnvelopeName(env, '')
    local vis, mn, mx = true, 0, 1
    if R.BR_EnvAlloc then
      local be = R.BR_EnvAlloc(env, false)
      if be then
        local active, visible, _, _, _, _, a, b = R.BR_EnvGetProperties(be)
        R.BR_EnvFree(be, false)
        vis = active and visible
        -- 13 окт: темп мастера — колонка всегда (REAPER прячет огибающую темпа, когда маркеры темпа ставят из API)
        if active and (name or ''):lower():find('tempo') then vis = true end
        if a and b and b > a then mn, mx = a, b end
      end
    end
    if vis then
      -- цвет как в аранжировке: ключ темы по типу огибающей
      local nm = (name or ''):lower()
      local key = M.env_key(name, nfx)
      if key:match('^col_env1[3-6]$') then nfx = nfx + 1 end
      -- границы в шкале огибающей (6 окт): громкость фейдерная — сырые значения
      -- точек лежат в ней; амплитудные границы BR давали зигзаг там, где REAPER
      -- рисует плоско. amin / amax — исходные (амплитуда), для подписей
      local smode = R.GetEnvelopeScalingMode and R.GetEnvelopeScalingMode(env) or 0
      local smn, smx = mn, mx
      if smode ~= 0 then smn, smx = R.ScaleToEnvelopeMode(smode, mn), R.ScaleToEnvelopeMode(smode, mx) end
      local e = { env = env, name = name or '', min = smn, max = smx, amin = mn, amax = mx, smode = smode, key = key, idx = i, ais = {} }
      -- automation items: как в аранжировке — цвет темы по типу огибающей
      e.ai_key = (nm:find('volume') and 'env_item_vol') or (nm:find('pan') and 'env_item_pan')
                 or (nm:find('mute') and 'env_item_mute') or 'env_item_pitch'
      if lpb and R.CountAutomationItems then
        for k = 0, R.CountAutomationItems(env) - 1 do
          local pos = R.GetSetAutomationItemInfo(env, k, 'D_POSITION', 0, false)
          local len = R.GetSetAutomationItemInfo(env, k, 'D_LENGTH', 0, false)
          local ai = { r0 = R.TimeMap2_timeToQN(0, pos) * lpb, r1 = R.TimeMap2_timeToQN(0, pos + len) * lpb,
                       sel = R.GetSetAutomationItemInfo(env, k, 'D_UISEL', 0, false) ~= 0, idx = k, pos = pos, len = len }
          -- подпись как в аранжировке: «пул: имя огибающей» (или имя пула)
          local pid = math.floor((R.GetSetAutomationItemInfo(env, k, 'D_POOL_ID', 0, false) or 0) + 0.5)
          local pname = R.GetSetAutomationItemInfo_String and select(2, R.GetSetAutomationItemInfo_String(env, k, 'P_POOL_NAME', '', false)) or ''
          ai.label = (pname and pname ~= '') and pname or ('%d: %s'):format(pid + 1, name or '')
          -- луп (2 окт): стыки повторов пула — срезами, как в аранжировке
          if R.GetSetAutomationItemInfo(env, k, 'D_LOOPSRC', 0, false) ~= 0 then
            local pq = R.GetSetAutomationItemInfo(env, k, 'D_POOL_QNLEN', 0, false) or 0
            local rate = R.GetSetAutomationItemInfo(env, k, 'D_PLAYRATE', 0, false) or 1
            local offs = R.GetSetAutomationItemInfo(env, k, 'D_STARTOFFS', 0, false) or 0
            if pq > 1e-6 and rate > 1e-6 then
              ai.loop_rows = pq / rate * lpb
              local q0 = R.TimeMap2_timeToQN(0, pos)
              local offs_rows = (R.TimeMap2_timeToQN(0, pos + offs) - q0) * lpb
              ai.loop_first = ai.r0 + (ai.loop_rows - (offs_rows % ai.loop_rows))
            end
          end
          e.ais[#e.ais + 1] = ai
        end
      end
      out[#out + 1] = e
    end
  end
  return out
end

-- n равномерных отсчётов огибающей на [t0, t1) (0..1) — мини-автоматизация
-- в ячейке матрицы
function M.env_samples(e, t0, t1, n)
  local out = {}
  local span = e.max - e.min
  for i = 1, n do
    local _, raw = R.Envelope_Evaluate(e.env, t0 + (t1 - t0) * (i - 0.5) / n, 0, 0)
    local v = span > 0 and ((raw or 0) - e.min) / span or 0
    out[i] = math.max(0, math.min(1, v))
  end
  return out
end

-- значения огибающей по строкам вида: v 0..1, pt — в строке есть точка
M.ENV_SUB = 4   -- подточек на строку — линия без изломов
function M.env_values(e, rows)
  local out = {}
  local span = e.max - e.min
  local function norm(raw)
    local v = span > 0 and ((raw or 0) - e.min) / span or 0
    if v < 0 then v = 0 elseif v > 1 then v = 1 end
    return v
  end
  -- 25 окт: темп мастера — по карте темпа REAPER (TimeMap), не по точкам огибающей: смены темпа видны,
  -- даже когда точек нет (карта и огибающая разошлись); ramp — плавный подъём / спад после смены (^ / v)
  local tempo = (e.name or ''):lower():find('tempo', 1, true) and R.TimeMap2_GetNextChangeTime
  for i, r in ipairs(rows) do
    local _, raw = R.Envelope_Evaluate(e.env, r.t, 0, 0)
    if tempo then raw = R.TimeMap2_GetDividedBpmAtTime(0, r.t + 1e-6) end
    local v = norm(raw)
    local nxt = rows[i + 1] and rows[i + 1].t or (r.t + (r.t - (rows[i - 1] and rows[i - 1].t or (r.t - 0.1))))
    local sub = {}
    for j = 1, M.ENV_SUB - 1 do
      local _, rv = R.Envelope_Evaluate(e.env, r.t + (nxt - r.t) * j / M.ENV_SUB, 0, 0)
      sub[j] = norm(rv)
    end
    local pt, shape = false, nil
    -- 6 окт: под automation item — точки его пула (все проходы лупа, как
    -- видны в аранжировке; опция aipoints), точки огибающей под ним скрыты
    local ai
    for _, a in ipairs(e.ais or {}) do
      if a.pos and r.t >= a.pos - 1e-9 and r.t < a.pos + a.len then ai = a end
    end
    if ai then
      if M.aipoints ~= false and R.GetEnvelopePointByTimeEx then
        local idx = R.GetEnvelopePointByTimeEx(e.env, ai.idx, nxt - 1e-6)
        if idx and idx >= 0 then
          local ok, pt_t, _, shp = R.GetEnvelopePointEx(e.env, ai.idx, idx)
          if ok and pt_t >= r.t - 1e-6 and pt_t < nxt - 1e-9 then pt = true; shape = shp end
        end
      end
    else
      local idx = R.GetEnvelopePointByTime(e.env, nxt - 1e-6)
      if idx and idx >= 0 then
        local ok, pt_t, _, shp = R.GetEnvelopePoint(e.env, idx)
        if ok and pt_t >= r.t - 1e-6 then pt = true; shape = shp end
      end
    end
    local ramp
    if tempo then
      local ct = i == 1 and r.t < 1e-6 and 0 or R.TimeMap2_GetNextChangeTime(0, r.t - 1e-6)
      if ct and ct >= r.t - 1e-6 and ct < nxt - 1e-9 then
        pt = true
        local nc = R.TimeMap2_GetNextChangeTime(0, ct + 1e-6)
        local b0 = R.TimeMap2_GetDividedBpmAtTime(0, ct + 1e-4)
        local t1 = (nc and nc > ct) and (nc - 1e-4) or (ct + 4)
        local b1 = R.TimeMap2_GetDividedBpmAtTime(0, t1)
        if math.abs(b1 - b0) > 0.5 then ramp = b1 > b0 and '^' or 'v' end
        raw = b0; v = norm(raw)
      end
    end
    out[i] = { v = v, pt = pt, raw = raw, sub = sub, shape = shape, ramp = ramp }
  end
  return out
end

-- ── регионы (матрица паттернов) ───────────────────────────────────────────
-- EnumProjectMarkers3 в 7.81 помечен «discouraged» (новые: GetNumRegionsOrMarkers,
-- GetRegionOrMarker, GetSetRegionOrMarkerInfo_String), но сигнатуры новых в
-- строках бинарника нет — берём старую, она работает. Кеш по ключу снимка.
function M.regions(lpb)
  local key = string.format('%d|%d', R.GetProjectStateChangeCount(0), lpb)
  if rcache.key == key then return rcache.list end
  local out = {}
  local markers = {}      -- маркеры для линейки трекера (2 окт): имя, строка (дробная), цвет
  -- библиотека паттернов: всё после маркера =LIB не входит в последовательность
  local lib_pos, end_pos, start_pos
  local i = 0
  while true do
    local ret, isrgn, pos, _, name, idx, color = R.EnumProjectMarkers3(0, i)
    if not ret or ret == 0 then break end
    if not isrgn then
      if name == M.LIB_MARKER then lib_pos = pos end
      if name == M.END_MARKER then end_pos = pos end
      if name == M.START_MARKER and not start_pos then start_pos = pos end
      markers[#markers + 1] = { idx = idx, name = name or '', pos = pos, row_f = R.TimeMap2_timeToQN(0, pos) * lpb, color = color }
    end
    i = i + 1
  end
  i = 0
  while true do
    local ret, isrgn, pos, rgnend, name, idx, color = R.EnumProjectMarkers3(0, i)
    if not ret or ret == 0 then break end
    if isrgn then
      local qn0, qn1 = R.TimeMap2_timeToQN(0, pos), R.TimeMap2_timeToQN(0, rgnend)
      local r0 = M.row_of_qn(qn0, lpb)
      local r1 = M.row_of_qn(qn1, lpb)
      out[#out + 1] = { idx = idx, name = name or '', pos = pos, rgnend = rgnend,
                        qn0 = qn0, qn1 = qn1, r0 = r0, r1 = r1, color = color,
                        -- библиотека — после =LIB И после =END (2 окт: =LIB, поставленный
                        -- раньше =END, прятал регионы последовательности)
                        lib = end_pos ~= nil and pos >= end_pos - 1e-6 and name ~= '=SESSION',   -- 8 окт: паттерны библиотеки — регионы после =END (маркера =LIB нет)
                        session = name == '=SESSION' }
    end
    i = i + 1
  end
  table.sort(out, function(a, b) return a.pos < b.pos end)
  -- 12 окт: секции (регион без кода поверх паттернов) — не слоты: отдельным списком out.sections
  local secs = {}
  if M.SEC then
    local pats
    pats, secs = M.SEC.split(out)
    out = pats
  end
  out.sections = secs
  out.lib_pos = lib_pos
  out.end_pos, out.start_pos = end_pos, start_pos   -- для последовательности без перебора маркеров каждый кадр
  out.markers = markers
  rcache.key, rcache.list = key, out
  return out
end
M.LIB_MARKER = '=LIB'
M.SESSION_REGION = '=SESSION'   -- зона сессии (6 окт): не слот, не паттерн
M.SHOW_ZONE = false             -- трекер показывает зону (сессия играет), ставит main
function M.session_zone()
  if not R.EnumProjectMarkers3 then return nil end
  local i = 0
  while true do
    local ret, isrgn, pos, rgnend, name = R.EnumProjectMarkers3(0, i)
    if not ret or ret == 0 then return nil end
    if isrgn and name == M.SESSION_REGION then return { pos, rgnend } end
    i = i + 1
  end
end

-- Паттерны: уникальные имена регионов; номер — минимальный idx экземпляра,
-- источник — первый экземпляр в последовательности (иначе в библиотеке).
function M.patterns(regions)
  local by = {}
  local list = {}
  for _, rg in ipairs(regions) do
    if rg.name ~= '' then
      local p = by[rg.name]
      if not p then p = { name = rg.name, num = rg.idx, src = nil, n = 0 }; by[rg.name] = p; list[#list + 1] = p end
      if rg.idx < p.num then p.num = rg.idx end
      if not rg.lib and not rg.session then p.n = p.n + 1 end
      if not p.src or (p.src.lib and not rg.lib) then p.src = rg end
    end
  end
  -- устойчивый порядок: по имени (без регистра, числа по значению), номер =
  -- позиция в списке. Раньше номер = минимальный idx региона с этим именем —
  -- после смены слота имена переезжали, номера пересчитывались, и стрелки
  -- < > прыгали через паттерны.
  local function key(nm) return (nm:lower():gsub('%d+', function(d) return ('%08d'):format(tonumber(d)) end)) end
  table.sort(list, function(a, b) return key(a.name) < key(b.name) end)
  for i, p in ipairs(list) do p.num = i end
  return list, by
end

-- ── пики (этап 2) ─────────────────────────────────────────────────────────
-- Вертикальная волна item: npix пиков (по пикселю на строку высоты).
-- Кеш по GUID item + offs/len/rate + npix. Пики, которых у REAPER ещё нет,
-- достраиваются порциями (BUILD_STEPS за вызов), чтобы окно не замирало.
-- кеш волн с пределом (5 окт): новый ключ на каждую ширину / зум / item —
-- без предела рос всю сессию; > 600 — сброс, видимые пересчитаются за кадры
local peaks_n = 0
local peaks_pts = 0   -- 19 окт: объём кэша в точках (запись — до 16384 точек max + min + spec; по числу записей 600 — до сотен МБ)
M.PEAKS_PTS_MAX = 1500000
local function new_peaks()
  peaks_n, peaks_pts = 0, 0
  return setmetatable({}, { __newindex = function(t, k, v)
    rawset(t, k, v); peaks_n = peaks_n + 1
    if type(v) == 'table' and v.n then peaks_pts = peaks_pts + v.n * (v.spec and 3 or 2) end
  end })
end
local peaks = new_peaks()
local building = {}
M.BUILD_STEPS = 40

-- Офлайн-источник (REAPER держит медиа офлайн: длина 0, пиков нет) —
-- подменяем свежим PCM-источником из того же файла (кеш по пути).
local fresh_src = {}
function M.online_src(src)
  if not src then return nil end
  local len = R.GetMediaSourceLength(src)
  if len and len > 0 then return src end
  local fn = R.GetMediaSourceFileName(src, '')
  if not fn or fn == '' then return src end
  local f = fresh_src[fn]
  if f == nil then
    f = R.PCM_Source_CreateFromFile(fn) or false
    fresh_src[fn] = f
  end
  return f or src
end

-- want_spec — ещё и спектральная окраска REAPER (extra_type 115: в каждом
-- пике 32-бит слово, младшие 15 бит — частота в Гц)
-- stretch-маркеры как карта «время item → время источника» (2 окт): список
-- { pos, src } по pos и подпись для ключа кэша пиков; nil, если маркеров нет
-- обратная карта (5 окт): позиция маркера-источника u (в долях при playrate,
-- как GetTakeStretchMarker) → время item; вне маркеров — наклон 1
function M.item_time_of_src(pts, u)
  if not pts or #pts == 0 then return nil end
  if u <= pts[1].src then return pts[1].pos - (pts[1].src - u) end
  for k = 1, #pts - 1 do
    local a, b = pts[k], pts[k + 1]
    if u <= b.src then
      local d = b.src - a.src
      return d > 1e-9 and (a.pos + (u - a.src) / d * (b.pos - a.pos)) or a.pos
    end
  end
  local z = pts[#pts]
  return z.pos + (u - z.src)
end

function M.stretch_map(take)
  if not take or not R.GetTakeNumStretchMarkers then return nil end
  local n = R.GetTakeNumStretchMarkers(take)
  if n == 0 then return nil end
  local pts, sig = {}, {}
  for i = 0, n - 1 do
    local _, pos, src = R.GetTakeStretchMarker(take, i)
    if pos and src then pts[#pts + 1] = { pos = pos, src = src }; sig[#sig + 1] = ('%.4f:%.4f'):format(pos, src) end
  end
  if #pts == 0 then return nil end
  table.sort(pts, function(a, b) return a.pos < b.pos end)
  return pts, table.concat(sig, ',')
end

-- время item t → секунды источника по карте маркеров. Позиция маркера в
-- источнике у REAPER — в долях при playrate (3 окт: конец 2.667 при rate 1.5 =
-- 4.0 с файла; раньше бралась как секунды — волна показывала 2/3 файла):
-- карта считается в этих долях (вне маркеров — наклон 1), потом × rate
local function map_src(pts, t, rate)
  local function u()
    if t <= pts[1].pos then return pts[1].src - (pts[1].pos - t) end
    for k = 1, #pts - 1 do
      local a, b = pts[k], pts[k + 1]
      if t <= b.pos then
        local d = b.pos - a.pos
        return d > 1e-9 and (a.src + (t - a.pos) / d * (b.src - a.src)) or a.src
      end
    end
    local z = pts[#pts]
    return z.src + (t - z.pos)
  end
  return u() * rate
end

-- stretch-маркеры take → доли длины item (0..1); nil, если нет
function M.stretch_fracs(take, len)
  if not take or not R.GetTakeNumStretchMarkers or len <= 0 then return nil end
  local n = R.GetTakeNumStretchMarkers(take)
  if n == 0 then return nil end
  local out, src = {}, {}
  -- 16 окт: и где удар был без растяжки (srcpos от начала файла в единицах rate; минус offset) — линия «откуда куда»
  local rate = R.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
  local o0 = R.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') / ((rate and rate > 0) and rate or 1)
  for i = 0, n - 1 do
    local _, pos, sp = R.GetTakeStretchMarker(take, i)
    if pos and pos > 1e-6 and pos < len - 1e-6 then out[#out + 1] = pos / len; src[#out] = sp and (sp - o0) / len or pos / len end
  end
  if #out == 0 then return nil end
  -- 16 окт: скорости отрезков (как в REAPER: 0.95x 1.11x …): все маркеры с краями, rate = Δsrc / Δpos
  local all = {}
  for i = 0, n - 1 do
    local _, pos, sp = R.GetTakeStretchMarker(take, i)
    all[#all + 1] = { p = pos, s = sp, sl = R.GetTakeStretchMarkerSlope and R.GetTakeStretchMarkerSlope(take, i) or 0 }   -- 16 окт: наклон отрезка
  end
  table.sort(all, function(a, b) return a.p < b.p end)
  local segs = {}
  for i = 1, #all - 1 do
    local a, b = all[i], all[i + 1]
    local dp = b.p - a.p
    if dp > 1e-6 then segs[#segs + 1] = { f0 = math.max(0, a.p / len), f1 = math.min(1, b.p / len), r = (b.s - a.s) / dp, sl = a.sl or 0 } end
  end
  src.segs = segs
  return out, src
end

M.OVERSAMPLE = 1   -- 1/2/4: пиков на пиксель (Options → wave detail); max/min по группе
function M.peaks(head, npix, want_spec)
  if not head.src or npix < 2 then return nil end
  if peaks_n > 600 or peaks_pts > M.PEAKS_PTS_MAX then peaks = new_peaks() end
  npix = math.floor(npix)
  -- луп (2 окт): пики одного периода источника, разложенные по item по модулю
  -- периода (раньше читался «источник» за его концом — волна сбивалась)
  if head.loop_src and not head._lin and not head.smap then
    local per = head.loop_src
    local rate = (head.rate and head.rate > 0) and head.rate or 1
    local key = ('%s|loop|%.4f|%.4f|%.4f|%d%s|%d'):format(head.guid, per, head.offs or 0, head.len, npix, want_spec and 's' or '', M.OVERSAMPLE or 1)
    local p = peaks[key]
    if p then return p end
    local nlin = math.max(2, math.min(16384, math.floor(npix * per * rate / math.max(1e-6, head.len)) * 2 + 2))
    local lin = M.peaks({ src = head.src, guid = head.guid .. '|loopsrc', offs = 0, len = per, rate = 1, _lin = true }, nlin, want_spec)
    if not lin then return nil end
    local out = { n = npix, max = {}, min = {}, spec = lin.spec and {} or nil }
    local function pick(a, b, acc)          -- a..b — секунды источника внутри [0, per)
      local ja = math.max(1, math.min(lin.n, math.floor(a / per * lin.n) + 1))
      local jb = math.max(ja, math.min(lin.n, math.floor(b / per * lin.n)))
      for j = ja, jb do
        if lin.max[j] > acc[1] then acc[1] = lin.max[j] end
        if lin.min[j] < acc[2] then acc[2] = lin.min[j] end
      end
      return ja
    end
    for i = 1, npix do
      local s0 = (head.offs or 0) + (i - 1) / npix * head.len * rate
      local s1 = (head.offs or 0) + i / npix * head.len * rate
      local a, b = s0 % per, s1 % per
      local acc = { -2, 2 }
      local ja
      if s1 - s0 >= per then ja = pick(0, per, acc)
      elseif b >= a then ja = pick(a, b, acc)
      else ja = pick(a, per, acc); pick(0, b, acc) end
      out.max[i], out.min[i] = acc[1] > -2 and acc[1] or 0, acc[2] < 2 and acc[2] or 0
      if out.spec then out.spec[i] = lin.spec[ja] end
    end
    peaks[key] = out
    return out
  end
  -- stretch-маркеры (2 окт): пики источника читаются линейно, потом
  -- раскладываются по карте «время item → время источника», как в REAPER
  if head.smap and not head._lin then
    local key = ('%s|smap|%s|%.4f|%.4f|%d%s|%d'):format(head.guid, head.smap_sig or '', head.len, head.rate, npix, want_spec and 's' or '', M.OVERSAMPLE or 1)
    local p = peaks[key]
    if p then return p end
    local rate = (head.rate and head.rate > 0) and head.rate or 1
    local srcs, lo, hi = {}, math.huge, -math.huge
    for i = 0, npix do
      local s = map_src(head.smap, i / npix * head.len, rate)
      srcs[i] = s
      if s < lo then lo = s end
      if s > hi then hi = s end
    end
    if lo < 0 then lo = 0 end
    if hi - lo < 1e-4 then return nil end
    local nlin = math.min(16384, npix * 2)
    local lin = M.peaks({ src = head.src, guid = head.guid .. '|lin', offs = lo, len = hi - lo, rate = 1, _lin = true }, nlin, want_spec)
    if not lin then return nil end
    local out = { n = npix, max = {}, min = {}, spec = lin.spec and {} or nil }
    local span = hi - lo
    for i = 1, npix do
      local a, b = srcs[i - 1], srcs[i]
      if a > b then a, b = b, a end
      local ja = math.max(1, math.min(lin.n, math.floor((a - lo) / span * lin.n) + 1))
      local jb = math.max(ja, math.min(lin.n, math.floor((b - lo) / span * lin.n)))
      local mx, mn = -2, 2
      for j = ja, jb do
        if lin.max[j] > mx then mx = lin.max[j] end
        if lin.min[j] < mn then mn = lin.min[j] end
      end
      out.max[i], out.min[i] = mx > -2 and mx or 0, mn < 2 and mn or 0
      if out.spec then out.spec[i] = lin.spec[ja] end
    end
    peaks[key] = out
    return out
  end
  local os = M.OVERSAMPLE or 1
  -- период лупа и длина источника — в ключе (5 окт): шов лупа меняет секцию
  -- источника, а guid / offs / len те же — волна оставалась старой
  -- 21 окт: ключ — раз на голову (она живёт снимок, поля в нём не меняются) и ширину: format на каждую голову
  -- каждый кадр был мусором волн
  local key
  if head._pk_n == npix and head._pk_s == (want_spec or false) and head._pk_o == os then key = head._pk
  else
    key = string.format('%s|%.4f|%.4f|%.4f|%d%s|%d|%.4f|%s', head.guid, head.offs, head.len, head.rate, npix, want_spec and 's' or '', os, head.loop_src or 0, tostring(head.src))
    head._pk, head._pk_n, head._pk_s, head._pk_o = key, npix, want_spec or false, os
  end
  local p = peaks[key]
  if p ~= nil then
    -- отрицательный результат (офлайн-медиа, ещё нет пиков) — не навсегда: повтор через 2 с
    if p == false then return nil end
    if p.retry then if R.time_precise() < p.retry then return nil end; peaks[key] = nil
    else return p end
  end
  local src = M.online_src(head.src)
  local span = head.len * head.rate            -- секунды источника под item
  if span <= 0 then peaks[key] = false; return nil end
  local function fetch(n, et)
    local b = R.new_array(n * (et == 115 and 3 or 2)); b.clear()
    local r = R.PCM_Source_GetPeaks(src, n / span, head.offs, 1, n, et, b)
    return r, r & 0xfffff, b
  end
  -- блоки буфера (4 окт): max — n запрошенных точек, за ним min — тоже со
  -- сдвигом n ЗАПРОШЕННЫХ, а не полученных (spl < n у края источника — min
  -- читались из max, нижняя половина волны пропадала)
  local nreq = math.min(npix * os, 16384)
  local rv, spl, buf = fetch(nreq, 0)
  if spl == 0 then
    -- пиков нет: запускаем достройку, результат — на следующих кадрах
    local b = building[key]
    if not b then
      if R.PCM_Source_BuildPeaks(src, 0) ~= 0 then building[key] = { src = src, t0 = R.time_precise() }
      else
        -- пики уже есть на диске, но свежий источник их ещё не подхватил:
        -- финализировать и сразу перечитать (как build_env слайсера)
        R.PCM_Source_BuildPeaks(src, 2)
        rv, spl, buf = fetch(nreq, 0)
        if spl == 0 then peaks[key] = { retry = R.time_precise() + 2.0 }; return nil end
      end
      if spl == 0 then return nil end
    else
      -- достройка не завершается (медиа ушло офлайн, источник сменился) —
      -- через 4 с бросаем и пробуем заново, иначе волна пропадает навсегда
      if R.time_precise() - (b.t0 or 0) > 4 then building[key] = nil; peaks[key] = { retry = R.time_precise() + 1.0 }; return nil end
      for _ = 1, M.BUILD_STEPS do
        if R.PCM_Source_BuildPeaks(b.src or src, 1) == 0 then
          R.PCM_Source_BuildPeaks(b.src or src, 2); building[key] = nil; break
        end
      end
      return nil
    end
  end
  if spl == 0 then return nil end
  -- «Сырой» режим (биты 20..23 rv ≠ 0): на высокой плотности REAPER отдаёт
  -- по одному сэмплу на точку, огибающая теряется (тонкая линия при громком
  -- сэмпле, 1 окт). Просим реже, пока не вернутся пары max/min, и
  -- растягиваем на сетку npix.
  local n = math.min(npix * os, 16384)
  -- 19 окт: короткий кусок (слайс в пару строк) — плотность выше файла пиков, а при уменьшении на пиксель
  -- оставалось по сэмплу (волна — линия у нуля): просим сэмплы густо и собираем max / min по пикселю сами
  if (rv >> 20) & 0xF ~= 0 then
    local nd = math.min(16384, math.max(npix * 8, math.floor(span * 16000)))
    if nd >= npix * 4 and nd <= 16384 then
      local r2, s2, b2 = fetch(nd, 0)
      if s2 > 0 then rv, spl, buf, nreq = r2, s2, b2, nd; n = 32 end   -- сырые сэмплы густо — без уменьшения ниже
    end
  end
  while (rv >> 20) & 0xF ~= 0 and n > 32 do
    n = n // 2
    local r2, s2, b2 = fetch(n, 0)
    if s2 == 0 then break end
    rv, spl, buf, nreq = r2, s2, b2, n
  end
  local t = buf.table()
  local raw = (rv >> 20) & 0xF ~= 0
  local out = { n = npix, max = {}, min = {} }
  -- точек больше, чем пикселей (передискретизация) — max/min по группе;
  -- меньше — растяжка (одна точка на несколько пикселей)
  for i = 1, npix do
    local j0 = math.floor((i - 1) / npix * spl) + 1
    local j1 = math.max(j0, math.floor(i / npix * spl))
    local mx, mn = -2, 2
    for j = j0, j1 do
      local a, b
      if raw then a = t[j]; b = a else a = t[j]; b = t[nreq + j] end
      if a and a > mx then mx = a end
      if b and b < mn then mn = b end
    end
    if mx < -1 then mx = 0 end; if mn > 1 then mn = 0 end
    out.max[i], out.min[i] = mx, mn
  end
  -- спектр (extra_type 115): всегда отдельным запросом на ~200 точек/с —
  -- на пиксельной плотности бита 0x1000000 нет; растягиваем на сетку
  if want_spec then
    local n2 = math.max(2, math.min(npix, math.floor(span * 200)))
    local r2, s2, b2 = fetch(n2, 115)
    if s2 > 0 and (r2 >> 20) & 0xF == 0 and r2 & 0x1000000 ~= 0 then
      local t2 = b2.table()
      out.spec = {}
      for i = 1, npix do out.spec[i] = t2[2 * n2 + math.floor((i - 1) / npix * s2) + 1] end   -- блок spec — после 2 × n2 запрошенных
    end
  end
  -- сплошной ноль = пики ещё не подхвачены (свежий источник офлайн-файла
  -- сначала отдаёт тишину) — не кешировать навсегда, перечитать через 1 с
  local peak = 0
  for i = 1, npix do local a = math.abs(out.max[i] or 0); if a > peak then peak = a end; a = math.abs(out.min[i] or 0); if a > peak then peak = a end end
  if peak < 1e-4 then
    R.PCM_Source_BuildPeaks(src, 0); R.PCM_Source_BuildPeaks(src, 2)
    peaks[key] = { retry = R.time_precise() + 1.0 }
    return nil
  end
  peaks[key] = out
  return out
end

-- пики файла браузера: PCM-источник живёт в кеше (до FILE_SRC_MAX), пики — M.peaks
local file_src, file_src_n, file_src_order = {}, 0, {}
M.FILE_SRC_MAX = 300
-- 16 окт: a, b — кусок файла (доли 0..1, пэд drumrs5k), spec — спектральные пики
function M.file_peaks(path, npix, a, b, spec)
  local e = file_src[path]
  if e == nil then
    local src = R.PCM_Source_CreateFromFile(path)
    if not src then file_src[path] = false; return nil end
    local len = R.GetMediaSourceLength(src) or 0
    e = { src = src, guid = 'file:' .. path, offs = 0, len = len, rate = 1 }
    file_src[path] = e
    file_src_n = file_src_n + 1; file_src_order[#file_src_order + 1] = path
    if file_src_n > M.FILE_SRC_MAX then
      local old = table.remove(file_src_order, 1)
      local oe = file_src[old]
      if oe and oe.src then pcall(R.PCM_Source_Destroy, oe.src) end
      file_src[old] = nil; file_src_n = file_src_n - 1
    end
  end
  if not e or e.len <= 0 then return nil end
  if (a and a > 0) or (b and b < 1) or spec then
    a, b = math.max(0, a or 0), math.min(1, b or 1)
    if b - a < 1e-5 then return nil end
    return M.peaks({ src = e.src, guid = ('%s|%.5f|%.5f'):format(e.guid, a, b), offs = a * e.len, len = (b - a) * e.len, rate = 1 }, npix, spec)
  end
  return M.peaks(e, npix)
end
-- длина файла из того же кеша (после file_peaks), секунды; nil — не знаем
function M.file_len(path) local e = file_src[path]; return e and e.len or nil end

function M.clear_peaks() peaks = new_peaks(); building = {} end
M.peaks_cache_size = function() return peaks_n end   -- 19 окт: счётчик, не обход каждый кадр

return M
