-- modules/freesound.lua (2 ноя) — custom-модуль: поиск звуков на freesound.org (Ctrl+W c f, :freesound).
-- Custom-модуль = файл в jf_tracker/modules/ или Data/jf_tracker_modules/, возвращает таблицу:
--   id, label, letter (буква после Ctrl+W c), side, help (строки справки { k, d }),
--   init(api), draw(U, L, x, y, w, h, focused), key(c, mods) → true, если съел, typing() → идёт набор.
-- api: R, dir, msg(s), preview_file(path), add_to_depot(path), fit(s, w), focus(id).
local M = { id = 'freesound', label = 'freesound', letter = 'f', side = 'right' }
M.about = 'Sounds from freesound.org: type words, the results play as you move, Enter puts one into the lib. Every download keeps its author and license in CREDITS.txt.'
M.help = {
  { k = '/  Enter', d = 'type words, Enter searches freesound.org (<10s >2s - length, cc0 - only CC0 sounds)' },
  { k = 'two columns', d = 'as in lf: authors are folders on the left, the sounds of the author under the cursor on the right; l - into the folder, h - back' },
  { k = 'j k  g G', d = 'move; in the sounds the one under the cursor plays (its mp3 preview is downloaded on the first listen)' },
  { k = 'Space', d = 'listen again' },
  { k = 'wave', d = 'the wave of the sound at the bottom: click - play from there, drag - scrub' },
  { k = 'Enter  l', d = 'author - into it; sound - into the lib of the cursor track (the marked ones, if any - each downloaded, in the order marked)' },
  { k = 'm  u', d = 'mark / unmark the row and step down (as in lf; on an author - all its sounds); u - unmark all' },
  { k = 'v', d = 'mark from here: then j k mark the rows passed, v again - stop' },
  { k = 'h', d = 'out of the author; on the authors - back to the previous search' },
  { k = 's', d = 'sort: relevance, most downloaded, best rated, newest, shortest, longest (a menu)' },
  { k = 'n  G', d = 'the next page is added at the end; j past the last row loads it too' },
  { k = '5j 3k', d = 'counts, as in Vim' },
  { k = ':freesound key K', d = 'your free API key once (freesound.org/apiv2/apply); :freesound words - search from anywhere' },
  { k = 'credits', d = 'the files lie in Data/jf_tracker_freesound/<author>/; author, license, link of each - CREDITS.txt there (CC BY needs the author)' },
  { k = 'Esc', d = 'back to the tracker' },
}
local A, FS
-- 3 ноя: как lf — S.lv 'a' (авторы, слева) / 'f' (звуки автора, справа); S.ac — курсор авторов, S.cur — звуков
local S = { lv = 'a', ac = 1, cur = 1, ascroll = 0, scroll = 0, typing = false, q = '', down = false, lastclick = 0, marks = {}, order = {}, hist = {} }

function M.init(api)
  A = api
  FS = dofile(api.dir .. '/jf_tracker_freesound.lua')
  M.FS = FS
end
function M.typing() return S.typing end
function M.paste(t) if S.typing then S.q = S.q .. t end end   -- Cmd+V в строке запроса

-- авторы по порядку первого появления в результатах (релевантность / сортировка сохраняются)
local GK, GR
local function groups()
  local k = ('%s|%s|%d'):format(FS.query, FS.sort, #FS.results)
  if k == GK then return GR end
  local by, out = {}, {}
  for _, h in ipairs(FS.results) do
    local g = by[h.user]
    if not g then g = { user = h.user, list = {} }; by[h.user] = g; out[#out + 1] = g end
    g.list[#g.list + 1] = h
  end
  GK, GR = k, out
  return out
end
local function author() return groups()[S.ac] end
local function files() local g = author(); return g and g.list or {} end
local function cur_file() return S.lv == 'f' and files()[S.cur] or nil end

local more
local function play_cur()
  local h = cur_file()
  if not h then return end
  local p = FS.fetch(h, function(path) if cur_file() == h then A.preview_file(path) end end)
  if p then A.preview_file(p) elseif not FS.err then A.msg('freesound: downloading ' .. h.name .. ' ...') end
end
local function mark(h, on)
  if not h then return end
  if on == nil then on = not S.marks[h.id] end
  if on and not S.marks[h.id] then S.marks[h.id] = h; S.order[#S.order + 1] = h
  elseif not on and S.marks[h.id] then
    S.marks[h.id] = nil
    for i, o in ipairs(S.order) do if o.id == h.id then table.remove(S.order, i); break end end
  end
end
local function mark_author(g)   -- автор — все его звуки (все отмечены — снять)
  if not g then return end
  local all = true
  for _, h in ipairs(g.list) do if not S.marks[h.id] then all = false end end
  for _, h in ipairs(g.list) do mark(h, not all) end
end
function more()   -- следующая страница — в конец списка (авторы дополняются)
  if FS.busy or #FS.results >= (FS.count or 0) or S.q == '' then return end
  if FS.search(S.q, (FS.page or 1) + 1, true) then A.msg('freesound: more results ...') end
end
local function to_lib()
  if #S.order > 0 then   -- отмеченные — по очереди отметки, каждый в lib, когда скачан
    local list = S.order
    S.marks, S.order = {}, {}
    for _, h in ipairs(list) do FS.fetch(h, function(path) A.add_to_depot(path) end) end
    A.msg(('freesound: %d marked into the lib (downloading)'):format(#list))
    return
  end
  local h = cur_file()
  if not h then return end
  if not FS.exists(FS.file_of(h)) then A.msg('freesound: downloading ' .. h.name .. ' ...') end
  FS.fetch(h, function(path) A.add_to_depot(path) end)
end
local function enter() if author() then S.lv, S.cur, S.scroll, S.vcur = 'f', 1, 0, nil; play_cur() end end
local function leave() S.lv, S.vis = 'a', nil end
local function move(n)
  if S.lv == 'a' then
    local na = #groups()
    S.ac = math.max(1, math.min(na, S.ac + n))
    if S.ac + n > na then more() end   -- за последним автором — догрузить
    return
  end
  local list = files()
  local c0 = S.cur
  local c = math.max(1, math.min(#list, S.cur + n))
  if S.vis then for i = math.min(c0, c), math.max(c0, c) do mark(list[i], true) end end
  if c ~= S.cur then S.cur = c; play_cur() end
end
function M.search(q, keep_hist)
  q = q or S.q
  if q == '' then return end
  if not keep_hist and FS.query ~= '' and FS.query ~= q then S.hist[#S.hist + 1] = FS.query end
  S.q = q
  S.lv, S.ac, S.cur, S.ascroll, S.scroll, S.vcur, S.avcur = 'a', 1, 1, 0, 0, nil, nil
  if FS.search(S.q) then A.msg('freesound: searching "' .. S.q .. '" ...') elseif FS.err then A.msg(FS.err) end
end
local function sort_menu()
  local items = {}
  local LET = { score = 'r', downloads_desc = 'd', rating_desc = 'b', created_desc = 'n', duration_asc = 's', duration_desc = 'l' }
  for _, so in ipairs(FS.SORTS) do
    items[#items + 1] = { key = LET[so[1]], label = so[2] .. (FS.sort == so[1] and '  (now)' or ''), fn = function() FS.sort = so[1]; M.search(S.q, true) end }
  end
  A.menu('freesound - sort', items)
end

function M.key(c)
  local TX = A.TX
  if S.typing then
    if c == 27 then S.typing = false
    elseif c == 13 then S.typing = false; M.search(S.q)
    elseif c == 8 then S.q = TX.bs(S.q)
    elseif TX.char(c) then S.q = S.q .. TX.char(c)
    else return true end
    return true
  end
  local ch = (c > 0 and c < 256) and string.char(c) or ''
  -- счётчик, как в Vim / lf: 5j 3k 10G
  if ch:match('^%d$') and not (ch == '0' and not S.count) then S.count = (S.count or 0) * 10 + tonumber(ch); A.msg(tostring(S.count)); return true end
  local n = S.count or 1
  local had = S.count ~= nil
  S.count = nil
  if c == 27 and (had or S.vis) then S.vis = nil; return true end
  local fl = S.lv == 'f'
  if ch == '/' then S.typing = true; S.q = ''
  elseif ch == 'j' or c == 1685026670 then move(n)
  elseif ch == 'k' or c == 30064 then move(-n)
  elseif ch == 'g' then if fl then S.cur = 1; play_cur() else S.ac = 1 end
  elseif ch == 'G' then
    if fl then local nn = #files(); S.cur = had and math.max(1, math.min(nn, n)) or math.max(1, nn); play_cur()
    else local na = #groups(); S.ac = had and math.max(1, math.min(na, n)) or math.max(1, na) end
  elseif ch == ' ' then if fl then play_cur() else enter() end
  elseif c == 13 or ch == 'l' or c == 1919379572 then if fl or #S.order > 0 then to_lib() else enter() end
  elseif ch == 'h' or c == 8 or c == 1818584692 then
    if fl then leave() else local q = table.remove(S.hist); if q then M.search(q, true) end end
  elseif ch == 'm' then
    for _ = 1, n do
      if fl then local list = files(); mark(list[S.cur]); if S.cur < #list then S.cur = S.cur + 1 end
      else mark_author(author()); if S.ac < #groups() then S.ac = S.ac + 1 end end
    end
  elseif ch == 'u' then S.marks, S.order = {}, {}; A.msg('freesound: marks cleared')
  elseif ch == 'v' then if fl then S.vis = not S.vis; if S.vis then mark(cur_file(), true); A.msg('freesound: marking - j k, v or Esc to stop') end end
  elseif ch == 's' then sort_menu()
  elseif ch == 'n' then more()
  else return false end
  return true
end

-- колонка строк: rows (список), cur, скролл в S[sk]; row(e, x, ry, w, sel) рисует строку; возвращает индекс под щелчком
local function column(U, L, x, y, w, h, rows, cur, sk, vk, active, row, click, inside, my)
  local nv = math.max(1, math.floor(h / L.rh))
  if cur ~= S[vk] then   -- курсор сдвинулся — список за ним (колесо листает само)
    S[vk] = cur
    if cur <= S[sk] then S[sk] = cur - 1 elseif cur > S[sk] + nv then S[sk] = cur - nv end
  end
  S[sk] = math.max(0, math.min(math.max(0, #rows - nv), S[sk]))
  local hit
  for i = 1, nv do
    local idx = S[sk] + i
    local e = rows[idx]
    if not e then break end
    local ry = y + (i - 1) * L.rh
    local hot = inside and my >= ry and my < ry + L.rh
    if idx == cur and cur > 0 then U.set(U.tint(U.AMBER, active and 0.25 or 0.12)); gfx.rect(x, ry, w, L.rh, 1)
    elseif hot then U.set(U.tint(U.TEXT, 0.06)); gfx.rect(x, ry, w, L.rh, 1) end
    row(e, x, ry, w, idx == cur and cur > 0)
    if hot and click then hit = idx end
  end
  return hit, nv
end

function M.draw(U, L, x, y, w, h, focused)
  if next(FS.jobs) then
    local e0 = FS.err
    local app = FS.append
    if FS.tick() and not app then S.lv, S.ac, S.cur, S.vcur, S.avcur = 'a', 1, 1, nil, nil end
    if FS.err and FS.err ~= e0 then A.msg(FS.err) end
  end
  local fit = A.fit
  local mx, my = gfx.mouse_x, gfx.mouse_y
  -- строка запроса
  local qy = y + 2
  U.text(x + L.pad, qy, fit('/' .. S.q .. (S.typing and '_' or ''), w - 2 * L.pad), S.typing and U.AMBER or (S.q ~= '' and U.TEXT or U.GREY))
  -- состояние
  local sy = qy + L.rh
  local st
  if FS.key() == '' then st = 'no API key: get a free one at freesound.org/apiv2/apply, then :freesound key <key>'
  elseif FS.busy then st = 'searching ...'
  elseif FS.err then st = FS.err
  elseif FS.query == '' then st = '/ words, Enter - search; <10s >2s cc0 filter'
  else
    local sn = 'relevance'
    for _, so in ipairs(FS.SORTS) do if so[1] == FS.sort then sn = so[2] end end
    st = ('%d of %d, %d authors   s: %s%s%s'):format(#FS.results, FS.count or 0, #groups(), sn, #S.order > 0 and ('   marked ' .. #S.order) or '', S.vis and '   -- MARK --' or '')
  end
  U.text(x + L.pad, sy, fit(st, w - 2 * L.pad), FS.err and (U.RED or U.AMBER) or U.GREY)
  -- волна выбранного звука внизу (когда превью скачано), позиция прослушивания — линией
  local wh = math.max(2 * L.rh, math.min(6 * L.rh, math.floor(h * 0.22)))
  local wy = y + h - wh - 2
  do
    local e = cur_file()
    local wx, ww = x + L.pad, w - 2 * L.pad
    U.set(U.BG); gfx.rect(wx, wy, ww, wh, 1)
    U.set(U.LINE or U.GREY); gfx.rect(wx, wy, ww, wh, 0)
    local p = e and FS.file_of(e)
    local pk = p and FS.exists(p) and ww > 8 and A.peaks(p, ww)
    local cy, hh = wy + math.floor(wh / 2), math.floor(wh / 2) - 2
    if pk and (pk.n or 0) > 0 then
      U.set(U.mix and U.mix(U.TEXT, U.CYAN, 0.4) or U.CYAN)
      for px = 0, ww - 1 do
        local i = math.floor(px * pk.n / ww) + 1
        local a, b = pk.min[i] or 0, pk.max[i] or 0
        if b - a < 0.03 then a, b = -0.015, 0.015 end
        gfx.line(wx + px, cy - b * hh, wx + px, cy - a * hh)
      end
      -- щелчок / протяжка по волне — играть с этого места (плейхед ведётся мышью)
      local onw = mx >= wx and mx < wx + ww and my >= wy and my < wy + wh
      if (gfx.mouse_cap & 1) == 1 and (S.wdrag or (onw and not S.down)) then
        S.wdrag = true
        local fr = math.max(0, math.min(1, (mx - wx) / ww))
        if not S.wfr or math.abs(fr - S.wfr) * ww >= 3 then S.wfr = fr; A.preview_from(p, fr) end
      elseif (gfx.mouse_cap & 1) == 0 then S.wdrag, S.wfr = nil, nil end
      local pos, len, path = A.preview_pos()
      if pos and len and len > 0 and path == p then
        local px = wx + math.floor(math.min(1, pos / len) * (ww - 1))
        U.set(U.mix and U.mix(U.AMBER, U.TEXT, 0.35) or U.AMBER); gfx.rect(px - 1, wy + 1, 3, wh - 2, 1)   -- ярче и шире: 3 px
      end
      if onw and not S.wdrag then U.set(U.TEXT); gfx.a = 0.25; gfx.rect(mx, wy + 1, 1, wh - 2, 1); gfx.a = 1 end   -- куда встанет щелчок
    elseif e then
      U.text(wx + L.pad, cy - math.floor(L.rh / 2), fit(FS.pending(e) and 'downloading ...' or 'j k / Space - listen, the wave comes with it', ww - 2 * L.pad), U.DIM or U.GREY)
    elseif author() then
      U.text(wx + L.pad, cy - math.floor(L.rh / 2), fit('l - into ' .. author().user .. ', the sounds play as you move', ww - 2 * L.pad), U.DIM or U.GREY)
    end
  end
  -- две колонки, как lf: авторы | звуки автора под курсором
  local ly = sy + L.rh + 4
  local lh = wy - 4 - ly
  local aw = math.max(U.measure('w') * 12, math.floor(w * 0.36))
  local fx, fw = x + aw + 1, w - aw - 1
  U.set(U.LINE or U.GREY); gfx.rect(x + aw, ly, 1, lh, 1)
  local click = (gfx.mouse_cap & 1) == 1 and not S.down and not S.wdrag
  local ina = mx >= x and mx < x + aw and my >= ly and my < ly + lh
  local inf = mx >= fx and mx < fx + fw and my >= ly and my < ly + lh
  local G = groups()
  local ha, nva = column(U, L, x, ly, aw, lh, G, S.ac, 'ascroll', 'avcur', S.lv == 'a' and focused, function(g, rx, ry, rw, sel)
    local nm = 0; for _, hh in ipairs(g.list) do if S.marks[hh.id] then nm = nm + 1 end end
    local cnt = (nm > 0 and (nm .. '/') or '') .. #g.list
    U.text(rx + L.pad, ry + 1, fit('/' .. g.user, rw - 2 * L.pad - U.measure(cnt .. ' ')), sel and U.AMBER or (nm > 0 and (U.CYAN or U.TEXT) or U.TEXT))
    U.text(rx + rw - L.pad - U.measure(cnt), ry + 1, cnt, U.GREY)
  end, click, ina, my)
  local lenw = U.measure('000.0s ')
  local licw = U.measure('CC BY-NC ')
  local hf = column(U, L, fx, ly, fw, lh, files(), S.lv == 'f' and S.cur or 0, 'scroll', 'vcur', S.lv == 'f' and focused, function(e, rx, ry, rw, sel)
    local nw = rw - 2 * L.pad - lenw - licw
    local mk = S.marks[e.id]
    if mk then U.set(U.tint(U.CYAN or U.AMBER, 0.18)); gfx.rect(rx, ry, rw, L.rh, 1) end
    local cached = FS.exists(FS.file_of(e))
    U.text(rx + L.pad, ry + 1, fit((FS.pending(e) and '~ ' or (cached and '+ ' or '  ')) .. e.name, nw), sel and U.AMBER or (mk and (U.CYAN or U.TEXT) or (S.lv == 'f' and U.TEXT or U.GREY)))
    local ls = ('%.1fs'):format(e.len or 0)
    U.text(rx + L.pad + nw + lenw - U.measure(ls .. ' '), ry + 1, ls, U.GREY)
    U.text(rx + rw - L.pad - licw, ry + 1, fit(e.lic, licw), e.lic == 'CC0' and U.GREEN or U.GREY)
  end, click, inf, my)
  if ha then S.ac, S.lv = ha, 'a' end
  if hf then
    local now = A.R.time_precise()
    if S.lv == 'f' and S.cur == hf and now - S.lastclick < 0.35 then to_lib() else S.lv, S.cur = 'f', hf; play_cur() end
    S.lastclick = now
  end
  S.down = (gfx.mouse_cap & 1) == 1
  if gfx.mouse_wheel ~= 0 and (ina or inf) then
    local d = gfx.mouse_wheel > 0 and -3 or 3
    gfx.mouse_wheel = 0
    if ina then S.ascroll = S.ascroll + d; if S.ascroll >= #G - nva then more() end else S.scroll = S.scroll + d end
  end
end

return M
