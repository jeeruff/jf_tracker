-- probe_tab1.lua — вернуть пользователя на вкладку 1 (после закрытия песочницы REAPER выбирает другую)
local p = reaper.EnumProjects(0); if p then reaper.SelectProjectInstance(p) end
