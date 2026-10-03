-- test_options.lua — окно Options на стабах: lua tests/test_options.lua
-- cycle — значения кнопками в ряд,
-- num — слайдер (клик и протяжка), toggle — клик.
package.path = './?.lua;' .. package.path
_G.gfx = { mouse_x = 0, mouse_y = 0, mouse_cap = 0, rect = function() end }
local U = { measure = function(s) return #s * 8 end, set = function() end, text = function() end, tint = function(c) return c end,
  BG = {}, TEXT = {}, AMBER = {}, LINE = {}, GREY = {}, CYAN = {}, DIM = {}, PANEL = {}, RED = {} }
local O = dofile('jf_tracker_options.lua')
O.init(U, { fit = function(s) return s end, mods = function() return {} end })
local st = { theme = 'reaper', alpha = 5, on = false }
O.open({
  { key = 't', label = 'theme', kind = 'cycle', values = { 'reaper', 'mono', 'gruvbox' }, get = function() return st.theme end, set = function(v) st.theme = v end },
  { key = 'a', label = 'alpha', kind = 'num', min = 0, max = 60, step = 1, fmt = '%d %%', get = function() return st.alpha end, set = function(v) st.alpha = v end },
  { key = 'o', label = 'flag', kind = 'toggle', get = function() return st.on end, set = function(v) st.on = v end },
})
local L = { rh = 16, pad = 4, cw = 8 }
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end end
local function at(x, y) gfx.mouse_x, gfx.mouse_y = x, y; O.draw(L, 1200, 800) end
O.draw(L, 1200, 800)
local r1, r2, r3 = O.vrect[1], O.vrect[2], O.vrect[3]
-- cycle: значения кнопками в ряд — клик по второй кнопке ставит mono
local bx2 = r1[1] + (#'reaper' * 8 + 8 + 2) + 4          -- вторая кнопка: после 'reaper' (ширина + 2 pad + 2)
at(bx2, r1[2] + 2)
eq('button hover', O.hbtn and O.hbtn.k, 2)
O.click(gfx.mouse_x, gfx.mouse_y)
eq('picked mono', st.theme, 'mono')
-- описание внизу — у строки под мышью
eq('hover row', O.hover, 1)
-- num: клик посередине дорожки ≈ 30, протяжка в конец = 60
at(r2[1] + math.floor(r2[3] / 2), r2[2] + 2); O.click(gfx.mouse_x, gfx.mouse_y)
eq('slider middle', math.abs(st.alpha - 30) <= 1, true)
gfx.mouse_cap = 1; at(r2[1] + r2[3] + 50, r2[2] + 2)
eq('drag to max', st.alpha, 60)
gfx.mouse_cap = 0; at(0, 0)
eq('drag ends', O.drag, nil)
-- toggle
at(r3[1] + 2, r3[2] + 2); O.click(gfx.mouse_x, gfx.mouse_y)
eq('toggle', st.on, true)
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
