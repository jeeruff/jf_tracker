-- test_png.lua — кодер PNG (jf_tracker_png.lua): crc / adler по эталонам,
-- файл 3x2 читается python3 (если есть — проверка вне Lua)
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/') or '.'
local PNG = dofile(DIR .. '/jf_tracker_png.lua')
local n, bad = 0, 0
local function eq(a, b, m) n = n + 1; if a ~= b then bad = bad + 1; print('FAIL ' .. m .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b)) end end

eq(PNG.crc32('123456789'), 0xCBF43926, 'crc32 check value')
eq(PNG.adler32('Wikipedia'), 0x11E60398, 'adler32 reference')
local rgb = string.char(255, 0, 0, 0, 255, 0, 0, 0, 255, 10, 20, 30, 40, 50, 60, 70, 80, 90)
local f = PNG.encode(3, 2, rgb)
eq(f:sub(1, 8), '\137PNG\r\n\26\n', 'signature')
eq(f:sub(13, 16), 'IHDR', 'IHDR first')
local big = PNG.encode(200, 120, string.rep('\1\2\3', 200 * 120))   -- > 65535: несколько stored-блоков
eq(#big > 200 * 120 * 3, true, 'big image: all bytes stored')
local tmp = os.tmpname() .. '.png'
local fh = io.open(tmp, 'wb'); fh:write(big); fh:close()
local py = io.popen(('python3 -c "import zlib,struct;d=open(%q,\'rb\').read();i=d.index(b\'IDAT\');l=struct.unpack(\'>I\',d[i-4:i])[0];r=zlib.decompress(d[i+4:i+4+l]);print(len(r))" 2>/dev/null'):format(tmp))
local out = py and py:read('a') or ''
if py then py:close() end
if out ~= '' then eq(tonumber(out), 120 * (1 + 200 * 3), 'zlib inflates to rows + filter bytes') end
os.remove(tmp)
print(('%d checks, %d failed'):format(n, bad))
if bad > 0 then os.exit(1) end
