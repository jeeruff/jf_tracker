-- jf_tracker_theory.lua — 21 окт: теория для harmonizer (чистый Lua, тест tests/test_theory.lua).
--
-- Из скриптов пользователя (без reaper.*):
--   лады и scale_pitches  — jf_chordcheat.lua (SCALES, 14 + гармонический / натуральный минор, блюз)
--   chroma / best_chord / сегменты — jf_chorddetect.lua (Goertzel-банк → 12 бинов, шаблоны аккордов)
--   parse_prog («Am 2 | F 2 | G7 1», и ступенями «I V vi IV») — jf_chordcheat.lua, ступени — новое
-- Плюс: лад по нотам по всем ладам, голосоведение (минимальное движение голосов), гармонизация мелодии.
-- Шаблоны аккордов — из jf_tracker_chord.lua (CH.T): одна таблица на MIDI и аудио.

local TH = {}
local CH

function TH.init(ch) CH = ch end

-- ── лады: шаги (полутоны) ─────────────────────────────────────────────────
TH.SCALES = {
  { id = 'major',     name = 'major',             iv = { 2, 2, 1, 2, 2, 2, 1 } },
  { id = 'minor',     name = 'minor',             iv = { 2, 1, 2, 2, 1, 2, 2 } },
  { id = 'dorian',    name = 'dorian',            iv = { 2, 1, 2, 2, 2, 1, 2 } },
  { id = 'phrygian',  name = 'phrygian',          iv = { 1, 2, 2, 2, 1, 2, 2 } },
  { id = 'lydian',    name = 'lydian',            iv = { 2, 2, 2, 1, 2, 2, 1 } },
  { id = 'mixo',      name = 'mixolydian',        iv = { 2, 2, 1, 2, 2, 1, 2 } },
  { id = 'locrian',   name = 'locrian',           iv = { 1, 2, 2, 1, 2, 2, 2 } },
  { id = 'harmmin',   name = 'harmonic minor',    iv = { 2, 1, 2, 2, 1, 3, 1 } },
  { id = 'melmin',    name = 'melodic minor',     iv = { 2, 1, 2, 2, 2, 2, 1 } },
  { id = 'phrygdom',  name = 'phrygian dominant', iv = { 1, 3, 1, 2, 1, 2, 2 } },
  { id = 'majpent',   name = 'major pentatonic',  iv = { 2, 2, 3, 2, 3 } },
  { id = 'minpent',   name = 'minor pentatonic',  iv = { 3, 2, 2, 3, 2 } },
  { id = 'blues',     name = 'blues',             iv = { 3, 2, 1, 1, 3, 2 } },
  { id = 'wholetone', name = 'whole tone',        iv = { 2, 2, 2, 2, 2, 2 } },
  { id = 'octatonic', name = 'octatonic',         iv = { 1, 2, 1, 2, 1, 2, 1, 2 } },
}
TH.BY = {}
for i, sc in ipairs(TH.SCALES) do TH.BY[sc.id] = sc; sc.i = i end

-- классы ступеней лада от тоники root: { pc … } (первая — тоника)
function TH.pcs(root, id)
  local sc = TH.BY[id] or TH.BY.major
  local out, c = { root % 12 }, root
  for k = 1, #sc.iv - 1 do c = c + sc.iv[k]; out[#out + 1] = c % 12 end
  return out
end
function TH.in_scale(p, root, id)
  for _, pc in ipairs(TH.pcs(root, id)) do if p % 12 == pc then return true end end
  return false
end
-- ближайшая ступень лада (равно — вниз)
function TH.snap(p, root, id)
  if TH.in_scale(p, root, id) then return p end
  for d = 1, 6 do
    if TH.in_scale(p - d, root, id) then return p - d end
    if TH.in_scale(p + d, root, id) then return p + d end
  end
  return p
end
-- сдвиг по ступеням лада (диатонический транспоз): нота вне лада — сначала к ступени
function TH.step(p, n, root, id)
  local pcs = TH.pcs(root, id)
  p = TH.snap(p, root, id)
  local oct, idx = math.floor((p - root) / 12), nil
  for k, pc in ipairs(pcs) do if (p - root) % 12 == (pc - root) % 12 then idx = k end end
  if not idx then return p + n end
  local m = #pcs
  local j = idx - 1 + n
  local o2 = oct + math.floor(j / m)
  local k2 = j % m + 1
  return root + o2 * 12 + (pcs[k2] - root) % 12
end

-- лад по нотам: лучший по всем ладам (вес тоники и квинты ×1.3, 7-ступенные впереди при равенстве);
-- ids — какие лады пробовать (по умолчанию все 7-ступенные)
function TH.detect(pitches, ids)
  local cnt = {}
  for i = 0, 11 do cnt[i] = 0 end
  for _, p in ipairs(pitches or {}) do cnt[p % 12] = cnt[p % 12] + 1 end
  ids = ids or { 'major', 'minor', 'dorian', 'mixo', 'phrygian', 'lydian', 'harmmin', 'melmin' }
  local best, br, bid = 0, nil, nil
  for _, id in ipairs(ids) do
    for r = 0, 11 do
      local s, pcs = 0, TH.pcs(r, id)
      for k, pc in ipairs(pcs) do s = s + cnt[pc] * ((k == 1 or k == 5) and 1.3 or 1) end
      local miss = 0
      for pc = 0, 11 do if cnt[pc] > 0 and not TH.in_scale(pc, r, id) then miss = miss + cnt[pc] end end
      s = s - 1.5 * miss
      s = s + 0.05 * cnt[r]   -- равенство множеств (A minor = D dorian …) — за тоникой, что звучит чаще
      if s > best + 1e-9 then best, br, bid = s, r, id end
    end
  end
  return br, bid
end

-- ── аккорды ступеней лада ─────────────────────────────────────────────────
-- аккорд ступени k (1..): терции лада от ступени; seventh — с септимой → имя по CH.name
function TH.degree_chord(root, id, k, seventh)
  local pcs = TH.pcs(root, id)
  local m = #pcs
  local notes = {}
  local base = 60 + (pcs[(k - 1) % m + 1] - 60) % 12
  local prev = base - 1
  for t = 0, (seventh and 3 or 2) do
    local pc = pcs[(k - 1 + 2 * t) % m + 1]
    local p = prev + 1 + (pc - (prev + 1)) % 12
    notes[#notes + 1] = p; prev = p
  end
  return CH.name(notes), notes
end
local ROMAN = { i = 1, ii = 2, iii = 3, iv = 4, v = 5, vi = 6, vii = 7 }
-- «vi», «V7», «iv», «bVII», «ii°» → имя аккорда в ладу
function TH.roman(tok, root, id)
  local acc, rn, suf = tok:match('^([b#]?)([IViv]+)(.*)$')
  if not rn then return nil end
  local k = ROMAN[rn:lower()]
  if not k then return nil end
  local seventh = suf:match('7') ~= nil
  local nm = TH.degree_chord(root, id, k, seventh)
  if acc ~= '' or rn ~= rn:lower() and rn:upper() ~= rn then return nil end
  -- регистр: прописные — мажор, строчные — минор (как пишут): поправить качество, если лад дал другое
  local c = CH.parse(nm)
  if not c then return nm end
  local pc = (c.root + (acc == 'b' and -1 or (acc == '#' and 1 or 0))) % 12
  local q
  if suf:match('[°o]') then q = seventh and 'm7b5' or 'dim'
  elseif rn == rn:upper() then q = seventh and (suf:match('maj') and 'maj7' or '7') or ''
  else q = seventh and 'm7' or 'm' end
  return CH.NAMES[pc + 1] .. q
end
-- прогрессия: «Am 2 | F 2 | G7 1» или «I V vi IV» (длина — в тактах, нет — 1) →
-- { { sym, dur, at } … }, общая длина; ошибка — nil, текст
function TH.parse_prog(s, root, id)
  local steps = {}
  for tok in (s or ''):gmatch('[^|,]+') do
    for word, dur in tok:gmatch('(%S+)%s*([%d%.]*)') do
      if not tonumber(word) then
        local sym = (CH.parse(word) and word) or (root and TH.roman(word, root, id or 'major'))
        if not sym then return nil, ('not a chord: %s'):format(word) end
        steps[#steps + 1] = { sym = sym, dur = tonumber(dur) or 1 }
      elseif #steps > 0 then steps[#steps].dur = tonumber(word) end
    end
  end
  if #steps == 0 then return nil, 'empty' end
  local t = 0
  for _, st in ipairs(steps) do st.at = t; t = t + st.dur end
  return steps, t
end

-- ── голосоведение ─────────────────────────────────────────────────────────
-- ноты аккорда sym ближе всего к prev (сумма движений голосов): перебор обращений и октав вокруг центра;
-- style: 'close' (по умолчанию) | 'open' (drop-2) ; bass — отдельный бас корнем ниже
function TH.voice_lead(sym, prev, center, style)
  local c = CH.parse(sym)
  if not c then return nil end
  center = center or 60
  local pcs = {}
  for _, iv in ipairs(c.ints) do pcs[#pcs + 1] = (c.root + iv) % 12 end
  local n = #pcs
  local best, bc
  for inv = 0, n - 1 do
    for oct = -2, 2 do
      local v, prevp = {}, nil
      for k = 0, n - 1 do
        local pc = pcs[(inv + k) % n + 1]
        local p
        if not prevp then p = center + oct * 12 + (pc - center) % 12 - 12 + (pc - (center - 12)) % 12 - (pc - center) % 12
          p = (center + oct * 12) - (center % 12) + pc
        else p = prevp + 1 + (pc - (prevp + 1)) % 12 end
        v[#v + 1] = p; prevp = p
      end
      if style == 'open' and #v >= 3 then v[#v - 1] = v[#v - 1] - 12; table.sort(v) end
      local cost = 0
      if prev and #prev > 0 then
        local sp = {}
        for _, p in ipairs(prev) do sp[#sp + 1] = p end
        table.sort(sp)
        for k = 1, #v do
          local q = sp[math.min(#sp, k)]
          cost = cost + math.abs(v[k] - q)
        end
      else
        local mid = 0; for _, p in ipairs(v) do mid = mid + p end
        cost = math.abs(mid / #v - center)
      end
      if not bc or cost < bc then best, bc = v, cost end
    end
  end
  if c.bass and c.bass ~= c.root then
    local b = best[1] - ((best[1] - c.bass) % 12)
    if b >= best[1] then b = b - 12 end
    table.insert(best, 1, b)
  end
  return best
end

-- ── хрома из аудио (jf_chorddetect) ──────────────────────────────────────
TH.SR = 4000
TH.NOTE_LO, TH.NOTE_HI = 45, 80
TH.SILENCE = 0.0015
local COEFF = {}
for n = TH.NOTE_LO, TH.NOTE_HI do COEFF[n] = 2 * math.cos(2 * math.pi * 440 * 2 ^ ((n - 69) / 12) / TH.SR) end
-- моно-окно (отсчёты при TH.SR) → хрома 12 бинов (сумма 1) или nil (тишина)
function TH.window_chroma(mono, N)
  N = N or #mono
  local acc = 0
  for i = 1, N do acc = acc + math.abs(mono[i]) end
  if N == 0 or acc / N < TH.SILENCE then return nil end
  local chroma = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
  for n = TH.NOTE_LO, TH.NOTE_HI do
    local coeff, s1, s2 = COEFF[n], 0, 0
    for i = 1, N do local s0 = mono[i] + coeff * s1 - s2; s2 = s1; s1 = s0 end
    local mag = math.sqrt(math.max(0, s1 * s1 + s2 * s2 - coeff * s1 * s2))
    chroma[n % 12 + 1] = chroma[n % 12 + 1] + math.log(1 + mag)
  end
  local sum = 0
  for i = 1, 12 do sum = sum + chroma[i] end
  if sum <= 0 then return nil end
  for i = 1, 12 do chroma[i] = chroma[i] / sum end
  return chroma
end
-- лучший аккорд по хроме: шаблоны CH.T (первые maxq качеств — простые раньше), бонус корню
TH.CHROMA_Q = { '', 'm', '7', 'maj7', 'm7', 'sus4', 'dim' }
function TH.best_chord(chroma, quals)
  local best, bs
  for root = 0, 11 do
    for _, q in ipairs(quals or TH.CHROMA_Q) do
      local c = CH.parse(CH.NAMES[root + 1] .. q)
      if c then
        local s = 0.15 * chroma[root + 1]
        for _, iv in ipairs(c.ints) do s = s + chroma[(root + iv) % 12 + 1] end
        s = s / math.sqrt(#c.ints)
        if not bs or s > bs then bs, best = s, CH.NAMES[root + 1] .. q end
      end
    end
  end
  return best, bs
end
-- 26 окт: ВЫСОТА ЗВУКА — YIN (de Cheveigné, Kawahara 2002) по моно-окну при частоте sr.
-- → f0 (Гц) и cmnd (0 — чистый тон, чем больше, тем менее периодичен) или nil (тишина / нет периода)
TH.PITCH_SR = 11025
function TH.yin(mono, N, sr, fmin, fmax)
  N = N or #mono; sr = sr or TH.PITCH_SR
  fmin, fmax = fmin or 40, fmax or 1600
  local tmax = math.min(math.floor(sr / fmin), math.floor(N / 2))
  local tmin = math.max(2, math.floor(sr / fmax))
  if tmax <= tmin + 2 then return nil end
  local acc = 0
  for i = 1, N do acc = acc + math.abs(mono[i]) end
  if acc / N < TH.SILENCE then return nil end
  local W = N - tmax
  local d, cm = {}, {}
  local run = 0
  for tau = 1, tmax do
    local sum = 0
    for j = 1, W do local df = mono[j] - mono[j + tau]; sum = sum + df * df end
    d[tau] = sum; run = run + sum
    cm[tau] = run > 0 and (sum * tau / run) or 1
  end
  local best
  for tau = tmin, tmax - 1 do
    if cm[tau] < 0.15 and cm[tau] <= cm[tau + 1] then best = tau; break end
  end
  if not best then
    local mv = math.huge
    for tau = tmin, tmax - 1 do if cm[tau] < mv then mv, best = cm[tau], tau end end
  end
  if not best then return nil end
  local a, b, c = cm[best - 1] or cm[best], cm[best], cm[best + 1] or cm[best]
  local den = a - 2 * b + c
  local t = best + ((math.abs(den) > 1e-12) and (0.5 * (a - c) / den) or 0)
  return sr / t, cm[best]
end
-- высота сэмпла: нота (pitch MIDI + центы), если звук периодичен; иначе аккорд по хроме
-- mono_p — окно при TH.PITCH_SR, mono_c — при TH.SR (для хромы); → { pitch, cents } | { chord } | nil
function TH.sample_root(mono_p, Np, mono_c, Nc)
  local f0, cm = TH.yin(mono_p, Np, TH.PITCH_SR)
  if f0 and cm < 0.2 then
    local m = 69 + 12 * math.log(f0 / 440, 2)
    local p = math.floor(m + 0.5)
    return { pitch = p, cents = math.floor((m - p) * 100 + 0.5), f0 = f0, conf = 1 - cm }
  end
  local ch = mono_c and TH.window_chroma(mono_c, Nc)
  if ch then local sym = TH.best_chord(ch); if sym then return { chord = sym } end end
  return nil
end
-- метки окон → сегменты { s, e, lab } (индексы окон); короче min_dur секунд — в соседа (jf_chorddetect)
function TH.segments(labels, hop, min_dur)
  local segs = {}
  for i, lab in ipairs(labels) do
    local last = segs[#segs]
    if last and last.lab == lab then last.e = i else segs[#segs + 1] = { s = i, e = i, lab = lab } end
  end
  for _ = 1, 10 do
    local changed, i = false, 1
    while i <= #segs do
      local seg = segs[i]
      if (seg.e - seg.s + 1) * hop < (min_dur or 0) and #segs > 1 then
        local prev, nxt = segs[i - 1], segs[i + 1]
        local eat = (prev and (not nxt or (prev.e - prev.s) >= (nxt.e - nxt.s))) and prev or nxt
        eat.s = math.min(eat.s, seg.s); eat.e = math.max(eat.e, seg.e)
        table.remove(segs, i); changed = true
      else i = i + 1 end
    end
    local j = 2
    while j <= #segs do
      if segs[j].lab == segs[j - 1].lab then segs[j - 1].e = segs[j].e; table.remove(segs, j) else j = j + 1 end
    end
    if not changed then break end
  end
  return segs
end

-- ── гармонизация мелодии ─────────────────────────────────────────────────
-- melody: { { pitch, w } … } (w — вес: длина / сильная доля) одного отрезка → кандидаты аккордов лада
-- по убыванию оценки: { { sym, score } … } (ступени с септимой и без)
function TH.harmonize(melody, root, id, prev_sym)
  local out = {}
  local m = #TH.pcs(root, id)
  for k = 1, math.min(7, m) do
    for _, sev in ipairs({ false, true }) do
      local sym, notes = TH.degree_chord(root, id, k, sev)
      local set = {}
      for _, p in ipairs(notes) do set[p % 12] = true end
      local s, tot = 0, 0
      for _, mn in ipairs(melody) do
        tot = tot + mn.w
        if set[mn.pitch % 12] then s = s + mn.w elseif not TH.in_scale(mn.pitch, root, id) then s = s - 0.5 * mn.w else s = s - 0.25 * mn.w end
      end
      local sc = tot > 0 and s / tot or 0
      if k == 1 or k == 4 or k == 5 then sc = sc + 0.08 end          -- опорные функции
      if sev then sc = sc - 0.05 end                                  -- септаккорд — если заслужил
      if prev_sym and sym == prev_sym then sc = sc - 0.1 end          -- смена гармонии предпочтительнее
      out[#out + 1] = { sym = sym, score = sc, degree = k, seventh = sev }
    end
  end
  table.sort(out, function(a, b) return a.score > b.score end)
  return out
end
-- второй голос: терция (3) / секста (6) в ладу выше (+) / ниже (−)
function TH.second_voice(p, interval, root, id)
  local n = (interval == 6 or interval == -6) and 5 or 2
  if interval < 0 then n = -n end
  return TH.step(p, n, root, id)
end

-- ── 27 окт: кандидаты и преобразования аккорда (панель harmonizer) ────────
-- хрома из нот: вес высоты — её длина (или 1); бас — чуть весомее (корень чаще внизу)
function TH.note_chroma(notes)
  local ch, tot, lo = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 0, nil
  for _, n in ipairs(notes) do if not lo or n.pitch < lo then lo = n.pitch end end
  for _, n in ipairs(notes) do
    local w = (n.w or 1) * (n.pitch == lo and 1.25 or 1)
    local k = math.floor(n.pitch + 0.5) % 12 + 1
    ch[k] = ch[k] + w; tot = tot + w
  end
  if tot <= 0 then return nil end
  for i = 1, 12 do ch[i] = ch[i] / tot end
  return ch
end
TH.CAND_Q = { '', 'm', '7', 'maj7', 'm7', 'sus4', 'sus2', 'dim', 'aug', '6', 'm6', 'm7b5', 'dim7', '9', 'add9' }
-- n лучших аккордов по хроме (оценка best_chord, звучащее мимо аккорда — штраф): { { sym, w } }, w лучшего = 1
function TH.chord_candidates(chroma, n, quals)
  local all = {}
  for root = 0, 11 do
    for _, q in ipairs(quals or TH.CAND_Q) do
      local c = CH.parse(CH.NAMES[root + 1] .. q)
      if c then
        local s, set = 0.15 * chroma[root + 1], {}
        for _, iv in ipairs(c.ints) do local k = (root + iv) % 12; if not set[k] then set[k] = true; s = s + chroma[k + 1] end end
        local out = 0
        for k = 0, 11 do if not set[k] then out = out + chroma[k + 1] end end
        all[#all + 1] = { sym = CH.NAMES[root + 1] .. q, s = (s - 0.5 * out) / math.sqrt(#c.ints) }
      end
    end
  end
  table.sort(all, function(a, b) return a.s > b.s end)
  local res = {}
  for i = 1, math.min(n or 4, #all) do
    if all[i].s <= 0 then break end
    res[#res + 1] = { sym = all[i].sym, w = all[i].s / all[1].s }
  end
  return res
end
-- имя набора классов высот без /баса, если можно (бас перебирается)
function TH.name_pcs(pcs)
  for _, b in ipairs(pcs) do
    local ps = { 48 + b }
    for _, c in ipairs(pcs) do if c ~= b then ps[#ps + 1] = 60 + c end end
    local nm = CH.name(ps)
    if nm and not nm:find('[/?]') then return nm end
  end
  local ps = {}
  for _, c in ipairs(pcs) do ps[#ps + 1] = 60 + c end
  return CH.name(ps)
end
-- НЕГАТИВНАЯ ГАРМОНИЯ (Э. Леви, популяризация — Дж. Кольер): зеркало вокруг оси между терциями лада
-- (в C — между Eb и E): p' = 2·root + 7 − p; октава — ближайшая к исходной (регистр не прыгает)
function TH.negative(p, root)
  local s = 2 * root + 7
  local k = math.floor((2 * p - s) / 12 + 0.5)
  return s - p + 12 * k
end
function TH.negative_sym(sym, root)
  local c = CH.parse(sym)
  if not c then return nil end
  local pcs, seen = {}, {}
  for _, iv in ipairs(c.ints) do local k = (2 * root + 7 - c.root - iv) % 12; if not seen[k] then seen[k] = true; pcs[#pcs + 1] = k end end
  return TH.name_pcs(pcs)
end
-- преобразования аккорда: negative (по ладу), нео-римановские P L R (трезвучия), тритоновая замена (доминанты)
-- → { { lab, sym, why } }
function TH.transforms(sym, root)
  local c = CH.parse(sym)
  if not c then return {} end
  local N = CH.NAMES
  local out = {}
  local neg = TH.negative_sym(sym, root)
  if neg then out[#out + 1] = { lab = 'neg', sym = neg, why = 'negative harmony: mirrored around the axis of the key' } end
  if c.suffix == '' or c.suffix == 'm' then
    local maj = c.suffix == ''
    out[#out + 1] = { lab = 'P', sym = N[c.root + 1] .. (maj and 'm' or ''), why = 'parallel: the third moves a semitone' }
    out[#out + 1] = { lab = 'R', sym = maj and (N[(c.root + 9) % 12 + 1] .. 'm') or N[(c.root + 3) % 12 + 1], why = 'relative: the fifth (major) / root (minor) moves a tone' }
    out[#out + 1] = { lab = 'L', sym = maj and (N[(c.root + 4) % 12 + 1] .. 'm') or N[(c.root + 8) % 12 + 1], why = 'leading-tone exchange: the root (major) / fifth (minor) moves a semitone' }
  end
  if c.suffix:match('^7') or c.suffix:match('^9') or c.suffix:match('^13') then
    out[#out + 1] = { lab = 'tt', sym = N[(c.root + 6) % 12 + 1] .. c.suffix, why = 'tritone substitution: the same tritone, the root a tritone away' }
  end
  return out
end

return TH
