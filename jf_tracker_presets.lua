-- jf_tracker_presets.lua — пресеты инструментов на шаблонах треков REAPER (16 окт).
--
-- Папка TrackTemplates/presets/<категория>/имя.RTrackTemplate (pad bass lead …).
-- Пресет = цепочка FX трека (любой синт + эффекты): Enter в браузере (режим presets)
-- ставит <FXCHAIN> шаблона на трек курсора, его items и остальное не трогаются.
-- Сохранение — чанк трека курсора без items (<ITEM …>) в файл шаблона.
--
-- Без reaper.*: разбор блоков чанка; тест tests/test_presets.lua.

local P = {}

P.CATS = { 'pad', 'bass', 'lead', 'keys', 'pluck', 'drums', 'fx', 'arp', 'chord' }

local function lines_of(s)
  local t = {}
  for l in ((s or '') .. '\n'):gmatch('([^\n]*)\n') do t[#t + 1] = l end
  if t[#t] == '' then t[#t] = nil end
  return t
end

-- блок «<TAG …» на глубине depth (1 — прямо в TRACK): индексы строк начала и его «>»
function P.find_block(lines, tag, depth)
  local d = 0
  local start, sd
  for i, l in ipairs(lines) do
    if l:match('^%s*<') then
      if not start and d == depth then
        local t = l:match('^%s*<(%S+)')
        if t == tag then start, sd = i, d end
      end
      d = d + 1
    elseif l:match('^%s*>%s*$') then
      d = d - 1
      if start and d == sd then return start, i end
    end
  end
  return nil
end

-- первый трек шаблона (шаблон бывает из нескольких треков — берём первый)
function P.first_track(tpl)
  local L = lines_of(tpl)
  local a, b
  for i, l in ipairs(L) do if l:match('^%s*<TRACK') then a = i; break end end
  if not a then return nil end
  local d = 0
  for j = a, #L do
    if L[j]:match('^%s*<') then d = d + 1 elseif L[j]:match('^%s*>%s*$') then d = d - 1; if d == 0 then b = j; break end end
  end
  if not b then return nil end
  local out = {}
  for i = a, b do out[#out + 1] = L[i] end
  return table.concat(out, '\n')
end

-- цепочка FX шаблона → в чанк трека (на место его <FXCHAIN>, нет — перед концом трека)
function P.apply_fxchain(track_chunk, tpl)
  local tr = P.first_track(tpl)
  if not tr then return nil, 'no track in the template' end
  local TL = lines_of(tr)
  local a, b = P.find_block(TL, 'FXCHAIN', 1)
  if not a then return nil, 'the template has no fx' end
  local CL = lines_of(track_chunk)
  local ca, cb = P.find_block(CL, 'FXCHAIN', 1)
  local out = {}
  if ca then
    for i = 1, ca - 1 do out[#out + 1] = CL[i] end
    for i = a, b do out[#out + 1] = TL[i] end
    for i = cb + 1, #CL do out[#out + 1] = CL[i] end
  else
    for i = 1, #CL - 1 do out[#out + 1] = CL[i] end
    for i = a, b do out[#out + 1] = TL[i] end
    out[#out + 1] = CL[#CL]
  end
  return table.concat(out, '\n')
end

-- чанк трека → шаблон без items
function P.template_of(track_chunk)
  local L = lines_of(track_chunk)
  local out, skip = {}, 0
  for _, l in ipairs(L) do
    if skip > 0 then
      if l:match('^%s*<') then skip = skip + 1 elseif l:match('^%s*>%s*$') then skip = skip - 1 end
    elseif l:match('^%s*<ITEM') then skip = 1
    else out[#out + 1] = l end
  end
  return table.concat(out, '\n') .. '\n'
end

-- имя файла пресета
function P.file_name(name) return ((name or 'preset'):gsub('[/\\:%*%?"<>|]', '_'):gsub('^%s+', ''):gsub('%s+$', '')) .. '.RTrackTemplate' end

return P
