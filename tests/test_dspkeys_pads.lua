-- test_dspkeys_pads.lua — режим пэдов drumrs5k в DSP (19 окт): Enter на рэке, h j k l, x, yy yp, p, M S, Esc
package.path = './?.lua;' .. package.path
local DK = dofile('jf_tracker_dspkeys.lua')
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end
local calls = {}
local function rec(s) return function(...) local a = { ... }; calls[#calls + 1] = s .. (a[2] ~= nil and (':' .. tostring(a[2])) or '') end end
local ctx = { msg = function() end, pad_rack = function(k) return k == 2 end,
  pad_nav = rec('nav'), pad_cut = rec('cut'), pad_yank = rec('yank'), pad_dup = rec('dup'), pad_paste = rec('paste'),
  pad_ms = rec('ms'), pad_listen = rec('listen'), pad_route_cur = rec('route'), dsp_enter = rec('enter'), play_stop = rec('play') }
DK.init(ctx)
local function key(s, sel) for ch in s:gmatch('.') do DK.key(ch:byte(), sel, 3, 5, {}) end end
local function last() return calls[#calls] end
local sel = { fx = 1, param = 1 }
DK.key(13, sel, 3, 5, {}); eq('Enter on a plain fx: dsp_enter', last(), 'enter:1'); eq('…no pads', DK.pads, nil)
sel.fx = 2; DK.key(13, sel, 3, 5, {}); eq('Enter on a rack: pads mode', DK.pads, true)
key('l', sel); eq('l: next note', last(), 'nav:1')
key('k', sel); eq('k: a row up (+4)', last(), 'nav:4')
key('j', sel); eq('j: a row down', last(), 'nav:-4')
key('x', sel); eq('x cuts the pad', last(), 'cut')
key('yy', sel); eq('yy takes it', last(), 'yank')
key('yp', sel); eq('yp duplicates', last(), 'dup')
key('p', sel); eq('p pastes', last(), 'paste')
key('M', sel); eq('M mute', last(), 'ms:false')
key('S', sel); eq('S solo', last(), 'ms:true')
DK.key(13, sel, 3, 5, {}); eq('Enter listens', last(), 'listen')
eq('pads: h does not move the fx', sel.fx, 2)
DK.key(27, sel, 3, 5, {}); eq('Esc leaves pads', DK.pads, nil)
key('h', sel); eq('then h moves fx again', sel.fx, 1)
print(('%d checks, %d failed'):format(n, bad))
if bad > 0 then os.exit(1) end
