-- modules/freesound.lua (2 ноя) — custom-модуль: поиск звуков на freesound.org (Ctrl+W c f, :freesound).
-- Custom-модуль = файл в jf_tracker/modules/ или Data/jf_tracker_modules/, возвращает таблицу:
--   id, label, letter (буква после Ctrl+W c), side, help (строки справки { k, d }),
--   init(api), draw(U, L, x, y, w, h, focused), key(c, mods) → true, если съел, typing() → идёт набор.
-- api: R, dir, msg(s), preview_file(path), add_to_depot(path), fit(s, w), focus(id).
local M = { id = 'freesound', label = 'freesound', letter = 'f', side = 'right' }
M.about = 'Sounds from freesound.org: type words, the results play as you move, Enter puts one into the lib. Every download keeps its author and license in CREDITS.txt.'
M.help = {
  { k = '/  Enter', d = 'type words, Enter searches freesound.org (<10s >2s - length, cc0 - only CC0 sounds)' },
  { k = 'j k  g G', d = 'move; the sound under the cursor plays (its mp3 preview is downloaded on the first listen)' },
  { k = 'Space', d = 'listen again' },
  { k = 'Enter  l', d = 'into the lib of the cursor track' },
  { k = 'n  N', d = 'next / previous page of results' },
  { k = ':freesound key K', d = 'your free API key once (freesound.org/apiv2/apply); :freesound words - search from anywhere' },
  { k = 'credits', d = 'author, license, link of every downloaded file: Data/jf_tracker_freesound/CREDITS.txt (CC BY needs the author)' },
  { k = 'Esc', d = 'back to the tracker' },
}
local A, FS
local S = { cur = 1, scroll = 0, typing = false, q = '', last = nil, down = false, lastclick = 0 }

function M.init(api)
  A = api
  FS = dofile(api.dir .. '/jf_tracker_freesound.lua')
  M.FS = FS
end
function M.typing() return S.typing end
function M.paste(t) if S.typing then S.q = S.q .. t end end   -- Cmd+V в строке запроса

local function play_cur()
  local h = FS.results[S.cur]
  if not h then return end
  local p = FS.fetch(h, function(path) if FS.results[S.cur] == h then A.preview_file(path) end end)
  if p then A.preview_file(p) elseif not FS.err then A.msg('freesound: downloading ' .. h.name .. ' ...') end
end
local function to_lib()
  local h = FS.results[S.cur]
  if not h then return end
  if not FS.exists(FS.file_of(h)) then A.msg('freesound: downloading ' .. h.name .. ' ...') end
  FS.fetch(h, function(path) A.add_to_depot(path) end)
end
local function move(n)
  local c = math.max(1, math.min(#FS.results, S.cur + n))
  if c ~= S.cur then S.cur = c; play_cur() end
end
function M.search(q, page)
  S.q = q or S.q
  if S.q == '' then return end
  S.cur, S.scroll = 1, 0
  if FS.search(S.q, page) then A.msg('freesound: searching "' .. S.q .. '" ...') elseif FS.err then A.msg(FS.err) end
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
  if ch == '/' then S.typing = true; S.q = ''
  elseif ch == 'j' or c == 1685026670 then move(1)
  elseif ch == 'k' or c == 30064 then move(-1)
  elseif ch == 'g' then S.cur = 1; play_cur()
  elseif ch == 'G' then S.cur = math.max(1, #FS.results); play_cur()
  elseif ch == ' ' then play_cur()
  elseif c == 13 or ch == 'l' then to_lib()
  elseif ch == 'n' then if (FS.page or 1) * FS.PAGE < (FS.count or 0) then M.search(S.q, (FS.page or 1) + 1) end
  elseif ch == 'N' then if (FS.page or 1) > 1 then M.search(S.q, FS.page - 1) end
  else return false end
  return true
end

function M.draw(U, L, x, y, w, h, focused)
  if next(FS.jobs) then
    local e0 = FS.err
    if FS.tick() then S.cur = 1 end
    if FS.err and FS.err ~= e0 then A.msg(FS.err) end
  end
  local fit = A.fit
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local inside = mx >= x and mx < x + w and my >= y and my < y + h
  -- строка запроса
  local qy = y + 2
  local qtxt = '/' .. S.q .. (S.typing and '_' or '')
  U.text(x + L.pad, qy, fit(qtxt, w - 2 * L.pad), S.typing and U.AMBER or (S.q ~= '' and U.TEXT or U.GREY))
  -- состояние
  local sy = qy + L.rh
  local st
  if FS.key() == '' then st = 'no API key: get a free one at freesound.org/apiv2/apply, then :freesound key <key>'
  elseif FS.busy then st = 'searching ...'
  elseif FS.err then st = FS.err
  elseif FS.query == '' then st = '/ words, Enter - search; <10s >2s cc0 filter'
  else st = ('%d-%d of %d   n N - pages'):format(((FS.page or 1) - 1) * FS.PAGE + math.min(1, #FS.results), ((FS.page or 1) - 1) * FS.PAGE + #FS.results, FS.count or 0) end
  U.text(x + L.pad, sy, fit(st, w - 2 * L.pad), FS.err and (U.RED or U.AMBER) or U.GREY)
  -- волна выбранного звука внизу (когда превью скачано), позиция прослушивания — линией
  local wh = math.max(2 * L.rh, math.min(6 * L.rh, math.floor(h * 0.22)))
  local wy = y + h - wh - 2
  do
    local e = FS.results[S.cur]
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
      local pos, len, path = A.preview_pos()
      if pos and len and len > 0 and path == p then
        U.set(U.AMBER); gfx.rect(wx + math.floor(math.min(1, pos / len) * (ww - 1)), wy + 1, 1, wh - 2, 1)
      end
    elseif e then
      U.text(wx + L.pad, cy - math.floor(L.rh / 2), fit(FS.pending(e) and 'downloading ...' or 'j k / Space - listen, the wave comes with it', ww - 2 * L.pad), U.DIM or U.GREY)
    end
  end
  -- список
  local ly = sy + L.rh + 4
  local nv = math.max(1, math.floor((wy - 4 - ly) / L.rh))
  if S.cur ~= S.vcur then   -- курсор сдвинулся — список за ним (колесо листает само)
    S.vcur = S.cur
    if S.cur <= S.scroll then S.scroll = S.cur - 1 elseif S.cur > S.scroll + nv then S.scroll = S.cur - nv end
  end
  local lenw, metaw = U.measure('000.0s  '), math.min(math.floor(w * 0.35), U.measure('w') * 22)
  local click = (gfx.mouse_cap & 1) == 1 and not S.down
  S.down = (gfx.mouse_cap & 1) == 1
  for i = 1, nv do
    local idx = S.scroll + i
    local e = FS.results[idx]
    if not e then break end
    local ry = ly + (i - 1) * L.rh
    local hot = inside and my >= ry and my < ry + L.rh
    if idx == S.cur then U.set(U.tint(U.AMBER, focused and 0.25 or 0.12)); gfx.rect(x, ry, w, L.rh, 1)
    elseif hot then U.set(U.tint(U.TEXT, 0.06)); gfx.rect(x, ry, w, L.rh, 1) end
    local cached = FS.exists(FS.file_of(e))
    local nw = w - 2 * L.pad - lenw - metaw
    U.text(x + L.pad, ry + 1, fit((FS.pending(e) and '~ ' or (cached and '+ ' or '  ')) .. e.name, nw), idx == S.cur and U.AMBER or U.TEXT)
    local ls = ('%.1fs'):format(e.len or 0)
    U.text(x + L.pad + nw + lenw - U.measure(ls .. '  '), ry + 1, ls, U.GREY)   -- вправо, с зазором до автора
    U.text(x + L.pad + nw + lenw, ry + 1, fit(e.user .. ' ' .. e.lic, metaw), e.lic == 'CC0' and U.GREEN or U.GREY)
    if hot and click then
      local now = A.R.time_precise()
      if S.cur == idx and now - S.lastclick < 0.35 then to_lib() else S.cur = idx; play_cur() end
      S.lastclick = now
    end
  end
  if inside and gfx.mouse_wheel ~= 0 then
    S.scroll = math.max(0, math.min(math.max(0, #FS.results - nv), S.scroll + (gfx.mouse_wheel > 0 and -3 or 3))); gfx.mouse_wheel = 0
  end
end

return M
