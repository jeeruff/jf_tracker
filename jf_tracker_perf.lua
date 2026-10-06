-- jf_tracker_perf.lua — производительность REAPER в духе htop (6 окт).
--
-- Поштучной нагрузки на CPU по трекам / FX API REAPER не отдаёт (в бинарнике
-- таких функций нет), поэтому окно собирает то, что доступно:
--   процесс REAPER — CPU %, память, потоки (ps раз в 2 с);
--   аудио — частота, буфер, задержка выхода;
--   треки — FX, PDC цепочки (сэмплы / мс), items; сортировка по тяжести;
--   трекер — кадр, отрисовка, пересборка, куча Lua (из пульса main).
-- n — нативный Performance Meter REAPER, Esc / q — закрыть.

local P = { active = false, t = 0, proc = nil, tracks = {}, scroll = 0 }
local R = reaper

-- 6 окт: команда — файлом .sh, без кавычек в строке ExecProcess (через
-- sh -c "…" с $pid и %cpu= вывод приходил пустым: CPU 0 %, Mem 0 MB)
local SCRIPT = R.GetResourcePath() .. '/jf_tracker_perf.sh'
local function sh(cmd)
  local f = io.open(SCRIPT, 'w'); if not f then return '' end
  f:write('#!/bin/sh\n', cmd, '\n'); f:close()
  local ok, out = pcall(R.ExecProcess, '/bin/sh "' .. SCRIPT .. '"', 1500)
  if not ok or not out then return '' end
  return (out:gsub('^%-?%d+\n', ''))
end

function P.refresh()
  local now = R.time_precise()
  if now - P.t < 2 and P.proc then return end
  P.t = now
  local out = sh("pid=$(/usr/bin/pgrep -xn REAPER); /bin/ps -o %cpu=,rss=,%mem= -p $pid; /bin/ps -M -p $pid | /usr/bin/wc -l")
  local cpu, rss, mem, thr = out:match('([%d%.]+)%s+(%d+)%s+([%d%.]+)%s+(%d+)')
  P.raw = (not cpu) and out:gsub('%s+', ' '):sub(1, 80) or nil       -- не разобрали — сырой вывод в окно
  P.proc = { cpu = tonumber(cpu) or 0, rss = (tonumber(rss) or 0) / 1024, mem = tonumber(mem) or 0, thr = math.max(0, (tonumber(thr) or 1) - 1) }
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
  local pr = P.proc or {}
  local lw = U.measure('Mem ') + L.pad
  U.text(x, y, 'CPU', U.CYAN); bar(U, x + lw, y, bw - lw - 2 * L.pad, L.rh, (pr.cpu or 0) / 100, ('%.1f%%'):format(pr.cpu or 0)); y = y + L.rh + 2
  U.text(x, y, 'Mem', U.CYAN); bar(U, x + lw, y, bw - lw - 2 * L.pad, L.rh, (pr.mem or 0) / 100, ('%.0f MB'):format(pr.rss or 0)); y = y + L.rh + 2
  local a = P.audio or {}
  for _, line in ipairs({
    P.raw and ('ps: ' .. (P.raw ~= '' and P.raw or '(no output)')) or ('threads %d'):format(pr.thr or 0),
    ('audio %d Hz, block %d (%.1f ms)'):format(a.sr or 0, a.bs or 0, (a.sr or 0) > 0 and (a.bs or 0) / a.sr * 1000 or 0),
    ('output latency %.1f ms'):format(a.lat or 0),
  }) do U.text(x, y, fit(line, bw - 2 * L.pad), U.TEXT); y = y + L.rh end
  -- пульс трекера: кадр / отрисовка / пересборка / куча
  local fr = hb and hb:match('(%d+fps)') or ''
  local dr = hb and hb:match('draw ([%d%.]+)') or '?'
  local rb = hb and hb:match('rebuild ([%d%.]+)') or '?'
  local lua = hb and hb:match('lua (%d+KB)') or ''
  U.text(x, y, fit(('tracker %s draw %s ms rebuild %s ms %s'):format(fr, dr, rb, lua), bw - 2 * L.pad), U.GREY)
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
