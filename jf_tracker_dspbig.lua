-- jf_tracker_dspbig.lua — DSP big (7 окт): цепочка FX трека / take на всё
-- окно, роутинг видно. Идея вида: ParaNormal FX Router (Sexan) — свой код.
--
-- Сигнал слева направо. Звенья цепочки идут столбцами (ряды): новый ряд,
-- когда у FX parallel = 0, первый — всегда serial; участники parallel-ряда
-- стоят столбиком в одном ряду, перед ними шина-разветвление, после —
-- шина-сумма. Контейнер — рамка с именем, дети внутри (вложенность любая),
-- свёрнутый (za) — один узел.
--
-- Клавиши: h l — по сигналу (l на контейнере — внутрь, h с первого ряда —
-- наружу), j k — по участникам ряда, Enter / o — окно FX, b — bypass,
-- s — solo в ряду (остальные участники bypass, повтор — все включены),
-- = — громкость веток к единице (wet = 1/n), | — FX в ряд к предыдущему /
-- из ряда, a — добавить после ряда, A — добавить в ряд (fzf), x / dd —
-- удалить, za — свернуть контейнер, g G — первый / последний, Esc / zz /
-- q — назад. Мышь: клик — выбор, двойной — окно, колесо — прокрутка.
--
-- Логика без reaper.*: дерево читается через fa (model.fxapi), правки —
-- через ops (main: edit.*). Тесты: tests/test_dspbig.lua.

local DB = {}
local U, ctx, ops

DB.sel = nil          -- GUID выбранного узла: адреса устаревают после любой правки
DB.fold = {}          -- [guid] = true — свёрнутый контейнер
DB.scroll = 0         -- горизонтальная прокрутка, px
DB.pend = nil         -- 'z' / 'd' — первая буква двухбуквенной команды

function DB.init(u, c, o) U, ctx, ops = u, c, o end

-- имя без префикса формата и производителя: «VST3: ReaEQ (Cockos)» → ReaEQ
function DB.short(name)
  name = (name or ''):gsub('^%w+i?:%s*', ''):gsub('%s*%b()%s*$', '')
  return name
end

-- ── модель ───────────────────────────────────────────────────────────────
-- дерево: root = { kids = { node… } }; node = { addr, guid, name, on, par,
-- wet, wet_i, kids (контейнер), parent, k (позиция в родителе) }.
-- Адрес ребёнка отдаёт сам REAPER (container_item.N) — формула не нужна
function DB.read(obj, fa)
  local function node(addr)
    local okr, rn = fa.GetNamedConfigParm(obj, addr, 'renamed_name')
    local name = (okr and rn ~= '') and rn or nil
    if not name then local _, nm = fa.GetFXName(obj, addr, ''); name = DB.short(nm) end
    local n = { addr = addr, name = name, guid = fa.GetFXGUID(obj, addr), on = fa.GetEnabled(obj, addr) }
    local okp, par = fa.GetNamedConfigParm(obj, addr, 'parallel')
    n.par = okp and tonumber(par) or 0
    -- 23 окт: полосы — сплиттер / джойнер REAPER (N-Band Splitter / Joiner) и полоса эффекта по его входному пину
    local _, raw = fa.GetFXName(obj, addr, '')
    n.split, n.join = DB.band_kind(raw)
    if n.split and fa.GetFormattedParamValue then
      n.xover = {}
      for i = 0, n.split - 2 do local _, t = fa.GetFormattedParamValue(obj, addr, i, ''); n.xover[#n.xover + 1] = t end
    end
    if fa.GetPinMappings then local lo = fa.GetPinMappings(obj, addr, 0, 0); n.pin_lo = tonumber(lo) end
    local wi = fa.GetParamFromIdent and fa.GetParamFromIdent(obj, addr, ':wet') or -1
    if wi and wi >= 0 then n.wet_i = wi; n.wet = fa.GetParamNormalized(obj, addr, wi) end
    local okc, cnt = fa.GetNamedConfigParm(obj, addr, 'container_count')
    if okc and tonumber(cnt) then
      n.kids = {}
      for k = 0, tonumber(cnt) - 1 do
        local ok2, a2 = fa.GetNamedConfigParm(obj, addr, 'container_item.' .. k)
        if ok2 and tonumber(a2) then
          local kid = node(tonumber(a2)); kid.parent = n; kid.k = k; kid.ki = k; n.kids[#n.kids + 1] = kid
        end
      end
      -- 23 окт: рэк drumrs5k — пэды банком (параллельный ряд): RS5K складывает свой звук, флаг parallel у простых
      -- пэдов 0, но по смыслу и звуку это параллель; в проекте флаги не меняются — только вид (vpar)
      if (name or ''):lower():find('^drumrs5k') then for i = 2, #n.kids do n.kids[i].vpar = true end end
    end
    return n
  end
  local root = { kids = {}, root = true }
  -- 18 окт: измерители jf_tracker_probe (gain staging) — не узлы: слот перед узлом — его вход (p_in),
  -- после прошлого — его выход (p_out). k — позиция в REAPER, ki — номер в списке kids (0..)
  local prev, pend
  for i = 0, fa.GetCount(obj) - 1 do
    local _, raw = fa.GetFXName(obj, i, '')
    if (raw or ''):find('jf_tracker_probe', 1, true) then
      local slot = math.floor((fa.GetParamNormalized(obj, i, 0) or 0) * 255 + 0.5)
      if prev then prev.p_out = slot end
      pend = slot
    else
      local n = node(i); n.parent = root; n.k = i; n.ki = #root.kids; n.p_in = pend; pend = nil
      root.kids[#root.kids + 1] = n; prev = n
    end
  end
  DB.bandize(root)
  return root
end

-- 23 окт: «3-Band Splitter» → 3, nil; «4-Band Joiner» → nil, 4 (JSFX REAPER loser/NBand*; имя — и переименованное)
function DB.band_kind(name)
  local s = (name or ''):lower()
  local n = tonumber(s:match('(%d)%-band splitter'))
  local j = tonumber(s:match('(%d)%-band joiner'))
  return n, j
end
-- полоса эффекта по маске входного пина 1 (бит k — канал k + 1): каналы 1/2 → 0, 3/4 → 1 …
function DB.band_of_mask(m)
  if not m or m <= 0 then return 0 end
  local b = 0
  while m & 1 == 0 and b < 31 do m = m >> 1; b = b + 1 end
  return b // 2
end
function DB.band_label(b, n, xs)
  xs = xs or {}
  local nm = n == 3 and ({ 'low', 'mid', 'high' })[b + 1] or (b == 0 and 'low' or (b == n - 1 and 'high' or ('mid ' .. b)))
  local r
  if b == 0 then r = xs[1] and ('< ' .. xs[1]) elseif b == n - 1 then r = xs[n - 1] and ('> ' .. xs[n - 1]) else r = xs[b] and xs[b + 1] and (xs[b] .. '-' .. xs[b + 1]) end
  return nm .. (r and ('  ' .. r) or '')
end
-- верхний уровень: [сплиттер N] … [джойнер N] → сплиттер, ряд из N полос-«контейнеров» (виртуальные: addr нет),
-- джойнер. Эффекты между ними — в полосу по своим пинам. Полоса знает свой сплиттер (s) и номер (band)
function DB.bandize(root)
  local kids, out, i = root.kids, {}, 1
  while i <= #kids do
    local s = kids[i]
    local jn
    if s.split then for j = i + 1, #kids do if kids[j].join == s.split then jn = j; break end end end
    if jn then
      out[#out + 1] = s
      local bands = {}
      for b = 0, s.split - 1 do
        bands[b] = { virtual = true, band = b, s = s, kids = {}, on = true, par = b == 0 and 0 or 1, name = DB.band_label(b, s.split, s.xover),
          guid = 'band:' .. tostring(s.guid) .. ':' .. b, parent = root, k = s.k }
      end
      for q = i + 1, jn - 1 do
        local f = kids[q]
        local b = math.min(s.split - 1, DB.band_of_mask(f.pin_lo))
        local bd = bands[b]
        f.parent, f.ki, f.bandof = bd, #bd.kids, bd
        bd.kids[#bd.kids + 1] = f
      end
      for b = 0, s.split - 1 do local bd = bands[b]; bd.ki = #out; out[#out + 1] = bd end
      out[#out + 1] = kids[jn]
      i = jn + 1
    else
      out[#out + 1] = s; i = i + 1
    end
  end
  for k, n in ipairs(out) do if not n.virtual then n.ki = k - 1 end end
  root.kids = out
end
-- куда вставить в полосу: после последнего её эффекта, иначе сразу за сплиттером (позиция REAPER верхнего уровня)
function DB.band_insert_pos(bd)
  local last = bd.kids[#bd.kids]
  return (last and last.k or bd.s.k) + 1
end

-- ряды: новый, когда parallel = 0; первый всегда serial
function DB.stages(list)
  local st = {}
  for i, n in ipairs(list) do
    if i == 1 or ((n.par or 0) == 0 and not n.vpar) then st[#st + 1] = { n } else table.insert(st[#st], n) end
    n.si, n.mi = #st, #st[#st]
  end
  return st
end

-- ── раскладка (чистая) ───────────────────────────────────────────────────
-- m = { nw, nh, gap, bus, pad, th }: узел, промежуток рядов, отступ шины,
-- поля рамки, строка заголовка рамки. Размеры снизу вверх, потом позиции
local function open(n) return n.kids and not DB.fold[n.guid] end
local size_chain
local function size_node(n, m)
  if m.dev and not n.kids then n.w, n.h = m.dev(n); return end   -- большой роутер: устройство со слайдерами
  if open(n) then
    local w, h = size_chain(n, m)
    n.w = math.max(m.nw, w + 2 * m.pad)
    n.h = h + m.th + 2 * m.pad
  else n.w, n.h = m.nw, m.nh end
end
size_chain = function(owner, m)
  owner.stages = DB.stages(owner.kids)
  local w, h = 0, 0
  for i, st in ipairs(owner.stages) do
    local sw, sh = 0, 0
    for j, n in ipairs(st) do
      size_node(n, m)
      sw = math.max(sw, n.w); sh = sh + n.h + (j > 1 and m.gap or 0)
    end
    if #st > 1 then sw = sw + 2 * m.bus end
    st.w, st.h = sw, sh
    w = w + sw + (i > 1 and m.gap or 0)
    h = math.max(h, sh)
  end
  if #owner.stages == 0 then w, h = m.nw, m.nh end   -- пустой контейнер / цепочка
  owner.cw, owner.ch = w, h
  return w, h
end
local function place_chain(owner, x, y, h, m)
  local cy = y + h / 2
  owner.cx0, owner.cx1, owner.cy = x, x + owner.cw, cy
  local sx = x
  for _, st in ipairs(owner.stages) do
    st.x, st.cy = sx, cy
    local my = cy - st.h / 2
    local inset = #st > 1 and m.bus or 0
    for _, n in ipairs(st) do
      n.x = sx + inset + math.floor((st.w - 2 * inset - n.w) / 2)
      n.y = math.floor(my)
      if open(n) then place_chain(n, n.x + m.pad, n.y + m.th + m.pad, n.h - m.th - 2 * m.pad, m) end
      my = my + n.h + m.gap
    end
    sx = sx + st.w + m.gap
  end
end
function DB.layout(root, m, x, y, h)
  local w, ch = size_chain(root, m)
  place_chain(root, x, y, math.max(ch, h or ch), m)
  return w, ch
end

-- все узлы по порядку обхода (родитель раньше детей)
function DB.walk(owner, out)
  out = out or {}
  for _, n in ipairs(owner.kids or {}) do
    out[#out + 1] = n
    if n.kids then DB.walk(n, out) end
  end
  return out
end
function DB.find(root, guid)
  for _, n in ipairs(DB.walk(root)) do if n.guid == guid then return n end end
end

-- ── навигация ────────────────────────────────────────────────────────────
-- root должен быть разложен (stages есть у раскрытых владельцев)
-- следующий ряд после n; конец цепочки контейнера — ряд за контейнером
local function after(n)
  local owner = n.parent
  local st = owner.stages or DB.stages(owner.kids)
  local nx = st[n.si + 1]
  if nx then return nx[math.min(n.mi, #nx)] end
  if owner.root then return nil end
  return after(owner)
end
function DB.move(root, n, dir)
  if not n then return (root.kids or {})[1] end
  local owner = n.parent
  local st = owner.stages or DB.stages(owner.kids)
  if dir == 'l' then
    if open(n) and n.kids[1] then return n.kids[1] end
    return after(n) or n
  elseif dir == 'h' then
    local pv = st[n.si - 1]
    if pv then return pv[math.min(n.mi, #pv)] end
    if not owner.root then return owner end
    return n
  elseif dir == 'j' then return st[n.si][n.mi + 1] or n
  elseif dir == 'k' then return st[n.si][n.mi - 1] or n end
  return n
end

-- ── клавиши ──────────────────────────────────────────────────────────────
-- true — съедена. root — дерево (разложенное), obj — трек / take
function DB.key(c, root, obj)
  local ch = c < 256 and string.char(c) or ''
  local n = DB.sel and DB.find(root, DB.sel)
  if not n and root.kids[1] then n = root.kids[1]; DB.sel = n.guid end
  local pend = DB.pend; DB.pend = nil
  if pend == 'z' then
    if ch == 'z' or ch == 'r' then ops.close() elseif ch == 'R' and ops.big then ops.big() elseif ch == 'a' and n and n.kids then DB.fold[n.guid] = not DB.fold[n.guid] or nil
    elseif ch == 'b' and n and ops.split then ops.split(n) end   -- 23 окт: zb — эффект в полосы (3 / 4 / 5 band)
    return true
  end
  if c == 27 or ch == 'q' then ops.close(); return true end
  if ch == 'z' then DB.pend = ch; return true end
  if ch == 'd' then if n then DB.delete(n, obj) end; return true end   -- 9 окт: d — удалить сразу (x — то же)
  local function go(m) if m then DB.sel = m.guid end end
  if ch == 'h' or ch == 'l' or ch == 'j' or ch == 'k' then go(DB.move(root, n, ch)); return true end
  if ch == 'g' then go(root.kids[1]); return true end
  if ch == 'G' then go(root.kids[#root.kids]); return true end
  if ch == 'a' then ops.add(n, false); return true end
  if ch == 'A' then if n then ops.add(n, true) end; return true end
  if not n then return ch ~= ':' end
  if n.virtual then ops.msg('band ' .. n.name .. ': a - add an effect into this band, l - inside, j k - other bands'); return true end   -- 23 окт: полоса — не эффект
  if c == 13 or ch == 'o' then ops.show(n.addr)
  elseif ch == 'b' then ops.bypass(n.addr)
  elseif ch == 'x' then DB.delete(n, obj)
  elseif ch == 's' then DB.solo(n)
  elseif ch == '=' then DB.unity(n)
  elseif ch == '|' then
    if (n.ki or n.k) == 0 then ops.msg('the first fx of a chain is always serial')
    else ops.parallel(n.addr, (n.par or 0) > 0 and 0 or 1) end
  else return false end
  return true
end

-- удалить: флаг parallel переходит к следующему звену, иначе оно
-- прилипнет к прошлому ряду (ловушка из разбора ParaNormal)
function DB.delete(n, obj)
  local nx = n.parent.kids[(n.ki or n.k) + 2]
  local after = DB.move_sel_after_delete(n)
  ops.remove(n.addr, ((n.par or 0) == 0 and nx and (nx.par or 0) > 0) and nx.addr or nil)
  DB.sel = after
end
function DB.move_sel_after_delete(n)
  local sib = n.parent.kids[(n.ki or n.k) + 2] or n.parent.kids[n.ki or n.k]
  if sib then return sib.guid end
  return not n.parent.root and n.parent.guid or nil
end
-- solo в ряду: остальные участники bypass; если они уже все выключены, а
-- этот включён — все включаются обратно
function DB.solo(n)
  local st = n.parent.stages and n.parent.stages[n.si]
  if not st or #st < 2 then ops.msg('solo: not in a parallel row'); return end
  local others_off = true
  for _, m in ipairs(st) do if m ~= n and m.on then others_off = false end end
  for _, m in ipairs(st) do
    local want = (others_off and n.on) and true or (m == n)
    if m.on ~= want then ops.enable(m.addr, want) end
  end
end
-- громкость веток к единице: wet = 1/n у всех участников ряда
function DB.unity(n)
  local st = n.parent.stages and n.parent.stages[n.si]
  if not st or #st < 2 then ops.msg('=: not in a parallel row'); return end
  for _, m in ipairs(st) do if m.wet_i then ops.param(m.addr, m.wet_i, 1 / #st) end end
  ops.msg(('branches: wet 1/%d each'):format(#st))
end

-- точка вставки для a / A: после ряда (serial) или после узла (parallel).
-- Возвращает родителя (nil — верх цепочки), позицию в нём и флаг parallel
function DB.insert_point(n, par)
  if not n then return nil, 0, 0 end
  local owner = n.parent
  local pos
  if par then pos = n.k + 1
  else
    local st = owner.stages and owner.stages[n.si]
    pos = (st and st[#st].k or n.k) + 1
  end
  return (not owner.root) and owner or nil, pos, par and 1 or 0
end

-- ── мышь ─────────────────────────────────────────────────────────────────
DB.last_click = { t = 0, guid = nil }
function DB.click(hv, now)
  local n = hv.dbnode
  if not n then return false end
  local dbl = DB.last_click.guid == n.guid and now - DB.last_click.t < 0.35
  DB.last_click = { t = now, guid = n.guid }
  DB.sel = n.guid
  -- 18 окт: Option+щелчок — удалить устройство (как d по нему; один undo)
  if gfx.mouse_cap & 16 == 16 then DB.delete(n); ops.msg('deleted: ' .. (n.name or '') .. ' (Opt+click; u - undo)'); return true end
  if gfx.mouse_cap & 8 == 8 then ops.bypass(n.addr); ops.msg('bypass: ' .. (n.name or '') .. ' (Shift+click)'); return true end   -- 18 окт: Shift+щелчок — байпас (как b)
  if dbl then ops.show(n.addr) end
  return true
end
function DB.wheel(d, w, total)
  DB.scroll = math.max(0, math.min(math.max(0, total - w), DB.scroll - d))
end

-- ── рисование ────────────────────────────────────────────────────────────
function DB.metrics(L)
  local cw = U.measure('m')
  return { nw = cw * 16, nh = 2 * L.rh + 2 * L.pad, gap = cw * 3, bus = cw * 2, pad = L.pad + 2, th = L.rh + L.pad }
end

-- glass (7 окт, опция routerglass): фон полупрозрачный — треки видны сквозь
-- роутер, узлы плотные
-- big (7 окт, zR): узлы — устройства: имя и слайдеры параметров (ctx.db_params,
-- значения — ctx.db_pval); протяжка по горизонтали, двойной клик — умолчание
DB.MAXP = 8
-- compact (7 окт): в панели DSP FX — без заголовка, узел в одну строку (имя),
-- кабели; прокрутка по горизонтали
-- 8 окт: прокрученная схема не вылезает за модуль — рисуется в буфер 89
-- в координатах окна (мышь и метки те же), на экран — только прямоугольник
-- модуля; метки f вне него не ставятся
function DB.draw(L, x, y, w, h, ...)
  if gfx.w <= 0 or gfx.h <= 0 then return DB.draw_in(L, x, y, w, h, ...) end
  if DB.buf_w ~= gfx.w or DB.buf_h ~= gfx.h then gfx.setimgdim(89, gfx.w, gfx.h); DB.buf_w, DB.buf_h = gfx.w, gfx.h end
  local dest0, hint0 = gfx.dest, ctx and ctx.hint
  gfx.dest = 89
  U.set(U.BG); gfx.rect(x, y, w, h, 1)
  if hint0 then
    ctx.hint = function(kind, hx, hy, hw, hh, data)
      if hx >= x and hx < x + w and hy >= y and hy < y + h then return hint0(kind, hx, hy, math.min(hw, x + w - hx), hh, data) end
    end
  end
  local ok, res = pcall(DB.draw_in, L, x, y, w, h, ...)
  gfx.dest = dest0
  if hint0 then ctx.hint = hint0 end
  if not ok then error(res, 0) end
  gfx.blit(89, 1, 0, x, y, w, h, x, y, w, h)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  if not (mx >= x and mx < x + w and my >= y and my < y + h) then return { dbig = false } end   -- узлы, уехавшие за край, мышь не ловят
  return res
end

function DB.draw_in(L, x, y, w, h, root, title, glass, big, compact)
  local hover = { dbig = true }
  local m = DB.metrics(L)
  DB.view_w = w
  if compact then
    local cw = U.measure('m')
    m.nw, m.nh, m.gap, m.bus, m.pad, m.th = cw * 14, L.rh + 4, cw * 5, cw, 3, L.rh   -- 11 окт: промежуток шире — в нём кнопка +
  end
  if big then
    local cw = U.measure('m')
    m.nw = cw * 26
    m.gap = cw * 4
    m.dev = function(n)
      n.params = n.params or (ctx.db_params and ctx.db_params(n.addr)) or {}
      local np = math.min(DB.MAXP, #n.params)
      return m.nw, (np + 1) * L.rh + 2 * L.pad + 4
    end
  end
  U.set(U.BG, glass and 0.72 or nil); gfx.rect(x, y, w, h, 1)
  U.set(U.BG)
  local top
  if compact then top = y + 2
  else
  -- шапка: что за цепочка; подсказки (9 окт) — в строке статуса (KH.BARS router / dspbig)
  -- 18 окт: кнопка gain — измерители уровня между эффектами (gain staging)
  local glab = 'gain'
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local gbw = U.measure(glab) + 2 * L.pad
  local gbx, gby = x + w - L.pad - gbw, y + L.pad
  local ghot = mx >= gbx and mx < gbx + gbw and my >= gby and my < gby + L.rh
  U.set(DB.meter and U.tint(U.CYAN, 0.25) or (ghot and U.tint(U.AMBER, 0.3) or U.BG)); gfx.rect(gbx, gby, gbw, L.rh, 1)
  U.set(DB.meter and U.CYAN or U.LINE); gfx.rect(gbx, gby, gbw, L.rh, 0)
  U.text(gbx + L.pad, gby + 1, glab, DB.meter and U.CYAN or (ghot and U.AMBER or U.TEXT))
  if ghot then hover.dbgain = true end
  U.text(x + L.pad, y + L.pad, ctx.fit((big and 'router big - ' or 'router - ') .. (title or ''), w - 3 * L.pad - gbw), U.AMBER)
  top = y + L.rh + 3 * L.pad
  end
  local bh = h - (top - y) - (compact and 2 or L.pad)
  local io = U.measure('in') + 4 * L.pad + U.measure('+') + 8   -- 11 окт: + перед первым узлом не налезает на «in»
  local cw, ch = DB.layout(root, m, 0, 0, bh)
  DB.total = cw + 2 * io + 4 * L.pad
  DB.scroll = math.max(0, math.min(math.max(0, DB.total - w), DB.scroll))
  local ox = x + L.pad + io - DB.scroll
  local oy = top   -- по вертикали центрует сама раскладка (высота bh)
  -- сдвиг всех координат: раскладка считалась от (0, 0)
  for _, n in ipairs(DB.walk(root)) do n.x, n.y = n.x + ox, n.y + oy end
  local function shift(owner)
    owner.cx0, owner.cx1, owner.cy = owner.cx0 + ox, owner.cx1 + ox, owner.cy + oy
    for _, st in ipairs(owner.stages or {}) do st.x, st.cy = st.x + ox, st.cy + oy end
    for _, n in ipairs(owner.kids) do if open(n) then shift(n) end end
  end
  shift(root)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  if not (DB.sel and DB.find(root, DB.sel)) and root.kids[1] then DB.sel = root.kids[1].guid end   -- выбор виден сразу
  local sel = DB.sel
  -- провода одной цепочки: вход → ряды → выход
  -- 11 окт: + на стыках цепочки (вставить эффект туда), = под узлом (эффект параллельно ему);
  -- только верхний уровень — внутрь вложенного контейнера вставка пока не умеет
  local joints = {}
  local function wires(owner, xin, xout)
    U.set(U.LINE)
    local px = xin
    local cy = math.floor(owner.cy)
    for si, st in ipairs(owner.stages) do
      if owner.root then
        local prev = si > 1 and owner.stages[si - 1] or nil
        joints[#joints + 1] = { x = (px + st.x) // 2, y = cy, after = prev and prev[#prev] or nil, first = si == 1 }
      end
      if #st == 1 then
        local n = st[1]
        gfx.line(px, cy, n.x, cy); px = n.x + n.w
      else
        local bx0, bx1 = st.x + m.bus // 2, st.x + st.w - m.bus // 2
        gfx.line(px, cy, bx0, cy)
        local c1, c2 = st[1].y + st[1].h // 2, st[#st].y + st[#st].h // 2
        gfx.line(bx0, c1, bx0, c2); gfx.line(bx1, c1, bx1, c2)
        for _, n in ipairs(st) do
          local ny = n.y + n.h // 2
          gfx.line(bx0, ny, n.x, ny); gfx.line(n.x + n.w, ny, bx1, ny)
        end
        px = bx1
      end
    end
    gfx.line(px, cy, xout, cy)
    if owner.root and #owner.stages > 0 then
      local last = owner.stages[#owner.stages]
      joints[#joints + 1] = { x = (px + xout) // 2, y = cy, after = last[#last] }
    end
  end
  local function box(n)
    local hot = mx >= n.x and mx < n.x + n.w and my >= n.y and my < n.y + n.h
    if hot then hover.dbnode = n end
    local is_sel = n.guid == sel
    local col = (not n.on) and U.GREY or U.TEXT
    if open(n) then
      U.set(is_sel and U.AMBER or U.LINE); gfx.rect(n.x, n.y, n.w, n.h, 0)
      U.set(U.BG); gfx.rect(n.x + L.pad, n.y - 1, U.measure(ctx.fit(n.name, n.w - 4 * L.pad)) + 2 * L.pad, L.rh, 1)
      U.text(n.x + 2 * L.pad, n.y + 1, ctx.fit(n.name, n.w - 4 * L.pad), is_sel and U.AMBER or col)
      local cin, cout = n.x, n.x + n.w
      if #n.kids == 0 then U.text(n.x + m.pad, n.y + m.th + m.pad, ctx.fit('empty - a adds inside', n.w - 2 * m.pad), U.GREY)
      else wires(n, cin, cout) end
      for _, k in ipairs(n.kids) do box(k) end
      return
    end
    U.set(hot and U.tint(U.AMBER, 0.2) or U.PANEL); gfx.rect(n.x, n.y, n.w, n.h, 1)
    U.set(is_sel and U.AMBER or U.LINE); gfx.rect(n.x, n.y, n.w, n.h, 0)
    if is_sel then gfx.rect(n.x - 1, n.y - 1, n.w + 2, n.h + 2, 0) end
    local nm = (n.kids and '[' .. #n.kids .. '] ' or '') .. n.name
    U.text(n.x + L.pad, n.y + (compact and 2 or L.pad), ctx.fit(nm, n.w - 2 * L.pad), is_sel and U.AMBER or col)
    if compact then
      if n.wet and n.wet < 0.999 then U.set(U.tint(U.AMBER, 0.6)); gfx.rect(n.x + 1, n.y + n.h - 2, math.floor((n.w - 2) * n.wet), 1, 1) end
      return
    end
    local info = {}
    if not n.on then info[#info + 1] = 'byp' end
    if n.wet and n.wet < 0.999 then info[#info + 1] = ('wet %d%%'):format(math.floor(n.wet * 100 + 0.5)) end
    if (n.par or 0) > 0 then info[#info + 1] = n.par == 2 and '= midi' or '=' end
    if #info > 0 then U.text(n.x + L.pad, n.y + L.pad + L.rh, ctx.fit(table.concat(info, '  '), n.w - 2 * L.pad), U.GREY) end
    -- полоса wet снизу узла (только если wet < 100 %)
    if n.wet and n.wet < 0.999 then U.set(U.tint(U.AMBER, 0.6)); gfx.rect(n.x + 1, n.y + n.h - 3, math.floor((n.w - 2) * n.wet), 2, 1) end
    if big and n.params then
      -- устройство: строка параметра — имя, слайдер, значение (тянется по горизонтали)
      local nw = U.measure('mmmmmmmm')
      local vw = U.measure('-00.0 dB')
      for i = 1, math.min(DB.MAXP, #n.params) do
        local p = n.params[i]
        local py = n.y + L.pad + i * L.rh + 2
        local sx, sw = n.x + L.pad + nw + L.pad, n.w - 4 * L.pad - nw - vw
        local v, txt = 0, ''
        if ctx.db_pval then v, txt = ctx.db_pval(p.fx or n.addr, p.i) end
        local hot = mx >= sx and mx < sx + sw and my >= py and my < py + L.rh
        local dragging = DB.pdrag and DB.pdrag.addr == (p.fx or n.addr) and DB.pdrag.i == p.i
        U.text(n.x + L.pad, py, ctx.fit(p.name or '', nw), (hot or dragging) and U.AMBER or U.GREY)
        U.set(U.DIM or U.LINE); gfx.rect(sx, py + math.floor(L.rh / 2) - 1, sw, 2, 1)
        U.set((hot or dragging) and U.AMBER or (n.on and U.CYAN or U.GREY)); gfx.rect(sx, py + 3, math.max(1, math.floor(sw * (v or 0))), L.rh - 6, 1)
        U.text(n.x + n.w - L.pad - vw, py, ctx.fit(txt or '', vw), U.TEXT)
        if hot then hover.dbparam = { addr = p.fx or n.addr, i = p.i, x = sx, w = sw, name = p.name }; hover.dbnode = n end
      end
    end
  end
  local empty_msg = 'no fx - a adds one'
  local xin, xout = x + L.pad - DB.scroll, ox + (#root.kids == 0 and (U.measure(empty_msg) + 2 * L.pad) or root.cw) + io - L.pad
  U.text(x + L.pad - DB.scroll, math.floor(root.cy) - L.rh // 2, 'in', U.GREY)
  U.text(xout + L.pad, math.floor(root.cy) - L.rh // 2, 'out', U.GREY)
  if #root.kids == 0 then
    U.text(ox, math.floor(root.cy) - L.rh // 2, empty_msg, U.GREY)
  else
    wires(root, xin + U.measure('in') + L.pad, xout)
    for _, n in ipairs(root.kids) do box(n) end
    -- кнопки-буквы: + на стыке, = под узлом верхнего уровня
    local function lbtn(cx, cy, lab, key, data, tip)
      local bw, bh = U.measure(lab) + 4, L.rh
      local bx, by = cx - bw // 2, cy - bh // 2
      if bx < x or bx + bw > x + w or by < y or by + bh > y + h then return end
      local hot = mx >= bx and mx < bx + bw and my >= by and my < by + bh
      U.set(hot and U.tint(U.AMBER, 0.35) or U.BG); gfx.rect(bx, by, bw, bh, 1)   -- 11 окт: без рамки, подложка — только под проводом / при наведении
      U.text(bx + 2, by, lab, hot and U.AMBER or U.GREY)
      if hot then hover[key] = data; hover.dbnode = nil; hover.dbtip = tip end
      if ctx.hint then ctx.hint(key, bx, by, bw, bh, data) end
    end
    -- 18 окт: gain staging — у ряда слева метр входа, справа выхода (измерители jf_tracker_probe), над рядом — разница dB
    if DB.meter then
      local function db(v) return v and v > 1e-7 and 20 * math.log(v, 10) or -150 end
      local function vmeter(mx0, y0, hh, slot)
        local l, r = DB.meter(slot)
        if not l then return nil end
        for c, v in ipairs({ l, r }) do
          local d = db(v)
          local f = math.max(0, math.min(1, (d + 60) / 66))
          local bx = mx0 + (c - 1) * 3
          U.set(U.mix(U.LINE, U.BG, 0.4)); gfx.rect(bx, y0, 2, hh, 1)
          local fh = math.floor(f * hh + 0.5)
          U.set(d > 0 and U.RED or (d > -6 and U.AMBER or U.GREEN)); gfx.rect(bx, y0 + hh - fh, 2, fh, 1)
        end
        return math.max(l, r)
      end
      for _, st in ipairs(root.stages or {}) do
        local n1, n2 = st[1], st[#st]
        local y0, y1, x1 = n1.y, n1.y, n1.x + n1.w
        for _, n in ipairs(st) do y1 = math.max(y1, n.y + n.h); x1 = math.max(x1, n.x + n.w) end
        local pin = n1.p_in and vmeter(n1.x - 8, y0, y1 - y0, n1.p_in)
        local pout = n2.p_out and vmeter(x1 + 3, y0, y1 - y0, n2.p_out)
        if pin and pout and pin > 1e-5 and pout > 1e-5 then
          local dd = db(pout) - db(pin)
          if math.abs(dd) >= 0.5 then
            local s = ('%+.1f'):format(dd)
            U.text(x1 - U.measure(s), y0 - L.rh, s, dd > 3 and U.AMBER or (dd < -3 and U.CYAN or U.GREY))
          end
        end
      end
    end
    for _, j in ipairs(joints) do
      lbtn(j.x, j.y, '+', 'dbplus', j, j.first and 'add an effect at the start of the chain' or ('add an effect after ' .. (j.after and j.after.name or '')))
    end
    for _, st in ipairs(root.stages or {}) do
      local n = st[#st]                          -- под нижним узлом ряда: ниже — ничего, не налезает
      if n and not open(n) then lbtn(n.x + n.w // 2, n.y + n.h + L.rh // 2 + 4, '=', 'dbpar', n, 'add an effect in parallel to ' .. (n.name or '') .. (#st > 1 and ' (joins this row)' or '')) end
    end
  end
  -- прокрутка: полоса снизу
  if DB.total > w then
    local bw = math.max(20, math.floor(w * w / DB.total))
    local bx = x + math.floor((w - bw) * DB.scroll / (DB.total - w))
    U.set(U.LINE); gfx.rect(bx, y + h - 3, bw, 3, 1)
  end
  return hover
end

return DB
