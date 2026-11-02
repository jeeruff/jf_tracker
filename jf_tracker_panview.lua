-- jf_tracker_panview.lua (2 ноя) — вид пана трека (zvp): трек — поле из N позиций (нечётное, середина — центр),
-- время сверху вниз. Нота стоит в позиции своего пана. Без reaper — тест tests/test_panview.lua.
-- Пан ячейки: аудио — head.pan (hex 00..FF, nil = центр) или команда 0Pxx; MIDI (slixer) — 0Pxx из jf_nx.
local PV = {}

PV.N = 17

-- пан -1..1 → позиция 1..N (середина — (N + 1) / 2)
function PV.pos_of(pan, n)
  n = n or PV.N
  pan = math.max(-1, math.min(1, pan or 0))
  return math.floor((pan + 1) / 2 * (n - 1) + 0.5) + 1
end
-- позиция 1..N → пан -1..1
function PV.pan_of(i, n)
  n = n or PV.N
  i = math.max(1, math.min(n, i))
  return (i - 1) / (n - 1) * 2 - 1
end
-- hex трекера 00..FF (80 = центр) ↔ пан
function PV.hex_pan(v) if v <= 128 then return (v - 128) / 128 end; return (v - 128) / 127 end
function PV.pan_hex(p) p = math.max(-1, math.min(1, p)); return math.floor(p < 0 and (128 + p * 128) or (128 + p * 127) + 0.5) end

-- пан ячейки-головы (audio / midi), -1..1
function PV.cell_pan(c)
  if not c then return 0 end
  if c.kind == 'audio' and c.pan then local v = tonumber(c.pan, 16); if v then return PV.hex_pan(v) end end
  for _, t in ipairs(c.fx or {}) do
    local v = type(t) == 'string' and t:match('^0P(%x%x)$')
    if v then return PV.hex_pan(tonumber(v, 16)) end
  end
  return 0
end

-- что видно в строке row трека col: { { pos, head = cell, cont = bool } } (голова — буква ноты, продолжение — |)
function PV.row(col, row, n)
  local out = {}
  for _, lane in ipairs(col.lanes or {}) do
    for _, sub in ipairs(lane.subs or {}) do
      local c = sub[row]
      if c then
        if c.kind == 'audio' or c.kind == 'midi' then out[#out + 1] = { pos = PV.pos_of(PV.cell_pan(c), n), head = c }
        elseif c.kind == 'cont' and c.of and (c.of.kind == 'audio' or c.of.kind == 'midi') then out[#out + 1] = { pos = PV.pos_of(PV.cell_pan(c.of), n), head = c.of, cont = true } end
      end
    end
  end
  return out
end

-- буква головы: нота C-4 → C, C#4 → c (диез — строчной); узко, одним символом
function PV.glyph(c)
  local nm = c and c.note or ''
  local l, s = nm:match('^(%a)(.)')
  if not l then return 'o' end
  return s == '#' and l:lower() or l:upper()
end

return PV
