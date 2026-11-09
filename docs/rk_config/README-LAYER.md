# reaper-keys + слой-переключатель (локальная модификация)

Эта установка reaper-keys 2.0-alpha пропатчена: `internal/rk.lua` проверяет
ExtState `reaper_keys_layer/enabled` и при выключенном слое форвардит клавиши
на прежние бинды через `internal/fallback.lua` + `internal/fallback_bindings.lua`.

- Кнопка-переключатель: `rk_toggle_layer.lua` (экшен «reaper-keys: toggle vim layer»).
- LED кнопки синкается при старте через `Scripts/__startup.lua`.
- После изменения своих ОБЫЧНЫХ биндов: сделать Export all keymap и перегенерить
  таблицу: `python3 tools/generate_fallback.py <export> "<KeyMaps>/reaper-keys.ReaperKeyMap"`.

## ВАЖНО
**НЕ устанавливать/не обновлять reaper-keys через ReaPack** — это затрёт патч
rk.lua и добавленные файлы. Для обновления upstream: скопировать новую версию
вручную и заново применить патч (см. блок `reaper_keys_layer` в rk.lua).

Бэкапы: `~/Library/Application Support/REAPER/Backups/`.
