-- jf_tracker_import.lua — импорт нарезанных инструментов (2 окт).
--
-- REX / RX2 (Propellerhead ReCycle): звук декодирует сам REAPER (источник
-- типа REX открывается PCM_Source_CreateFromFile), здесь читаются только
-- позиции слайсов: файл — IFF-контейнер «CAT REX2», внутри «CAT SLCL» с
-- чанками SLCE (11 байт: позиция в кадрах uint32 BE, длина uint32 BE,
-- 2 байта уровня, 1 байт флагов). Слайсы длиной ≤ 1 кадр — служебные
-- маркеры ReCycle, пропускаются. SINF: каналы, …, частота (uint32 BE со
-- смещения 2), длина в кадрах (uint32 BE со смещения 6).
--
-- XRNI (инструменты Renoise и Redux): zip с Instrument.xml и
-- SampleData/SampleNN (имя).flac. Из XML берутся сэмплы по порядку: имя,
-- BaseNote, IsAlias и SliceMarkers/SliceMarker/SamplePosition (в кадрах).
-- Распаковку (unzip) и вставку в проект делает main.
--
-- SFZ (11 окт) — текст, разбирает IM.sfz (ниже).
--
-- Без reaper.*: тестируется на файлах.

local IM = {}

local function u32(s, i) local a, b, c, d = s:byte(i, i + 3); return ((a * 256 + b) * 256 + c) * 256 + d end

-- позиции слайсов RX2: { sr=, frames=, slices = { секунды … } } или nil, причина
function IM.rx2_slices(path)
  local f = io.open(path, 'rb')
  if not f then return nil, 'cannot open' end
  local d = f:read('*a'); f:close()
  if #d < 12 or d:sub(1, 4) ~= 'CAT ' or d:sub(9, 12) ~= 'REX2' then return nil, 'not a REX2 file' end
  local pos, sr, frames = {}, nil, nil
  local function walk(off, stop)
    while off + 8 <= stop do
      local id, size = d:sub(off, off + 3), u32(d, off + 4)
      local data = off + 8
      if id == 'CAT ' then walk(data + 4, math.min(stop, data + size))
      elseif id == 'SLCE' and size >= 8 then
        local p, len = u32(d, data), u32(d, data + 4)
        if len > 1 then pos[#pos + 1] = p end
      elseif id == 'SINF' and size >= 10 then
        sr = u32(d, data + 2); frames = u32(d, data + 6)
      end
      off = data + size + (size % 2)
    end
  end
  walk(13, #d + 1)
  if not sr or sr <= 0 then return nil, 'no SINF (sample rate)' end
  table.sort(pos)
  local out = {}
  for _, p in ipairs(pos) do
    local t = p / sr
    if #out == 0 or t - out[#out] > 1e-4 then out[#out + 1] = t end
  end
  return { sr = sr, frames = frames, slices = out }
end

-- сэмплы Instrument.xml: { { name=, base=, alias=, slices = { кадры } } … } по порядку
function IM.xrni_samples(xml)
  local out = {}
  -- сэмплы — в <Samples> генератора; фразы и модуляция своих <Sample> не имеют
  local body = xml:match('<Samples>(.*)</Samples>') or xml
  for blk in body:gmatch('<Sample>(.-)</Sample>') do
    local s = { name = blk:match('<Name>(.-)</Name>') or '', base = tonumber(blk:match('<BaseNote>(%-?%d+)</BaseNote>') or ''),
                alias = blk:match('<IsAlias>true</IsAlias>') ~= nil, slices = {} }
    local sm = blk:match('<SliceMarkers>(.-)</SliceMarkers>')
    if sm then
      for p in sm:gmatch('<SamplePosition>(%d+)</SamplePosition>') do s.slices[#s.slices + 1] = tonumber(p) end
    end
    s.name = s.name:gsub('&amp;', '&'):gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&quot;', '"'):gsub('&apos;', "'")
    out[#out + 1] = s
  end
  return out
end

-- файл сэмпла NN в списке zip (строки unzip -Z1): «SampleData/SampleNN (…).ext»
function IM.xrni_file(list, idx)
  local tag = ('SampleData/Sample%02d '):format(idx)
  for line in list:gmatch('[^\r\n]+') do
    if line:sub(1, #tag) == tag then return line end
  end
  return nil
end

function IM.kind(path)
  local ext = (path:match('%.([%w]+)$') or ''):lower()
  if ext == 'rx2' or ext == 'rex' then return 'rex' end
  if ext == 'xrni' then return 'xrni' end
  if ext == 'sfz' then return 'sfz' end
  return nil
end

-- ── SFZ (11 окт): текст — заголовки <control> <global> <master> <group> <region>
-- и opcode=value; region наследует значения global → master → group. Значение
-- sample — до конца строки или до следующего «opcode=» (в путях бывают пробелы).
-- Клавиши — числом или именем ноты (c4 = 60). Пути: \ → /, относительно папки
-- .sfz (+ default_path из <control>), «..» сворачиваются.
local NOTE = { c = 0, d = 2, e = 4, f = 5, g = 7, a = 9, b = 11 }
function IM.sfz_key(v)
  if v == nil then return nil end
  local n = tonumber(v)
  if n then return math.floor(n) end
  local l, acc, oct = tostring(v):lower():match('^([a-g])([#b]?)(%-?%d+)$')
  if not l then return nil end
  return (tonumber(oct) + 1) * 12 + NOTE[l] + (acc == '#' and 1 or (acc == 'b' and -1 or 0))
end
local function norm(path)
  local abs = path:sub(1, 1) == '/'
  local out = {}
  for seg in path:gmatch('[^/]+') do
    if seg == '..' then if #out > 0 and out[#out] ~= '..' then out[#out] = nil else out[#out + 1] = seg end
    elseif seg ~= '.' then out[#out + 1] = seg end
  end
  return (abs and '/' or '') .. table.concat(out, '/')
end
-- regions: { sample = путь, lokey, hikey, key (pitch_keycenter), lovel, hivel, offset, end_, loop (bool), loopstart, loopend, tune }
function IM.sfz(text, dir)
  text = (text or ''):gsub('\r', '')
  local lines = {}
  for ln in (text .. '\n'):gmatch('([^\n]*)\n') do lines[#lines + 1] = (ln:gsub('//.*$', '')) end
  local scope = { control = {}, global = {}, master = {}, group = {} }
  local cur, regions = nil, {}
  local function close_region()
    if cur then regions[#regions + 1] = cur; cur = nil end
  end
  local function set(k, v)
    local t = cur or scope[scope._at or 'global']
    t[k] = v
  end
  for _, ln in ipairs(lines) do
    local i = 1
    while i <= #ln do
      local hs, he, h = ln:find('<(%w+)>', i)
      local os_, oe, k = ln:find('([%w_]+)=', i)
      if hs and (not os_ or hs < os_) then
        close_region()
        if h == 'region' then
          cur = {}
          for _, lvl in ipairs({ 'global', 'master', 'group' }) do for k2, v2 in pairs(scope[lvl]) do cur[k2] = v2 end end
        elseif scope[h] then
          scope._at = h
          if h == 'group' then scope.group = {} elseif h == 'master' then scope.master = {}; scope.group = {} end
        else scope._at = 'global' end
        i = he + 1
      elseif os_ then
        local rest = ln:sub(oe + 1)
        local v
        if k == 'sample' or k == 'default_path' then
          local nx = rest:find('%s+[%w_]+=') or rest:find('%s*<%w+>')
          v = (nx and rest:sub(1, nx - 1) or rest):gsub('%s+$', '')
          i = oe + 1 + (nx and nx - 1 or #rest)
        else
          v = rest:match('^(%S*)')
          i = oe + 1 + #v
        end
        if (scope._at == 'control') and not cur then scope.control[k] = v else set(k, v) end
      else break end
    end
  end
  close_region()
  local base = (dir or ''):gsub('/+$', '')
  local dp = (scope.control.default_path or ''):gsub('\\', '/')
  local out = {}
  for _, r in ipairs(regions) do
    if r.sample and r.sample ~= '' then
      local sp = r.sample:gsub('\\', '/')
      if sp:sub(1, 1) ~= '/' then sp = base .. '/' .. dp .. sp end
      local key = IM.sfz_key(r.key)
      local lm = r.loop_mode or r.loopmode
      out[#out + 1] = {
        sample = norm(sp),
        lokey = IM.sfz_key(r.lokey) or key or 0, hikey = IM.sfz_key(r.hikey) or key or 127,
        key = IM.sfz_key(r.pitch_keycenter) or key or 60,
        lovel = tonumber(r.lovel) or 0, hivel = tonumber(r.hivel) or 127,
        offset = tonumber(r.offset) or 0, end_ = tonumber(r['end']),
        loop = lm == 'loop_continuous' or lm == 'loop_sustain',
        loopstart = tonumber(r.loopstart or r.loop_start), loopend = tonumber(r.loopend or r.loop_end),
        tune = tonumber(r.tune) or 0, transpose = tonumber(r.transpose) or 0,
      }
    end
  end
  table.sort(out, function(a, b) if a.lokey ~= b.lokey then return a.lokey < b.lokey end return a.lovel < b.lovel end)
  return out
end

return IM
