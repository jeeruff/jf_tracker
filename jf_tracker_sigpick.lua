-- jf_tracker_sigpick.lua — выпадашка размера такта (18 окт): вместо строки :sig N/D here.
--
-- Сверху крупно N/D (активная половина — янтарная), под ним таблица: строки — знаменатели 2 4 8 16,
-- колонки — числители 1..16; клик по клетке — размер сразу. Ниже — область: этот паттерн / весь проект.
-- Клавиши: цифры — набор активной половины, Tab или / — другая половина, h l — числитель −/+,
-- j k — знаменатель вниз / вверх по таблице, a — область, Enter — применить, Esc — закрыть.
-- Без reaper.* — тест tests/test_sigpick.lua; применение — ctx.sig_cmd (ставит main через SP.apply).

local SP = { on = false }
SP.DENS = { 2, 4, 8, 16 }
SP.NMAX = 16

-- rg_name — имя паттерна (nil — паттерна нет, только весь проект)
function SP.open(n, d, scope, rg_idx, rg_name, x, y)
  SP.on = true
  SP.n, SP.d = n or 4, d or 4
  SP.scope = (scope == 'here' and rg_idx) and 'here' or 'all'
  SP.rg, SP.rg_name = rg_idx, rg_name
  SP.field, SP.buf = 'n', ''
  SP.x, SP.y = x or 0, y or 0
  SP.hover = nil
end
function SP.close() SP.on = false; SP.hover = nil end

local function den_index(d) for i, v in ipairs(SP.DENS) do if v == d then return i end end end

-- набор цифр: числитель 1..64; знаменатель — когда набранное есть в таблице (1 → ждёт 16)
local function type_digit(ch)
  local s = SP.buf .. ch
  local v = tonumber(s)
  if SP.field == 'n' then
    if v and v > 64 then s, v = ch, tonumber(ch) end
    if v and v >= 1 then SP.n = v end
    SP.buf = #s >= 2 and '' or s
  else
    if v and den_index(v) then SP.d = v; SP.buf = (v == 1) and s or ''
    elseif v == 1 then SP.buf = s                              -- 1… — ждём 16
    else SP.buf = ''; v = tonumber(ch); if v and den_index(v) then SP.d = v end end
  end
end

-- клавиша → 'apply' | 'close' | true (съедена) ; c — код gfx.getchar
function SP.key(c)
  local ch = c > 0 and c < 256 and string.char(c) or ''
  if c == 27 then SP.close(); return 'close' end
  if c == 13 then return 'apply' end
  if ch:match('^%d$') then type_digit(ch); return true end
  if c == 9 or ch == '/' then SP.field = SP.field == 'n' and 'd' or 'n'; SP.buf = ''; return true end
  if c == 8 then                                               -- BS — последняя цифра активной половины (45 → 4)
    local v = SP.field == 'n' and SP.n or SP.d
    local rest = tostring(v):sub(1, -2)
    if rest ~= '' and SP.field == 'n' then SP.n = tonumber(rest) end
    SP.buf = rest
    return true
  end
  if ch == 'h' or c == 1818584692 then SP.n = math.max(1, SP.n - 1); SP.buf = ''; return true end
  if ch == 'l' or c == 1919379572 then SP.n = math.min(64, SP.n + 1); SP.buf = ''; return true end
  if ch == 'j' or ch == 'k' or c == 1685026670 or c == 30064 then
    local i = den_index(SP.d) or 2
    i = (ch == 'j' or c == 1685026670) and math.min(#SP.DENS, i + 1) or math.max(1, i - 1)
    SP.d = SP.DENS[i]; SP.buf = ''; return true
  end
  if ch == 'a' then if SP.rg then SP.scope = SP.scope == 'here' and 'all' or 'here' end; return true end
  return true                                                  -- открыта — остальное не утекает в трекер
end

-- то, что уйдёт в :sig
function SP.cmd() return ('%d/%d %s'):format(SP.n, SP.d, SP.scope) end

-- раскладка в пикселях: cw, rh — клетка шрифта, pad, bigk — множитель крупного шрифта
function SP.layout(cw, rh, pad, bigk, W, H)
  local lay = {}
  local cellw = 3 * cw
  local w = 2 * pad + 3 * cw + SP.NMAX * cellw
  local bigh = math.floor(rh * bigk)
  local h = pad + bigh + pad + #SP.DENS * rh + pad + rh + 2 + rh + pad
  local x = math.max(0, math.min(SP.x, (W or 1e9) - w))
  local y = SP.y
  if H and y + h > H then y = math.max(0, H - h) end
  lay.x, lay.y, lay.w, lay.h = x, y, w, h
  lay.big = { x = x + pad, y = y + pad, h = bigh }
  local ty = y + pad + bigh + pad
  lay.cells = {}
  for r, d in ipairs(SP.DENS) do
    for n = 1, SP.NMAX do
      lay.cells[#lay.cells + 1] = { n = n, d = d, x = x + pad + 3 * cw + (n - 1) * cellw, y = ty + (r - 1) * rh, w = cellw, h = rh }
    end
  end
  lay.rowlab = { x = x + pad, y = ty }
  local by = ty + #SP.DENS * rh + pad
  lay.scope_y = by
  lay.hint_y = by + rh + 2
  return lay
end

function SP.hit(lay, mx, my)
  for _, c in ipairs(lay.cells) do
    if mx >= c.x and mx < c.x + c.w and my >= c.y and my < c.y + c.h then return { cell = c } end
  end
  for _, b in ipairs(lay.scope or {}) do
    if mx >= b.x and mx < b.x + b.w and my >= b.y and my < b.y + b.h then return { scope = b.scope } end
  end
  if lay.bign and mx >= lay.bign.x and mx < lay.bign.x + lay.bign.w and my >= lay.big.y and my < lay.big.y + lay.big.h then return { field = 'n' } end
  if lay.bigd and mx >= lay.bigd.x and mx < lay.bigd.x + lay.bigd.w and my >= lay.big.y and my < lay.big.y + lay.big.h then return { field = 'd' } end
  if mx >= lay.x and mx < lay.x + lay.w and my >= lay.y and my < lay.y + lay.h then return { inside = true } end
  return nil
end

-- рисование: U — палитра и text/measure, D — big_text / big_measure; возвращает раскладку
function SP.draw(U, D, L, W, H)
  local bigk = 3
  local lay = SP.layout(L.cw, L.rh, L.pad, bigk, W, H)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  U.set(U.BG); gfx.rect(lay.x, lay.y, lay.w, lay.h, 1)
  U.set(U.TEXT); gfx.rect(lay.x, lay.y, lay.w, lay.h, 0)
  -- крупно N/D
  local ns, ds = tostring(SP.n), tostring(SP.d)
  local bx = lay.big.x
  local nw, sw = D.big_measure(ns, bigk), D.big_measure('/', bigk)
  local dw = D.big_measure(ds, bigk)
  lay.bign = { x = bx, w = nw }
  lay.bigd = { x = bx + nw + sw, w = dw }
  D.big_text(bx, lay.big.y, ns, SP.field == 'n' and U.AMBER or U.TEXT, bigk)
  D.big_text(bx + nw, lay.big.y, '/', U.GREY, bigk)
  D.big_text(bx + nw + sw, lay.big.y, ds, SP.field == 'd' and U.AMBER or U.TEXT, bigk)
  if SP.buf ~= '' then U.text(bx + nw + sw + dw + L.pad, lay.big.y + lay.big.h - L.rh, SP.buf .. '_', U.GREY) end
  -- таблица
  for r, d in ipairs(SP.DENS) do U.text(lay.rowlab.x, lay.rowlab.y + (r - 1) * L.rh, '/' .. d, d == SP.d and U.AMBER or U.GREY) end
  local hv = SP.hit(lay, mx, my)
  for _, c in ipairs(lay.cells) do
    local cur = c.n == SP.n and c.d == SP.d
    local hot = hv and hv.cell == c
    if cur then U.set(U.AMBER); gfx.rect(c.x, c.y, c.w - 1, c.h - 1, 1)
    elseif hot then U.set(U.tint(U.AMBER, 0.3)); gfx.rect(c.x, c.y, c.w - 1, c.h - 1, 1) end
    local s = tostring(c.n)
    local common = (c.d == 4 and c.n <= 7) or (c.d == 8 and (c.n == 5 or c.n == 6 or c.n == 7 or c.n == 9 or c.n == 12))
    U.text(c.x + math.floor((c.w - U.measure(s)) / 2), c.y, s, cur and U.BG or (common and U.TEXT or U.GREY))
  end
  -- область
  lay.scope = {}
  local sx = lay.x + L.pad
  local opts = { { 'here', SP.rg_name and ('this pattern ' .. SP.rg_name) or 'this pattern' }, { 'all', 'whole project' } }
  for _, o in ipairs(opts) do
    local lab = o[2]
    local bw = U.measure(lab) + 2 * L.pad
    local dis = o[1] == 'here' and not SP.rg
    local on = SP.scope == o[1]
    local hot = not dis and mx >= sx and mx < sx + bw and my >= lay.scope_y and my < lay.scope_y + L.rh
    U.set(on and U.tint(U.CYAN, 0.25) or (hot and U.tint(U.AMBER, 0.3) or U.BG)); gfx.rect(sx, lay.scope_y, bw, L.rh, 1)
    U.set(on and U.CYAN or U.LINE); gfx.rect(sx, lay.scope_y, bw, L.rh, 0)
    U.text(sx + L.pad, lay.scope_y, lab, dis and U.DIM or (on and U.CYAN or U.TEXT))
    if not dis then lay.scope[#lay.scope + 1] = { scope = o[1], x = sx, y = lay.scope_y, w = bw, h = L.rh } end
    sx = sx + bw + L.pad
  end
  U.text(lay.x + L.pad, lay.hint_y, 'digits  Tab /  h l  j k  a  Enter  Esc', U.DIM)
  SP.lay = lay
  SP.hover = SP.hit(lay, mx, my)
  return lay
end

return SP
