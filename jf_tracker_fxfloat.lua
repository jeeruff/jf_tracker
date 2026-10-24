-- jf_tracker_fxfloat.lua — опция «no auto FX windows» (24 окт): окна, которые REAPER открывает сам
-- («Auto-float newly created FX windows») при добавлении эффекта — из трекера, из браузера REAPER, внутри
-- контейнеров. Опрос 4 раза в секунду: эффект, которого не было в прошлый опрос (новый GUID), с открытым
-- плавающим окном — окно закрыть. Окна уже стоящих эффектов (открыл сам: O, двойной клик) не трогаем.
-- Настройку REAPER не меняем. FF.poll(R) — из цикла трекера; на первом опросе только запоминает.

local FF = { seen = nil, t = 0, closed = 0 }

local function walk(R, tr, addr, fn, depth)
  fn(addr)
  if depth > 6 then return end
  local ok, cnt = R.TrackFX_GetNamedConfigParm(tr, addr, 'container_count')
  cnt = ok and tonumber(cnt) or 0
  for k = 0, cnt - 1 do
    local ok2, id = R.TrackFX_GetNamedConfigParm(tr, addr, 'container_item.' .. k)
    if ok2 and tonumber(id) then walk(R, tr, tonumber(id), fn, depth + 1) end
  end
end

function FF.poll(R, now)
  if now and now - FF.t < 0.25 then return end
  FF.t = now or 0
  local proj = R.EnumProjects(-1)
  if proj ~= FF.proj then FF.proj = proj; FF.seen = nil end   -- другая вкладка проекта: её эффекты не «новые»
  local seen, first = {}, FF.seen == nil
  local old = FF.seen or {}
  local n = R.CountTracks(0)
  for ti = -1, n - 1 do
    local tr = ti < 0 and R.GetMasterTrack(0) or R.GetTrack(0, ti)
    for i = 0, R.TrackFX_GetCount(tr) - 1 do
      walk(R, tr, i, function(a)
        local g = R.TrackFX_GetFXGUID(tr, a)
        if g then
          seen[g] = true
          if not first and not old[g] and R.TrackFX_GetFloatingWindow(tr, a) then
            R.TrackFX_Show(tr, a, 2); FF.closed = FF.closed + 1
          end
        end
      end, 0)
    end
  end
  FF.seen = seen
end

function FF.reset() FF.seen = nil end   -- опция выключена / смена проекта: новый отсчёт

return FF
