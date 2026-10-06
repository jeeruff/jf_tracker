-- jf_tracker_perf.lua — производительность REAPER в духе htop (6 окт).
--
-- Нагрузки CPU и памяти REAPER API не отдаёт (ни по процессу, ни по трекам /
-- FX). Внешних процессов окно не запускает (6 окт, решение пользователя: ps
-- убран) — только API REAPER и сам трекер:
--   трекер — доля кадра на отрисовку, память Lua, кадр / пересборка;
--   аудио — частота, буфер, задержка выхода;
--   треки — FX, PDC цепочки (сэмплы / мс), items; сортировка по тяжести;
--   трекер — кадр, отрисовка, пересборка, куча Lua (из пульса main).
-- n — нативный Performance Meter REAPER, Esc / q — закрыть.

local P = { active = false, t = 0, proc = nil, tracks = {}, scroll = 0 }
local R = reaper


function P.refresh()
  local now = R.time_precise()
  if now - P.t < 2 and P.proc then return end
  P.t = now
  P.proc = true
  local _, sr = R.GetAudioDeviceInfo('SRATE', '')
  local _, bs = R.GetAudioDeviceInfo('BSIZE', '')
  P.audio = { sr = tonumber(sr) or 0, bs = tonumber(bs) or 0, lat = (R.GetOutputLatency and R.GetOutputLatency() or 0) * 1000 }
  local list = {}
  for i = 0, R.CountTracks(0) - 1 do
    local tr = R.GetTrack(0, i)
    local _, name = R.GetTrackName(tr)
    local nfx = R.TrackFX_GetCount(tr)
    local pdc = 0
    if nfx > 0 then local ok, v = R.TrackFX_GetNamedConfigParm(tr, 0, 'chain_pdc_reporting'); pdc = ok and tonumber(v) or 0 end
    list[#list + 1] = { name = name, fx = nfx, pdc = pdc, items = R.CountTrackMediaItems(tr),
                        armed = R.GetMediaTrackInfo_Value(tr, 'I_RECARM') == 1, muted = R.GetMediaTrackInfo_Value(tr, 'B_MUTE') == 1 }
  end
  table.sort(list, function(a, b) if a.pdc ~= b.pdc then return a.pdc > b.pdc end return a.fx > b.fx end)
  P.tracks = list
end

-- полоска htop: [|||||     42.0%]
local function bar(U, x, y, w, h, frac, label)
  frac = math.max(0, math.min(1, frac))
  U.set(U.LINE); gfx.rect(x, y, w, h, 0)
  local fw = math.floor((w - 2) * frac)
  local col = frac > 0.8 and U.RED or (frac > 0.5 and U.AMBER or U.GREEN)
  U.set(col); gfx.rect(x + 1, y + 1, fw, h - 2, 1)
  if label then U.text(x + w - U.measure(label) - 4, y, label, U.TEXT) end
end

-- рисуется на месте матрицы (6 окт): x, y, w, h — её прямоугольник
function P.draw(U, L, bx, by, bw, bh, hb, fit)
  if not P.active then return end
  P.refresh()
  U.set(U.PANEL); gfx.rect(bx, by, bw, bh, 1)
  local x, y = bx + L.pad, by + 2
  U.text(x, y, fit('performance  n: REAPER meter  Esc: close', bw - 2 * L.pad), U.AMBER)
  y = y + L.rh + 4
  -- полоски — то, что считается без внешних процессов (6 окт): доля кадра
  -- трекера на работу и память Lua; CPU / RAM самого REAPER — n (его метр)
  local fps = tonumber(hb and hb:match('([%d%.]+)fps') or '') or 0
  local dr = tonumber(hb and hb:match('draw ([%d%.]+)') or '') or 0
  local rb = tonumber(hb and hb:match('rebuild ([%d%.]+)') or '') or 0      -- последняя пересборка модели (не каждый кадр)
  -- работа каждого кадра: снимок + раскладка + отрисовка + обновление (6 окт:
  -- пересборка в полосу не входит — она только при изменении проекта)
  local sn = tonumber(hb and hb:match('snap ([%d%.]+)') or '') or 0
  local lo = tonumber(hb and hb:match('layout ([%d%.]+)') or '') or 0
  local up = tonumber(hb and hb:match('upd ([%d%.]+)') or '') or 0
  local work = sn + lo + dr + up
  local frame_ms = fps > 0 and 1000 / fps or 33.3
  local kb = collectgarbage('count')
  local lw = U.measure('frame ') + L.pad
  U.text(x, y, 'frame', U.CYAN); bar(U, x + lw, y, bw - lw - 2 * L.pad, L.rh, work / frame_ms, ('%.1f / %.0f ms'):format(work, frame_ms)); y = y + L.rh + 2
  U.text(x, y, 'Lua', U.CYAN); bar(U, x + lw, y, bw - lw - 2 * L.pad, L.rh, kb / (64 * 1024), ('%.1f MB'):format(kb / 1024)); y = y + L.rh + 2
  local a = P.audio or {}
  local nfx, maxpdc = 0, 0
  for _, t in ipairs(P.tracks) do nfx = nfx + t.fx; if t.pdc > maxpdc then maxpdc = t.pdc end end
  for _, line in ipairs({
    ('audio %d Hz, block %d (%.1f ms)'):format(a.sr or 0, a.bs or 0, (a.sr or 0) > 0 and (a.bs or 0) / a.sr * 1000 or 0),
    ('output latency %.1f ms'):format(a.lat or 0),
    ('%d tracks, %d fx, longest PDC %.1f ms'):format(#P.tracks, nfx, (a.sr or 0) > 0 and maxpdc / a.sr * 1000 or 0),
  }) do U.text(x, y, fit(line, bw - 2 * L.pad), U.TEXT); y = y + L.rh end
  U.text(x, y, fit(('tracker %.0f fps, ~%.0f%% of one core; last rebuild %.1f ms (on project changes); REAPER CPU / RAM: n'):format(fps, work * fps / 10, rb), bw - 2 * L.pad), U.GREY)
  y = y + L.rh + 4
  -- треки как процессы htop; колонки — по ширине
  local wide = bw > L.cw * 60
  local cols = wide and { { 'TRACK', 0 }, { 'FX', 26 }, { 'PDC', 32 }, { 'ms', 42 }, { 'ITEMS', 50 }, { 'ST', 58 } }
                     or { { 'TRACK', 0 }, { 'FX', -14 }, { 'ms', -9 } }
  local function cx(k) local o = cols[k][2]; return o >= 0 and (x + L.cw * o) or (bx + bw - L.pad + L.cw * o) end
  U.set(U.tint(U.CYAN, 0.25)); gfx.rect(bx + 1, y, bw - 2, L.rh, 1)
  for k, cdef in ipairs(cols) do U.text(cx(k), y, cdef[1], U.BG) end
  y = y + L.rh
  local nvis = math.floor((by + bh - y - 2) / L.rh)
  P.scroll = math.max(0, math.min(P.scroll, math.max(0, #P.tracks - nvis)))
  for i = P.scroll + 1, math.min(#P.tracks, P.scroll + nvis) do
    local t = P.tracks[i]
    local ms = (a.sr or 0) > 0 and t.pdc / a.sr * 1000 or 0
    local heavy = ms > 5
    U.text(cx(1), y, fit(t.name, (cols[2] and cx(2) or bx + bw) - cx(1) - L.pad), heavy and U.AMBER or U.TEXT)
    U.text(cx(2), y, tostring(t.fx), U.TEXT)
    if wide then
      U.text(cx(3), y, tostring(math.floor(t.pdc)), t.pdc > 0 and U.AMBER or U.GREY)
      U.text(cx(4), y, ('%.1f'):format(ms), t.pdc > 0 and U.AMBER or U.GREY)
      U.text(cx(5), y, tostring(t.items), U.GREY)
      U.text(cx(6), y, (t.armed and 'R ' or '') .. (t.muted and 'M' or ''), t.armed and U.RED or U.GREY)
    else U.text(cx(3), y, ('%.1f'):format(ms), t.pdc > 0 and U.AMBER or U.GREY) end
    y = y + L.rh
  end
  P.box = { bx, by, bw, bh }
end

function P.key(c)
  if not P.active then return false end
  local ch = c < 256 and string.char(c) or ''
  if c == 27 or ch == 'q' then P.active = false
  elseif ch == 'n' then R.Main_OnCommand(40240, 0)              -- View: Show performance meter window
  elseif ch == 'j' then P.scroll = P.scroll + 1
  elseif ch == 'k' then P.scroll = math.max(0, P.scroll - 1) end
  return true
end

return P
