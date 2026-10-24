-- jf_tracker_pins.lua — матрица пинов эффекта (24 окт): как Pin Connector REAPER, в стиле трекера.
-- Слева — входы плагина (столбцы) от каналов трека (строки), справа — выходы плагина в каналы трека.
-- PN.read(A, obj, fx, nch) → { nin, nout, nch, ins = { [pin] = маска }, outs = { … }, inn = { имена }, outn = { … } }
-- PN.toggle(st, side, pin, ch) → новая маска пина (бит канала ch, с 0); PN.grid(st, x, y, cw, rh, lw) → прямоугольники клеток
-- Каналов — до 32 (младшее слово маски). Без reaper.* в расчёте — тест tests/test_pins.lua (A — таблица функций).

local PN = {}
PN.MAXCH = 32

function PN.read(A, obj, fx, nch)
  local st = { nin = 0, nout = 0, nch = math.max(2, math.min(PN.MAXCH, nch or 2)), ins = {}, outs = {}, inn = {}, outn = {} }
  local ok, _, ni, no = pcall(A.GetIOSize, obj, fx)   -- первое значение — тип плагина
  if ok and ni then st.nin, st.nout = math.max(0, ni), math.max(0, no or 0) end
  local function pins(isout, n, masks, names)
    for p = 0, n - 1 do
      local lo = A.GetPinMappings(obj, fx, isout, p)
      masks[p] = tonumber(lo) or 0
      local okn, nm = A.GetNamedConfigParm(obj, fx, (isout == 1 and 'out_pin_' or 'in_pin_') .. p)
      names[p] = (okn and nm ~= '' and nm) or ((isout == 1 and 'out ' or 'in ') .. (p + 1))
    end
  end
  pins(0, st.nin, st.ins, st.inn)
  pins(1, st.nout, st.outs, st.outn)
  return st
end

function PN.has(mask, ch) return (mask or 0) & (1 << ch) ~= 0 end

function PN.toggle(st, side, pin, ch)
  local masks = side == 'in' and st.ins or st.outs
  local m = masks[pin] or 0
  m = m ~ (1 << ch)
  masks[pin] = m
  return m
end

-- по умолчанию REAPER: пин k ↔ канал k (диагональ)
function PN.reset(st)
  for p = 0, st.nin - 1 do st.ins[p] = (p < st.nch) and (1 << p) or 0 end
  for p = 0, st.nout - 1 do st.outs[p] = (p < st.nch) and (1 << p) or 0 end
end

-- клетки: x0 — левый край, lw — ширина подписей каналов слева, gap — между матрицами
function PN.grid(st, x0, y0, cw, rh, lw, gap)
  local cells = {}
  local ix = x0 + lw
  local ox = ix + st.nin * cw + gap
  for ch = 0, st.nch - 1 do
    local y = y0 + ch * rh
    for p = 0, st.nin - 1 do cells[#cells + 1] = { side = 'in', pin = p, ch = ch, x = ix + p * cw, y = y, w = cw, h = rh } end
    for p = 0, st.nout - 1 do cells[#cells + 1] = { side = 'out', pin = p, ch = ch, x = ox + p * cw, y = y, w = cw, h = rh } end
  end
  return cells, ix, ox
end

return PN
