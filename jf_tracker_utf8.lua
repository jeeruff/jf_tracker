-- jf_tracker_utf8.lua — набор текста не только латиницей (20 окт): кириллица и любой Юникод в полях ввода.
-- gfx.getchar отдаёт ASCII как есть, остальное — 'u'-префиксом 0x75000000 + код символа.
-- TX.char(c) → строка UTF-8 или nil (не печатный символ); TX.bs(s) — убрать последний символ, не байт.
local TX = {}
function TX.char(c)
  if not c then return nil end
  if c >= 32 and c < 127 then return string.char(c) end
  if c >= 0x75000000 and c < 0x76000000 then
    local cp = c - 0x75000000
    if cp >= 0xA0 and cp < 0x110000 and not (cp >= 0xD800 and cp < 0xE000) then return utf8.char(cp) end
  end
  return nil
end
function TX.bs(s)
  s = s or ''
  return (s:gsub('[%z\1-\127\194-\244][\128-\191]*$', ''))
end
return TX
