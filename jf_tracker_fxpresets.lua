-- jf_tracker_fxpresets.lua — поиск по пресетам плагинов (28 окт; тест tests/test_presets_index.lua).
-- Источник — папка REAPER/presets: <тип>-<имя>.ini — пресеты пользователя ([PresetN] Name=), <…>-builtin.ini —
-- кеш заводских ([factory] / [aufactory] NNNNN=имя; REAPER пишет его, когда плагин открывали). Без reaper.*:
-- файлы читает вызывающий (PI.parse_ini(текст)), сопоставление с плагином — PI.key_of_file / PI.key_of_fx.
local PI = {}

-- ключ файла пресетов: «vst:reacomp», «vst3:serum2-691258006», «au:xfer records: nerve», «js:jf_slixer_jsfx»; builtin
function PI.key_of_file(fname)
  local stem = fname:gsub('%.ini$', '')
  if stem == fname then return nil end
  local builtin = false
  if stem:sub(-8) == '-builtin' then stem = stem:sub(1, -9); builtin = true end
  local kind, rest = stem:match('^(%w+)%-(.+)$')
  if not kind then return nil end
  kind = kind:lower()
  if kind ~= 'vst' and kind ~= 'vst3' and kind ~= 'au' and kind ~= 'js' and kind ~= 'clap' then return nil end
  return kind .. ':' .. rest:lower(), builtin
end

-- ключ плагина из EnumInstalledFX (имя с типом, ident) — тот же вид, что у файла
function PI.key_of_fx(name, ident)
  local typ = (name or ''):match('^(%w+)i?:')
  if not typ or not ident then return nil end
  typ = typ:lower():gsub('i$', '')
  if typ == 'vst' then
    local b = ident:match('([^/]+)$') or ident
    b = b:gsub('<.*$', ''):gsub('%.vst%.dylib$', ''):gsub('%.dylib$', ''):gsub('%.vst$', ''):gsub('%.so$', ''):gsub('%.dll$', '')
    return 'vst:' .. b:lower()
  elseif typ == 'vst3' then
    local b = ident:match('([^/]+)$') or ident
    local id = b:match('<(%d+)')
    b = b:gsub('<.*$', ''):gsub('%.vst3$', '')
    return 'vst3:' .. b:lower() .. (id and ('-' .. id) or ''), 'vst3:' .. b:lower()
  elseif typ == 'au' then return 'au:' .. ident:lower()
  elseif typ == 'js' then return 'js:' .. ident:gsub('[/%.]', '_'):lower()
  elseif typ == 'clap' then return 'clap:' .. ident:lower() end
  return nil
end

-- имена пресетов из текста ini: пользовательские ([PresetN] Name=) и заводские ([factory] NNNNN=)
function PI.parse_ini(txt)
  local out, sec = {}, nil
  for line in (txt or ''):gmatch('[^\r\n]+') do
    local s = line:match('^%[(.-)%]%s*$')
    if s then sec = s:lower()
    elseif sec and sec:match('^preset%d+$') then
      local nm = line:match('^Name=(.*)$')
      if nm and nm ~= '' then out[#out + 1] = nm end
    elseif sec == 'factory' or sec == 'aufactory' then
      local nm = line:match('^%d+=(.*)$')
      -- безымянные слоты (Program 1, Program List A: Program 0-3, Preset 12) — не пресеты
      local blank = nm and (nm:match('^[Pp]rogram[%s%d%-]*$') or nm:match('[Pp]rogram [Ll]ist %w+: [Pp]rogram') or nm:match('^[Pp]reset[%s%d%-]*$'))
      if nm and nm ~= '' and nm ~= '(Custom)' and nm ~= 'Default' and not blank then out[#out + 1] = nm end
    end
  end
  return out
end

-- индекс: files = { { name = 'vst-reacomp.ini', text = '…' } }, fx = { { label, data } } →
-- { { fx = элемент списка fx, preset = имя, user = true / false } }
function PI.build(files, fx)
  local by = {}
  for _, it in ipairs(fx) do
    local k1, k2 = PI.key_of_fx(it.label, it.data)
    if k1 and not by[k1] then by[k1] = it end
    if k2 and not by[k2] then by[k2] = it end
  end
  local out = {}
  for _, f in ipairs(files) do
    local key, builtin = PI.key_of_file(f.name)
    local it = key and by[key]
    if it then
      for _, nm in ipairs(PI.parse_ini(f.text)) do out[#out + 1] = { fx = it, preset = nm, user = not builtin } end
    end
  end
  return out
end

return PI
