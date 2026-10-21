-- jf_tracker_numkeys.lua — 21 окт: число перед клавишей в панелях reform / humanizer / bouncer (как в DSP):
-- N h / l — шаг ×N, N j / k — на N строк, N Enter — значение строки (023 → 0.23), Esc — отменить число,
-- BS — стереть цифру. Одиночный 0 — по-прежнему сброс; если за ним пошли цифры — сброс откатывается (снимок).
-- Без reaper.* — тест tests/test_numkeys.lua.

local NK = {}

local function deep(v)
  if type(v) ~= 'table' then return v end
  local t = {}
  for k, x in pairs(v) do t[k] = deep(x) end
  return t
end
-- вернуть содержимое снимка в ту же таблицу (на неё ссылается main)
local function restore(dst, src)
  for k in pairs(dst) do dst[k] = nil end
  for k, x in pairs(src) do dst[k] = deep(x) end
end

-- 0NN → 0.NN, -0NN → -0.NN
function NK.value(b)
  if not b:find('.', 1, true) then b = b:gsub('^(%-?)0(%d)', '%1' .. '0.%2') end
  return tonumber(b)
end

local OPS = { [104] = 'h', [108] = 'l', [72] = 'h', [76] = 'l', [106] = 'j', [107] = 'k',
  [1818584692] = 'h', [1919379572] = 'l', [1685026670] = 'j', [30064] = 'k' }

-- M — панель (буфер M.num), st — её состояние (для отката сброса нулём).
-- → nil — не наше (обычная обработка; одиночный 0 начинает буфер и тоже идёт в обычную обработку),
--   'eaten' — съедено, 'changed' — откат сброса (перерисовать / применить),
--   { op = 'h'|'l'|'j'|'k', n = счёт } | { op = 'set', v = число }
function NK.key(M, st, c)
  local ch = c > 0 and c < 256 and string.char(c) or ''
  local b = M.num
  if ch:match('^%d$') or (ch == '.' and b) or (ch == '-' and not b) then
    if not b and ch == '0' then M.num = '0'; M.snap = deep(st); return nil end
    if b == '0' and M.snap and ch ~= '.' then   -- за нулём пошли цифры — это число, сброс откатить
      restore(st, M.snap); M.snap = nil; M.num = b .. ch; return 'changed'
    end
    if #(b or '') < 8 then M.num = (b or '') .. ch end
    return 'eaten'
  end
  if not b then return nil end
  local snap = M.snap
  M.num, M.snap = nil, nil
  if b == '0' and snap then return nil end      -- одиночный 0 (сброс) уже сделан — клавиша как обычно
  if c == 27 then return 'eaten' end
  if c == 8 then M.num = #b > 1 and b:sub(1, -2) or nil; return 'eaten' end
  if c == 13 then local v = NK.value(b); if v then return { op = 'set', v = v } end; return 'eaten' end
  local op = OPS[c]
  local n = math.floor(tonumber(b) or 0)
  if op and n >= 1 then return { op = op, n = math.min(n, 999) } end
  return nil
end

-- текст значения при наборе (у курсора)
function NK.show(M) if not M.num or (M.num == '0' and M.snap) then return nil end; return M.num .. '_' end   -- одиночный 0 — это сброс, не показывать

return NK
