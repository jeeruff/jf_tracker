-- jf_tracker_looploom.lua — looploom (13 окт): модуль лупа удержания инструмента.
-- Вкладка рядом с properties и note mod. Слева — спектрограмма инструмента с лупом
-- (начало — зелёная линия, конец — янтарная, кроссфейд — полосы перед ними) и
-- кандидатами: спектрально похожие пары точек скобками внизу (ярче — шов совпадает лучше);
-- под ней — шов крупно: что луп играет до конца (слева) и с начала (справа), тусклым —
-- как файл шёл бы дальше (видно, совпала ли фаза). Справа — параметры (те же ключи, что
-- в properties: ctx.sp_adjust / sp_set_frac / sp_menu / sp_reset).
-- Мышь — сам модуль (щелчок, протяжка, колесо), клавиши — LL.key. Без reaper.* в логике
-- рисования: всё через ctx.
local LL = { sel = 1, seam_ms = 20, prev_cap = 0, cands = nil, cands_key = nil, status = nil }
local U, ctx

LL.ROWS = {
  { k = 'loopm', label = 'loop' }, { k = 'susa', label = 'start' }, { k = 'susb', label = 'end' },
  { k = 'susx', label = 'x-fade' }, { k = 'susc', label = 'curve' }, { k = 'susl', label = 'level' },
  { k = 'susr', label = 'find' },
}
local MENU = { loopm = true, susc = true }
local ACT = { susl = true, susr = true }
local TIP = {
  loopm = 'loop mode: off / whole sample / sustain - Enter or click: the list',
  susa = 'loop start - h l, drag the green line or the slider; R finds the points again',
  susb = 'loop end - h l, drag the amber line or the slider; the bake moves it up to 20 ms to the best phase',
  susx = 'crossfade at the seam (up to 2 s): the end of the loop fades into what was before the start',
  susc = 'crossfade curve: auto / linear / equal power / s-curve - Enter: the list',
  susl = 'level: flat - the decay inside the loop is evened out to the level at the start; natural - as in the file',
  susr = 'find the points again (spectrum + seam phase); n N - next / previous candidate',
}

function LL.init(u, c) U, ctx = u, c end

-- волна файла (кэш по ключу): { sr, ch, n }
local waves = {}
local function wave(path, key, upto)
  local k = path .. '|' .. (key or '')
  if waves[k] == nil then
    for kk in pairs(waves) do if kk:sub(1, #path + 1) == path .. '|' then waves[kk] = nil end end
    waves[k] = ctx.SU().wav_read(path, upto) or false
  end
  return waves[k] or nil
end

-- кандидаты лупа для инструмента (раз на инструмент / его кусок файла)
local function cands(e)
  local a, b = ctx.sus_span(e)
  local key = tostring(e.item) .. ('%.4f %.4f'):format(a, b)
  if LL.cands_key ~= key then
    LL.cands_key = key
    local f = ctx.sus_find(e)
    LL.cands = f and f.cands or {}
  end
  return LL.cands
end

local function apply(e, c)
  local lp = ctx.sus_get(e)
  if not (lp and lp.on) then return end
  lp.ls, lp.le = c.ls, c.le
  lp.file, lp.boff = nil, nil
  ctx.sus_points(e, lp)
  ctx.msg(('looploom: candidate %.3f - %.3f s, the seam matches %d %%'):format(c.ls, c.le, math.floor(c.match * 100 + 0.5)))
end

local function seam(e, lp, x, y, w, h, ps_path)
  U.set(U.BG); gfx.rect(x, y, w, h, 1)
  local mid = x + math.floor(w / 2)
  U.set(U.LINE); gfx.rect(mid, y, 1, h, 1)
  local a, b = ctx.sus_span(e)
  local wv, i_end, i_start, ghost
  if lp.file and lp.boff and ctx.file_exists(lp.file) then
    wv = wave(lp.file, ctx.SU().tag(lp), math.huge)
    if wv then i_start = math.floor(lp.boff * wv.sr + 0.5); i_end = wv.n end
  end
  local src = ps_path and wave(ps_path, 'src', math.ceil((b + 0.1) * 192000))
  if not wv then
    wv = src
    if wv then i_start = math.floor(lp.ls * wv.sr + 0.5); i_end = math.floor(lp.le * wv.sr + 0.5) end
  end
  if not wv then U.text(x + 4, y, ctx.fit('looploom: the seam view reads WAV files', w - 8), U.GREY); return end
  local N = math.max(8, math.floor(LL.seam_ms / 1000 * wv.sr))
  local c1 = wv.ch[1]
  local hw = mid - x
  local pk = 1e-6
  for k = i_end - N, i_end - 1 do pk = math.max(pk, math.abs(c1[k + 1] or 0)) end
  for k = i_start, i_start + N - 1 do pk = math.max(pk, math.abs(c1[k + 1] or 0)) end
  local cy, sc = y + h / 2, (h / 2 - 2) / pk
  local function bars(ch, i0, px0, col, al)
    U.set(col, al)
    for p = 0, hw - 1 do
      local k0 = i0 + math.floor(p * N / hw)
      local k1 = math.max(k0, i0 + math.floor((p + 1) * N / hw) - 1)
      local lo, hi = 1, -1
      for k = k0, k1 do local v = ch[k + 1] or 0; if v < lo then lo = v end; if v > hi then hi = v end end
      if hi >= lo then gfx.rect(px0 + p, math.floor(cy - hi * sc), 1, math.max(1, math.floor((hi - lo) * sc)), 1) end
    end
  end
  -- тусклым: как файл шёл бы после конца лупа (по исходнику) — сравнить фазу со звучащим началом
  if src then local ge = math.floor(lp.le * src.sr + 0.5); bars(src.ch[1], ge, mid + 1, U.GREY, 0.45) end
  bars(c1, i_end - N, x, U.AMBER, 1)
  bars(c1, i_start, mid + 1, U.GREEN, 1)
  local lab = ('end | start  %d ms  + -'):format(LL.seam_ms)
  U.text(x + 2, y, ctx.fit(lab, w - 4), U.DIM)
end

function LL.draw(L, x, y, w, h, e, focused)
  LL.status = nil
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local cap = gfx.mouse_cap & 1
  local down, inside = cap == 1 and LL.prev_cap == 0, mx >= x and mx < x + w and my >= y and my < y + h
  LL.prev_cap = cap
  U.set(U.PANEL); gfx.rect(x, y, w, h, 1)
  if not (e and e.item) then U.text(x + L.pad, y, ctx.fit('looploom: select an instrument', w - L.pad), U.GREY); return end
  local lp = ctx.sus_get(e)
  local mode = ctx.loop_mode(e)
  -- справа — параметры; слева — спектрограмма и шов
  local rw = math.min(math.max(L.cw * 30, math.floor(w * 0.36)), w)
  if w - rw < L.cw * 20 then rw = w end
  local rx = x + w - rw
  local hot_row
  local lw = U.measure('x-fade ') + 2 * L.pad
  for i, r in ipairs(LL.ROWS) do
    local ry = y + (i - 1) * L.rh
    if ry + L.rh > y + h then break end
    local hot = inside and mx >= rx and my >= ry and my < ry + L.rh
    if hot then hot_row = i end
    local sel = focused and i == LL.sel
    if hot or sel then U.set(U.tint(U.AMBER, hot and 0.2 or 0.12)); gfx.rect(rx, ry, rw, L.rh, 1) end
    if sel then U.set(ctx.FOCUS() or U.CYAN); gfx.rect(rx, ry, 2, L.rh, 1) end
    local off = mode ~= 'sus' and r.k ~= 'loopm'
    U.text(rx + L.pad, ry, r.label, off and U.DIM or (sel and U.AMBER or U.TEXT))
    local v = off and '-' or (ctx.sp_raw(e, r.k) or '')
    local fr = (not off) and ctx.sp_frac(e, r.k)
    local bw = fr and math.max(0, math.floor((rw - lw) * 0.4)) or 0
    local vx = rx + lw
    U.text(vx, ry, ctx.fit(v, rw - lw - bw - L.pad), MENU[r.k] and U.CYAN or U.TEXT)
    if fr then
      local bx = rx + rw - bw - L.pad
      U.set(U.LINE); gfx.rect(bx, ry + math.floor(L.rh / 2), bw, 1, 1)
      U.set(hot and U.AMBER or U.CYAN); gfx.rect(bx, ry + 3, math.max(1, math.floor(bw * math.max(0, math.min(1, fr)))), L.rh - 6, 1)
      r.bar = { x = bx, w = bw }
    else r.bar = nil end
  end
  if hot_row then LL.status = 'looploom ' .. LL.ROWS[hot_row].label .. ': ' .. (TIP[LL.ROWS[hot_row].k] or '') end
  -- виды
  local vw = rw < w and (rx - x - L.pad) or 0
  local a, b = ctx.sus_span(e)
  local span = math.max(1e-6, b - a)
  local function X(t) return x + math.floor((t - a) / span * vw) end
  local hov_line, hov_cand
  local vy, vh = y, 0
  if vw > L.cw * 10 then
    vh = math.floor(h * 0.6)
    local job = ctx.sgram(e)
    U.set(U.BG); gfx.rect(x, vy, vw, vh, 1)
    if job then gfx.blit(job.img, 1, 0, 0, 0, job.cols, job.rows, x, vy, vw, vh) end
    if mode == 'sus' and lp then
      local xs, xe = X(lp.ls), X(lp.le)
      U.set(U.AMBER, 0.12); gfx.rect(xs, vy, math.max(1, xe - xs), vh, 1)
      local fx = math.floor((lp.xf or 0) / span * vw)
      U.set(U.AMBER, 0.35); gfx.rect(xe - fx, vy, fx, 4, 1)            -- кроссфейд: конец лупа уходит …
      U.set(U.CYAN, 0.35); gfx.rect(xs - fx, vy, fx, 4, 1)             -- … в то, что было перед началом
      local near_s = inside and math.abs(mx - xs) <= 4 and my >= vy and my < vy + vh
      local near_e = inside and math.abs(mx - xe) <= 4 and my >= vy and my < vy + vh and not near_s
      U.set(near_s and U.TEXT or U.GREEN); gfx.rect(xs, vy, near_s and 2 or 1, vh, 1)
      U.set(near_e and U.TEXT or U.AMBER); gfx.rect(xe, vy, near_e and 2 or 1, vh, 1)
      if near_s then hov_line = 'susa' elseif near_e then hov_line = 'susb' end
      -- кандидаты: скобки снизу, по строке на кандидата (не больше, чем влезает)
      local cs = cands(e)
      local rows = math.min(#cs, math.max(0, math.floor((vh - 8) / 5)))
      for i = 1, rows do
        local c = cs[i]
        local cy = vy + vh - 3 - (i - 1) * 5
        local c0, c1 = X(c.ls), X(c.le)
        local hot = inside and not hov_line and my >= cy - 2 and my <= cy + 2 and mx >= c0 and mx <= c1
        local col = U.mix(U.GREY, U.GREEN, math.max(0, math.min(1, (c.match - 0.5) * 2)))
        U.set(hot and U.TEXT or col, hot and 1 or 0.85)
        gfx.rect(c0, cy, math.max(1, c1 - c0), 1, 1); gfx.rect(c0, cy - 2, 1, 3, 1); gfx.rect(c1, cy - 2, 1, 3, 1)
        if hot then hov_cand = c; LL.status = ('looploom candidate %d: %.3f - %.3f s, the seam matches %d %% - click: take it'):format(i, c.ls, c.le, math.floor(c.match * 100 + 0.5)) end
      end
      if hov_line then LL.status = 'looploom: drag the loop ' .. (hov_line == 'susa' and 'start' or 'end') end
    elseif mode ~= 'sus' then
      U.text(x + L.pad, vy, ctx.fit('loop: ' .. mode .. ' - set loop = sustain to weave a loop', vw - 2 * L.pad), U.GREY)
    end
    -- шов
    local sy = vy + vh + 2
    if mode == 'sus' and lp and y + h - sy >= 2 * L.rh then
      local _, _, ps = ctx.sus_span(e)
      seam(e, lp, x, sy, vw, y + h - sy, ps and ctx.src_path(ps))
      if inside and mx < x + vw and my >= sy then LL.status = ('looploom seam: left - the loop end, right - its start (amber / green), grey - how the file went on; wheel: %d ms'):format(LL.seam_ms) end
    end
  end
  -- мышь
  if LL.drag then
    if cap == 1 then
      if mx ~= LL.drag.lx then LL.drag.lx = mx; ctx.sp_set_frac(e, LL.drag.k, (mx - LL.drag.x) / math.max(1, LL.drag.w)) end
    else LL.drag = nil end
  elseif down and inside then
    ctx.set_focus('looploom')
    if hot_row then
      local r = LL.ROWS[hot_row]
      local now = reaper.time_precise()
      local dbl = LL.click and LL.click.k == r.k and now - LL.click.t < 0.35
      LL.click = { k = r.k, t = now }
      LL.sel = hot_row
      if dbl then ctx.sp_reset(e, r.k)
      elseif r.bar and mx >= r.bar.x then LL.drag = { k = r.k, x = r.bar.x, w = r.bar.w, lx = mx }; ctx.sp_set_frac(e, r.k, (mx - r.bar.x) / math.max(1, r.bar.w))
      elseif MENU[r.k] then ctx.sp_menu(e, r.k)
      elseif ACT[r.k] then ctx.sp_adjust(e, r.k, 1) end
    elseif hov_line then LL.drag = { k = hov_line, x = x, w = vw, lx = mx }
    elseif hov_cand then apply(e, hov_cand) end
  end
  if inside and gfx.mouse_wheel ~= 0 then
    local d = gfx.mouse_wheel > 0 and 1 or -1
    if hot_row then ctx.sp_adjust(e, LL.ROWS[hot_row].k, d)
    elseif my > vy + vh then LL.seam_ms = math.max(2, math.min(500, math.floor(LL.seam_ms * (d > 0 and 0.8 or 1.25) + 0.5))) end
    gfx.mouse_wheel = 0
  end
end

-- клавиши: j k строка, h l значение, Enter — список / действие, R сброс, n N — кандидаты, + - шов
function LL.key(c, e)
  local ch = c < 256 and string.char(c) or ''
  local r = LL.ROWS[LL.sel]
  if ch == 'j' then LL.sel = math.min(#LL.ROWS, LL.sel + 1)
  elseif ch == 'k' then LL.sel = math.max(1, LL.sel - 1)
  elseif ch == 'g' then LL.sel = 1
  elseif ch == 'G' then LL.sel = #LL.ROWS
  elseif ch == 'h' or ch == 'H' then if e then ctx.sp_adjust(e, r.k, -1) end
  elseif ch == 'l' or ch == 'L' then if e then ctx.sp_adjust(e, r.k, 1) end
  elseif c == 13 then if e then if MENU[r.k] then ctx.sp_menu(e, r.k) else ctx.sp_adjust(e, r.k, 1) end end
  elseif ch == 'R' then if e then ctx.sp_reset(e, r.k) end
  elseif ch == 'n' or ch == 'N' then
    if not e then return true end
    local cs = cands(e)
    if #cs == 0 then ctx.msg('looploom: no candidates'); return true end
    LL.ci = ((LL.ci or 0) + (ch == 'n' and 1 or -1) - 1) % #cs + 1
    apply(e, cs[LL.ci])
  elseif ch == '+' or ch == '=' then LL.seam_ms = math.max(2, math.floor(LL.seam_ms * 0.8 + 0.5))
  elseif ch == '-' then LL.seam_ms = math.min(500, math.floor(LL.seam_ms * 1.25 + 0.5))
  else return false end
  return true
end

return LL
