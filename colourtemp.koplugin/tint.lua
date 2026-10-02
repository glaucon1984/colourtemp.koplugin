--[[
    Colour temperature -- tint engine.

    Two independent parts live here:

    1. Pure colour maths (Tint.kelvinToRGB, Tint.multiplier): a colour
       temperature in kelvin plus an intensity become an RGB multiplier.
       White multiplied by it is the new "paper" colour; every other
       colour is scaled the same way, so black stays black.

    2. The screen hook (Tint.install / Tint._updateWindow). On Android
       KOReader keeps a full-size shadow framebuffer (Screen.bb) and, on
       every refresh, framebuffer_android:_updateWindow() copies the whole
       shadow buffer into the native window and posts it. We wrap that
       method: when the tint is on we copy the shadow buffer into a
       private buffer, multiply it by the tint colour (C blitter, a few
       milliseconds), and hand that buffer to the original _updateWindow
       by temporarily exposing it as Screen.full_bb, which the original
       prefers over Screen.bb. The shadow buffer itself is never touched,
       so partial repaints keep working and turning the tint off is just
       "stop wrapping".

    Night mode: KOReader's software night mode sets an "inverse" flag on
    the shadow buffer and _updateWindow inverts while copying. Tinting
    before that inversion would turn the warm white into a cold dark blue,
    so when the flag is set we invert into our buffer ourselves, apply the
    tint to the already-inverted image, and present it with the flag
    cleared. Result: dark page, slightly warm text, the same thing a
    night-light filter does on a dark theme.

    Nothing here requires Android itself: Screen and the blitbuffer
    module are injected, which is what the test harness relies on.
]]

local Tint = {}

Tint.MIN_KELVIN = 1800
Tint.MAX_KELVIN = 6500
Tint.DEFAULT_KELVIN = 3400
Tint.KELVIN_STEP = 100

Tint.MIN_INTENSITY = 10
Tint.MAX_INTENSITY = 100
Tint.DEFAULT_INTENSITY = 100

-- Give up (and fall back to the untinted path) after this many consecutive
-- failures inside the hook, so a broken build can never lock the screen.
local MAX_FAILURES = 3

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function round(v)
    return math.floor(v + 0.5)
end

--- Colour temperature (kelvin) -> r, g, b in 0..255.
-- Tanner Helland's black-body approximation. Red is always 255 in the range
-- we care about, so this is a pure "take some blue and green away" curve;
-- 6500 K and above are treated as plain white (no tint at all).
function Tint.kelvinToRGB(kelvin)
    kelvin = clamp(tonumber(kelvin) or Tint.DEFAULT_KELVIN, 1000, 40000)
    if kelvin >= 6500 then
        return 255, 255, 255
    end
    local t = kelvin / 100
    local r, g, b
    if t <= 66 then
        r = 255
        g = 99.4708025861 * math.log(t) - 161.1195681661
    else
        r = 329.698727446 * (t - 60) ^ -0.1332047592
        g = 288.1221695283 * (t - 60) ^ -0.0755148492
    end
    if t >= 66 then
        b = 255
    elseif t <= 19 then
        b = 0
    else
        b = 138.5177312231 * math.log(t - 10) - 305.0447927307
    end
    return round(clamp(r, 0, 255)), round(clamp(g, 0, 255)), round(clamp(b, 0, 255))
end

--- RGB multiplier for a kelvin value at a given intensity (10..100 %).
-- Intensity blends between no tint (white) and the full black-body colour,
-- the same knob Android's own Night Light exposes next to its schedule.
function Tint.multiplier(kelvin, intensity)
    local r, g, b = Tint.kelvinToRGB(kelvin)
    local k = clamp(tonumber(intensity) or Tint.DEFAULT_INTENSITY, 0, 100) / 100
    return round(255 - (255 - r) * k), round(255 - (255 - g) * k), round(255 - (255 - b) * k)
end

--- Clamp a kelvin value to the supported range (whole kelvin). Not snapped
-- to KELVIN_STEP: KOReader's 0..100 warmth scale maps to 47 K per step.
function Tint.normalizeKelvin(kelvin)
    kelvin = round(tonumber(kelvin) or Tint.DEFAULT_KELVIN)
    return clamp(kelvin, Tint.MIN_KELVIN, Tint.MAX_KELVIN)
end

function Tint.normalizeIntensity(intensity)
    intensity = round(tonumber(intensity) or Tint.DEFAULT_INTENSITY)
    return clamp(intensity, Tint.MIN_INTENSITY, Tint.MAX_INTENSITY)
end

-- ==================== screen hook ====================

local state = {
    installed = false,
    screen = nil,       -- the live Screen instance we wrapped
    BB = nil,           -- ffi/blitbuffer module (injected)
    original = nil,     -- the _updateWindow we wrapped
    log = nil,          -- logger-like table (optional)
    active = false,
    tint_night_mode = true,
    color = nil,        -- BB colour used for the multiply
    buffer = nil,       -- our private tinted copy of the shadow buffer
    buffer_w = nil,     -- physical dimensions of `buffer`
    buffer_h = nil,
    buffer_type = nil,
    failures = 0,
    posts = 0,          -- tinted posts so far (for tests / debugging)
}

local function warn(...)
    if state.log and state.log.warn then
        state.log.warn("colourtemp:", ...)
    end
end

local function freeBuffer()
    if state.buffer then
        pcall(function() state.buffer:free() end)
    end
    state.buffer, state.buffer_w, state.buffer_h, state.buffer_type = nil, nil, nil, nil
end

-- Make sure our buffer matches the shadow buffer's physical size and type
-- (the shadow buffer is re-created on rotation and split-screen changes).
local function ensureBuffer(src)
    local w, h, bbtype = src.w, src.h, src:getType()
    if state.buffer and state.buffer_w == w and state.buffer_h == h and state.buffer_type == bbtype then
        return state.buffer
    end
    freeBuffer()
    state.buffer = state.BB.new(w, h, bbtype)
    state.buffer_w, state.buffer_h, state.buffer_type = w, h, bbtype
    return state.buffer
end

-- Fill our buffer with the tinted version of `src`.
local function prepare(src, inverse)
    local buf = ensureBuffer(src)
    buf:setRotation(src:getRotation())
    -- We present an already-processed image: never let the original
    -- _updateWindow invert it a second time.
    buf:setInverse(0)
    if inverse then
        buf:invertblitFrom(src)
    else
        buf:blitFrom(src)
    end
    buf:multiplyRectRGB(0, 0, buf:getWidth(), buf:getHeight(), state.color)
    return buf
end

-- The replacement for framebuffer_android:_updateWindow().
function Tint._updateWindow(screen)
    local original = state.original
    if not state.active or not state.color then
        return original(screen)
    end
    local src = screen.full_bb or screen.bb
    if not src then
        return original(screen)
    end
    local inverse = src:getInverse() == 1
    if inverse and not state.tint_night_mode then
        return original(screen)
    end

    local ok, buf = pcall(prepare, src, inverse)
    if not ok then
        state.failures = state.failures + 1
        warn("tint failed, posting untinted frame:", buf)
        if state.failures >= MAX_FAILURES then
            warn("too many failures, tint disabled until re-enabled")
            state.active = false
            freeBuffer()
        end
        return original(screen)
    end
    state.failures = 0

    local saved = screen.full_bb
    screen.full_bb = buf
    local ok2, err = pcall(original, screen)
    screen.full_bb = saved
    state.posts = state.posts + 1
    if not ok2 then
        error(err, 0)
    end
end

--- Wrap Screen._updateWindow. Idempotent; returns true on success.
-- @param Screen the live Device.screen instance
-- @param BB the ffi/blitbuffer module
-- @param log optional logger (needs .warn)
function Tint.install(Screen, BB, log)
    state.log = log
    if state.installed then
        return true
    end
    if type(Screen) ~= "table" or type(Screen._updateWindow) ~= "function" then
        warn("no _updateWindow on this Screen; not an Android framebuffer?")
        return false
    end
    if type(BB) ~= "table" or type(BB.new) ~= "function" then
        return false
    end
    -- The C blitter is what makes a full-frame multiply affordable; the Lua
    -- fallback would take seconds per page and also handles the inverse
    -- flag differently. KOReader always uses the C blitter on Android.
    if type(BB.getUseCBB) == "function" and not BB:getUseCBB() then
        warn("C blitbuffer not in use; tint disabled")
        return false
    end
    if rawget(Screen, "_colourtemp_original") then
        -- Another instance of us (or an older copy) already wrapped it.
        state.original = Screen._colourtemp_original
    else
        state.original = Screen._updateWindow
        Screen._colourtemp_original = state.original
    end
    state.screen = Screen
    state.BB = BB
    Screen._updateWindow = function(self)
        return Tint._updateWindow(self)
    end
    state.installed = true
    return true
end

--- Undo install(); only used by tests and when the plugin is torn down.
function Tint.uninstall()
    if not state.installed then return end
    local Screen = state.screen
    if rawget(Screen, "_colourtemp_original") then
        Screen._updateWindow = nil -- fall back to the class method
        Screen._colourtemp_original = nil
    end
    freeBuffer()
    state.installed = false
    state.screen, state.original, state.BB = nil, nil, nil
    state.active = false
    state.failures = 0
end

--- Set the tint from kelvin + intensity. Returns the r, g, b used.
function Tint.setColor(kelvin, intensity)
    local r, g, b = Tint.multiplier(kelvin, intensity)
    if state.BB then
        state.color = state.BB.ColorRGB24(r, g, b)
    end
    state.failures = 0
    return r, g, b
end

function Tint.setActive(active)
    state.active = active and true or false
    state.failures = 0
    if not state.active then
        freeBuffer()
    end
end

function Tint.isActive()
    return state.active
end

function Tint.setNightModeTint(enabled)
    state.tint_night_mode = enabled and true or false
end

function Tint.isInstalled()
    return state.installed
end

-- For tests.
function Tint._state()
    return state
end

return Tint
