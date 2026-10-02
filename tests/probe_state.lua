-- probe_state.lua — счётчик состояния проекта → ExtState jf_tracker/probe
-- (проверка, что трекер ничего не меняет в проекте)
reaper.SetExtState('jf_tracker', 'probe', string.format('count=%d tracks=%d items=%d',
  reaper.GetProjectStateChangeCount(0), reaper.CountTracks(0), reaper.CountMediaItems(0)), false)
