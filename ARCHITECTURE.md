# Как устроен jf_tracker

Одна страница, чтобы понять трекер, не читая 46 000 строк кода. Для людей,
которые «знают азы», и для LLM, которой дали задачу. Правила для LLM, которые
здесь легко нарушить, — в [AGENTS.md](AGENTS.md).

## Главная мысль

Трекер — это **вид**, а не программа со своими данными. Всё, что видно в
трекере, — обычные треки, items, MIDI, регионы и огибающие проекта REAPER.
Закрыл трекер — проект остался как был. Своего файла у трекера нет, только
настройки (ExtState `jf_tracker/…`).

Отсюда три правила, на которых держится весь код:

1. **Читает проект один модуль** — `jf_tracker_model.lua`. Он делает
   *снимок*: весь проект, разложенный по строкам трекера. Снимок только для
   чтения.
2. **Пишет в проект один модуль** — `jf_tracker_edit.lua`. Любая правка идёт
   через `edit.run('имя', функция)` и становится **одним шагом undo**.
   После правки снимок помечается устаревшим (`model.invalidate()`).
3. **Рисует один модуль** — `jf_tracker_draw.lua` (через `gfx` REAPER, без
   ReaImGui). Панели рисуют только внутри своего прямоугольника.

## Путь одного кадра

REAPER вызывает `frame()` в `jf_tracker.lua` примерно 30–60 раз в секунду
(`reaper.defer`). За кадр происходит:

```
снимок         model.snapshot(lpb)        проект → строки (пересборка, только если проект изменился)
   ↓
раскладка      relayout() → D.layout      где что стоит: дерево панелей (panes) → прямоугольники
   ↓
рисование      draw.frame(...)            трекер, панели, статус; каждая панель заполняет hover
   ↓
hover          «что под мышью»            таблица: ячейка, кнопка, ручка, вкладка…
   ↓
ввод           gfx.getchar() / мышь       клавиша → панель в фокусе или Vim-слой; щелчок → hover
   ↓
правка         edit.run(...)              один undo-шаг → model.invalidate()
   ↓
следующий кадр — снимок пересобран, на экране уже новое
```

Клавиша сначала проходит общие сочетания (Cmd+hjkl — фокус окон, Ctrl+W —
режим PANE, F-клавиши), потом достаётся **панели в фокусе**
(`state.focus`). Панель отвечает «съела» или «нет»; несъеденная идёт в
Vim-слой (`jf_tracker_vim.lua`): режимы NORMAL / INSERT / VISUAL, движения,
операторы, `:команды`.

## Из чего состоит окно

Окно — **дерево сплитов, как в tmux / zellij** (`jf_tracker_panes.lua`).
Лист дерева — панель или стек панелей с ярлыками (вкладки). Трекер — тоже
лист, просто его нельзя закрыть. Реестр всех панелей — `PN.PANELS`
(id, подпись, буква, сторона по умолчанию). Раскладка сохраняется одной
строкой в ExtState `panes` и в скринсетах.

У каждой панели один и тот же образец:

- `draw(x, y, w, h)` — нарисовать себя в прямоугольнике и записать в `hover`,
  что где лежит;
- `key(c)` — обработать клавишу: `true` — съела, иначе клавиша идёт дальше;
- щелчок мыши обрабатывается по `hover`, а не по координатам.

## Словарь

| слово | что это |
|---|---|
| **row** (строка) | шаг сетки трекера. Сколько строк в четверти — **LPB**. Строка 0 = начало проекта. Смена LPB ничего в проекте не меняет, это масштаб. |
| **track / column** | трек REAPER = колонка трекера. |
| **lane / sub** | подколонка трека: несколько нот одновременно (аккорд) или fixed lane REAPER. |
| **head / cont** | ячейка, где событие начинается (head), и строки, на которые оно тянется (cont, «продолжение»). |
| **item / take** | items и takes REAPER; нота трекера — это MIDI-нота или аудио-item. |
| **pool / lib** | список инструментов (сэмплы, слайсы, MIDI-клипы). Хранится на заглушённом скрытом треке **LIB**. Номер инструмента — `num`, ключ — `gkey`. |
| **slice** | кусок сэмпла (виртуальная нарезка, `jf_tracker_slicer.lua`), у слайса есть `parent`. |
| **region / pattern** | регион REAPER = паттерн трекера. Одноимённые регионы — копии одного паттерна (alias). |
| **matrix / slot** | матрица паттернов: порядок регионов в песне, слот = строка порядка. |
| **session / clips** | клипы как в Ableton поверх линейного проекта. |
| **pane / leaf / stack** | панель окна / лист дерева / несколько панелей во вкладках одного листа. |
| **focus** | какая панель получает клавиши (`state.focus`). |
| **ctx** | большая таблица функций главного модуля, которую получают другие модули. Через неё они просят сделать что-то, не зная, как это устроено внутри. |
| **hover** | что под мышью в этом кадре; заполняется при рисовании. |
| **snap** | текущий снимок модели. |
| **state** | настройки и состояние окна (LPB, тема, раскладка…), большая часть — в ExtState. |
| **EXT / ExtState** | хранилище настроек REAPER; пространство трекера — `jf_tracker`. |

## Где проверять

- `tests/test_*.lua` — тесты на заглушках, без REAPER: `lua tests/test_vim.lua`.
- `tests/restart.sh` — перезапуск трекера в живом REAPER (через веб-интерфейс 8080).
- Опция **debug** пишет `REAPER/jf_tracker_debug.log`: каждая клавиша с
  файлом и строкой обработчика. Если «не работает» — читать первым.
- `CHECK.md` — что проверить руками после изменений.
- `DEVELOPMENT.md` — история решений и планы.

## Файлы

Таблицу ниже собирает `lua tools/archmap.lua` из шапок-комментариев модулей.
Руками её не править: поправь шапку файла и перезапусти скрипт.

<!-- files:begin -->
| файл | строк | за что отвечает |
|---|---:|---|
| **ядро: данные и правка** | | |
| `jf_tracker.lua` | 33370 | трекерный вид таймлайна REAPER с Vim-редактированием. |
| `jf_tracker_model.lua` | 2929 | снимок проекта REAPER в трекерных строках. |
| `jf_tracker_edit.lua` | 6027 | ВСЕ записи трекера в проект REAPER. |
| `jf_tracker_alias.lua` | 866 | алиасы паттернов (этап 6). |
| `jf_tracker_arr.lua` | 101 | аранжировки (9 окт): фиксированные лейны трека — его версии, аранжировка — именованный набор играющих лейнов всех треков (C_LANEPLAYS). |
| `jf_tracker_cmds.lua` | 459 | команды-огибающие и генераторы (этап 7). |
| `jf_tracker_chord.lua` | 202 | аккорды (8 окт): анализатор и гармонайзер. |
| `jf_tracker_import.lua` | 184 | импорт нарезанных инструментов (2 окт). |
| **клавиши и команды** | | |
| `jf_tracker_vim.lua` | 4382 | Vim-слой трекера: режимы, движения, операторы. |
| `jf_tracker_keys.lua` | 130 | раскладка клавиш трекера. |
| `jf_tracker_whichkey.lua` | 72 | подсказка второй клавиши (7 окт, как which-key в Emacs / Neovim): нажат префикс (d, z, g …) — главный модуль вместо быстрых опций показывает, что м… |
| `jf_tracker_keyhelp.lua` | 1338 | контекстная справка по клавишам (2 окт). |
| `jf_tracker_hints.lua` | 161 | Vim-подсказки (как Vimium / easymotion / warpd). |
| `jf_tracker_instkeys.lua` | 186 | клавиши модуля инструментов в духе Vim (2 окт). |
| `jf_tracker_dspkeys.lua` | 234 | клавиши DSP-панели в духе Vim (2 окт). |
| `jf_tracker_ctrlmouse.lua` | 169 | мышь с Ctrl (8 окт): универсальная ручка. |
| `jf_tracker_names.lua` | 62 | подсказки имён (5 окт): «/» в поле имени трека, инструмента, item или региона открывает список. |
| **окно: раскладка и рисование** | | |
| `jf_tracker_draw.lua` | 12470 | отрисовка снимка трекера в gfx. |
| `jf_tracker_panes.lua` | 978 | раскладка окна как в tmux / zellij (9 окт). |
| `jf_tracker_ui.lua` | 257 | нативная графика REAPER (gfx), минимализм. |
| `jf_tracker_themes.lua` | 121 | темы трекера (3 окт). |
| `jf_tracker_smart.lua` | 339 | смарт-панель (9 окт, как Smart Select в PlayerPro / Paketti): у ячейки курсора всплывает сетка значений того поля, где стоит курсор — ноты (октавы … |
| `jf_tracker_ask.lua` | 60 | маленький вопрос посреди окна (3 окт). |
| `jf_tracker_png.lua` | 78 | PNG без внешних программ (8 окт, снимки measure). |
| `jf_tracker_logo.lua` | 517 | логотип JFTRACKER для about (главный модуль, 3 окт). |
| **панели и вкладки** | | |
| `jf_tracker_matrix.lua` | 1398 | матрица паттернов (этап 3). |
| `jf_tracker_session.lua` | 1027 | session: клипы как в Ableton поверх линейного таймлайна REAPER (6 окт). |
| `jf_tracker_browser.lua` | 2285 | сайдбар-браузер (справа от трекера). |
| `jf_tracker_fxbrowser.lua` | 491 | браузер эффектов слева от DSP-панели (2 окт). |
| `jf_tracker_sampleprops.lua` | 499 | панель свойств сэмпла справа от волны (вкладка Sample, 2 окт; как свойства сэмпла в Renoise, но всё нативное: item и take REAPER). |
| `jf_tracker_slicer.lua` | 1890 | виртуальная нарезка сэмпла (инструмента пула). |
| `jf_tracker_preview.lua` | 420 | предпрослушивание вставляемого события. |
| `jf_tracker_params.lua` | 369 | панель «params» во вкладке modulation (3 окт). |
| `jf_tracker_modmatrix.lua` | 258 | модуляционная матрица: нативная модуляция параметров FX REAPER (Parameter Modulation) в виде простой таблицы. |
| `jf_tracker_fxclass.lua` | 205 | классификатор параметров FX и автомодуль (3 окт). |
| `jf_tracker_dspmods.lua` | 465 | реестр модулей DSP-панели. |
| `jf_tracker_dspbig.lua` | 602 | DSP big (7 окт): цепочка FX трека / take на всё окно, роутинг видно. |
| `jf_tracker_aiedit.lua` | 564 | редактор точек automation item (5 окт). |
| `jf_tracker_lfogen.lua` | 411 | генератор кривых в точки огибающей (2 окт). |
| `jf_tracker_sgram.lua` | 167 | спектрограмма (5 окт): время × частота тепловой картой. |
| `jf_tracker_macros.lua` | 343 | вкладка macros (9 окт): макросы трекера в одном месте. |
| `jf_tracker_macro.lua` | 122 | макро-вид трекера (3 окт, :macro): вид «с высоты». |
| `jf_tracker_midimap.lua` | 287 | MIDI learn для слайсера (вкладка midi, 2 окт). |
| `jf_tracker_harm.lua` | 450 | вкладка harmonizer (8 окт), рядом с midi. |
| `jf_tracker_video.lua` | 149 | вкладка video (9 окт). |
| `jf_tracker_visor.lua` | 1209 | панель visor: шейдеры ReaVisor прямо из трекера (10 окт). |
| `jf_tracker_garden.lua` | 215 | вкладка Garden (F2, 2 окт): нелинейность внутри линейного REAPER. |
| `jf_tracker_orca.lua` | 284 | ядро Orca (Hundred Rabbits) для Garden трекера. |
| `jf_tracker_notes.lua` | 221 | текстовый редактор заметок (2 окт). |
| `jf_tracker_pm.lua` | 792 | проект-менеджер jf_pm в трекере (6 окт, экспериментально). |
| `jf_tracker_perf.lua` | 165 | производительность REAPER в духе htop (6 окт). |
| `jf_tracker_audio.lua` | 98 | аудиоустройство REAPER из трекера (10 окт): вкладка audio в options и zB (размер буфера). |
| **опции, справка, служебное** | | |
| `jf_tracker_options.lua` | 941 | окно Options: все переключатели и числа трекера в одном всплывающем списке (кнопка «options» в контроле, :options, \o). |
| `jf_tracker_screensets.lua` | 45 | формат файла скринсетов (4 окт): строка на набор, «имя&lt;TAB>ключ=тип:значение;…», тип b (0/1) / n (число) / s (строка, ; → %3B). |
| `jf_tracker_doc.lua` | 247 | справка F1 прямо в трекере (6 окт). |
| `jf_tracker_tour.lua` | 120 | интерактивный тур (4 окт): ячейка tutorial главного модуля. |
| `jf_tracker_version.lua` | 879 | версия и список изменений (Options → about). |
| **прочее** | | |
| `jf_tracker_actions.lua` | 102 | панель actions (16 окт): список действий REAPER шире родного окна Actions. |
| `jf_tracker_aim.lua` | 68 | математика прицела (12 окт): где в файле звучит нота на строке курсора, где это в секундах показанного инструмента e, где резать в проекте; привязк… |
| `jf_tracker_arc.lua` | 75 | monome arc в трекере (15 окт): 4 кольца = 4 параметра эффекта. |
| `jf_tracker_autocanvas.lua` | 347 | холст автоматизации (15 окт): страница curve вкладки automation. |
| `jf_tracker_curves.lua` | 95 | кривые для выделения на колонке огибающей (24 окт): reform для автоматизации. |
| `jf_tracker_drumrack.lua` | 148 | drumrs5k (16 окт): контейнер RS5K видом драм-рэка. |
| `jf_tracker_dsprack.lua` | 72 | геометрия цепочки DSP без reaper / gfx (28 окт; тест tests/test_dsprack.lua). |
| `jf_tracker_fxdump.lua` | 54 | снимок параметров плагина (PLAN_DSP этап 0, 22 окт): образцы для парсера. |
| `jf_tracker_fxfloat.lua` | 47 | опция «no auto FX windows» (24 окт): окна, которые REAPER открывает сам («Auto-float newly created FX windows») при добавлении эффекта — из трекера… |
| `jf_tracker_fxparse.lua` | 194 | парсер параметров плагина по тексту значения (PLAN_DSP этапы 1–2, 22 окт). |
| `jf_tracker_fxpresets.lua` | 79 | поиск по пресетам плагинов (28 окт; тест tests/test_presets_index.lua). |
| `jf_tracker_humanizer.lua` | 215 | панель humanizer (19 окт): тонкая настройка «человечности». |
| `jf_tracker_keyrep.lua` | 73 | свой автоповтор зажатой клавиши (27 окт; вынесен для тестов tests/test_keyrep.lua). |
| `jf_tracker_layers.lua` | 91 | слоёный инструмент (14 окт): несколько items звучат одной нотой. |
| `jf_tracker_llm.lua` | 157 | мост к языковой модели / MCP (10 окт). |
| `jf_tracker_mem.lua` | 121 | :mem (21 окт): кто держит память Lua. |
| `jf_tracker_nmodui.lua` | 130 | модуль note mod (12 окт): слоты модуляции инструмента. |
| `jf_tracker_notemod.lua` | 279 | модуляция, которую запускает нота (12 окт, этап 1). |
| `jf_tracker_numkeys.lua` | 60 | 21 окт: число перед клавишей в панелях reform / humanizer / bouncer (как в DSP): N h / l — шаг ×N, N j / k — на N строк, N Enter — значение строки … |
| `jf_tracker_padseq.lua` | 54 | pads (17 окт, MPC style): паттерны песни на нотных клавишах, игра паттернами вживую. |
| `jf_tracker_pins.lua` | 56 | матрица пинов эффекта (24 окт): как Pin Connector REAPER, в стиле трекера. |
| `jf_tracker_playlist.lua` | 142 | playlist матрицы (18 окт): порядок паттернов текстом, как region playlist. |
| `jf_tracker_premod.lua` | 85 | premod (22 окт): кривая автоматизации ДО ноты. |
| `jf_tracker_presets.lua` | 94 | пресеты инструментов на шаблонах треков REAPER (16 окт). |
| `jf_tracker_reform.lua` | 198 | reform (19 окт): живая переделка выделенных нот. |
| `jf_tracker_renderer.lua` | 212 | панель renderer (20 окт, gB): баунс нот в аудио и инструмент DSP → сэмплер. |
| `jf_tracker_sections.lua` | 138 | коды паттернов и секции (12 окт). |
| `jf_tracker_sigpick.lua` | 161 | выпадашка размера такта (18 окт): вместо строки :sig N/D here. |
| `jf_tracker_slxpanel.lua` | 334 | пульт jf_slixer в DSP трекера, 1 в 1 с окном плагина (25 окт). |
| `jf_tracker_smap.lua` | 1299 | карта сэмплов папки, как граф Obsidian (27 окт 2026). |
| `jf_tracker_snaps.lua` | 81 | 22 окт: быстрые пресеты трека в DSP: 4 снапшота всех параметров FX трека в углах XY-пэда (1 — левый верх, 2 — правый верх, 3 — левый низ, 4 — правы… |
| `jf_tracker_surge.lua` | 169 | патчи Surge XT из трекера (16 окт). |
| `jf_tracker_szone.lua` | 31 | 21 окт: место зоны сессии (=SESSION) — расчёт без reaper.* (тест tests/test_szone.lua). |
| `jf_tracker_themetab.lua` | 304 | вкладка theme окна Options (10 окт): темы и шрифты с примерами. |
| `jf_tracker_theory.lua` | 434 | 21 окт: теория для harmonizer (чистый Lua, тест tests/test_theory.lua). |
| `jf_tracker_tracks.lua` | 199 | дерево треков для модуля tracks (13 окт, как файловый менеджер lf). |
| `jf_tracker_undosnap.lua` | 96 | снимок состояния проекта для ветвей дерева undo (15 окт). |
| `jf_tracker_undotree.lua` | 331 | дерево undo (15 окт), как undotree в Vim. |
| `jf_tracker_utf8.lua` | 18 | набор текста не только латиницей (20 окт): кириллица и любой Юникод в полях ввода. |
| `jf_tracker_xform.lua` | 156 | модификаторы (15 окт): трансформации времени и громкости блока событий. |
| `jf_tracker_zones.lua` | 85 | зоны цепей рэка (23 окт): key / vel / sel, как Key / Vel / Chain в Ableton Rack. |
<!-- files:end -->

## Карта модулей и клавиш

Собирает `lua tools/archmap.lua` из `PN.PANELS` (jf_tracker_panes.lua) и which-key
(jf_tracker_whichkey.lua). Руками не править. Перед перестановкой модуля, буквы
или префикса — сверься с этой картой; после — перезапусти скрипт и посмотри diff.

<!-- keys:begin -->
### Модули окна

| модуль (id) | подпись | буква (gt, Ctrl+W g) | место по умолчанию | когда есть |
|---|---|---|---|---|
| `tracker` | tracker | `t` |  | всегда |
| `patterns` | patterns | `T` | left | всегда |
| `matrix` | matrix | `m` | left | всегда |
| `browser` | browser | `b` | right | всегда |
| `map` | map | `w` | right | всегда |
| `inst` | lib | `l` | right | всегда |
| `ctrl` | main | `n` | top | всегда |
| `slices` | slices | `s` | top | влита (не показывается) |
| `sprops` | properties | `e` | right | itemtab |
| `nmod` | note mod | `N` | right | itemtab |
| `mixer` | mixer | `x` | bottom | mixer |
| `tracks` | tracks | `k` | left | всегда |
| `clipboard` | clipboard | `y` | right | всегда |
| `undotree` | undo | `U` | right | всегда |
| `perf` | performance | `P` | left | всегда |
| `actions` | actions | `A` | right | всегда |
| `reform` | reform | `R` | right | всегда |
| `humanizer` | humanizer | `H` | right | всегда |
| `renderer` | bouncer | `B` | right | всегда |
| `help` | help | `?` | right | всегда |
| `notes` | notes | `o` | bottom | всегда |
| `fxb` | fx | `f` | right | всегда |
| `pm` | pm | `p` | right | всегда |
| `dsp` | dsp | `d` | bottom | всегда |
| `retro` | rec | `r` | top, вкладка сверху | всегда |
| `sample` | item | `i` | top, вкладка сверху | всегда |
| `automation` | automation | `a` | top, вкладка сверху | всегда |
| `modulation` | modulation | `u` | top, вкладка сверху | влита (не показывается) |
| `midi` | midi | `M` | top, вкладка сверху | всегда |
| `harm` | harmonizer | `h` | top, вкладка сверху | всегда |
| `clips` | clips | `C` | top, вкладка сверху | всегда |
| `macros` | macros | `q` | top, вкладка сверху | всегда |
| `scopes` | scopes | `c` | top, вкладка сверху | всегда |
| `master` | master | `S` | top, вкладка сверху | всегда |
| `video` | video | `v` | top, вкладка сверху | всегда |
| `visor` | visor | `V` | top, вкладка сверху | всегда |
| `grid` | grid | `g` | top, вкладка сверху | всегда |
| `garden` | orca | `O` | top, вкладка сверху | dev |

### Префиксы клавиш (NORMAL, which-key)

| префикс | заголовок | клавиши дальше |
|---|---|---|
| `'` | ' - harpoon (pinned places) | `a` `1..9` `'` `b` `d` |
| `@` | @ - play a macro | `a..z` `@` `Opt+Shift+2` |
| `T` | Opt+T - take (the note under the cursor) | `f` `o` |
| `browser_z` | z - browser view | `i` `o` `z` `m` |
| `c` | c - change | `c` |
| `d` | d - delete | `d` `c` `C` `W` `p` `P` `t` `r` `R` `T` `a` |
| `da` | da - delete all (the track, in the song) | `e` `l` `j` `k` `h` `E` `L` `J K H` |
| `dsp_a` | a - add / automate | `f` `F` `a` `p` `i` `d` `m` |
| `dsp_c` | c - rack / container | `c` `u` `n` `v` `b` `f` `=` `/` `s` |
| `dsp_d` | d - delete | `d` `m` `a` |
| `dsp_y` | y - copy | `y` |
| `dsp_z` | z - view / router / pages | `z` `e` `Tab` `w` `X` `r` `R` `l` `f` `F` `p` `P` `m` |
| `dsp_zs` | cs - pad size | `s` `m` `l` |
| `g` | g - go | `g` `12 Enter` `w` `p` `P` `s` `S` `m` `t` `T` `i` `r` |
| `item_z` | z - view of the item | `z` `w` `x` |
| `pane` | PANE (Ctrl+W) - Esc out | `h j k l` `H J K L` `w W  1..9` `g + key` `s v + key` `T + key` `B` `X + key  x` `+ -  < >` `=` `z` `c` `Space` `u` |
| `q` | q - record a macro | `a..z` |
| `r` | r - replace | `key` |
| `t` | t - track | `t` `d` `x` `p` `s` `r` `n` `c` `y` `a` `m` `u` `A` `i` `I` `l` `w` `f` `R` `T` `F` `j k` |
| `y` | y - copy | `y` `c` |
| `z` | z - view | `z` `Z` `1` `w` `t` `b` `a` `c` `o` `e` `C` `f` `M` `m` `> <` `. ,` `x` `X` `u` `p` `s` `r` `R` |
<!-- keys:end -->
