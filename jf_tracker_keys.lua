-- jf_tracker_keys.lua — раскладка клавиш трекера. ФАЙЛ ПОЛЬЗОВАТЕЛЯ:
-- обновления скрипта его не трогают (как userkeys.lua в Hackey-Trackey).
--
-- Vim-команды (h j k l w b d y p …) живут в jf_tracker_vim.lua, их коды —
-- обычный ASCII. Здесь: (1) пианино для INSERT-режима, (2) коды спец-клавиш.
-- Узнать код клавиши: `:debug` — последний код виден в строке статуса.

local keys = {}

-- ── пианино (как в Renoise): нижний ряд — октава, верхний — октава+1 ──────
-- z s x d c v g b h n j m  = C C# D D# E F F# G G# A A# B
-- , l . ; /                = C C# D D# E   (октава +1)
-- q 2 w 3 e r 5 t 6 y 7 u  = C C# D D# E F F# G G# A A# B (октава +1)
-- i 9 o 0 p                = C C# D D# E   (октава +2)
-- ⌘1..⌘0                   = слот пула 1..10 (инструмент), ` = note-off
-- INSERT (Ableton-раскладка, 2 окт): пианино — ТОЛЬКО ряд qwertyuiop и цифры
-- (чёрные), как верхний ряд клавиатуры Ableton; q = C текущей октавы.
-- Нижние ряды — управление: h j k l движение, g/G начало/конец, b/n такт,
-- z/x октава, c/C velocity, , . инструмент, a step auto, s :step, d удалить,
-- f следующее fx-поле, m mute, ` note-off, > < лупы; Esc → NORMAL.
local high = { q = 0, ['2'] = 1, w = 2, ['3'] = 3, e = 4, r = 5, ['5'] = 6, t = 7, ['6'] = 8,
               y = 9, ['7'] = 10, u = 11, i = 12, ['9'] = 13, o = 14, ['0'] = 15, p = 16 }
-- 13 окт: опция keys: renoise — две октавы сразу, как в Renoise: нижний ряд z s x d c v g b h n j m , l . ; / —
-- октава курсора, верхний q 2 w 3 e … — на октаву выше (z x c / , . h j … в INSERT — ноты; октава — [ ],
-- движение — стрелки). Без опции — один верхний ряд (Ableton), нижние — управление.
local low = { z = 0, s = 1, x = 2, d = 3, c = 4, v = 5, g = 6, b = 7, h = 8, n = 9, j = 10, m = 11,
              [','] = 12, l = 13, ['.'] = 14, [';'] = 15, ['/'] = 16 }
keys.piano = {}
keys.renoise = false
-- подпись смещения: в Renoise до B — нижний ряд, выше — верхний (q = C октавы +1)
keys.plabel = {}
function keys.set_renoise(on)
  keys.renoise = on and true or false
  for k in pairs(keys.piano) do keys.piano[k] = nil end      -- та же таблица (её держат vim и main)
  for k in pairs(keys.plabel) do keys.plabel[k] = nil end
  for k, v in pairs(high) do keys.piano[k:byte()] = v + (keys.renoise and 12 or 0) end
  if keys.renoise then for k, v in pairs(low) do keys.piano[k:byte()] = v end end
  for code, off in pairs(keys.piano) do
    local ch = string.char(code)
    local hi = high[ch] ~= nil
    if not keys.plabel[off] or (keys.renoise and ((off >= 12) == hi)) then keys.plabel[off] = ch end
  end
end
keys.set_renoise(false)
-- 16 окт: раскладка frow — клавиатура на цифрах и F-ряду, буквы свободны для команд:
-- 1 2 3 4 5 6 7 8 9 0 - =  = C D E F G A B C D E F G (белые, полторы октавы)
-- F1 F2 . F4 F5 F6 . F8 F9 . F11 = C# D# . F# G# A# . C# D# . F# (чёрные над промежутками;
-- F3 F7 F10 — промежутки E-F и B-C, чёрной нет). Октава [ ], громкость { }.
-- Пока клавиатура играет (видна или INSERT), F-хоткеи не работают (main).
keys.layout = 'qwerty'
local FCODE = { [1] = 26161, [2] = 26162, [4] = 26164, [5] = 26165, [6] = 26166, [8] = 26168, [9] = 26169, [11] = 6697265 }
local frow_white = { ['1'] = 0, ['2'] = 2, ['3'] = 4, ['4'] = 5, ['5'] = 7, ['6'] = 9, ['7'] = 11, ['8'] = 12, ['9'] = 14, ['0'] = 16, ['-'] = 17, ['='] = 19 }
local frow_black = { [1] = 1, [2] = 3, [4] = 6, [5] = 8, [6] = 10, [8] = 13, [9] = 15, [11] = 18 }
function keys.set_layout(name)
  keys.layout = (name == 'frow' or name == 'renoise') and name or 'qwerty'
  if keys.layout == 'qwerty' then keys.set_renoise(false); return end
  if keys.layout == 'renoise' then keys.set_renoise(true); return end   -- 17 окт: снова третьим значением опции
  keys.renoise = false
  for k in pairs(keys.piano) do keys.piano[k] = nil end
  for k in pairs(keys.plabel) do keys.plabel[k] = nil end
  for ch, off in pairs(frow_white) do keys.piano[ch:byte()] = off; keys.plabel[off] = ch end
  for n, off in pairs(frow_black) do keys.piano[FCODE[n]] = off; keys.plabel[off] = 'f' .. n end   -- f4 строчными: уже, чем F4

end
keys.frow = function() return keys.layout == 'frow' end
-- код виртуальной клавиши (JS_VKeys) символа: буквы и цифры — как есть, знаки — свои коды
local VK = { [','] = 0xBC, ['.'] = 0xBE, [';'] = 0xBA, ['/'] = 0xBF }
function keys.vk(ch) return VK[ch] or ch:upper():byte() end
-- 16 окт: код клавиши gfx.getchar → JS_VKeys: символ — как выше, F1..F12 (26161.. / 6697264..) — 0x70..0x7B
VK['-'], VK['='] = 0xBD, 0xBB
-- имя клавиши по коду gfx.getchar: символ, F-ряд — f1 … f12 (строчными, узко)
function keys.name(code)
  if code >= 26161 and code <= 26169 then return 'f' .. (code - 26160) end
  if code >= 6697264 and code <= 6697266 then return 'f' .. (code - 6697254) end
  if code >= 0 and code < 256 then return string.char(code) end
  return nil
end
function keys.vk_of(code)
  if code >= 26161 and code <= 26169 then return 0x70 + code - 26161 end
  if code >= 6697264 and code <= 6697266 then return 0x79 + code - 6697264 end
  if code < 256 then return keys.vk(string.char(code)) end
  return nil
end

-- ── раскладки: русская ЙЦУКЕН → QWERTY по положению клавиш ───────────────
-- gfx.getchar отдаёт код символа, а не клавиши: в русской раскладке вместо
-- `h` приходит «р». Переводим по физическому месту, чтобы Vim-команды,
-- пианино и hex-ввод работали в любой раскладке. Другие раскладки — сюда же.
local ru = {
  ['й']='q',['ц']='w',['у']='e',['к']='r',['е']='t',['н']='y',['г']='u',['ш']='i',['щ']='o',['з']='p',['х']='[',['ъ']=']',
  ['ф']='a',['ы']='s',['в']='d',['а']='f',['п']='g',['р']='h',['о']='j',['л']='k',['д']='l',['ж']=';',['э']="'",
  ['я']='z',['ч']='x',['с']='c',['м']='v',['и']='b',['т']='n',['ь']='m',['б']=',',['ю']='.',['ё']='`',
  ['Й']='Q',['Ц']='W',['У']='E',['К']='R',['Е']='T',['Н']='Y',['Г']='U',['Ш']='I',['Щ']='O',['З']='P',['Х']='{',['Ъ']='}',
  ['Ф']='A',['Ы']='S',['В']='D',['А']='F',['П']='G',['Р']='H',['О']='J',['Л']='K',['Д']='L',['Ж']=':',['Э']='"',
  ['Я']='Z',['Ч']='X',['С']='C',['М']='V',['И']='B',['Т']='N',['Ь']='M',['Б']='<',['Ю']='>',['Ё']='~',
  ['№']='#',
}
keys.layout = {}
keys.to_ru = {}                                   -- латиница → кириллица (подписи клавиш)
for from, to in pairs(ru) do keys.layout[utf8.codepoint(from)] = to:byte(); keys.to_ru[to] = from end

-- код клавиши из gfx.getchar → код в латинской раскладке (или как есть).
-- Не-ASCII REAPER присылает как 'u' << 24 | код символа (5 окт: без снятия
-- префикса кириллица не находилась вовсе). keys.ru — последняя буква была
-- русской: подписи клавиш показываем кириллицей
keys.ru = false
function keys.translate(c)
  local cp = (c >= 0x75000000 and c < 0x76000000) and (c - 0x75000000) or c
  local t = keys.layout[cp]
  if t then keys.ru = true; return t end
  if (c >= 65 and c <= 90) or (c >= 97 and c <= 122) then keys.ru = false end
  return c
end
-- подпись клавиши (латинская буква / символ) в текущей раскладке
function keys.label(ch)
  if keys.ru and keys.to_ru[ch] then return keys.to_ru[ch] end
  return ch
end

-- ── спец-клавиши (коды gfx.getchar) ───────────────────────────────────────
keys.up, keys.down, keys.left, keys.right = 30064, 1685026670, 1818584692, 1919379572
keys.pgup, keys.pgdown, keys.home, keys['end'] = 1885828464, 1885824110, 1752132965, 6647396
keys.esc, keys.enter, keys.tab, keys.backspace, keys.delete = 27, 13, 9, 8, 6579564
keys.noteoff = ('`'):byte()
keys.f1 = 26161
keys.f11 = 6697265      -- док ↔ полноэкранное окно

return keys
