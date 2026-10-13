-- test_tracks.lua — дерево треков модуля tracks (jf_tracker_tracks.lua). Запуск: lua tests/test_tracks.lua
local DIR = (arg and arg[0] or ''):match('(.*)/tests/') or '.'
local T = dofile(DIR .. '/jf_tracker_tracks.lua')
local fails, checks = 0, 0
local function ok(name, cond, info)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL ' .. name .. (info and (': ' .. info) or '')) end
end
-- «a b(c d) e» → список; строка обратно
local function L(s)
  local out, d = {}, 0
  for tok in s:gmatch('%S') do
    if tok == '(' then d = d + 1 elseif tok == ')' then d = d - 1 else out[#out + 1] = { id = tok, d = d } end
  end
  return out
end
local function S(list)
  local o, d = {}, 0
  for _, e in ipairs(list) do
    while d < e.d do o[#o + 1] = '('; d = d + 1 end
    while d > e.d do o[#o + 1] = ')'; d = d - 1 end
    o[#o + 1] = e.id
  end
  while d > 0 do o[#o + 1] = ')'; d = d - 1 end
  return table.concat(o, ' ')
end
local function eq(name, got, want) ok(name, got == want, ('got "%s", want "%s"'):format(got, want)) end

-- 1. глубины ↔ I_FOLDERDEPTH
local l = L('a b ( c d ) e')
local fd = T.folderdepths(l)
eq('folderdepths', table.concat(fd, ','), '0,1,0,-1,0')
eq('depths back', table.concat(T.depths(fd), ','), '0,0,1,1,0')
eq('nested close', table.concat(T.folderdepths(L('a ( b ( c ) )')), ','), '1,1,-2')
eq('round trip', S(L('a ( b ( c ) d ) e')), 'a ( b ( c ) d ) e')
-- 2. блок, родитель, братья
l = L('a ( b ( c ) d ) e')
local i, j = T.block(l, 1); ok('block of a folder', i == 1 and j == 4)
ok('parent of c is b', T.parent(l, 3) == 2)
ok('sibling of d up is b', T.sibling(l, 4, -1) == 2)
ok('sibling of a down is e', T.sibling(l, 1, 1) == 5)
ok('no sibling up of b', T.sibling(l, 2, -1) == nil)
-- 3. >> : в предыдущего брата
eq('indent into a plain track (it becomes a folder)', S((T.indent(L('a b c'), { 'b' }))), 'a ( b ) c')
eq('indent into a folder: last child', S((T.indent(L('a ( x ) b'), { 'b' }))), 'a ( x b )')
eq('indent a folder with its children', S((T.indent(L('a b ( c )'), { 'b' }))), 'a ( b ( c ) )')
local _, n = T.indent(L('a b'), { 'a' }); ok('indent without a sibling above does nothing', n == 0)
-- 4. << : из папки — за блоком родителя
eq('outdent the last child', S((T.outdent(L('a ( b c ) d'), { 'c' }))), 'a ( b ) c d')
eq('outdent a middle child - after the whole folder', S((T.outdent(L('a ( b c ) d'), { 'b' }))), 'a ( c ) b d')
eq('outdent a subfolder with children', S((T.outdent(L('a ( b ( c ) )'), { 'b' }))), 'a b ( c )')
-- 5. J K: перенос среди братьев блоками
eq('move down over a folder', S((T.move(L('a b ( c ) d'), { 'a' }, 1))), 'b ( c ) a d')
eq('move a folder up', S((T.move(L('a b ( c ) d'), { 'b' }, -1))), 'b ( c ) a d')
_, n = T.move(L('a ( b ) c'), { 'b' }, -1); ok('move stays inside its folder', n == 0)
-- 6. вставка за блоком на его уровень
eq('insert after a folder - not inside it', S(T.insert(L('a ( b ) c'), { { id = 'n', d = 0 } }, 'a', true)), 'a ( b ) n c')
eq('insert after the last child - stays inside', S(T.insert(L('a ( b ) c'), { { id = 'n', d = 0 } }, 'b', true)), 'a ( b n ) c')
eq('insert before', S(T.insert(L('a b'), { { id = 'n', d = 0 } }, 'b', false)), 'a n b')
eq('insert a pasted folder', S(T.insert(L('a b'), { { id = 'x', d = 0 }, { id = 'y', d = 1 } }, 'a', true)), 'a x ( y ) b')
-- 7. папка вокруг отмеченных
eq('wrap one track', S(T.wrap(L('a b c'), { 'b' }, 'F')), 'a F ( b ) c')
eq('wrap marked across the list', S(T.wrap(L('a b c d'), { 'b', 'd' }, 'F')), 'a F ( b d ) c')
eq('wrap a folder and its child once', S(T.wrap(L('a ( b ) c'), { 'a', 'b' }, 'F')), 'F ( a ( b ) ) c')
eq('wrap inside a folder', S(T.wrap(L('a ( b c )'), { 'c' }, 'F')), 'a ( b F ( c ) )')
-- 8. корни выбора
eq('roots drop children of marked folders', table.concat(T.roots(L('a ( b ) c'), { 'b', 'a', 'c' }), ','), 'a,c')

print(('%d checks, %d failed'):format(checks, fails))
os.exit(fails == 0 and 0 or 1)
