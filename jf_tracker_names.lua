-- jf_tracker_names.lua — подсказки имён (5 окт): «/» в поле имени трека,
-- инструмента, item или региона открывает список. Имена треков и
-- инструментов — из правил SWS Auto Color/Icon (sws-autocoloricon.ini, тип 0
-- = имя трека: выбранное имя сразу красит правило SWS) и запаса ниже;
-- регионы — части формы.
local N = {}

N.DEFAULT = {
  'kick', 'snare', 'clap', 'rim', 'hihat', 'open hat', 'ride', 'crash', 'cymbal', 'tom', 'perc', 'shaker',
  'tambourine', 'conga', 'bongo', 'cowbell', 'break', 'drums', 'beat', 'loop', 'fill',
  'bass', 'sub', '808', 'bass guitar', 'bassguitar', 'reese', 'acid',
  'pad', 'texture', 'drone', 'ambience', 'atmo', 'bell', 'pluck', 'arp', 'lead', 'stab', 'chord', 'synth',
  'keys', 'piano', 'rhodes', 'organ', 'guitar', 'gtr', 'amp', 'strings', 'brass', 'horn', 'flute', 'sax',
  'vox', 'voice', 'choir', 'chop', 'sample', 'riser', 'impact', 'sweep', 'noise', 'foley', 'field', 'sfx', 'fx',
  'reverb', 'delay', 'bus', 'send', 'aux', 'print', 'ref', 'midi',
}
N.REGION = {
  'intro', 'verse', 'pre', 'chorus', 'hook', 'drop', 'build', 'break', 'bridge', 'breakdown',
  'interlude', 'solo', 'fill', 'outro', 'end', 'a', 'b', 'c',
}

-- правила SWS: AutoColor N=тип имя цвет "иконка" … ; имя бывает в кавычках
function N.sws(path)
  path = path or (reaper.GetResourcePath() .. '/sws-autocoloricon.ini')
  local f = io.open(path, 'r'); if not f then return {} end
  local out = {}
  for line in f:lines() do
    local ty, rest = line:match('^AutoColor %d+=(%d+) (.*)$')
    if ty == '0' and rest then
      local nm = rest:match('^"([^"]*)"') or rest:match('^(%S+)')
      if nm and nm ~= '' and not nm:match('^%(') then out[#out + 1] = nm end
    end
  end
  f:close()
  return out
end

local cache
-- kind: 'region' | другое (трек / инструмент / item)
function N.list(kind)
  if kind == 'region' then return N.REGION end
  if not cache then
    cache = {}; local seen = {}
    for _, src in ipairs({ N.sws(), N.DEFAULT }) do
      for _, nm in ipairs(src) do
        local k = nm:lower()
        if not seen[k] then seen[k] = true; cache[#cache + 1] = nm end
      end
    end
  end
  return cache
end

-- командные строки, где аргумент — имя: префикс и вид списка
N.PREFIX = { { 'iprop name ', 'item' }, { 'tname ', 'track' }, { 'iname ', 'inst' }, { 'name ', 'region' } }
function N.target(line)
  for _, p in ipairs(N.PREFIX) do
    if line:sub(1, #p[1]) == p[1] then return p[1], p[2] end
  end
end

return N
