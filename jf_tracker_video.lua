-- jf_tracker_video.lua — вкладка video (9 окт).
--
-- Кадр видео ReaScript в gfx не получает — картинку показывает Video window
-- REAPER; здесь — управление вокруг него:
--   слева  — пульт видео трека курсора: window (Video window вкл / выкл),
--            Video processor на треке (добавить, пресеты < >, параметры
--            слайдерами: тянуть, колесо; у REAPER нет API значения по умолчанию);
--   справа — видео-item проекта: строка, трек, имя, длина; щелчок / Enter —
--            курсор трекера туда.
-- Клавиши (вкладка в фокусе): j k — список, Enter — туда, w — window,
-- p — добавить Video processor, < > — пресет, J K — параметр, H L — значение
-- (шаг 1/100), Esc — трекер.
--
-- VD.draw(L, U, x, y, w, h, focused, data, fit, hint) → hover
-- data = { win = bool, track = имя, items = { {name, tname, row, len, cur} },
--          vp = nil | { preset, npre, params = { {name, v, txt} } } }
-- VD.key(c, data) / VD.click(hv, dbl) → действие { kind = … } | true | nil
-- Без reaper.* — тест tests/test_video.lua.

local VD = { sel = 1, psel = 1, scroll = 0 }

local function btn(U, L, x, y, label, on, mx, my, ms)
  local w = ms(label) + 2 * L.pad
  local hot = mx >= x and mx < x + w and my >= y and my < y + L.rh
  U.set(on and U.tint(U.AMBER, 0.25) or (hot and U.mix(U.BG, U.TEXT, 0.16) or U.BG)); gfx.rect(x, y, w, L.rh, 1)
  U.set(on and U.AMBER or U.LINE); gfx.rect(x, y, w, L.rh, 0)
  U.text(x + L.pad, y, label, on and U.AMBER or (hot and U.TEXT or U.GREY))
  return w, hot
end

function VD.draw(L, U, x, y, w, h, focused, data, fit, hint)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local ms = U.measure
  local hover
  data = data or {}
  -- пульт слева: ширина по самым длинным подписям, остальное — списку
  local lw = math.min(math.floor(w * 0.45), ms('W') * 40)
  local bx, by = x + L.pad, y
  local right = x + lw - L.pad
  -- 9 окт: не влезло в колонку пульта — на следующую строку (без наложений)
  local function room(wd) if bx + wd > right and bx > x + L.pad then bx, by = x + L.pad, by + L.rh + 2 end end
  local function b(label, on, kind, tip)
    room(ms(label) + 2 * L.pad)
    local bw, hot = btn(U, L, bx, by, label, on, mx, my, ms)
    if hot then hover = { kind = kind, tip = tip } end
    if hint then hint('video', bx, by, bw, L.rh, kind) end
    bx = bx + bw + L.pad
  end
  local tl = fit('video ' .. (data.track or ''), math.min(ms('W') * 14, right - bx))
  U.text(bx, by, tl, U.GREY); bx = bx + ms(tl) + 2 * L.pad
  b('window', data.win, 'win', 'Video window of REAPER - show / hide (w)')
  local vp = data.vp
  if not vp then
    b('+ processor', false, 'addvp', 'add Video processor to the cursor track (p) - fades, text, chroma key … as presets')
  else
    b('<', false, 'prev', 'previous preset (<)')
    local pn0 = vp.preset ~= '' and vp.preset or 'no preset'
    room(math.min(ms(pn0), ms('WWWWWW')) + ms('>') + 3 * L.pad)
    local pn = fit(pn0, math.max(ms('WWW'), right - bx - ms('>') - 3 * L.pad))
    U.text(bx, by, pn, U.TEXT); bx = bx + ms(pn) + L.pad
    b('>', false, 'next', 'next preset (>)')
  end
  -- параметры процессора: имя | дорожка | значение
  local py = by + L.rh + 4
  if vp then
    local nw = 0
    for _, p in ipairs(vp.params) do nw = math.max(nw, ms(p.name)) end
    nw = math.min(nw, math.floor(lw * 0.4))
    local vw = ms('-00.00')
    for i, p in ipairs(vp.params) do
      local ry = py + (i - 1) * L.rh
      if ry + L.rh > y + h then break end
      local tx0, tw = x + L.pad + nw + L.pad, lw - nw - vw - 4 * L.pad
      local hot = mx >= x and mx < x + lw and my >= ry and my < ry + L.rh
      local sel = focused and i == VD.psel
      if sel then U.set(U.mix(U.BG, U.TEXT, 0.12)); gfx.rect(x + 1, ry, lw - 2, L.rh, 1) end
      U.text(x + L.pad, ry, fit(p.name, nw), (hot or sel) and U.AMBER or U.GREY)
      U.set(U.DIM); gfx.rect(tx0, ry + math.floor(L.rh / 2) - 1, tw, 2, 1)
      U.set(hot and U.AMBER or U.TEXT); gfx.rect(tx0, ry + 4, math.max(1, math.floor(math.max(0, math.min(1, p.v)) * tw + 0.5)), L.rh - 8, 1)
      U.text(tx0 + tw + L.pad, ry, fit(p.txt or '', vw + L.pad), U.GREY)
      if hot then hover = { kind = 'param', i = i, x0 = tx0, w = tw, v = math.max(0, math.min(1, (mx - tx0) / math.max(1, tw))),
                            tip = p.name .. ' - drag / wheel (Shift fine); J K select, H L change' } end
    end
  else
    U.text(x + L.pad, py, fit('no Video processor on this track', lw - 2 * L.pad), U.GREY)
  end
  -- список видео справа
  local lx = x + lw + 2 * L.pad
  U.set(U.LINE); gfx.rect(lx - L.pad - 1, y, 1, h, 1)
  local list = data.items or {}
  U.text(lx, y, fit(('video items %d'):format(#list), x + w - lx), U.GREY)
  local rw, tw2 = ms('0000'), ms('WWWWWWWW')
  local nvis = math.max(1, math.floor((h - L.rh - 2) / L.rh))
  VD.sel = math.max(1, math.min(#list, VD.sel))
  if VD.sel > VD.scroll + nvis then VD.scroll = VD.sel - nvis end
  if VD.sel <= VD.scroll then VD.scroll = math.max(0, VD.sel - 1) end
  if #list == 0 then U.text(lx, y + L.rh + 2, fit('no video in the project - drop a video file from the browser onto a track', x + w - lx), U.GREY) end
  for k = 1, nvis do
    local i = VD.scroll + k
    local e = list[i]
    if not e then break end
    local ry = y + L.rh + 2 + (k - 1) * L.rh
    local hot = mx >= lx and mx < x + w and my >= ry and my < ry + L.rh
    if (focused and i == VD.sel) or e.cur then U.set(e.cur and U.tint(U.AMBER, 0.25) or U.mix(U.BG, U.TEXT, 0.12)); gfx.rect(lx - 2, ry, x + w - lx, L.rh, 1) end
    U.text(lx, ry, ('%04d'):format(e.row or 0), U.GREY)
    U.text(lx + rw + L.pad, ry, fit(e.tname or '', tw2), U.CYAN)
    local len = ('%.1fs'):format(e.len or 0)
    local nx = lx + rw + tw2 + 2 * L.pad
    U.text(nx, ry, fit(e.name or '', x + w - nx - ms(len) - 2 * L.pad), hot and U.AMBER or U.TEXT)
    U.text(x + w - L.pad - ms(len), ry, len, U.GREY)
    if hot then hover = { kind = 'item', i = i, tip = 'click / Enter: tracker cursor to this video' } end
  end
  return hover
end

-- клавиши: действие для main или true (съели) / nil (не наше)
function VD.key(c, data)
  data = data or {}
  local n = #(data.items or {})
  local np = data.vp and #data.vp.params or 0
  local ch = c > 0 and c < 256 and string.char(c) or ''
  if c == 27 then return { kind = 'leave' }
  elseif ch == 'j' then VD.sel = math.min(math.max(1, n), VD.sel + 1); return true
  elseif ch == 'k' then VD.sel = math.max(1, VD.sel - 1); return true
  elseif c == 13 then if n > 0 then return { kind = 'item', i = VD.sel } end; return true
  elseif ch == 'w' then return { kind = 'win' }
  elseif ch == 'p' then return data.vp and true or { kind = 'addvp' }
  elseif ch == '<' or ch == ',' then return { kind = 'prev' }
  elseif ch == '>' or ch == '.' then return { kind = 'next' }
  elseif ch == 'J' then VD.psel = math.min(math.max(1, np), VD.psel + 1); return true
  elseif ch == 'K' then VD.psel = math.max(1, VD.psel - 1); return true
  elseif ch == 'H' or ch == 'L' then
    local p = data.vp and data.vp.params[VD.psel]
    if p then return { kind = 'param', i = VD.psel, v = math.max(0, math.min(1, p.v + (ch == 'L' and 0.01 or -0.01))) } end
    return true
  end
  return nil
end

-- щелчок по hover: действие
function VD.click(hv, dbl)
  if not hv then return nil end
  if hv.kind == 'item' then VD.sel = hv.i; return { kind = 'item', i = hv.i } end
  if hv.kind == 'param' then VD.psel = hv.i; return { kind = 'param', i = hv.i, v = hv.v } end
  return { kind = hv.kind }
end

return VD
