-- jf_tracker_premod.lua — premod (22 окт): кривая автоматизации ДО ноты.
--
-- Как клипы автоматизации FL Studio, но нативно: на огибающей параметра FX трека —
-- pooled automation items REAPER, каждый кончается ровно на начале ноты трека
-- (MIDI-ноты в items и аудио-ноты трекера). Кривая одна на все (правится в пуле).
-- Опции: pre — длина подката в долях (QN); key — keytrack: выше нота — короче и
-- быстрее подкат (C-4 = x1, октава вверх = вдвое короче); vel — сила ноты → размах;
-- hum — humanize 0..100 %: чуть раньше / позже, размах и подложка кривой (форма).
-- Случайность детерминированная (от позиции ноты): переприменение не «дрожит».
--
-- Хранение: P_EXT:jf_premod трека, «env|pool|pre|flags|hum;…» (env как у note mod:
-- fx:<GUID>:<param>). Здесь — только чистые функции (тест без REAPER).

local PK = {}

function PK.parse(s)
  local out = {}
  for part in (s or ''):gmatch('[^;]+') do
    local env, pool, pre, flags, hum, pitch, label = part:match('^([^|]+)|(%-?%d+)|([%d%.]+)|(%a*)|(%d+)@?(%d*)|?(.*)$')
    if env then
      out[#out + 1] = { env = env, pool = tonumber(pool), pre = tonumber(pre), key = flags:find('k') ~= nil,
        vel = flags:find('v') ~= nil, hum = tonumber(hum), pitch = tonumber(pitch), label = label ~= '' and label or env }   -- 22 окт: @N — только ноты высоты N
    end
  end
  return out
end

function PK.encode(list)
  local t = {}
  for _, c in ipairs(list or {}) do
    t[#t + 1] = ('%s|%d|%s|%s%s|%d%s|%s'):format(c.env, c.pool or -1, ('%.4f'):format(c.pre or 1):gsub('0+$', ''):gsub('%.$', ''),
      c.key and 'k' or '', c.vel and 'v' or '', math.floor(c.hum or 0), c.pitch and ('@' .. math.floor(c.pitch)) or '', (c.label or ''):gsub('[|;]', ' '))
  end
  return table.concat(t, ';')
end

-- детерминированное 0..1 от числа (позиция ноты) и соли
function PK.rnd(x, salt)
  local v = math.sin(x * 12.9898 + (salt or 0) * 78.233) * 43758.5453
  return v - math.floor(v)
end

-- notes = { { qn = начало в QN, pitch = 0..127, vel = 1..127 } } (любой порядок);
-- cfg — запись PK.parse; poolqn — длина кривой пула в QN.
-- Возвращает { { qn = начало AI, len = длина в QN, rate, amp, base } } по возрастанию.
-- Аккорд (ноты в одном месте) — один подкат (самая высокая нота — для keytrack).
-- Подкат не налезает на прошлую ноту: длина — не больше промежутка.
function PK.places(notes, cfg, poolqn)
  local ns = {}
  for _, n in ipairs(notes or {}) do if not cfg.pitch or n.pitch == cfg.pitch then ns[#ns + 1] = n end end   -- 22 окт: только одна высота (бочка кита)
  table.sort(ns, function(a, b) if math.abs(a.qn - b.qn) > 1e-6 then return a.qn < b.qn end; return (a.pitch or 60) > (b.pitch or 60) end)
  local on = {}
  for _, n in ipairs(ns) do
    local last = on[#on]
    if not last or n.qn - last.qn > 1e-4 then on[#on + 1] = n
    elseif (n.vel or 0) > (last.vel or 0) then last.vel = n.vel end
  end
  local out, h, pre = {}, math.max(0, math.min(100, cfg.hum or 0)) / 100, math.max(1 / 64, cfg.pre or 1)
  poolqn = poolqn and poolqn > 0 and poolqn or pre
  for i, n in ipairs(on) do
    local len = pre
    if cfg.key then len = pre / 2 ^ (((n.pitch or 60) - 60) / 12) end
    local prev = on[i - 1]
    if prev then len = math.min(len, n.qn - prev.qn) end
    len = math.max(1 / 128, len)
    local r1, r2, r3 = PK.rnd(n.qn, 1) * 2 - 1, PK.rnd(n.qn, 2) * 2 - 1, PK.rnd(n.qn, 3)
    local e = n.qn + h * 0.12 * len * r1                       -- конец: чуть раньше / позже ноты
    local amp = (cfg.vel and (n.vel or 127) / 127 or 1) * (1 + h * 0.3 * r2)
    out[#out + 1] = { qn = e - len, len = len, rate = poolqn / len, amp = math.max(0, math.min(2, amp)), base = h * 0.15 * r3 }
  end
  return out
end

-- одинаковы ли расстановки (have — из REAPER, want — PK.places), в QN
function PK.same(have, want)
  if #have ~= #want then return false end
  for i = 1, #want do
    local a, b = have[i], want[i]
    if math.abs(a.qn - b.qn) > 1e-4 or math.abs(a.len - b.len) > 1e-4 or math.abs(a.rate - b.rate) > 1e-3
      or math.abs(a.amp - b.amp) > 1e-3 or math.abs(a.base - b.base) > 1e-3 then return false end
  end
  return true
end

return PK
