-- jf_tracker_dspmods.lua — реестр модулей DSP-панели. ФАЙЛ ПОЛЬЗОВАТЕЛЯ.
--
-- Эффект без записи здесь показывается «как есть»: первые параметры,
-- виджет по типу (тоггл / ступени / полоска). Запись в реестре — кураторский
-- вид: какие параметры показать, в каком порядке, с какой подписью, в
-- сколько колонок. Параметры ищутся по ПОДСТРОКЕ имени (как его отдаёт
-- TrackFX_GetParamName), поэтому индексы слайдеров не важны.
--
-- match — подстрока имени FX (без префикса «JS: » / «VST: »), без регистра.

local DM = {}

DM.modules = {
  {
    match = 'jf_slixer',
    title = 'slixer',
    cols = 2,
    params = {
      { 'Slice mode',            'slice mode' },
      { 'Transient sensitivity', 'sens' },
      { 'Equal parts',           'parts' },
      { 'Zero-cross',            'zero-x' },
      { 'Trigger mode',          'trigger' },
      { 'LOOP',                  'loop' },
      { 'Stretch (all slices)',  'stretch' },
      { 'Master gain',           'gain' },
      { 'Voice mode',            'voice' },
      { 'Legato',                'legato' },
      { 'Glide',                 'glide' },
      { 'Input quantize',        'quantize' },
      { 'ARP: on',               'arp' },
      { 'ARP: rate',             'arp rate' },
      { 'ARP: order',            'arp order' },
      { 'FX dry/wet',            'dry/wet' },
    },
  },
  {
    match = 'reaeq',
    title = 'ReaEQ',
    cols = 2,
    params = {
      { 'Freq-Low Shelf', 'lo freq' }, { 'Gain-Low Shelf', 'lo gain' },
      { 'Freq-Band 2', 'b2 freq' }, { 'Gain-Band 2', 'b2 gain' },
      { 'Freq-Band 3', 'b3 freq' }, { 'Gain-Band 3', 'b3 gain' },
      { 'Freq-High Shelf', 'hi freq' }, { 'Gain-High Shelf', 'hi gain' },
    },
  },
}

-- найти запись по имени FX
function DM.match(fxname)
  local n = (fxname or ''):lower()
  for _, m in ipairs(DM.modules) do
    if n:find(m.match, 1, true) then return m end
  end
  return nil
end

return DM
