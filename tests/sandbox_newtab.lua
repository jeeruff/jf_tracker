-- sandbox_newtab.lua — новая пустая вкладка для песочницы (40859); наполняет sandbox_setup.lua отдельным запуском
reaper.SetExtState('jf_tracker', 'sandbox', 'newtab', false)
reaper.Main_OnCommand(40859, 0)
