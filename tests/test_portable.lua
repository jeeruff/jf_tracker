-- test_portable.lua (5 ноя) — исходники не склеивают os.getenv(...) без запасного значения: на Windows нет HOME,
-- `os.getenv('HOME') .. путь` ронял трекер при запуске (0.9.3, jf_tracker.lua:14030). lua tests/test_portable.lua
local DIR = (arg and arg[0] or ''):match('(.*)/tests/') or '.'
local fails, n = 0, 0
local p = io.popen('ls "' .. DIR .. '"/jf_tracker*.lua "' .. DIR .. '"/modules/*.lua 2>/dev/null')
for f in p:lines() do
  local h = io.open(f); local src = h:read('a'); h:close()
  local ln = 0
  for line in (src .. '\n'):gmatch('([^\n]*)\n') do
    ln = ln + 1
    local code = line:gsub('%s%-%-%s.*$', '')
    n = n + 1
    if code:find("os%.getenv%b()%s*%.%.") then fails = fails + 1; print(('FAIL %s:%d unguarded os.getenv(...) ..: %s'):format(f:match('[^/]+$'), ln, code:sub(1, 120))) end
  end
end
p:close()
print(('%d lines, %d failed'):format(n, fails))
os.exit(fails == 0 and 0 or 1)
