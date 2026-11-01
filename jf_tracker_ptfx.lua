-- jf_tracker_ptfx.lua — команды ProTracker в PT-mode (1 ноя). Набор и показ — как в ProTracker 2.3D (Cxx, 9xx,
-- Dxx …), хранятся — нашими кодами (0M, 09, ZB …): один движок, две раскладки. Без reaper.* — тест tests/test_ptfx.lua.
--
-- PT     наше   перевод значения
-- 0xy    0A xy  арпеджио
-- 1xx    0U xx  slide up (стиль слайда pt — опция slide style)
-- 2xx    0D xx  slide down
-- 3xx    0G xx  tone portamento ≈ glide за xx строк
-- 4xy    0V xy  vibrato
-- 8xx    0P xx  pan (в PT не было, есть в его потомках)
-- 9xx    09 xx  sample offset xx/256 всего сэмпла
-- Ax0    0I x·16  volume slide up;  A0y  0O y·16  down
-- Bxx    ZJ xx  position jump — слот последовательности
-- Cxx    0M     громкость 00..40 (64) → 0M 00..80 (×2)
-- Dxy    ZB     pattern break, строка десятичная: D10 = строка 10
-- E9x    0R     retrig каждые x тиков (speed 6) → y/16 строки
-- Fxx    ZT xx  xx ≥ 20: темп BPM; меньше — speed (тики) — нет
-- 7xy    0T xy  tremolo (1 ноя)
-- Нет: 5, 6, E0..E8, EA..EF (fine slides, cut, delay …)

local PT = {}

-- PT: c — символ команды 0..F, xx — байт; → наш код, значение | nil, причина
function PT.to_ours(c, xx)
  c = c:upper()
  local x, y = xx >> 4, xx & 15
  if c == '0' then return '0A', xx
  elseif c == '1' then return '0U', xx
  elseif c == '2' then return '0D', xx
  elseif c == '3' then return '0G', xx
  elseif c == '4' then return '0V', xx
  elseif c == '7' then return '0T', xx
  elseif c == '8' then return '0P', xx
  elseif c == '9' then return '09', xx
  elseif c == 'A' then
    if x > 0 and y == 0 then return '0I', math.min(255, x * 16) end
    if x == 0 and y > 0 then return '0O', math.min(255, y * 16) end
    return nil, 'Axy: x - up or y - down, not both'
  elseif c == 'B' then return 'ZJ', xx
  elseif c == 'C' then return '0M', math.min(255, math.min(64, xx) * 2)
  elseif c == 'D' then
    if x > 9 or y > 9 then return nil, 'Dxy: the row in decimal (D00..D63)' end
    return 'ZB', x * 10 + y
  elseif c == 'E' then
    if x == 9 then return '0R', math.max(1, math.min(15, math.floor(y * 16 / 6 + 0.5))) end
    return nil, ('E%X: not in jf_tracker (E9x retrig is)'):format(x)
  elseif c == 'F' then
    if xx >= 0x20 then return 'ZT', xx end
    return nil, 'Fxx under 20 is the speed in ticks - jf_tracker has no ticks (F20..FF is the tempo)'
  end
  return nil, c .. 'xx: not in jf_tracker (5, 6)'
end

-- наш код и значение → 3 знака PT для показа | nil (показать как есть)
function PT.from_ours(code, v)
  local h = function(n) return ('%02X'):format(math.max(0, math.min(255, n))) end
  if code == '0A' then return '0' .. h(v)
  elseif code == '0U' then return '1' .. h(v)
  elseif code == '0D' then return '2' .. h(v)
  elseif code == '0G' then return '3' .. h(v)
  elseif code == '0V' then return '4' .. h(v)
  elseif code == '0T' then return '7' .. h(v)
  elseif code == '0P' then return '8' .. h(v)
  elseif code == '09' or code == '0S' then return '9' .. h(v)
  elseif code == '0I' then return 'A' .. h(math.min(15, v // 16) * 16)
  elseif code == '0O' then return 'A' .. h(math.min(15, v // 16))
  elseif code == 'ZJ' then return 'B' .. h(v)
  elseif code == '0M' then return 'C' .. h(math.min(64, (v + 1) // 2))
  elseif code == 'ZB' then local r = math.min(99, v); return ('D%d%d'):format(r // 10, r % 10)
  elseif code == '0R' then return 'E9' .. ('%X'):format(math.max(1, math.min(15, math.floor((v & 15) * 6 / 16 + 0.5))))
  elseif code == 'ZT' then return 'F' .. h(v) end
  return nil
end

-- строка команды трекера ('0M80') → её показ в PT-mode ('C40 ') или как есть
function PT.show(s)
  if type(s) ~= 'string' or #s < 4 then return s end
  local p = PT.from_ours(s:sub(1, 2), tonumber(s:sub(3, 4), 16) or 0)
  return p and (p .. ' ') or s
end

return PT
