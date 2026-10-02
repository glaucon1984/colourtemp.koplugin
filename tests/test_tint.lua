-- Harness for colourtemp.koplugin/tint.lua: fake blitbuffer + fake Screen.
-- usage: luajit test_tint.lua <plugin dir>
local dir = arg[1] or "."
local Tint = dofile(dir .. "/tint.lua")

local checks, failed = 0, 0
local function check(cond, msg)
    checks = checks + 1
    if not cond then
        failed = failed + 1
        print("FAIL: " .. msg)
    end
end

-- ---------- pure maths ----------
local r, g, b = Tint.kelvinToRGB(6500)
check(r == 255 and g == 255 and b == 255, "6500K is identity")
r, g, b = Tint.kelvinToRGB(9000)
check(r == 255 and g == 255 and b == 255, "above 6500K is identity")
r, g, b = Tint.kelvinToRGB(3400)
check(r == 255 and g == 190 and b == 135, "3400K matches reference table, got " .. r .. "," .. g .. "," .. b)
r, g, b = Tint.kelvinToRGB(2700)
check(r == 255 and g == 167 and b == 87, "2700K matches reference table")
r, g, b = Tint.kelvinToRGB(1800)
check(r == 255 and b == 0, "1800K has no blue")
r, g, b = Tint.multiplier(3400, 100)
check(g == 190 and b == 135, "intensity 100 = full colour")
r, g, b = Tint.multiplier(3400, 50)
check(r == 255 and g == 223 and b == 195, "intensity 50 halves the tint, got " .. g .. "," .. b)
r, g, b = Tint.multiplier(3400, 0)
check(r == 255 and g == 255 and b == 255, "intensity 0 = white")
check(Tint.normalizeKelvin(3449) == 3449 and Tint.normalizeKelvin(3450.4) == 3450, "kelvin kept to the kelvin (no 100 K snapping)")
check(Tint.normalizeKelvin(100) == 1800 and Tint.normalizeKelvin(99999) == 6500, "kelvin clamps")
check(Tint.normalizeKelvin("abc") == 3400, "bad kelvin -> default")
check(Tint.normalizeIntensity(3) == 10 and Tint.normalizeIntensity(150) == 100 and Tint.normalizeIntensity(nil) == 100, "intensity clamps")

-- ---------- fake blitbuffer ----------
-- A pixel is {r,g,b}; buffers are flat arrays. Rotation is just a flag.
local BB = { TYPE_BBRGB32 = 4, use_cbb = true }
function BB:getUseCBB() return self.use_cbb end
function BB.ColorRGB24(r, g, b) return { r = r, g = g, b = b } end
local bbmt = {}
bbmt.__index = bbmt
local allocs, frees = 0, 0
function BB.new(w, h, bbtype)
    allocs = allocs + 1
    local bb = setmetatable({ w = w, h = h, type = bbtype, rotation = 0, inverse = 0, px = {} }, bbmt)
    for i = 1, w * h do bb.px[i] = { 255, 255, 255 } end
    return bb
end
function bbmt:getType() return self.type end
function bbmt:getRotation() return self.rotation end
function bbmt:setRotation(r) self.rotation = r end
function bbmt:getInverse() return self.inverse end
function bbmt:setInverse(i) self.inverse = i end
function bbmt:getWidth() return (self.rotation % 2 == 1) and self.h or self.w end
function bbmt:getHeight() return (self.rotation % 2 == 1) and self.w or self.h end
function bbmt:free() frees = frees + 1; self.freed = true end
function bbmt:blitFrom(src)
    assert(not self.freed, "blit into freed buffer")
    assert(src.w == self.w and src.h == self.h, "size mismatch")
    for i = 1, self.w * self.h do
        local p = src.px[i]
        self.px[i] = { p[1], p[2], p[3] }
    end
end
function bbmt:invertblitFrom(src)
    assert(src.type == self.type, "invertblitFrom needs same type")
    for i = 1, self.w * self.h do
        local p = src.px[i]
        self.px[i] = { 255 - p[1], 255 - p[2], 255 - p[3] }
    end
end
function bbmt:multiplyRectRGB(x, y, w, h, c)
    assert(x == 0 and y == 0 and w == self:getWidth() and h == self:getHeight(), "multiply must cover the whole (logical) buffer")
    if self.fail_multiply then error("boom") end
    for i = 1, self.w * self.h do
        local p = self.px[i]
        self.px[i] = { math.floor(p[1] * c.r / 255), math.floor(p[2] * c.g / 255), math.floor(p[3] * c.b / 255) }
    end
end

-- ---------- fake Screen (framebuffer_android stand-in) ----------
local posted = {}       -- list of {inverse=, pixel1=}
local Class = {}
Class.__index = Class
function Class:_updateWindow()
    local ext_bb = self.full_bb or self.bb
    if self.fail_post then error("post failed") end
    -- the real one clones inverse/rotation and copies; emulate the visible result
    local p = ext_bb.px[1]
    if ext_bb:getInverse() == 1 then p = { 255 - p[1], 255 - p[2], 255 - p[3] } end
    table.insert(posted, { inverse = ext_bb:getInverse(), rotation = ext_bb:getRotation(), p = p, bb = ext_bb })
end
local Screen = setmetatable({}, Class)
Screen.bb = BB.new(4, 3, BB.TYPE_BBRGB32)

local log = { warnings = 0 }
log.warn = function(...) log.warnings = log.warnings + 1 end

-- ---------- install ----------
check(Tint.install({}, BB, log) == false, "install refuses a Screen without _updateWindow")
check(Tint.install(Screen, BB, log) == true, "install succeeds")
check(Tint.install(Screen, BB, log) == true, "install is idempotent")
check(rawget(Screen, "_updateWindow") ~= nil, "wrapper lives on the instance")
check(Screen._colourtemp_original == Class._updateWindow, "original remembered")

-- inactive: plain pass-through, no allocation
Screen:_updateWindow()
check(#posted == 1 and posted[1].bb == Screen.bb, "inactive -> original buffer posted")
check(allocs == 1, "inactive -> no extra buffer allocated")

-- active, no night mode
Tint.setColor(3400, 100)
Tint.setActive(true)
Screen:_updateWindow()
check(#posted == 2 and posted[2].bb ~= Screen.bb, "active -> private buffer posted")
check(posted[2].p[1] == 255 and posted[2].p[2] == 190 and posted[2].p[3] == 135, "white became 3400K cream")
check(posted[2].inverse == 0, "private buffer presented without inverse flag")
check(Screen.full_bb == nil, "full_bb restored after post")
check(Screen.bb.px[1][2] == 255, "shadow buffer untouched")
check(allocs == 2, "one buffer allocated")
Screen:_updateWindow()
check(allocs == 2, "buffer reused on next post")

-- black stays black
Screen.bb.px[1] = { 0, 0, 0 }
Screen:_updateWindow()
check(posted[#posted].p[1] == 0 and posted[#posted].p[3] == 0, "black stays black")
Screen.bb.px[1] = { 255, 255, 255 }

-- night mode: shadow has inverse flag, pixels not inverted (CBB semantics)
Screen.bb.inverse = 1
Screen:_updateWindow()
local p = posted[#posted].p
check(posted[#posted].inverse == 0, "night mode: presented already inverted, flag cleared")
check(p[1] == 0 and p[2] == 0 and p[3] == 0, "night mode: white page -> black (not blue), got " .. p[1] .. "," .. p[2] .. "," .. p[3])
Screen.bb.px[1] = { 0, 0, 0 } -- black text
Screen:_updateWindow()
p = posted[#posted].p
check(p[1] == 255 and p[2] == 190 and p[3] == 135, "night mode: black text -> warm white")
-- night mode tint disabled -> original path with inverse flag intact
Tint.setNightModeTint(false)
Screen:_updateWindow()
check(posted[#posted].bb == Screen.bb and posted[#posted].inverse == 1, "night tint off -> untouched inverted post")
Tint.setNightModeTint(true)
Screen.bb.inverse = 0
Screen.bb.px[1] = { 255, 255, 255 }

-- rotation is mirrored
Screen.bb.rotation = 1
Screen:_updateWindow()
check(posted[#posted].rotation == 1, "rotation cloned onto private buffer")
Screen.bb.rotation = 0

-- resize: shadow buffer replaced by a bigger one -> reallocate, free old
local before = allocs
Screen.bb = BB.new(6, 5, BB.TYPE_BBRGB32)
Screen:_updateWindow()
check(allocs == before + 2 and frees == 1, "resize reallocates the private buffer and frees the old one")

-- existing full_bb (viewport) is used as source and restored
local vp = BB.new(6, 5, BB.TYPE_BBRGB32)
vp.px[1] = { 200, 200, 200 }
Screen.full_bb = vp
Screen:_updateWindow()
check(Screen.full_bb == vp, "pre-existing full_bb restored")
check(posted[#posted].p[2] == math.floor(200 * 190 / 255), "full_bb used as source when present")
Screen.full_bb = nil

-- failure inside prepare -> untinted post, then disabled after 3
local st = Tint._state()
st.buffer.fail_multiply = true
local w0 = log.warnings
Screen:_updateWindow()
check(posted[#posted].bb == Screen.bb, "prepare failure -> original buffer posted")
check(log.warnings > w0, "failure logged")
Screen:_updateWindow()
Screen:_updateWindow()
check(Tint.isActive() == false, "three failures disable the tint")
check(st.buffer == nil, "buffer freed after giving up")
Tint.setActive(true)
Screen:_updateWindow()
check(Tint.isActive() and posted[#posted].bb ~= Screen.bb, "re-enabling works and tints again")

-- failure inside the original post propagates but full_bb is restored
Screen.fail_post = true
local ok = pcall(Screen._updateWindow, Screen)
check(ok == false, "original error propagates")
check(Screen.full_bb == nil, "full_bb restored even when the original errors")
Screen.fail_post = false

-- setActive(false) frees the buffer; posts go untouched
Tint.setActive(false)
check(Tint._state().buffer == nil, "disable frees buffer")
Screen:_updateWindow()
check(posted[#posted].bb == Screen.bb, "disabled -> original buffer posted")

-- uninstall restores the class method
Tint.uninstall()
check(rawget(Screen, "_updateWindow") == nil and Screen._updateWindow == Class._updateWindow, "uninstall restores class method")

-- refuse without CBB
BB.use_cbb = false
check(Tint.install(Screen, BB, log) == false, "install refuses the Lua blitter")
BB.use_cbb = true

print(string.format("%d checks, %d failed", checks, failed))
os.exit(failed == 0 and 0 or 1)
