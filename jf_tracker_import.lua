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
  return nil
end

return IM
