-- jf_tracker_padseq.lua — pads (17 окт, MPC style): паттерны песни на нотных клавишах, игра паттернами вживую.
--
-- Клавиша → паттерн: смещение ноты клавиши (0, 1, 2 … как у слайсов) → N-й паттерн списка (уникальные имена
-- в порядке первого появления в песне). Запуск: quant — с конца играющего паттерна (очередь матрицы),
-- sudden — сразу, с той же фазой внутри паттерна. session rec — порядок сыгранных паттернов пишется,
-- остановка записи дописывает его в конец песни связанными повторами.
-- Без reaper.* — тест tests/test_padseq.lua.

local P = { on = false, mode = 'quant', rec = false, log = {} }

-- паттерны для клавиш: регионы песни (не секции, не служебные), уникальные имена, по первому появлению
function P.list(seq)
  local out, seen = {}, {}
  for _, rg in ipairs(seq or {}) do
    if not rg.gap and not rg.section and not rg.session and not rg.lib and rg.name and rg.name ~= '' and not rg.name:match('^=') and not seen[rg.name] then
      seen[rg.name] = true; out[#out + 1] = rg
    end
  end
  return out
end

-- смещение ноты клавиши → паттерн (смещения по возрастанию: 0 — первый)
function P.pick(list, off)
  if not off or off < 0 then return nil end
  return list[off + 1]
end

-- sudden: куда прыгнуть — то же место внутри нового паттерна (фаза по модулю его длины)
function P.sudden_pos(cur, playpos, dst)
  local len = dst.rgnend - dst.pos
  if len <= 0 then return dst.pos end
  local ph = cur and (playpos - cur.pos) or 0
  ph = ph % len
  return dst.pos + ph
end

-- запись: играющий паттерн сменился — в журнал (повтор того же подряд — тоже: паттерн сыграл ещё раз)
function P.rec_tick(cur, playpos)
  if not (P.rec and cur) then return end
  local last = P.log[#P.log]
  if not last or last.idx ~= cur.idx or playpos < (P.last_pos or playpos) - 1e-4 then
    P.log[#P.log + 1] = { name = cur.name, idx = cur.idx }
  end
  P.last_pos = playpos
end

-- журнал → имена по порядку (для дописывания в песню)
function P.names()
  local out = {}
  for _, e in ipairs(P.log) do out[#out + 1] = e.name end
  return out
end

return P
