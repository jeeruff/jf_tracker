-- jf_tracker_arc.lua — monome arc в трекере (15 окт): 4 кольца = 4 параметра эффекта.
--
-- Мост: демон jf_grid (модуль daemon_tracker) копит повороты колец в суммы и пишет
-- ExtState jf_tracker/arcenc «t1,t2,t3,t4»; трекер берёт разницу с прошлым чтением
-- (ничего не теряется, сколько бы кадров ни прошло) и пишет уровни колец обратно
-- в jf_tracker/arcrings «v1,v2,v3,v4» (0..1, -1 — кольцо пустое).
--
-- Куда идут кольца: фокус в DSP — эффект под курсором DSP; для него четыре параметра
-- из памяти по имени эффекта (назначил раз — так и у следующих экземпляров),
-- иначе четыре подряд от параметра под курсором. Ушёл из DSP — кольца остаются
-- на последнем эффекте (играешь, а клавиатура в трекере).
--
-- Без reaper.*: чтение / запись — у main, здесь расчёт; тест tests/test_arc.lua.

local A = { last = nil, bound = nil }

-- суммы поворотов → дельты колец с прошлого чтения (первое чтение — без дельт)
function A.deltas(str)
  local t = {}
  for v in (str or ''):gmatch('%-?%d+') do t[#t + 1] = tonumber(v) end
  if #t < 4 then return { 0, 0, 0, 0 } end
  local d = { 0, 0, 0, 0 }
  if A.last then for n = 1, 4 do d[n] = t[n] - A.last[n] end end
  A.last = t
  return d
end

-- память: «fxname» → «p1,p2,p3,p4» (индексы параметров эффекта, -1 — пусто)
function A.encode(list)
  local o = {}
  for n = 1, 4 do o[n] = tostring(list[n] or -1) end
  return table.concat(o, ',')
end
function A.decode(s)
  local t = {}
  for v in (s or ''):gmatch('%-?%d+') do t[#t + 1] = tonumber(v) end
  if #t < 4 then return nil end
  return t
end

-- четыре параметра эффекта: из памяти, иначе подряд от выбранного (params — список
-- { i = индекс, name = }; sel — номер выбранного в списке)
function A.slots(params, sel, mem)
  local out = {}
  if mem then
    for n = 1, 4 do
      local pi = mem[n]
      if pi and pi >= 0 then
        for _, p in ipairs(params) do if p.i == pi then out[n] = { i = p.i, name = p.name } end end
      end
    end
    return out
  end
  local k0 = math.max(1, math.min(sel or 1, math.max(1, #params - 3)))
  for n = 1, 4 do
    local p = params[k0 + n - 1]
    if p then out[n] = { i = p.i, name = p.name } end
  end
  return out
end

-- шаг значения: 64 деления кольца на оборот → полный ход за ~4 оборота; fine — вчетверо тоньше
function A.step(v, d, fine)
  local k = fine and (1 / 1024) or (1 / 256)
  return math.max(0, math.min(1, (v or 0) + d * k))
end

-- уровни колец для демона
function A.rings(vals)
  local o = {}
  for n = 1, 4 do o[n] = vals[n] and ('%.3f'):format(vals[n]) or '-1' end
  return table.concat(o, ',')
end

return A
