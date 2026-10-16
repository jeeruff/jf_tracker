-- jf_tracker_surge.lua — патчи Surge XT из трекера (16 окт).
--
-- Surge не отдаёт REAPER свои пресеты (GetPresetIndex — 0), его патчи — файлы .fxp
-- (patches_factory/<категория>/…, свои — ~/Documents/Surge XT/Patches). Запись
-- vst_chunk у VST3 молча не действует, поэтому патч ставится через чанк трека:
-- блок <VST …> = строка-обёртка VST3 (в её последних 12 байтах — общая длина
-- данных) + base64-строки данных по 210 байт + строка имени программы + «>».
-- Данные = [длина компонента LE][компонент][контроллер]; компонент Surge =
-- 01 00 00 00 + блок «sub3» (32 байта заголовка + XML патча) + хвост JUCE.
-- В .fxp после 60 байт заголовка (длина блока — BE в байтах 56..59) лежит тот же
-- блок «sub3»: он и подставляется, остальное остаётся как было.
--
-- Без reaper.*: тест tests/test_surge.lua.

local S = {}

-- ── base64 ────────────────────────────────────────────────────────────────
local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local DEC = {}
for i = 1, 64 do DEC[B64:byte(i)] = i - 1 end
function S.b64dec(s)
  local out, n, acc, bits = {}, 0, 0, 0
  for i = 1, #s do
    local v = DEC[s:byte(i)]
    if v then
      acc = (acc << 6) | v; bits = bits + 6
      if bits >= 8 then bits = bits - 8; n = n + 1; out[n] = string.char((acc >> bits) & 0xFF) end
    end
  end
  return table.concat(out)
end
function S.b64enc(d)
  local out = {}
  for i = 1, #d, 3 do
    local a, b, c = d:byte(i, i + 2)
    local v = (a << 16) | ((b or 0) << 8) | (c or 0)
    local q = { (v >> 18) & 63, (v >> 12) & 63, (v >> 6) & 63, v & 63 }
    out[#out + 1] = B64:sub(q[1] + 1, q[1] + 1) .. B64:sub(q[2] + 1, q[2] + 1)
      .. (b and B64:sub(q[3] + 1, q[3] + 1) or '=') .. (c and B64:sub(q[4] + 1, q[4] + 1) or '=')
  end
  return table.concat(out)
end

local function u32le(d, i) return string.unpack('<I4', d, i) end
local function u32be(d, i) return string.unpack('>I4', d, i) end

-- блок «sub3» из файла .fxp (nil — не патч Surge)
function S.fxp_chunk(fxp)
  if #(fxp or '') < 64 or fxp:sub(1, 4) ~= 'CcnK' then return nil end
  local n = u32be(fxp, 57)
  local ch = fxp:sub(61, 60 + n)
  if ch:sub(1, 4) ~= 'sub3' or #ch ~= n then return nil end
  return ch
end
-- имя патча из XML блока
function S.patch_name(chunk) return (chunk or ''):match('<meta name="([^"]*)"') end

-- данные состояния: новый блок «sub3» на место старого; nil — не Surge
function S.replace_state(data, chunk)
  if #(data or '') < 16 then return nil end
  local csz = u32le(data, 1)
  local comp = data:sub(5, 4 + csz)
  local ctl = data:sub(5 + csz)
  if comp:sub(5, 8) ~= 'sub3' then return nil end
  local xs = u32le(comp, 9)
  local tail = comp:sub(5 + 32 + xs)
  local nc = comp:sub(1, 4) .. chunk .. tail
  return string.pack('<I4', #nc) .. nc .. ctl
end

-- в чанке трека заменить данные блока VST номер nth (по порядку блоков <VST, с 1);
-- возвращает новый чанк или nil
function S.patch_track_chunk(tc, nth, chunk)
  local lines = {}
  for l in (tc .. '\n'):gmatch('([^\n]*)\n') do lines[#lines + 1] = l end
  local k, cnt = nil, 0
  for i, l in ipairs(lines) do
    if l:match('^%s*<VST ') then cnt = cnt + 1; if cnt == nth then k = i; break end end
  end
  if not k then return nil end
  local e
  for i = k + 1, #lines do if lines[i]:match('^%s*>%s*$') then e = i; break end end
  if not e or e - k < 4 then return nil end
  local ind = lines[k + 1]:match('^(%s*)') or ''
  local parts = {}
  for i = k + 2, e - 2 do parts[#parts + 1] = S.b64dec(lines[i]) end
  local data = S.replace_state(table.concat(parts), chunk)
  if not data then return nil end
  -- строка-обёртка: последние 12 байт — длина данных, 1, 0xFFFF
  local hdr = S.b64dec(lines[k + 1])
  if #hdr < 12 then return nil end
  hdr = hdr:sub(1, #hdr - 12) .. string.pack('<I4', #data) .. hdr:sub(#hdr - 7)
  local out = {}
  for i = 1, k do out[#out + 1] = lines[i] end
  out[#out + 1] = ind .. S.b64enc(hdr)
  for i = 1, #data, 210 do out[#out + 1] = ind .. S.b64enc(data:sub(i, i + 209)) end
  for i = e - 1, #lines do out[#out + 1] = lines[i] end
  if out[#out] == '' then out[#out] = nil end
  return table.concat(out, '\n')
end

-- категория и имя из пути: …/patches_factory/Basses/Attacky.fxp → Basses, Attacky
-- 16 окт: папка — весь путь от корня (3rd party: автор / категория), «A.Liv / Basses»
function S.label(path, root)
  local rel = path:sub(#root + 2)
  local dir = rel:match('^(.*)/[^/]+$') or ''
  local nm = (rel:match('([^/]+)%.fxp$') or rel)
  return (dir:gsub('/', ' / ')), nm
end

return S
