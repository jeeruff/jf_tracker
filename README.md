# jf_tracker — трекерный вид таймлайна REAPER с Vim-редактированием

Этапы 1–3 плана MVP (хандовер 30 сен 2026) + Vim-слой: вид, волны, матрица
паттернов, редактирование нот и аудио.

## Принципы (проверять каждое решение)

- **Трекер — вид, REAPER — движок.** Данные — треки, items, takes, MIDI,
  lanes, регионы. Своего формата нет. Все записи — в `jf_tracker_edit.lua`,
  каждая своим undo-блоком `jf_tracker: <что>`; штатный Ctrl+Z (и `u`) их
  откатывает.
- **Vim.** NORMAL / INSERT / VISUAL / V-LINE / `:`. Строка = строка, событие
  (item или нота) = слово, подколонка = столбец. Счётчики, операторы с
  движениями, регистр, `.`, макросы `q`/`@`. Полная раскладка — в шапке
  `jf_tracker_vim.lua`.
- **Нативная графика** `gfx`, встроенный битмап-шрифт `gfx.setfont(0)`
  («default bitmapped font, no configuration is possible»). ReaImGui нет.
- **Тиклесс.** Строка = 1/LPB четверти; всё меньше строки — доля `xx/256`
  (колонка delay). LPB — только масштаб вида.
- **Раскладка** слева направо: [матрица паттернов — этап 3] → номера строк →
  треки → lanes → подколонки `нота vol delay`.
- **API сверять** по строкам бинарника: `strings /Applications/REAPER.app/Contents/MacOS/REAPER | grep 'I_FIXEDLANE'`
  (локального reascripthelp.html нет).

## Файлы

| Файл | Что |
|---|---|
| `jf_tracker.lua` | окно, defer-цикл, клавиши, статус; ExtState `jf_tracker/*` |
| `jf_tracker_model.lua` | снимок проекта → строки. **Единственный** читатель `reaper.*` |
| `jf_tracker_draw.lua` | отрисовка снимка; из REAPER не читает ничего |
| `jf_tracker_vim.lua` | режимы, движения, операторы, регистры, макросы; reaper.* не трогает |
| `jf_tracker_edit.lua` | ВСЕ записи в проект: delete / mute / transpose / split / note-off / yank-paste / insert / mute_span |
| `jf_tracker_matrix.lua` | матрица паттернов: регионы × треки, фокус по Tab, mute ячейки, y/p паттерна |
| `jf_tracker_alias.lua` | алиасы: синхронизация одноимённых регионов, повтор паттерна |
| `jf_tracker_slicer.lua` | виртуальная нарезка инструмента во вкладке sample (`S.draw_in` в прямоугольник), ровная/по транзиентам, P_EXT:jf_slices |
| `jf_tracker_cmds.lua` | команды-огибающие и генераторы: U D G 4 0 A R P F, хранение P_EXT:jf_cmds, пересборка take-огибающих и копий |
| `daemon_tracker.lua` | модуль демона jf_grid (monome): грид = матрица, обмен через ExtState mx/gridkey |
| `jf_tracker_browser.lua` | сайдбар: files / db (Media Explorer) / pm (jf_pm), auto-превью, drag & drop (`B.drag`), Enter → депо трека (=LIB) |
| `jf_tracker_preview.lua` | предпрослушивание: аудио — CF_Preview через FX трека (SWS), MIDI — транспорт от строки |
| `jf_tracker_help.html` | справка: философия, архитектура, глоссарий хоткеев; открывается по F1 |
| `jf_tracker_keys.lua` | пианино INSERT-режима и коды спец-клавиш; файл пользователя |
| `tests/test_vim.lua` | Vim-слой на стабах: `lua tests/test_vim.lua` (81 проверка) |
| `tests/smoke_edit.lua` | живой прогон правок в песочнице (отказ вне песочницы), результат в ExtState `jf_tracker/smoke` |
| `tests/sandbox_regions.lua` | регионы-паттерны для песочницы |
| `tests/test_model.lua` | модель на стабах: `lua tests/test_model.lua` (68 проверок) |
| `tests/sandbox_setup.lua` | наполнить ПУСТУЮ вкладку тестовым материалом (отказ, если проект не пуст) |
| `tests/probe_state.lua` | счётчик состояния проекта → ExtState `jf_tracker/probe` |

Палитра — `Scripts/jf_looper/jf_looper_ui.lua` (цвета темы с проверкой
контраста WCAG; оттуда экспортированы `U.theme/readable/contrast/mix`).

## Модель

- Строки абсолютные от QN 0; `row, delay = row_of_qn(qn, lpb)`.
- Трек → колонка; `I_FREEMODE == 2` → lanes по `I_NUMFIXEDLANES`, имя
  `P_LANENAME:n`; items по `I_FIXEDLANE`. Трек `DEPOT` скрыт.
- Lane → подколонки (`subs`): нота занимает строки `[r0, r1]` в первой
  свободной подколонке. Один механизм для полифонии MIDI и перекрытия items.
- Аудио: голова = `нота vol delay`, строка ниже — имя take, дальше волна.
  Питч: `D_PITCH` + `12·log2(D_PLAYRATE)` при выключенном `B_PPITCH`;
  `C-4` = оригинал (MIDI 60). Vol: `0x80` = 0 dB (item·take).
- MIDI: `MIDI_GetAllEvts` → разбор потока `<i4Bs4>` (offset, flag, msg);
  `MIDI_GetProjQNFromPPQPos` → QN. Note-off = `OFF` (с delay). Нота короче
  строки — только голова, `OFF` в следующей строке. Зацикленный item
  (`B_LOOPSRC`) разворачивается через длину источника в QN (`MAX_UNROLL` 256).
- Кеш снимка: `GetProjectStateChangeCount | LPB | MIDI_GetTrackHash` всех
  треков (опрос хешей 4 Гц). Разобранные ноты кешируются по GUID take + `MIDI_GetHash`.
- Пики: `PCM_Source_GetPeaks(src, npix/span, offs, 1, npix, 0, buf)`, buf =
  max[n] ++ min[n]; биты 20..23 rv ≠ 0 → сырые сэмплы. Нет пиков →
  `PCM_Source_BuildPeaks` по 40 шагов за кадр, волна появляется позже.

## Клавиши

Нормальный режим (Vim):

| | |
|---|---|
| `h j k l` / стрелки | подколонка / строка; `H L` — трек; `0 $` — крайние колонки |
| `w b e` | событие вперёд / назад / конец события; `W B` — в любой подколонке трека |
| `gg G` `{ }` | начало / конец; такт назад / вперёд. `^D ^U ^F ^B` — страницы |
| `zz zt zb` | прокрутка к курсору |
| `za zc zo zM zR` | свернуть / развернуть трек — точки на событиях (fold как в Renoise) |
| `x` `dd` `d{motion}` | удалить событие / строку / диапазон (в регистр) |
| `yy` `y{motion}` `p` | скопировать / вставить у курсора (item — state chunk без GUID, нота — числами) |
| `c{motion}` `cc` | удалить и перейти в INSERT |
| `s` | разрезать по строке всё, что её накрывает (SplitMediaItem / две ноты) |
| `m` | mute (B_MUTE / muted ноты) |
| `^A ^X` | транспонировать ±1 (счётчик — на n); `r{нота}` — задать высоту |
| `u ^R` `.` | undo / redo (штатные) / повторить правку |
| `q{a-z} … q`, `@{a-z}`, `@@` | макросы |
| `i a` `v V` `:` | INSERT, VISUAL, V-LINE, командная строка |
| `[ ]` `( )` | октава −/+, инструмент депо −/+ |
| `F` `Space` `Enter` `Tab` | follow, play/stop, edit-курсор в строку, фокус матрицы |
| `+ -` | LPB |

INSERT: пианино (`z s x d c v g b h n j m , l . ; /` — октава, `q 2 w 3 e r 5 t 6 y 7 u i 9 o 0 p` —
октава+1), `1` — note-off (укоротить событие до строки), Backspace/Delete —
удалить, `[ ]` — октава, Esc. Вставка: MIDI-нота длиной `step` строк, если
на строке есть MIDI-item (или трек без аудио, иначе создаётся MIDI-item на
такт); иначе копия item из `DEPOT` (инструмент `inst`) с `D_PITCH` = нота − C-4.

VISUAL: движения расширяют блок, `d x y c m s ^A ^X r p o`, `Esc`.

`:` — `q`, `w` (сохранить проект), `wq`, `lpb N`, `step N`, `oct N`, `inst N`,
`fx N` (колонок команд, 0–4), `env` (огибающие), `preview` (прослушивание при
вводе), `follow`, `debug`, `fold`, `unfold`. `F1` — справка (html).

**Шрифт**: по умолчанию битмап REAPER ×2 (`:scale 1..4`): `D.text` рендерит
строку в offscreen (ключ строка+цвет+фон, слоты 100..999, сброс по кругу) и
блитит с масштабом; без подложки — аддитивно (gfx.mode 1), инверсные поля —
с подложкой. `:space N` — зазор над буквами (D.SPACE, в L.rh). `:font N` —
TTF. Все замеры через `D.measure/D.texth` (U.measure/U.texth в модулях).
Вертикальные имена матрицы — попиксельный поворот (vcache 1000..1022).
**a / A**: `a` — `state.envs`; `A` — `vim.open_picker` (fzf: подпоследовательность,
подстрока ранжируется выше) по параметрам автоматизации трека курсора: огибающие
трека через действия «Toggle track … envelope visible» (сканируются по тексту
в диапазонах 40400–40420, 40860–40870, 41860–41870) и `GetFXEnvelope(tr, fx,
param, true)` для параметров FX.
**Подсказки** `jf_tracker_hints.lua`: цели собираются при отрисовке
(`D.hint`/`ctx.hint` → `H.add`), `f` → `H.start` (метки из 12 букв × 2),
`H.key` → цель → `hint_go` в main (фокус + курсор/действие). Тест
`tests/test_hints.lua`.
**DSP-виджеты**: `p.kind` toggle|steps|slider из `TrackFX_GetParameterStepSizes`
+ `TrackFX_GetParamEx`; клик по тогглу переключает, ступени — целыми шагами.
**Реестр DSP-модулей** `jf_tracker_dspmods.lua` (`DM.match(fxname)` → {title,
cols, params={{подстрока имени, подпись}…}}); `M.track_fx` при совпадении
подбирает параметры по имени (`param_entry`), блок рисуется в `cols` колонок.
**Фокус клавиатуры** `state.focus` ∈ tracker | matrix | top | browser,
`ctx.set_focus(f)` (проверяет доступность, закрывает слайсер при уходе,
открывает его при входе на sample), Tab — `toggle_focus` по кругу; рамка
`D.FOCUS` (#ff00ff, 2 px) вокруг модуля в `D.frame` (top — `L.top_rect`).
Фокус top: sample → `SL.key`, modulation → j/k/l/a/p (`modsel`), scope → Esc.
**Вкладки верха** `:tab scope|sample|modulation`: sample — волна выбранного
инструмента + слайсы (двойной клик → слайсер); mod — `M.track_mods` через
TrackFX_GetNamedConfigParm `param.N.mod.active` + lfo/acs/plink, клик →
`E.mod_toggle` (SetNamedConfigParm).
**Живая матрица**: курсор на регионе → edit-курсор (если стоит); Space при
воспроизведении → очередь (`MX.queued`), прыжок `SetEditCurPos(seekplay)` на
границе текущего региона/такта в `process_queue` (точность кадра).
**Пул трека** (`col.pool`): уникальные аудио-источники items трека; items после
маркера `=LIB` (`snap.lib_pos`, `M.lib_pos()`) помечены `depot` (библиотека трека),
`E.depot_add(path, track)` кладёт файл после =LIB (`E.ensure_lib` ставит маркер на
такт после конца проекта), `E.drop(track, lane, lpb, row, path)` — item / сабпроект
(.rpp через InsertMedia) в строке. Трек DEPOT — наследие, читается, не создаётся;
полоска над заголовком с мини-волнами в цвет item; слот выбирают ⌘1..⌘0 и
⌘J/⌘K (цифры без ⌘ — чёрные клавиши верхнего ряда пианино); выбранный играет 1 с,
тоггл `[>] preview` под списком инструментов или `:poolprev`; note-off на `` ` ``.
**Мышь**: клик по событию выделяет item в REAPER, двойной — Item properties
(40009) / MIDI-редактор (40153); правый клик — контекстное меню по зоне
(`gfx.showmenu`, без разделителей — индексы прямые).
**`:`** показывает снизу список команд с описаниями (`V.COMMANDS`), Tab
дополняет/перебирает. **`/`** — поиск по имени/ноте/команде, `n`/`N`/`*`.
**Hydra** по лидеру `\`: which-key-всплывашка снизу с группами event / track /
pattern / view / instrument — те же builders действий, что у контекстного
меню (`event_actions`, `track_actions`, `region_actions`, `view_actions` в
main), у каждого действия своя клавиша. `?` — шпаргалка.
**F11 / `:dock`**: док ↔ плавающее окно на всю рабочую область
(`my_getViewport` + `gfx.dock(0, x, y, w, h)`); номер докера помнится в
ExtState `dock_last`. Шрифт по умолчанию 24 (gfx на Retina рисует 1:1),
контраст текста доведён до 7:1, у строки курсора янтарная верхняя кромка,
у строки edit-курсора зелёная. Пул — список над каждым треком в границах
его колонки: «N имя» + тонкая волна в цвет item.
**Слайсер**: тайм-коды в `P_EXT:jf_slices` + `jf_slice_base` (offs;len) у
item-инструмента; `E.insert_slice` копирует chunk и ставит offs/len; `Sxx` =
слайс (`E.item_slices`), beatsync → `Txx`; INSERT верхний ряд q..p = слайсы
1..10 при нарезанном инструменте. Транзиенты — своя детекция по
PCM_Source_GetPeaks 500 Гц (порог/отношение от чувствительности, зазор 40 мс).
Dxx/Uxx (питч-слайды) — этап 7, не сделано.
**Браузер** (`jf_tracker_browser.lua`): вкладки files/db (`B.mode`), базы
Media Explorer — `reaper.ini` секция `[reaper_sexplorer]` (`ShortcutN=NN.ReaperFileList`,
`ShortcutTN=DB: имя`), файлы — `MediaDB/NN.ReaperFileList` (`FILE "путь"`,
`DATA … l:м:сс`), кеш `B.dbcache`; 60 k файлов читаются ~0.7 с. Фильтр `/`
(`B.filter`, `B.set_all`), hover: число — строка, строка — кнопка шапки
(files/db/size/hide → `B.click`). Ширина — `state.sidenarrow` (16/26 символов).
**Шапка A M S R**: `A` — есть огибающие (контур), показаны (заливка); клик/хинт
`btn what='auto'` → `ctx.toggle_track_envs(col)` (`state.trackenvs[guid]` = true/false,
nil = как глобальный `state.envs`; ExtState `trackenvs` «guid=1,guid=0»), клавиша `a` →
`toggle_envs` (все + сброс поканальных). `o` в NORMAL → `ctx.reveal_item` (select item,
40913 scroll track, 41622 toggle zoom, JS_Window_SetForeground main). Рамка фокуса в
INSERT — `D.FOCUS_INS` красная, 3 px (`info.vmode`). Рамки items 2 px + заливка gfx.a 0.10.
**Рамки items / automation items**: модель кладёт в `lane.items`
`{item, r0, r1 (дробные строки = QN·LPB), midi, si (подколонка аудио; MIDI — вся
lane), rgb, sel, muted}` и в `e.ais` `{r0, r1, sel}` + `e.ai_key` (тема
`env_item_vol/pan/mute/pitch`, `M.track_envs(tr, lpb)`); draw рисует после
тела: кайма 1 px цветом item (U.mix к BG 0.45, выбранный — к TEXT 0.3), срез
по краю тела без кромки; AI — заливка gfx.a 0.28/0.45 + кайма. Живой тест
`tests/smoke_items.lua`, AI в песочнице — `tests/sandbox_ai.lua`.
**Огибающие интерактивны**: env-колонки в `L.flat` (`f.env`), `E.env_set/
env_del/env_nudge` (точка в пределах tol = полстроки → SetEnvelopePoint,
иначе InsertEnvelopePoint; значения 0..1 от min/max BR_EnvGetProperties),
мышь: клик/протяжка (env_drag ключ без повторов), правый клик удалить,
колесо 1/64; цвет — ключ темы по имени (`e.key`). Клавиатура (vim, `env_of(fi)`):
INSERT hex-пара → `ctx.env_set`, BS → `env_del`; NORMAL x/BS → `env_del`,
^A/^X → `env_nudge`. **Текстовые макросы (этап 10)**: `/` `\` на огибающей —
`E.env_ramp(e, t0, t1, v0|nil, v1)` (DeleteEnvelopePointRange между концами +
две точки, один undo-блок) за 1 бит; `:ramp xx [len|Nb]` (в VISUAL — по
выделению, `V.cmd_from` помнит режим до `:`); на vol аудио `/` `\` и
`:fade in|out [len]` — команды Ixx/Oxx (xx = строки·16). Живой тест
`tests/smoke_ramp.lua`: 2 точки, середина = (v0+1)/2, undo возвращает.
**Секвенсер паттернов**: `model.patterns(regions)` (имя → номер/источник/число
в последовательности), маркер `=LIB` отделяет библиотеку (`rg.lib`);
`alias.set_slot(regions, slot, pat)` — в библиотеку единственный экземпляр
(`move_to_lib`), удалить items слота, `shift_after(end, delta)` (items всех
треков кроме DEPOT + маркеры/регионы через SetProjectMarkerByIndex), регион
переименовать и удлинить, скопировать источник. Матрица рисует только
последовательность (`ctx.sequence()`), стрелки `< >` у номера, клавиши `<`/`>`.
Вертикальные имена — `D.vtext` (offscreen-буфер 900 + gfx.blit −90°).
Огибающие — `M.ENV_SUB` подточек на строку. `e` — граница после события.
**Матрица**: «NN имя» (индекс региона), сетка ячеек, зум `z`/`:mxzoom`:
схема (полоска загруженности) ↔ микровид (штрихи событий по позициям).
**Пик-метры** `:meters` — поверх колонок от низа колонки вверх, высота =
уровень × высота тела, альфа 0.45.
**Огибающие** — линия как в аранжировке (draw_env_cell с prev). **Шапка**:
M/S/R кнопки (hover.btn), папки через `GetTrackDepth`/`I_FOLDERDEPTH`.
**Разделители модулей** 2 px (D.SEP).
**Раскладка**: коды клавиш переводятся по физическому положению (ЙЦУКЕН →
QWERTY, таблица `keys.layout` в `jf_tracker_keys.lua`, `keys.translate`) до
диспетчера — Vim-команды, пианино и hex работают в русской раскладке.
**Курсор** — инверсное поле (нота / vol / delay / команда), его строка
подсвечена на всю ширину; `h`/`l` идут по полям, через границу подколонки.
`^A`/`^X` меняют поле под курсором; в INSERT на полях vol/delay — две hex-цифры,
на команде — буква + две; `r` — то же без шага вниз; Backspace сбрасывает поле.
`:pitchmode shift|resample` — режим питча трека (ExtState по GUID трека).
**Алиасы (этап 6)**: регионы с одним именем — один паттерн; после каждой
правки регион под курсором переписывает одноимённые (`jf_tracker_alias.lua`,
хук `edit.after` в том же undo-блоке; `:autosync`, `:sync`). В матрице `y`/`p` —
запомнить регион / его повтор в конце проекта.
**Колонки команд** (показ, этап 5): `9xx` offset, `8xx` pan, `Ixx`/`Oxx` fades
(строки × 16), `L01` loop, `M0x` канал, `Sxx` beatsync, `Pxx` дробный питч —
из свойств item/take; лишние — строками ниже головы.
**Огибающие** трека (видимые, активные; диапазон из `BR_EnvGetProperties`) —
колонки справа от lanes: полоска = значение 0..1, hex — где точка.
**Превью при вводе**: аудио — `CF_CreatePreview` источника депо с `D_PITCH`
через `CF_Preview_SetOutputTrack` (звучит через FX трека); MIDI — play от
строки на `step` строк, затем stop и возврат edit-курсора (только если
проект стоит).

Матрица (Tab): `h j k l` — ячейка (трекер прокручивается к региону),
`m`/Enter — mute всех items ячейки, `g G`, Tab/Esc — назад. Мышь: клик —
ячейка, правый клик — mute.

## Проверено живьём (30 сен 2026, песочница, REAPER 7.81)

Правки (`tests/smoke_edit.lua`, реальный проект): `x`/`u` на item и на
MIDI-ноте, `yy`+`p` (+1 item), `s` (+1), `2^A` → D_PITCH 2.0, `m`, `iz` →
нота, `i1` → OFF в строке, `Vjd` (−1), mute ячейки матрицы; undo-блоки
подписаны `jf_tracker: …`.


- Аудио: голова `D-4 80` у item с rate 2^(2/12) без preserve pitch, `C-3` у
  `D_PITCH = -12`; перекрывающийся item ушёл во вторую подколонку; item ровно
  в одну строку не даёт `cont`; muted — серым.
- Lanes: трек с 2 fixed lanes → две lane-колонки с именами.
- MIDI: полифония по подколонкам, `OFF` в строке конца, нота на 1/8 строки
  позже → `delay 80`, зацикленный item повторил ноты через такт.
- DEPOT не показан. Счётчик состояния проекта за время работы окна не рос
  (рост давали только play/stop и сам запуск скриптов через `-nonewinst`).
- Первый снимок вскрыл наложение волны на текст головы — исправлено:
  волна рисуется со строки после имени.

Не проверено: раскладка на светлой теме; поведение на проекте с сотнями
треков (снимок строится по всему проекту); `TimeMap2_timeToBeats` в статусе
при нестандартных размерах.

## Ограничения и ловушки

- **Один экземпляр**: при старте пишется ExtState `jf_tracker/owner` = свой id;
  экземпляр с чужим id в owner выходит. Запуск из Actions / `-nonewinst` /
  `run_tracker.lua` всегда перехватывает окно, дублей нет.
- **Перезапуск окна снаружи** — только `tests/run_tracker.lua` (pcall + ExtState
  `err_load`) и только когда пульс `jf_tracker/hb` остановился: прямой
  `REAPER -nonewinst jf_tracker.lua` при живом экземпляре вешает диалог
  «ReaScript task control» (окна нет, ошибок нет; диагностика —
  `tests/probe_dialogs.lua`), а гонка «quit-флаг ↔ новый экземпляр» даёт два
  экземпляра. Пульс: `hb` = время, треки, режим, fps и профиль кадра в мс.

- Битмап-шрифт мелкий на Retina. Переход на TTF — одна строка в `D.layout`
  (`gfx.setfont(1, 'JetBrainsMono Nerd Font', N)`), ширины всё равно меряются.
- MIDI-item с `D_PLAYRATE ≠ 1` и циклом: период повтора берётся от длины
  источника без учёта rate.
- `BR_GetMediaItemGUID` (SWS) для ключей кеша; без SWS — `tostring(item)`.
- Сброс edit-курсора при stop и запуск скрипта через `REAPER -nonewinst`
  увеличивают `GetProjectStateChangeCount` — это не изменения проекта.
- В песочнице `P_LANENAME:1` не записалось до появления item на lane —
  трекер показал запасное `L2`.

## Дальше (по хандоверу)

- `.` после операции в VISUAL повторяет только оператор (Vim повторил бы блок
  того же размера).
- Регионы через `EnumProjectMarkers3` (discouraged, но сигнатуры новых
  `GetRegionOrMarker*` в строках бинарника нет) — заменить, когда появится
  документация.
- Этап 7 СДЕЛАН (`jf_tracker_cmds.lua`): U/D/G/4/0/A/R/P/F в `P_EXT:jf_cmds`,
  `C.rebuild` очищает take Pitch/Volume внутри item (DeleteEnvelopePointRange,
  время точек = (t − pos)·rate) и генерирует заново; take-огибающие создаются
  действием «Take: Toggle take … envelope» (41612 pitch, ищется по тексту);
  MIDI U/D — pitchbend CC 0xE0 с линейной формой. `Bxx` — jump в слот xx: исполняется трекером в кадре по строке плейхеда
  (process_jumps). Не сделано: 1xx/2xx/3xx как алиасы, break (D занят слайдом).
  Paketti: пользователь ждёт разрешения автора — посмотреть, что брать.
- Nerd-иконки: на битмапе невозможны (ASCII-набор REAPER); в TTF-режиме
  (JetBrainsMono Nerd Font) — можно, гибрид: второй слот шрифта только для
  иконок (M/S/R, play, вкладки).
- Осциллоскопы СДЕЛАНЫ: `Effects/jf_tracker_scope.jsfx`
  (`options:gmem=jf_tracker_scope`, слот×512: кольцо 256 сэмплов ~8 кГц,
  [256] указатель, [257] heartbeat); `:scopes` → `E.scopes(cols, on)`
  (find-or-add instantiate −1, slider1 = индекс трека; off — TrackFX_Delete);
  main читает gmem (`gmem_attach` один раз) и рисует во вкладке scope.
  Валидатор JSFX: `Scripts/jf_grid/jf_validate_jsfx.py` — чисто.
- DSP-панель СДЕЛАНА: `:dsp` → `L.dsp_h` (18 % высоты), `M.track_fx`
  (имя, enabled, первые 8 параметров) в снимке, `M.fx_values` на кадр
  (кеш fxv_cache), `E.fx_param/fx_bypass/fx_show/fx_add/fx_remove`;
  фокус 'dsp' (h/l/j/k, ^A/^X ±2 %, b, o, x, a — fzf по EnumInstalledFX,
  A — fzf параметров → GetFXEnvelope); мышь: клик/протяжка/колесо/dblclick.
  Автоматизация остаётся в колонке (решение пользователя).
- Папки треков: вложенность показана сдвигом и приглушением шапки (сделано),
  далее — сворачивание папки целиком.
- Запись: `:rec`, `:input` (hydra входов), `:smartin` (jf_smart_set_input
  по выбранному треку) — сделано; punch/overdub в lanes — этап 8.
- Этап 8: лайв-секвенсор регионов (очередь — сделано), запись в lanes.
- Этап 9 НАЧАТ: `daemon_tracker.lua` — модуль демона jf_grid (id 9, в
  MODULES; метка присутствия в INSTR — JSFX `jf_tracker_scope`, т.е. мод
  виден в списке миграции при `:scopes`). Протокол ExtState: трекер пишет
  `jf_tracker/mx` (nrows,ncols,cur,play,queue;ячейки), модуль рисует грид
  (ряды = слоты, колонки = треки, яркости 1/6/3/12/9/15) и пишет
  `jf_tracker/gridkey` «x,y,n»; трекер ставит регион в очередь / играет.
  Дальше: arc (LPB/octave/step), нижний ряд как транспорт, интеграция с
  гранулятором и слайсером экосистемы.

## 1 октября: большая партия

- Tab/Shift-Tab глобально (main, до диспетчера фокуса); фокус `inst` (панель
  инструментов, `L.inst_rect`). `ctx.toggle_focus(dir)`.
- Жёсткие паттерны: `A.trim(regions)` (split по началу региона, D_LENGTH по
  концу), хук `edit.after` + кнопка/`t`/`:trim`. Время в регионе:
  `E.time_delete/E.time_insert(tracks, t0, t1|dt, limit)` + `env_shift`
  (точки и AI); `ctx.time_edit(what, fi, row, n, all)`; vim BS/INS/`I`.
- Матрица детальный зум: `L.mx_row_h`, `MX.DETAIL_ROWS`, `grid.ev[].rgb`,
  `grid.envs` (`M.env_samples`), `info.env_shown`, `ctx.env_colour`.
- Колонка волны: `L.w_wave/x_wave`, `state.wave`, `M.peaks(head, n, want_spec)`
  (extra 115 → `out.spec`, цвет = частота в младших 15 битах); отрицательный
  кеш пиков с повтором через 2 с (офлайн-медиа).
- Мост спектра: `jf_tracker_scope.jsfx` FFT 1024/Ханн → 48 полос в
  gmem[base+260..307], кадр в [259]; draw `draw_analyzer` (scope/spec/sgram,
  спектрограмма в изображении 1024+slot); `state.scopemode`; вкладка scope
  убрана, анализаторы в `master` (слот 31, `E.MASTER_SCOPE_SLOT`).
- gmem-переключение: `with_ns(ns, fn)` в main; шина jf_mono [0..4] (4 Hz,
  `mono_read`, запрос владения gmem[2] = 9 / -1); jf_rec: владелец gmem[26],
  ширина [4], экранный слой 1000000/1050000 по индексу кольца (развёртка от
  головы), почтовый ящик 10..15, превью 16..18, alive [30]; `retro_put`,
  `retro_preview`; `col.rec_slot`; `E.retro_add`.
- Сэмпл-модуль: `S.sel`, `S.open_file` (PCM-источник файла), `S.mouse_*`,
  `E.insert_span(track, lane, lpb, row, entry, t0, t1, pos)`, `E.depot_span`;
  вынос выделения → `ctx.drop_span`. Браузер `v` → `ctx.sample_view`.
- DSP: контейнеры (`container_count`, `container_item.K`, `parallel`;
  `f.kids`, параметры детей с `p.fx`), drag блоков → `E.fx_move`
  (TrackFX_CopyToTrack move), правый клик → `E.mod_set(track, fx, param,
  what, on, src_fx, src_param)`, `ctx.cmd_by_text`.
- Браузер pm внутрь проекта: `B.scan_project(path)` (текст .rpp: TRACK-chunk с
  абсолютными FILE, samples, MARKER → regions/markers), `E.insert_track_chunk`,
  `E.drop_region`; `wave` → `M.file_peaks(path, n)` (кеш источников ≤ 300).
- Ресайз: `state.side_px`, `state.top_px` (ExtState), `resize_drag`.
- Иконки: `D.icons`, `D.ic(name, text)`, `ctx.ic`, `:icons` (TTF).
- **Баг ctx (1 окт)**: `local ctx = {…}` — функции внутри ссылались на глобальный
  `ctx` (nil): локаль не видна в собственном инициализаторе. Теперь `local ctx;
  ctx = {…}`. Падали Tab и всё, что звало `ctx.*` изнутри таблицы.
- Инъекция клавиш для живых тестов: ExtState `jf_tracker/inject` = «код[,cap]#n»
  (cap подменяет mouse_cap для `ctx.mods`). reaper-keys: мост в `internal/rk.lua`
  (бэкап `rk.lua.bak.*`) — Tab/Shift-Tab при фокусе окна jf_tracker → inject.
- Пики: офлайн-источник → `M.online_src` (свежий PCM из файла); «все нули» не
  кешируются (повтор через 1 с); пики на диске — `BuildPeaks(src,2)` и перечитать.
- Паттерны: `M.patterns` сортирует по имени, `p.num` = позиция; `slot_cycle`
  перечитывает регионы сразу. Матрица: `L.mx_dur_w`, длина в тактах.
- Блок матрицы: `MX.anchor`, `MX.block()`, `A.cells_mute/copy/paste/delete`,
  `ctx.mx_block(what)`.
- Слайсер: `commit()` пишет нарезку сразу; `S.view` peaks/spec/sgram
  (спектрограмма — аудио-аксессор take, FFT 512 в Lua, кеш-изображения 1100..1180);
  копии через `insert_chunk` не наследуют `P_EXT:jf_slices`.
- INSERT-нота: голова — `E.delete` + вставка; продолжение — `E.note_off` + вставка;
  Shift — рядом. `range_or_event` для d/c/y + движение из пустоты.

## Версия и установка

Текущая версия — в `jf_tracker_version.lua` (Options → about показывает список изменений).
Папка `Scripts/jf_tracker/` целиком, плюс `effects/jf_tracker_scope.jsfx` → `REAPER/Effects/`
(мост осциллоскопа, метка присутствия для модуля грида). Тесты без REAPER:
`lua tests/test_vim.lua`, `lua tests/test_model.lua`, `lua tests/test_orca.lua`, `lua tests/test_garden.lua`.
Смоуки (`tests/smoke_*.lua`) запускаются только во вкладке-песочнице с треками «A drums» / «B lanes».
