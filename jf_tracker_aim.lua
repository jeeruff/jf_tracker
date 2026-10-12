-- jf_tracker_aim.lua — математика прицела (12 окт): где в файле звучит нота на строке курсора,
-- где это в секундах показанного инструмента e, где резать в проекте; привязки точки реза.
-- Без reaper.* — тест tests/test_aim.lua.
--
-- n = нота: { pos (проект, с), offs (D_STARTOFFS, с файла), rate (D_PLAYRATE), len (с) }
-- e = инструмент в окне: { offs, rate }

local A = {}

-- место в файле, которое нота играет в момент t проекта
function A.src_at(n, t) return n.offs + (t - n.pos) * n.rate end

-- то же место в секундах окна инструмента e (может быть вне e: тот же файл, другой кусок)
function A.e_time(n, e, t) return (A.src_at(n, t) - e.offs) / e.rate end

-- обратно: точка окна e → момент проекта, где нота играет это место
function A.proj_of(n, e, te) return n.pos + (e.offs + te * e.rate - n.offs) / n.rate end

-- можно ли резать в t: строго внутри ноты (рез на краю не делит)
function A.inside(n, t, eps) eps = eps or 1e-4; return t > n.pos + eps and t < n.pos + n.len - eps end

-- ближайшее из списка (транзиенты), nil — пусто
function A.nearest(list, t)
  local best
  for _, v in ipairs(list or {}) do if not best or math.abs(v - t) < math.abs(best - t) then best = v end end
  return best
end

-- ближайший к середине переход через ноль в отсчётах s[1..n]: индекс i, где s[i-1] и s[i] разного знака
-- (или ноль); nil — нет. Время — t0 + (i - 1) / n * span
function A.zero_index(s, n)
  if not s or n < 2 then return nil end
  local c = math.floor(n / 2) + 1
  for d = 0, n do
    for _, i in ipairs({ c + d, c - d }) do
      if i > 1 and i <= n and (s[i - 1] or 0) * (s[i] or 0) <= 0 then return i end
    end
  end
  return nil
end

-- строка курсора → верхняя кромка; нота, кончающаяся ровно на ней, — тоже «под курсором» (её конец)
function A.ends_at(n, t, eps) eps = eps or 2e-3; return math.abs(n.pos + n.len - t) < eps end

return A
