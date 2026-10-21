-- jf_tracker_szone.lua — 21 окт: место зоны сессии (=SESSION) — расчёт без reaper.* (тест tests/test_szone.lua).
--
-- Зона — служебный регион за песней: туда сажаются копии для прослушки эскизов, палитры и запуска клипов.
-- В песню попадать не должна: начало — не раньше =END, не поверх регионов песни (и библиотечных за =END),
-- не поверх items без метки P_EXT:jf_session.

local SZ = {}
SZ.GAP_BARS = 16   -- зона — через столько тактов после всего остального

-- song: { end_pos = позиция =END или nil, regions = { { pos, rgnend, name } … } (без зоны),
--         items = { { pos, len, tagged } … } } → время, после которого зоне можно начинаться
function SZ.after(song)
  local t = song.end_pos or 0
  for _, r in ipairs(song.regions or {}) do if r.rgnend > t then t = r.rgnend end end
  for _, it in ipairs(song.items or {}) do if not it.tagged and it.pos + it.len > t then t = it.pos + it.len end end
  return t
end

-- зона z = { pos, rgnend } в песне? → причина (строка) или nil
function SZ.in_song(z, song)
  if song.end_pos and z.pos < song.end_pos - 1e-6 then return 'before =END' end
  for _, r in ipairs(song.regions or {}) do
    if r.pos < z.rgnend - 1e-6 and r.rgnend > z.pos + 1e-6 then return 'over ' .. (r.name or 'a region') end
  end
  for _, it in ipairs(song.items or {}) do
    if not it.tagged and it.pos < z.rgnend - 1e-6 and it.pos + it.len > z.pos + 1e-6 then return 'over song items' end
  end
  return nil
end

return SZ
