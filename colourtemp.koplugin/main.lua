--[[
    Colour temperature -- a self-contained KOReader plugin for Android.

    Drop the colourtemp.koplugin folder into koreader/plugins/ and restart
    KOReader. Nothing outside this folder is touched: the tint is applied
    at runtime by wrapping one method of the live Screen object (see
    tint.lua for how and why that works).

    Besides the tint itself, the plugin makes KOReader treat the phone as a
    "natural light" device (one with warm front lights), so everything that
    is normally hidden on Android because there is no warmth control starts
    working, driven by the software tint:
      - the AutoWarmth plugin ("Auto warmth and night mode"),
      - the stock warmth gesture actions and their swipe-distance handling,
      - the "Frontlight warmth" status bar item.
    KOReader's warmth scale is 0..100 %; here 0 % = 6500 K (no tint) and
    100 % = 1800 K.

    Licensed under the GNU AGPL v3 or later, like KOReader itself.
]]

local Device = require("device")

if not Device:isAndroid() then
    -- Only the Android framebuffer posts whole frames through
    -- _updateWindow(); other platforms have no hook point for this.
    return { disabled = true, }
end
if Device:hasEinkScreen() then
    -- Android e-ink devices (Onyx, Tolino...) have hardware warmth that
    -- KOReader already drives; a software tint would do nothing useful on
    -- a grayscale panel.
    return { disabled = true, }
end

local BB = require("ffi/blitbuffer")
local Dispatcher = require("dispatcher")
local Notification = require("ui/widget/notification")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen
local Powerd = Device:getPowerDevice()

local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local Tint = dofile(plugin_dir .. "tint.lua")

local MENU_KEY = "colourtemp"
local KELVIN_SPAN = Tint.MAX_KELVIN - Tint.MIN_KELVIN

local PRESETS = {
    { _("Soft"),         5000 },
    { _("Warm"),         4000 },
    { _("Reading lamp"), 3400 },
    { _("Sunset"),       2700 },
    { _("Candle"),       2000 },
}

local ColourTemp = WidgetContainer:extend{
    name = "colourtemp",
}

-- ==================== kelvin <-> KOReader warmth ====================

-- KOReader (AutoWarmth, gestures, status bar) talks warmth in 0..100 %.
function ColourTemp.warmthFromKelvin(kelvin)
    local w = (Tint.MAX_KELVIN - Tint.normalizeKelvin(kelvin)) / KELVIN_SPAN * 100
    return math.floor(w + 0.5)
end

function ColourTemp.kelvinFromWarmth(warmth)
    warmth = math.max(0, math.min(100, tonumber(warmth) or 0))
    return Tint.normalizeKelvin(Tint.MAX_KELVIN - warmth / 100 * KELVIN_SPAN)
end

-- ==================== settings ====================

function ColourTemp.isEnabled()
    return G_reader_settings:isTrue("colourtemp_enabled")
end

function ColourTemp.getKelvin()
    return Tint.normalizeKelvin(G_reader_settings:readSetting("colourtemp_kelvin") or Tint.DEFAULT_KELVIN)
end

function ColourTemp.getIntensity()
    return Tint.normalizeIntensity(G_reader_settings:readSetting("colourtemp_intensity") or Tint.DEFAULT_INTENSITY)
end

function ColourTemp.tintsNightMode()
    return G_reader_settings:nilOrTrue("colourtemp_night_mode")
end

-- Push the saved settings into the tint engine (and the emulated power
-- device) and repaint. Static: also called from the power device hook.
function ColourTemp.apply(refresh)
    local kelvin = ColourTemp.getKelvin()
    Tint.setColor(kelvin, ColourTemp.getIntensity())
    Tint.setNightModeTint(ColourTemp.tintsNightMode())
    -- 6500 K is plain white: skip the per-frame work entirely.
    Tint.setActive(ColourTemp.isEnabled() and kelvin < Tint.MAX_KELVIN)
    if ColourTemp.emulating then
        Powerd.fl_warmth = ColourTemp.warmthFromKelvin(kelvin)
    end
    if refresh ~= false then
        UIManager:setDirty("all", "ui")
    end
end

function ColourTemp.setEnabled(enabled)
    G_reader_settings:saveSetting("colourtemp_enabled", enabled and true or false)
    ColourTemp.apply()
end

function ColourTemp.setKelvin(kelvin, enable)
    G_reader_settings:saveSetting("colourtemp_kelvin", Tint.normalizeKelvin(kelvin))
    if enable then
        G_reader_settings:saveSetting("colourtemp_enabled", true)
    end
    ColourTemp.apply()
end

function ColourTemp.setIntensity(intensity, enable)
    G_reader_settings:saveSetting("colourtemp_intensity", Tint.normalizeIntensity(intensity))
    if enable then
        G_reader_settings:saveSetting("colourtemp_enabled", true)
    end
    ColourTemp.apply()
end

-- ==================== natural light emulation ====================

-- Make KOReader believe this device has warm front lights, backed by the
-- tint. Runs once at module load (PluginLoader only loads main.lua for
-- enabled plugins), before AutoWarmth and the gestures plugin initialise,
-- because they look at Device:hasNaturalLight() in their init().
ColourTemp.emulating = false

function ColourTemp.emulateNaturalLight()
    if ColourTemp.emulating then return true end
    if Device:hasNaturalLight() then
        -- A real warmth device: leave its hardware alone.
        return false
    end
    if type(Powerd) ~= "table" or type(Powerd.setWarmth) ~= "function" then
        return false
    end
    Device.hasNaturalLight = function() return true end
    -- The public PowerD warmth API is 0..100; keep the native scale the same.
    Powerd.fl_warmth_min = 0
    Powerd.fl_warmth_max = 100
    Powerd.warmth_scale = 1
    Powerd.warm_diff = 100
    Powerd.fl_warmth = ColourTemp.warmthFromKelvin(ColourTemp.getKelvin())
    Powerd.frontlightWarmthHW = function(self)
        return self.fl_warmth or 0
    end
    -- Called by BasePowerD:setWarmth() (AutoWarmth, stock gestures, the
    -- frontlight widget). Picking a warmth switches the tint on, like
    -- turning the warm LEDs up on a real device.
    Powerd.setWarmthHW = function(self, warmth)
        ColourTemp.setKelvin(ColourTemp.kelvinFromWarmth(warmth), true)
    end
    ColourTemp.emulating = true
    return true
end

-- ==================== lifecycle ====================

function ColourTemp:init()
    -- install() is idempotent: the file manager and the reader each create
    -- their own instance of us, and the wrapper must survive the switch
    -- between them.
    self.hooked = Tint.install(Screen, BB, logger)
    if self.hooked then
        ColourTemp.apply(false)
    else
        logger.warn("colourtemp: could not hook the screen, tint unavailable")
    end
    self:onDispatcherRegisterActions()
    self.registerOrder()
    self.ui.menu:registerToMainMenu(self)
    if self.hooked then
        -- The gestures plugin initialises after us (alphabetical order);
        -- wait until every module of this UI is up before touching it.
        local function assign() self:assignEdgeGestures() end
        if type(self.ui.registerPostInitCallback) == "function" then
            self.ui:registerPostInitCallback(assign)
        else
            UIManager:nextTick(assign)
        end
    end
end

-- ==================== gestures / dispatcher ====================

function ColourTemp:onDispatcherRegisterActions()
    Dispatcher:registerAction("colourtemp_toggle", {
        category = "none", event = "ToggleColourTemp",
        title = _("Toggle colour temperature tint"), screen = true,
    })
    Dispatcher:registerAction("colourtemp_set", {
        category = "absolutenumber", event = "SetColourTemp",
        min = Tint.MIN_KELVIN, max = Tint.MAX_KELVIN, step = Tint.KELVIN_STEP, unit = "K",
        title = _("Set colour temperature"), screen = true,
    })
    Dispatcher:registerAction("colourtemp_warmer", {
        category = "incrementalnumber", event = "ColourTempWarmer",
        min = Tint.KELVIN_STEP, max = 2000, step = Tint.KELVIN_STEP, unit = "K",
        title = _("Warmer colour temperature"), screen = true,
    })
    Dispatcher:registerAction("colourtemp_cooler", {
        category = "incrementalnumber", event = "ColourTempCooler",
        min = Tint.KELVIN_STEP, max = 2000, step = Tint.KELVIN_STEP, unit = "K",
        title = _("Cooler colour temperature"), screen = true, separator = true,
    })
    if ColourTemp.emulating then
        -- KOReader's own warmth actions were registered with
        -- condition = false (no natural light at startup), which hides them
        -- and stops the gesture defaults from running them. Re-register
        -- them unconditionally; DeviceListener handles their events and
        -- ends up in Powerd.setWarmthHW above.
        local stock = {
            set_frontlight_warmth = {
                category = "absolutenumber", event = "SetFlWarmth", min = 0, max = 100,
                title = _("Set frontlight warmth"), screen = true,
            },
            increase_frontlight_warmth = {
                category = "incrementalnumber", event = "IncreaseFlWarmth", min = 1, max = 100,
                title = _("Increase frontlight warmth"), screen = true,
            },
            decrease_frontlight_warmth = {
                category = "incrementalnumber", event = "DecreaseFlWarmth", min = 1, max = 100,
                title = _("Decrease frontlight warmth"), screen = true, separator = true,
            },
        }
        for name, def in pairs(stock) do
            if type(Dispatcher.removeAction) == "function" then
                pcall(Dispatcher.removeAction, Dispatcher, name)
            end
            Dispatcher:registerAction(name, def)
        end
    end
end

-- One-time setup: map the right-edge swipes to warmer/cooler by swipe
-- distance, the way KOReader does by default on devices with warm lights.
-- Only fills slots that are unset ("Pass through"); anything the user
-- configured, including an explicit "Nothing", is left alone.
function ColourTemp:assignEdgeGestures()
    if G_reader_settings:isTrue("colourtemp_gestures_assigned") then return false end
    local gestures = self.ui and self.ui.gestures
    if not gestures or type(gestures.data) ~= "table" then
        -- Gestures plugin disabled or not loaded yet: try again next time.
        return false
    end
    local changed = false
    for _, section in ipairs({ "gesture_fm", "gesture_reader" }) do
        local tbl = gestures.data[section]
        if type(tbl) == "table" then
            if tbl.one_finger_swipe_right_edge_up == nil then
                tbl.one_finger_swipe_right_edge_up = { colourtemp_warmer = 0 }
                changed = true
            end
            if tbl.one_finger_swipe_right_edge_down == nil then
                tbl.one_finger_swipe_right_edge_down = { colourtemp_cooler = 0 }
                changed = true
            end
        end
    end
    if changed then
        gestures.updated = true
        if type(gestures.onFlushSettings) == "function" then
            gestures:onFlushSettings()
        end
        Notification:notify(_("Colour temperature: right-edge swipes now change the warmth"))
    end
    G_reader_settings:saveSetting("colourtemp_gestures_assigned", true)
    return changed
end

local function notifyState()
    if ColourTemp.isEnabled() then
        Notification:notify(T(_("Colour temperature: %1 K"), ColourTemp.getKelvin()))
    else
        Notification:notify(_("Colour temperature tint off"))
    end
end

-- Incremental actions receive either a number (the step the user picked in
-- the gesture settings) or a gesture object ("gesture distance"). The
-- distance mapping is KOReader's own (DeviceListener.calculateGestureDelta):
-- delta = half the range * x^2, x being the swipe length as a fraction of
-- the screen. A short flick is 100 K, half the screen about 600 K, a full
-- swipe 2400 K.
function ColourTemp.kelvinDelta(ges)
    if type(ges) == "number" then
        return math.max(Tint.KELVIN_STEP, ges)
    end
    if type(ges) ~= "table" then
        return 3 * Tint.KELVIN_STEP
    end
    local multiplier = (ges.ges == "two_finger_swipe" or ges.ges == "swipe") and 0.8 or 1
    local width, height = Screen:getWidth(), Screen:getHeight()
    local scale
    if ges.direction == "south" or ges.direction == "north" then
        scale = height * multiplier
    elseif ges.direction == "west" or ges.direction == "east" then
        scale = width * multiplier
    else
        scale = math.sqrt(width ^ 2 + height ^ 2) * multiplier
    end
    local x = math.min(1, (ges.distance or 1) / scale)
    local delta = math.ceil(0.5 * KELVIN_SPAN * x ^ 2 / Tint.KELVIN_STEP) * Tint.KELVIN_STEP
    return math.max(Tint.KELVIN_STEP, delta)
end

function ColourTemp:onToggleColourTemp()
    ColourTemp.setEnabled(not ColourTemp.isEnabled())
    notifyState()
    return true
end

function ColourTemp:onSetColourTemp(kelvin)
    ColourTemp.setKelvin(kelvin, true)
    notifyState()
    return true
end

function ColourTemp:onColourTempWarmer(ges)
    ColourTemp.setKelvin(ColourTemp.getKelvin() - ColourTemp.kelvinDelta(ges), true)
    notifyState()
    return true
end

function ColourTemp:onColourTempCooler(ges)
    ColourTemp.setKelvin(ColourTemp.getKelvin() + ColourTemp.kelvinDelta(ges), true)
    notifyState()
    return true
end

-- ==================== menu ====================

-- Place our entry right after "Night mode" at the top of the Settings tab,
-- in both the reader and the file manager. The order tables are cached by
-- require(), so this only has to succeed once per session.
function ColourTemp.registerOrder()
    local placed = false
    for _, module in ipairs({ "ui/elements/reader_menu_order", "ui/elements/filemanager_menu_order" }) do
        local ok, order = pcall(require, module)
        if ok and type(order) == "table" and type(order.setting) == "table" then
            local section = order.setting
            local present = false
            for _, key in ipairs(section) do
                if key == MENU_KEY then present = true break end
            end
            if not present then
                for index, key in ipairs(section) do
                    if key == "night_mode" then
                        table.insert(section, index + 1, MENU_KEY)
                        present = true
                        break
                    end
                end
            end
            placed = placed or present
        end
    end
    return placed
end

function ColourTemp:showKelvinDialog()
    UIManager:show(SpinWidget:new{
        title_text = _("Colour temperature"),
        info_text = _("Lower values are warmer (more orange). 6500 K is plain white."),
        value = ColourTemp.getKelvin(),
        value_min = Tint.MIN_KELVIN,
        value_max = Tint.MAX_KELVIN,
        value_step = Tint.KELVIN_STEP,
        value_hold_step = 5 * Tint.KELVIN_STEP,
        default_value = Tint.DEFAULT_KELVIN,
        unit = "K",
        keep_shown_on_apply = true,
        ok_always_enabled = true,
        callback = function(spin)
            ColourTemp.setKelvin(spin.value, true)
        end,
    })
end

function ColourTemp:showIntensityDialog()
    UIManager:show(SpinWidget:new{
        title_text = _("Tint intensity"),
        info_text = _("How strongly the chosen colour temperature is applied."),
        value = ColourTemp.getIntensity(),
        value_min = Tint.MIN_INTENSITY,
        value_max = Tint.MAX_INTENSITY,
        value_step = 5,
        value_hold_step = 20,
        default_value = Tint.DEFAULT_INTENSITY,
        unit = "%",
        keep_shown_on_apply = true,
        ok_always_enabled = true,
        callback = function(spin)
            ColourTemp.setIntensity(spin.value, true)
        end,
    })
end

function ColourTemp:presetItems()
    local items = {}
    for _, preset in ipairs(PRESETS) do
        local label, kelvin = preset[1], preset[2]
        table.insert(items, {
            text = T("%1 (%2 K)", label, kelvin),
            checked_func = function()
                return ColourTemp.isEnabled() and ColourTemp.getKelvin() == kelvin
            end,
            radio = true,
            callback = function()
                ColourTemp.setKelvin(kelvin, true)
            end,
        })
    end
    return items
end

function ColourTemp:addToMainMenu(menu_items)
    if not self.hooked then
        menu_items[MENU_KEY] = {
            text = _("Colour temperature"),
            sorting_hint = "screen",
            sub_item_table = {
                {
                    text = _("Not available: the screen could not be hooked"),
                    enabled = false,
                },
            },
        }
        return
    end
    menu_items[MENU_KEY] = {
        text = _("Colour temperature"),
        -- Fallback placement if the menu order tables could not be edited.
        sorting_hint = "screen",
        checked_func = function() return ColourTemp.isEnabled() end,
        sub_item_table = {
            {
                text = _("Warm tint"),
                checked_func = function() return ColourTemp.isEnabled() end,
                callback = function() ColourTemp.setEnabled(not ColourTemp.isEnabled()) end,
                help_text = _("Multiplies everything drawn on screen by a warm colour, so white paper turns cream to orange and black text stays black. Swipe up or down on the right edge of the screen to change it, or assign other gestures under Taps and gestures. KOReader's warmth scale (AutoWarmth, status bar) maps 0 % to 6500 K and 100 % to 1800 K."),
            },
            {
                text_func = function()
                    local kelvin = ColourTemp.getKelvin()
                    return T(_("Colour temperature: %1 K (warmth %2 %)"), kelvin, ColourTemp.warmthFromKelvin(kelvin))
                end,
                keep_menu_open = true,
                callback = function() self:showKelvinDialog() end,
            },
            {
                text_func = function()
                    return T(_("Intensity: %1 %"), ColourTemp.getIntensity())
                end,
                keep_menu_open = true,
                callback = function() self:showIntensityDialog() end,
                separator = true,
            },
            {
                text = _("Presets"),
                sub_item_table = self:presetItems(),
            },
            {
                text = _("Also tint in night mode"),
                checked_func = function() return ColourTemp.tintsNightMode() end,
                callback = function()
                    G_reader_settings:saveSetting("colourtemp_night_mode", not ColourTemp.tintsNightMode())
                    ColourTemp.apply()
                end,
                help_text = _("In night mode the page is inverted first and the tint is applied to the result: a dark page with slightly warm text. Turn this off to keep night mode untinted."),
            },
        },
    }
end

-- Module level on purpose: see emulateNaturalLight().
if not ColourTemp.emulateNaturalLight() then
    logger.dbg("colourtemp: natural light emulation not installed")
end

return ColourTemp
