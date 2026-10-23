-- test_info_table.lua (23 окт): таблица info кадра — без дублей ключей (22 окт: modsel затёр функцию) и без полей,
-- спрятанных за комментарием в той же строке (21 окт: sig_at и ещё 4 поля); проверки — tools/*.py
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local function run(cmd) local ok = os.execute(('cd %q && %s'):format(DIR, cmd)); return ok == true or ok == 0 end
local bad = 0
if not run('python3 tools/info_dups.py > /dev/null') then bad = bad + 1; print('FAIL duplicate keys in info: python3 tools/info_dups.py') end
if not run('python3 tools/comment_trap.py jf_tracker*.lua > /dev/null') then bad = bad + 1; print('FAIL fields behind a comment: python3 tools/comment_trap.py') end
print(('test_info_table: 2 checks, %d failed'):format(bad)); os.exit(bad == 0 and 0 or 1)
