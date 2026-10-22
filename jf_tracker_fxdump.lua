-- jf_tracker_fxdump.lua — снимок параметров плагина (PLAN_DSP этап 0, 22 окт): образцы для парсера.
--
-- FD.dump(A, obj, fx) → текст: строка плагина, потом по строке на параметр, через Tab:
--   индекс  имя  шаг  toggle  текст при 0  0.25  0.5  0.75  1  (FormatParamValueNormalized — без записи в плагин)
-- FD.parse(text) → { name, params = { { i, name, step, toggle, t = { 5 текстов } } } } — для тестов без REAPER.
-- A — таблица API (model.fxapi: TrackFX_* или TakeFX_*), obj — трек / take.

local FD = {}
FD.AT = { 0, 0.25, 0.5, 0.75, 1 }

local function clean(s) return ((s or ''):gsub('[\t\r\n]', ' ')) end

function FD.dump(A, obj, fx)
  local _, fname = A.GetFXName(obj, fx, '')
  local np = A.GetNumParams(obj, fx)
  local out = { 'plugin\t' .. clean(fname) .. '\t' .. np }
  for pi = 0, np - 1 do
    local _, pname = A.GetParamName(obj, fx, pi, '')
    local step, toggle = '', ''
    if A.GetParameterStepSizes then
      local ok, st, _, _, istog = A.GetParameterStepSizes(obj, fx, pi)
      if ok then step = st and ('%g'):format(st) or ''; toggle = istog and '1' or '' end
    end
    local t = {}
    for k, v in ipairs(FD.AT) do
      local ok, s = false, ''
      if A.FormatParamValueNormalized then ok, s = A.FormatParamValueNormalized(obj, fx, pi, v, '') end
      t[k] = ok and clean(s) or ''
    end
    out[#out + 1] = table.concat({ pi, clean(pname), step, toggle, table.unpack(t) }, '\t')
  end
  return table.concat(out, '\n') .. '\n'
end

function FD.parse(text)
  local r = { params = {} }
  for line in (text or ''):gmatch('[^\n]+') do
    local f = {}
    for v in (line .. '\t'):gmatch('([^\t]*)\t') do f[#f + 1] = v end
    if f[1] == 'plugin' then r.name, r.np = f[2], tonumber(f[3])
    elseif tonumber(f[1]) then
      r.params[#r.params + 1] = { i = tonumber(f[1]), name = f[2], step = tonumber(f[3]), toggle = f[4] == '1', t = { f[5] or '', f[6] or '', f[7] or '', f[8] or '', f[9] or '' } }
    end
  end
  return r
end

-- имя файла образца: без двоеточия типа (CLAPi: …) и знаков, которых нет в именах файлов
function FD.file_name(fname)
  local n = (fname or 'fx'):gsub('^%w+i?:%s*', ''):gsub('[^%w%-_ ]+', ''):gsub('%s+', '_')
  return n ~= '' and n or 'fx'
end

return FD
