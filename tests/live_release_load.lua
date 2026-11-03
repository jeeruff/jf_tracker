-- live_release_load.lua (3 ноя) — релизная сборка (без dev-файлов: orca, pm, демон) грузится без окна, в пустой вкладке-песочнице.
-- Ловит то, что dev-копия не видит: 0.9.1 падал у всех на jf_tracker.lua:618 (Orca из релиза убрана, поле garden nil).
-- Запуск: собрать экспорт (python3 tools/make_index.py --export HEAD <dir>/jf_tracker), затем
--   JF_REL = '<dir>/jf_tracker'; return dofile('<путь>/tests/live_release_load.lua')   через tests/nw.py
local _, pn = reaper.EnumProjects(-1, '')
if (pn or '') ~= '' or reaper.CountTracks(0) > 0 then return 'REFUSED: not an empty sandbox tab' end
if not JF_REL then return 'REFUSED: set JF_REL to the exported jf_tracker folder' end
JF_TRACKER_ATEXIT = true
local d, gi, gq = reaper.defer, gfx.init, gfx.quit
reaper.defer = function() end
gfx.init = function() return 1 end
gfx.quit = function() end
local ok, err = pcall(dofile, JF_REL .. '/jf_tracker.lua')
reaper.defer, gfx.init, gfx.quit = d, gi, gq
JF_TRACKER_SAVE_WIN = nil
return ok and 'release: LOADED' or ('release: ERR ' .. tostring(err))
