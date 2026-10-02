-- Harness for colourtemp.koplugin/main.lua: stub KOReader modules and drive
-- the plugin through init, menu, settings, dispatcher events, the natural
-- light emulation and the one-time gesture assignment.
-- usage: luajit test_main.lua <plugin dir> [android|desktop|eink]
local dir = arg[1] or "."
local mode = arg[2] or "android"

local checks, failed = 0, 0
local function check(cond, msg)
    checks = checks + 1
    if not cond then
        failed = failed + 1
        print("FAIL: " .. msg)
    end
end

-- ---------- stubs ----------
local settings = {}
G_reader_settings = {
    readSetting = function(_, k) return settings[k] end,
    saveSetting = function(_, k, v) settings[k] = v end,
    isTrue = function(_, k) return settings[k] == true end,
    nilOrTrue = function(_, k) return settings[k] == nil or settings[k] == true end,
}

local Screen = { bb = { getInverse = function() return 0 end } }
local Class = {}
Class.__index = Class
Class._updateWindow = function() end
Class.getWidth = function() return 1000 end
Class.getHeight = function() return 2000 end
setmetatable(Screen, Class)

-- A BasePowerD-like power device: setWarmth is the real upstream logic.
local hw_calls = {}
local Powerd = {
    fl_warmth_min = 0, fl_warmth_max = 100, warmth_scale = 1, fl_warmth = nil,
}
function Powerd:normalizeWarmth(w) return math.max(0, math.min(100, w)) end
function Powerd:toNativeWarmth(w) return math.floor(w / self.warmth_scale + 0.5) end
function Powerd:fromNativeWarmth(w) return math.floor(w * self.warmth_scale + 0.5) end
function Powerd:frontlightWarmth()
    if not Device:hasNaturalLight() then return 0 end
    return self.fl_warmth
end
function Powerd:setWarmth(warmth, force)
    if not Device:hasNaturalLight() then return false end
    if not force and warmth == self:frontlightWarmth() then return false end
    self.fl_warmth = self:normalizeWarmth(warmth)
    self:setWarmthHW(self:toNativeWarmth(self.fl_warmth))
    return true
end
function Powerd:setWarmthHW(w) table.insert(hw_calls, w) end
function Powerd:frontlightWarmthHW() return 0 end

Device = {
    screen = Screen,
    isAndroid = function() return mode ~= "desktop" end,
    hasEinkScreen = function() return mode == "eink" end,
    hasNaturalLight = function() return false end,
    getPowerDevice = function() return Powerd end,
}
local registered, removed = {}, {}
local Dispatcher = {
    registerAction = function(_, name, def) if registered[name] == nil then registered[name] = def end end,
    removeAction = function(_, name) registered[name] = nil; removed[name] = true end,
}
-- pretend KOReader registered its stock warmth actions as disabled
registered.increase_frontlight_warmth = { condition = false }
registered.decrease_frontlight_warmth = { condition = false }
registered.set_frontlight_warmth = { condition = false }

local notifications = {}
local Notification = { notify = function(_, text) table.insert(notifications, text) end }
local shown = {}
local SpinWidget = { new = function(_, o) table.insert(shown, o); return o end }
local dirty = 0
local ticks = {}
local UIManager = {
    setDirty = function() dirty = dirty + 1 end,
    show = function() end,
    nextTick = function(_, fn) table.insert(ticks, fn) end,
}
local WidgetContainer = { extend = function(self, o) o.__index = o; return setmetatable(o, { __index = self }) end }
local logger = { warn = function() end, dbg = function() end }
local reader_order = { setting = { "frontlight", "night_mode", "----------------------------", "network", "screen" } }
local fm_order = { setting = { "frontlight", "night_mode", "network" } }
local BB = { new = function() end, getUseCBB = function() return true end, ColorRGB24 = function(r, g, b) return { r = r, g = g, b = b } end }

package.preload["device"] = function() return Device end
package.preload["ffi/blitbuffer"] = function() return BB end
package.preload["dispatcher"] = function() return Dispatcher end
package.preload["ui/widget/notification"] = function() return Notification end
package.preload["ui/widget/spinwidget"] = function() return SpinWidget end
package.preload["ui/uimanager"] = function() return UIManager end
package.preload["ui/widget/container/widgetcontainer"] = function() return WidgetContainer end
package.preload["logger"] = function() return logger end
package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.preload["ffi/util"] = function()
    return { template = function(s, ...)
        local args = { ... }
        return (s:gsub("%%(%d)", function(n) return tostring(args[tonumber(n)]) end))
    end }
end
package.preload["ui/elements/reader_menu_order"] = function() return reader_order end
package.preload["ui/elements/filemanager_menu_order"] = function() return fm_order end

-- ---------- load ----------
local chunk = assert(loadfile(dir .. "/main.lua"))
local Plugin = chunk()

if mode ~= "android" then
    check(type(Plugin) == "table" and Plugin.disabled == true, mode .. ": plugin disabled")
    check(Device:hasNaturalLight() == false, mode .. ": device untouched")
    print(string.format("%d checks, %d failed", checks, failed))
    os.exit(failed == 0 and 0 or 1)
end

-- ---------- natural light emulation (module level) ----------
check(Plugin.emulating == true, "emulation installed at module load")
check(Device:hasNaturalLight() == true, "device now reports natural light")
check(Powerd.fl_warmth_max == 100 and Powerd.warmth_scale == 1, "powerd warmth range 0..100")
check(Powerd.fl_warmth == 66, "initial fl_warmth derived from default 3400 K (66 %), got " .. tostring(Powerd.fl_warmth))
check(Plugin.warmthFromKelvin(6500) == 0 and Plugin.warmthFromKelvin(1800) == 100, "warmth endpoints")
check(Plugin.kelvinFromWarmth(0) == 6500 and Plugin.kelvinFromWarmth(100) == 1800 and Plugin.kelvinFromWarmth(50) == 4150, "kelvin endpoints and midpoint")
for w = 0, 100 do
    if Plugin.warmthFromKelvin(Plugin.kelvinFromWarmth(w)) ~= w then
        check(false, "warmth round trip fails at " .. w)
        break
    end
end

-- ---------- instance ----------
local function newUI()
    local ui = {
        menu = { registerToMainMenu = function() end },
        post_init = {},
    }
    ui.registerPostInitCallback = function(self, cb) table.insert(self.post_init, cb) end
    return ui
end
local function newInstance(ui)
    local inst = setmetatable({ ui = ui }, { __index = Plugin })
    inst:init()
    return inst
end

local ui = newUI()
local inst = newInstance(ui)
check(inst.hooked == true, "screen hooked")
check(registered.colourtemp_toggle and registered.colourtemp_set and registered.colourtemp_warmer and registered.colourtemp_cooler, "four own dispatcher actions registered")
check(registered.colourtemp_set.category == "absolutenumber" and registered.colourtemp_set.min == 1800 and registered.colourtemp_set.max == 6500, "set action range")
check(removed.increase_frontlight_warmth and registered.increase_frontlight_warmth.condition == nil and registered.increase_frontlight_warmth.event == "IncreaseFlWarmth", "stock warmth actions re-registered without condition")
check(registered.set_frontlight_warmth.max == 100, "stock set warmth range 0..100")
check(reader_order.setting[3] == "colourtemp" and fm_order.setting[3] == "colourtemp", "menu key placed after night_mode in both orders")
check(#ui.post_init == 1, "gesture assignment deferred to post-init")

-- defaults
check(Plugin.isEnabled() == false, "disabled by default")
check(Plugin.getKelvin() == 3400 and Plugin.getIntensity() == 100 and Plugin.tintsNightMode() == true, "defaults")

-- ---------- gesture assignment ----------
-- no gestures plugin yet: nothing happens, flag not set, retried later
ui.post_init[1]()
check(settings.colourtemp_gestures_assigned == nil, "no gestures plugin -> not marked done")

local flushed = 0
ui.gestures = {
    data = {
        gesture_fm = { one_finger_swipe_right_edge_up = nil, one_finger_swipe_right_edge_down = {} },
        gesture_reader = { one_finger_swipe_right_edge_up = { toggle_frontlight = true }, one_finger_swipe_right_edge_down = nil },
    },
    onFlushSettings = function(self) if self.updated then flushed = flushed + 1; self.updated = false end end,
}
ui.post_init[1]()
local fm, rd = ui.gestures.data.gesture_fm, ui.gestures.data.gesture_reader
check(fm.one_finger_swipe_right_edge_up and fm.one_finger_swipe_right_edge_up.colourtemp_warmer == 0, "FM right edge up (pass through) -> warmer by distance")
check(next(fm.one_finger_swipe_right_edge_down) == nil, "FM right edge down (explicit Nothing) left alone")
check(rd.one_finger_swipe_right_edge_up.toggle_frontlight == true and rd.one_finger_swipe_right_edge_up.colourtemp_warmer == nil, "reader right edge up (user mapping) left alone")
check(rd.one_finger_swipe_right_edge_down and rd.one_finger_swipe_right_edge_down.colourtemp_cooler == 0, "reader right edge down (pass through) -> cooler by distance")
check(flushed == 1, "gestures settings flushed")
check(settings.colourtemp_gestures_assigned == true, "assignment marked done")
check(notifications[#notifications] == "Colour temperature: right-edge swipes now change the warmth", "user told about the new gestures")
-- second run: nothing changes even if slots are empty again
fm.one_finger_swipe_right_edge_up = nil
check(inst:assignEdgeGestures() == false and fm.one_finger_swipe_right_edge_up == nil, "assignment is one-time")

-- ---------- gesture distance ----------
check(Plugin.kelvinDelta(200) == 200, "explicit step passes through")
check(Plugin.kelvinDelta(5) == 100, "explicit step below 100 K becomes 100 K")
check(Plugin.kelvinDelta(nil) == 300, "no gesture -> 300 K")
local function swipe(frac) return { ges = "swipe", direction = "north", distance = frac * 2000 * 0.8 } end
check(Plugin.kelvinDelta(swipe(0.05)) == 100, "short flick -> 100 K")
check(Plugin.kelvinDelta(swipe(0.25)) == 200, "quarter swipe -> 200 K, got " .. Plugin.kelvinDelta(swipe(0.25)))
check(Plugin.kelvinDelta(swipe(0.5)) == 600, "half swipe -> 600 K, got " .. Plugin.kelvinDelta(swipe(0.5)))
check(Plugin.kelvinDelta(swipe(1)) == 2400, "full swipe -> 2400 K")
check(Plugin.kelvinDelta(swipe(3)) == 2400, "overshoot clamps")
check(Plugin.kelvinDelta({ ges = "swipe", direction = "east", distance = 400 }) == 600, "horizontal swipe scaled by width")
check(Plugin.kelvinDelta({ ges = "pan", direction = "northeast", distance = 100 }) == 100, "diagonal pan uses diagonal scale")

-- ---------- menu ----------
local items = {}
inst:addToMainMenu(items)
local m = items.colourtemp
check(m and m.text == "Colour temperature" and #m.sub_item_table == 5, "menu built with 5 entries")
check(m.sub_item_table[2].text_func() == "Colour temperature: 3400 K (warmth 66 %)", "kelvin label with warmth, got " .. m.sub_item_table[2].text_func())
check(m.sub_item_table[3].text_func() == "Intensity: 100 %", "intensity label")
check(#m.sub_item_table[4].sub_item_table == 5, "five presets")

dirty = 0
m.sub_item_table[1].callback()
check(Plugin.isEnabled() == true and dirty == 1, "menu toggle enables and repaints")
check(m.checked_func() == true, "top-level entry shows checked")

m.sub_item_table[4].sub_item_table[5].callback()
check(Plugin.getKelvin() == 2000, "candle preset applied")
check(Powerd.fl_warmth == 96, "powerd warmth follows the menu (2000 K -> 96 %), got " .. tostring(Powerd.fl_warmth))
check(m.sub_item_table[4].sub_item_table[5].checked_func() == true, "candle preset checked")

inst:showKelvinDialog()
local spin = shown[#shown]
check(spin.value == 2000 and spin.value_min == 1800 and spin.value_max == 6500 and spin.value_step == 100 and spin.unit == "K", "kelvin spinner config")
spin.callback({ value = 4567 })
check(Plugin.getKelvin() == 4567, "kelvin spinner value applied as is")
inst:showIntensityDialog()
spin = shown[#shown]
spin.callback({ value = 42 })
check(Plugin.getIntensity() == 42, "intensity spinner value applied")

-- ---------- second instance (reader after file manager) ----------
local inst2 = newInstance(newUI())
check(inst2.hooked == true, "second instance hooks fine")
local count = 0
for _, k in ipairs(reader_order.setting) do if k == "colourtemp" then count = count + 1 end end
check(count == 1, "menu key inserted only once")

-- ---------- dispatcher events ----------
inst:onToggleColourTemp()
check(Plugin.isEnabled() == false and notifications[#notifications] == "Colour temperature tint off", "toggle event off + notification")
inst:onSetColourTemp(3000)
check(Plugin.isEnabled() == true and Plugin.getKelvin() == 3000 and notifications[#notifications] == "Colour temperature: 3000 K", "set event enables and notifies")
inst:onColourTempWarmer(200)
check(Plugin.getKelvin() == 2800, "warmer by 200")
inst:onColourTempWarmer(swipe(0.5))
check(Plugin.getKelvin() == 2200, "warmer by half-screen swipe = 600 K")
inst:onColourTempCooler(swipe(0.05))
check(Plugin.getKelvin() == 2300, "cooler by flick = 100 K")
inst:onColourTempCooler(5000)
check(Plugin.getKelvin() == 6500, "cooler clamps at 6500")
inst:onColourTempWarmer(99999)
check(Plugin.getKelvin() == 1800, "warmer clamps at 1800")

-- ---------- AutoWarmth / stock path through Powerd:setWarmth ----------
Plugin.setEnabled(false)
Plugin.setKelvin(3400)
check(Powerd:setWarmth(66) == false, "unchanged warmth is a no-op (fl_warmth in sync)")
check(Powerd:setWarmth(90) == true, "AutoWarmth-style setWarmth accepted")
check(Plugin.getKelvin() == 2270 and Plugin.isEnabled() == true, "warmth 90 % -> 2270 K and tint on, got " .. Plugin.getKelvin())
check(Powerd.fl_warmth == 90 and Powerd:frontlightWarmth() == 90, "powerd reports the warmth it was given")
Powerd:setWarmth(0)
check(Plugin.getKelvin() == 6500, "warmth 0 -> 6500 K (no tint, still enabled)")
check(Powerd:frontlightWarmthHW() == 0, "HW read returns current warmth")
check(#hw_calls == 0, "the stock Android setWarmthHW was never called")

-- night mode toggle
m.sub_item_table[5].callback()
check(Plugin.tintsNightMode() == false, "night mode tint toggled off")
m.sub_item_table[5].callback()
check(Plugin.tintsNightMode() == true, "night mode tint toggled on")

-- unhookable screen -> notice menu
inst.hooked = false
items = {}
inst:addToMainMenu(items)
check(items.colourtemp.sub_item_table[1].enabled == false, "unhooked -> disabled notice")

print(string.format("%d checks, %d failed", checks, failed))
os.exit(failed == 0 and 0 or 1)
