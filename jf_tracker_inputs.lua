-- jf_tracker_inputs.lua (11 ноя) — панель inputs: входы всех треков матрицей. Строки — треки, колонки — входы
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

-- rows: { { name, v, rgb } }; → hover { r, c } | { all = c }
function IN.draw(U, L, rows, cols, x, y, w, h, focused, mx, my, fit)
  local hv
  U.set(U.PANEL); gfx.rect(x, y, w, h, 1)
  if #rows == 0 then U.text(x + L.pad, y + 2, 'no tracks', U.DIM); return end
  IN.r = math.max(1, math.min(#rows, IN.r)); IN.c = math.max(1, math.min(#cols, IN.c))
  local nw = math.min(L.cw * 12, math.floor(w * 0.3))
  -- колонка — по самой длинной подписи, не шире 10 знаков; не влезает — прокрутка за курсором
  local cw = L.cw * 3
  for _, c in ipairs(cols) do cw = math.max(cw, math.min(L.cw * 10, U.measure(c.label) + 2 * L.pad)) end
  local fitn = math.max(1, math.floor((w - nw) / cw))
  IN.c0 = IN.c0 or 1
  if IN.c < IN.c0 then IN.c0 = IN.c elseif IN.c >= IN.c0 + fitn then IN.c0 = IN.c - fitn + 1 end
  local hy = y + 2
  -- шапка: подписи колонок (щелчок — этот вход всем трекам)
  for k = IN.c0, math.min(#cols, IN.c0 + fitn - 1) do
    local c = cols[k]
    local cx = x + nw + (k - IN.c0) * cw
    local hot = mx >= cx and mx < cx + cw and my >= hy and my < hy + L.rh
    local col = c.kind == 'midi' and U.CYAN or (c.kind == 'audio' and U.GREEN or U.GREY)
    U.text(cx + L.pad, hy, fit(c.label, cw - 2 * L.pad), hot and U.AMBER or col)
    if hot then hv = { all = k } end
  end
  U.text(x + L.pad, hy, fit('track \\ input', nw - L.pad), U.GREY)
  local ry0 = hy + L.rh + 2
  local nvis = math.max(1, math.floor((y + h - ry0) / L.rh))
  IN.r0 = IN.r0 or 1
  if IN.r < IN.r0 then IN.r0 = IN.r elseif IN.r >= IN.r0 + nvis then IN.r0 = IN.r - nvis + 1 end
  for i = IN.r0, math.min(#rows, IN.r0 + nvis - 1) do
    local row = rows[i]
    local ry = ry0 + (i - IN.r0) * L.rh
    if row.rgb then U.set(row.rgb); gfx.rect(x + 1, ry + 1, 2, L.rh - 2, 1) end
    U.text(x + L.pad + 2, ry, fit(row.name, nw - L.pad - 4), i == IN.r and focused and U.AMBER or U.TEXT)
    local on = col_of(cols, row.v)
    for k = IN.c0, math.min(#cols, IN.c0 + fitn - 1) do
      local cx = x + nw + (k - IN.c0) * cw
      local hot = mx >= cx and mx < cx + cw and my >= ry and my < ry + L.rh
      local cur = focused and i == IN.r and k == IN.c
      if on == k then U.set(U.tint(cols[k].kind == 'midi' and U.CYAN or (cols[k].kind == 'audio' and U.GREEN or U.GREY), 0.45)); gfx.rect(cx + 1, ry + 1, cw - 2, L.rh - 2, 1) end
      U.set(cur and U.AMBER or (hot and U.TEXT or U.LINE)); gfx.rect(cx + 1, ry + 1, cw - 2, L.rh - 2, 0)
      if hot then hv = { r = i, c = k } end
    end
  end
  return hv
end

-- клавиши → действие { op = 'set' | 'all' | 'solo', r, c } | 'leave' | true (своё) | nil (не наше)
function IN.key(c, nrows, ncols)
  local ch = c > 0 and c < 256 and string.char(c) or ''
  if c == 27 then return 'leave' end
  if ch == 'j' or c == 1685026670 then IN.r = math.min(nrows, IN.r + 1); return true end
  if ch == 'k' or c == 30064 then IN.r = math.max(1, IN.r - 1); return true end
  if ch == 'l' or c == 1919379572 then IN.c = math.min(ncols, IN.c + 1); return true end
  if ch == 'h' or c == 1818584692 then IN.c = math.max(1, IN.c - 1); return true end
  if c == 13 or ch == ' ' then return { op = 'set', r = IN.r, c = IN.c } end
  if ch == 'a' then return { op = 'all', c = IN.c } end
  if ch == 'x' then return { op = 'solo', r = IN.r } end
  return nil
end

return IN
