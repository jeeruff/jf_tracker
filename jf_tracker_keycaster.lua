-- jf_tracker_keycaster.lua (6 ноя) — панель keycaster: обычная QWERTY-клавиатура, нажатые клавиши горят и гаснут
-- за полсекунды (для показа, как работает трекер: видно и буквы, и модификаторы). Состояние клавиш — снаружи:
-- KC.draw получает down(vk) → true, если клавиша VK держится (main: JS_VKeys_GetState). Раскладка — в долях
-- ширины клавиши u: ряд Esc F1..F12, цифры, три буквенных ряда, нижний с пробелом и стрелками.

local KC = {}

-- { подпись, VK, ширина в u }; VK — коды Windows (SWELL на macOS: Cmd = VK_CONTROL 17, Control = VK_LWIN 91)
local function row(...) return { ... } end
KC.ROWS = {
  row({ 'esc', 27, 1.5 }, { 'F1', 112, 1 }, { 'F2', 113, 1 }, { 'F3', 114, 1 }, { 'F4', 115, 1 }, { 'F5', 116, 1 }, { 'F6', 117, 1 },
      { 'F7', 118, 1 }, { 'F8', 119, 1 }, { 'F9', 120, 1 }, { 'F10', 121, 1 }, { 'F11', 122, 1 }, { 'F12', 123, 1.5 }),
  row({ '`', 192, 1 }, { '1', 49, 1 }, { '2', 50, 1 }, { '3', 51, 1 }, { '4', 52, 1 }, { '5', 53, 1 }, { '6', 54, 1 }, { '7', 55, 1 },
      { '8', 56, 1 }, { '9', 57, 1 }, { '0', 48, 1 }, { '-', 189, 1 }, { '=', 187, 1 }, { 'bs', 8, 2 }),
  row({ 'tab', 9, 1.5 }, { 'q', 81, 1 }, { 'w', 87, 1 }, { 'e', 69, 1 }, { 'r', 82, 1 }, { 't', 84, 1 }, { 'y', 89, 1 }, { 'u', 85, 1 },
      { 'i', 73, 1 }, { 'o', 79, 1 }, { 'p', 80, 1 }, { '[', 219, 1 }, { ']', 221, 1 }, { '\\', 220, 1.5 }),
  row({ 'caps', 20, 1.75 }, { 'a', 65, 1 }, { 's', 83, 1 }, { 'd', 68, 1 }, { 'f', 70, 1 }, { 'g', 71, 1 }, { 'h', 72, 1 }, { 'j', 74, 1 },
      { 'k', 75, 1 }, { 'l', 76, 1 }, { ';', 186, 1 }, { "'", 222, 1 }, { 'enter', 13, 2.25 }),
  row({ 'shift', 16, 2.25 }, { 'z', 90, 1 }, { 'x', 88, 1 }, { 'c', 67, 1 }, { 'v', 86, 1 }, { 'b', 66, 1 }, { 'n', 78, 1 }, { 'm', 77, 1 },
      { ',', 188, 1 }, { '.', 190, 1 }, { '/', 191, 1 }, { 'shift', 16, 2.75 }),
  row({ 'ctrl', 'ctrl', 1.25 }, { 'opt', 18, 1.25 }, { 'cmd', 'cmd', 1.5 }, { 'space', 32, 5.5 }, { 'cmd', 'cmd', 1.5 }, { 'opt', 18, 1.25 },
      { '<', 37, 1 }, { 'v', 40, 1 }, { '^', 38, 1 }, { '>', 39, 1 }),
}
KC.W = 15   -- ширина ряда в u
KC.FADE = 0.5
KC.lit = {}  -- [vk] = время последнего «держится»

-- vk модификатора по ОС: на macOS SWELL отдаёт Cmd как VK_CONTROL (17), Control — как VK_LWIN (91)
function KC.vk(v, mac)
  if v == 'cmd' then return mac and 17 or 91 end
  if v == 'ctrl' then return mac and 91 or 17 end
  return v
end

-- x y w h — прямоугольник панели; U — jf_tracker_ui (set, text, measure, mix, tint, цвета); down(vk) — держится ли;
-- now — время; mac — macOS
function KC.draw(U, x, y, w, h, down, now, mac)
  U.set(U.PANEL); gfx.rect(x, y, w, h, 1)
  local pad = 4
  local u = math.floor((w - 2 * pad) / KC.W)
  local kh = math.floor((h - 2 * pad) / #KC.ROWS)
  kh = math.min(kh, math.floor(u * 1.1))
  if u < 6 or kh < 6 then U.text(x + pad, y + pad, 'keycaster: too small', U.GREY); return end
  local th = gfx.texth
  local y0 = y + pad + math.max(0, math.floor((h - 2 * pad - kh * #KC.ROWS) / 2))
  local x00 = x + pad + math.max(0, math.floor((w - 2 * pad - u * KC.W) / 2))
  for ri, r in ipairs(KC.ROWS) do
    local kx = x00
    local ky = y0 + (ri - 1) * kh
    for _, k in ipairs(r) do
      local kw = math.floor(k[3] * u + 0.5)
      local vk = KC.vk(k[2], mac)
      if down and down(vk) then KC.lit[vk] = now end
      local age = KC.lit[vk] and (now - KC.lit[vk]) or 99
      local a = age < KC.FADE and (1 - age / KC.FADE) or 0
      local held = age < 0.05
      local base = U.mix(U.BG, U.TEXT, 0.12)
      local fill = a > 0 and U.mix(base, U.AMBER, held and 0.85 or 0.25 + 0.6 * a) or base
      U.set(fill); gfx.rect(kx + 1, ky + 1, kw - 2, kh - 2, 1)
      U.set(a > 0 and U.AMBER or U.LINE); gfx.rect(kx + 1, ky + 1, kw - 2, kh - 2, 0)
      local lab = k[1]
      if U.measure(lab) > kw - 4 then lab = lab:sub(1, math.max(1, math.floor((kw - 4) / math.max(1, U.measure('W'))))) end
      if kh - 2 >= th then
        U.text(kx + math.floor((kw - U.measure(lab)) / 2), ky + math.floor((kh - th) / 2), lab, a > 0.4 and U.BG or U.TEXT, fill)
      end
      kx = kx + kw
    end
  end
end

return KC
