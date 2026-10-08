-- jf_tracker_png.lua — PNG без внешних программ (8 окт, снимки measure).
--
-- PNG.encode(w, h, rgb) — rgb: строка w*h*3 байт (RGB, сверху вниз) →
-- строка файла PNG. Сжатия нет: deflate «stored»-блоками (до 65535 байт),
-- zlib-заголовок, adler32, crc32 чанков — всё на чистом Lua 5.3+.
-- PNG.grab(x, y, w, h) — пиксели текущего gfx.dest (gfx.getpixel) → rgb.
--
-- Без reaper.* в encode: тестируется в tests/test_png.lua.

local PNG = {}

local CRC = {}
for i = 0, 255 do
  local c = i
  for _ = 1, 8 do c = (c & 1 == 1) and (0xEDB88320 ~ (c >> 1)) or (c >> 1) end
  CRC[i] = c
end
local function crc32(s, c)
  c = (c or 0) ~ 0xFFFFFFFF
  for i = 1, #s do c = CRC[(c ~ s:byte(i)) & 0xFF] ~ (c >> 8) end
  return c ~ 0xFFFFFFFF
end
PNG.crc32 = crc32

local function adler32(s)
  local a, b = 1, 0
  local n, i = #s, 1
  while i <= n do
    local j = math.min(n, i + 3800)            -- без переполнения до взятия модуля
    for k = i, j do a = a + s:byte(k); b = b + a end
    a, b = a % 65521, b % 65521
    i = j + 1
  end
  return (b << 16) | a
end
PNG.adler32 = adler32

local function chunk(kind, data)
  return string.pack('>I4', #data) .. kind .. data .. string.pack('>I4', crc32(kind .. data))
end

function PNG.encode(w, h, rgb)
  local rows = {}
  local stride = w * 3
  for y = 0, h - 1 do rows[#rows + 1] = '\0' .. rgb:sub(y * stride + 1, (y + 1) * stride) end
  local raw = table.concat(rows)
  local z = { '\x78\x01' }
  local n, i = #raw, 1
  if n == 0 then z[#z + 1] = '\1\0\0\255\255' end
  while i <= n do
    local len = math.min(65535, n - i + 1)
    local last = (i + len > n) and 1 or 0
    z[#z + 1] = string.char(last) .. string.pack('<I2<I2', len, len ~ 0xFFFF) .. raw:sub(i, i + len - 1)
    i = i + len
  end
  z[#z + 1] = string.pack('>I4', adler32(raw))
  return '\137PNG\r\n\26\n'
    .. chunk('IHDR', string.pack('>I4>I4BBBBB', w, h, 8, 2, 0, 0, 0))
    .. chunk('IDAT', table.concat(z))
    .. chunk('IEND', '')
end

-- пиксели прямоугольника текущего gfx.dest
function PNG.grab(x, y, w, h)
  local out, row = {}, {}
  local char, floor = string.char, math.floor
  for yy = y, y + h - 1 do
    for xx = x, x + w - 1 do
      gfx.x, gfx.y = xx, yy
      local r, g, b = gfx.getpixel()
      row[#row + 1] = char(floor((r or 0) * 255 + 0.5), floor((g or 0) * 255 + 0.5), floor((b or 0) * 255 + 0.5))
    end
    out[#out + 1] = table.concat(row); row = {}
  end
  return table.concat(out)
end

return PNG
