-- jf_tracker_inputs.lua (11 ноя) — панель inputs: входы всех треков матрицей. Строки — входы, колонки — треки (13 ноя)
-- (none, MIDI все / каждое устройство, аудио моно и стерео). У трека REAPER один вход: клетка горит у текущего.
-- Щелчок / Enter — этот вход треку; a — этот вход всем трекам; x — у всех, кроме трека курсора, вход убрать
-- (none); h j k l — курсор; Esc — в трекер. Без reaper.* в отрисовке: данные — IN.rows / IN.cols от main.
local IN = { r = 1, c = 1 }

-- колонки: { label, v (I_RECINPUT), kind }
function IN.columns(R)
  local cols = { { label = 'none', v = -1, kind = 'none' } }
  cols[#cols + 1] = { label = 'MIDI all', v = 4096 + (63 << 5), kind = 'midi' }
  for d = 0, R.GetNumMIDIInputs() - 1 do
    local ok, nm = R.GetMIDIInputName(d, '')
    if ok and nm ~= '' then cols[#cols + 1] = { label = nm, v = 4096 + (d << 5), kind = 'midi' } end
  end
  local n = R.GetNumAudioInputs()
  for i = 0, n - 2, 2 do cols[#cols + 1] = { label = ('%d/%d'):format(i + 1, i + 2), v = 1024 + i, kind = 'audio' } end
  for i = 0, n - 1 do cols[#cols + 1] = { label = tostring(i + 1), v = i, kind = 'audio' } end
  return cols
end

-- вход трека → колонка (MIDI: канал не важен — устройство; аудио — точное значение)
local function col_of(cols, v)
  for k, c in ipairs(cols) do
    if c.v == v then return k end
    if c.kind == 'midi' and v >= 4096 and ((v - 4096) >> 5) == ((c.v - 4096) >> 5) then return k end
  end
end

-- rows (треки): { { name, v, rgb, tr } }; cols (входы). 13 ноя: таблица повёрнута — строки = входы, колонки = треки
-- (как в трекере); xs[i] = { x, w } — колонка трека i в трекере: панель под трекером (стек с DSP / mixer) — те же
-- x и ширины, иначе поровну. → hover { r = трек, c = вход } | { all = вход } (подпись входа — этот вход всем трекам)
function IN.draw(U, L, rows, cols, x, y, w, h, focused, mx, my, fit, xs)
  local hv
  U.set(U.PANEL); gfx.rect(x, y, w, h, 1)
  if #rows == 0 then U.text(x + L.pad, y + 2, 'no tracks', U.DIM); return end
  IN.r = math.max(1, math.min(#rows, IN.r)); IN.c = math.max(1, math.min(#cols, IN.c))
  -- подписи входов — колонка слева (по самой длинной, не шире 14 знаков / трети панели)
  local nw = L.cw * 4
  for _, c in ipairs(cols) do nw = math.max(nw, math.min(L.cw * 14, U.measure(c.label) + 2 * L.pad)) end
  nw = math.min(nw, math.floor(w * 0.35))
  -- колонки треков: по трекеру, если он над / под панелью и колонки видны в её ширине; иначе поровну
  local tx = {}
  local aligned = false
  if xs then
    for i = 1, #rows do local g = xs[i]; if g and g.x >= x + nw and g.x + g.w <= x + w + 1 then tx[i] = g; aligned = true end end
  end
  if not aligned then
    local tw = math.max(L.cw * 4, math.floor((w - nw) / math.max(1, #rows)))
    local fitn = math.max(1, math.floor((w - nw) / tw))
    IN.r0 = IN.r0 or 1
    if IN.r < IN.r0 then IN.r0 = IN.r elseif IN.r >= IN.r0 + fitn then IN.r0 = IN.r - fitn + 1 end
    for i = IN.r0, math.min(#rows, IN.r0 + fitn - 1) do tx[i] = { x = x + nw + (i - IN.r0) * tw, w = tw } end
  end
  local hy = y + 2
  -- шапка: имена треков (цвет трека — полоска)
  U.text(x + L.pad, hy, fit('input \\ track', nw - L.pad), U.GREY)
  for i, g in pairs(tx) do
    local row = rows[i]
    if row.rgb then U.set(row.rgb); gfx.rect(g.x + 1, hy + L.rh - 2, g.w - 2, 2, 1) end
    U.text(g.x + L.pad, hy, fit(row.name, g.w - 2 * L.pad), i == IN.r and focused and U.AMBER or U.TEXT)
  end
  local ry0 = hy + L.rh + 2
  local nvis = math.max(1, math.floor((y + h - ry0) / L.rh))
  IN.c0 = IN.c0 or 1
  if IN.c < IN.c0 then IN.c0 = IN.c elseif IN.c >= IN.c0 + nvis then IN.c0 = IN.c - nvis + 1 end
  for k = IN.c0, math.min(#cols, IN.c0 + nvis - 1) do
    local c = cols[k]
    local ry = ry0 + (k - IN.c0) * L.rh
    local kcol = c.kind == 'midi' and U.CYAN or (c.kind == 'audio' and U.GREEN or U.GREY)
    local lhot = mx >= x and mx < x + nw and my >= ry and my < ry + L.rh
    U.text(x + L.pad, ry, fit(c.label, nw - 2 * L.pad), lhot and U.AMBER or (k == IN.c and focused and U.AMBER or kcol))
    if lhot then hv = { all = k } end
    if IN.hint then IN.hint('in', x + L.pad, ry, nw - 2 * L.pad, L.rh, { c = k }) end   -- 13 ноя: метки f — на вход
    for i, g in pairs(tx) do
      local on = col_of(cols, rows[i].v) == k
      local hot = mx >= g.x and mx < g.x + g.w and my >= ry and my < ry + L.rh
      local cur = focused and i == IN.r and k == IN.c
      if on then U.set(U.tint(kcol, 0.45)); gfx.rect(g.x + 1, ry + 1, g.w - 2, L.rh - 2, 1) end
      U.set(cur and U.AMBER or (hot and U.TEXT or U.LINE)); gfx.rect(g.x + 1, ry + 1, g.w - 2, L.rh - 2, 0)
      if hot then hv = { r = i, c = k } end
      if IN.hint then IN.hint('in', g.x + 1, ry, g.w - 2, L.rh, { r = i, c = k }) end   -- 13 ноя: метки f — на клетку
    end
  end
  return hv
end

-- клавиши → действие { op = 'set' | 'all' | 'solo', r, c } | 'leave' | true (своё) | nil (не наше)
function IN.key(c, nrows, ncols)
  local ch = c > 0 and c < 256 and string.char(c) or ''
  if c == 27 then return 'leave' end
  -- 13 ноя: таблица повёрнута — j k по входам (строки), h l по трекам (колонки)
  if ch == 'j' or c == 1685026670 then IN.c = math.min(ncols, IN.c + 1); return true end
  if ch == 'k' or c == 30064 then IN.c = math.max(1, IN.c - 1); return true end
  if ch == 'l' or c == 1919379572 then IN.r = math.min(nrows, IN.r + 1); return true end
  if ch == 'h' or c == 1818584692 then IN.r = math.max(1, IN.r - 1); return true end
  if c == 13 or ch == ' ' then return { op = 'set', r = IN.r, c = IN.c } end
  if ch == 'a' then return { op = 'all', c = IN.c } end
  if ch == 'x' then return { op = 'solo', r = IN.r } end
  return nil
end

return IN
