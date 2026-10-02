# Colour temperature — a KOReader plugin for Android

A software warm tint for KOReader on Android phones and tablets. It lowers the
colour temperature of everything KOReader draws, the same way a night-light
or blue-light filter does, on devices where neither the OS nor KOReader
offers a warmth control.

KOReader itself only supports warmth on e-ink Androids with warm front lights
(Onyx, Tolino, Lenovo, Nook...). On an ordinary phone its light controller
reports "no warmth" and the menu entry never appears. This plugin fills that
gap without touching any KOReader file.

## Install

1. Download `colourtemp.koplugin.zip` from the
   [latest release](https://github.com/glaucon1984/colourtemp.koplugin/releases/latest)
   and unzip it.
2. Copy the `colourtemp.koplugin` folder into `koreader/plugins/` on the
   device (next to the bundled plugins).
3. Restart KOReader.
4. Open the top menu, Settings tab: **Colour temperature** sits right under
   **Night mode**, in both the reader and the file browser.

Requires a KOReader release from 2024 or later (the `multiplyRectRGB`
blitter primitive). The plugin disables itself on non-Android builds and on
Android e-ink devices, where the hardware warmth KOReader already drives is
the better tool.

## Menu

- **Warm tint** — on/off.
- **Colour temperature** — 1800 K to 6500 K (default 3400 K, a warm reading
  lamp; the dialog steps by 100 K, gestures and AutoWarmth can land on any
  value). 6500 K is plain white; lower is more orange. The dialog stays open
  while you adjust, so you see the effect immediately. The label also shows
  the equivalent KOReader warmth percentage.
- **Intensity** — 10 % to 100 %: how strongly the chosen temperature is
  applied, like Android's own Night Light intensity slider.
- **Presets** — Soft (5000 K), Warm (4000 K), Reading lamp (3400 K),
  Sunset (2700 K), Candle (2000 K).
- **Also tint in night mode** — in night mode the page is inverted first and
  the tint applied to the result: dark page, slightly warm text. Turn it off
  to keep night mode untinted.

## Gestures

On first start the plugin maps the **right-edge swipes** (one-finger swipe,
right edge up / down) to *Warmer / Cooler colour temperature: gesture
distance*, the same gestures KOReader assigns by default on readers with
warm lights. It only fills slots that were "Pass through"; anything you had
configured, including an explicit "Nothing", is kept. This happens once
(flag `colourtemp_gestures_assigned` in the settings), so you can change or
remove the mappings afterwards.

Four actions appear under *Taps and gestures → Gesture manager → Screen and
lights* (and in profiles / the quick menu):

- Toggle colour temperature tint
- Set colour temperature (absolute, in kelvin)
- Warmer colour temperature / Cooler colour temperature, by a fixed step
  in kelvin or by **gesture distance**. The distance mapping is the one
  KOReader uses for its frontlight gestures: half the range times the
  square of the swipe length as a fraction of the screen, rounded up to
  100 K. A short flick is 100 K, a quarter-screen swipe 200 K, half a
  screen about 600 K, a full swipe 2400 K.

Picking a temperature with any of them also switches the tint on.

KOReader's own *Increase / Decrease / Set frontlight warmth* actions are
enabled as well (see below); they work in KOReader's 0 to 100 % warmth
scale instead of kelvin.

## AutoWarmth, status bar and the warmth scale

KOReader only shows warmth features on devices that report "natural light"
(warm front lights). The plugin makes the phone report exactly that and
backs the power device's warmth with the tint, so:

- the bundled **AutoWarmth** plugin offers its full *Auto warmth and night
  mode* menu (sun-based or scheduled warmth) and drives the tint. The
  plugin list may still call it "Auto night mode" because that name is
  computed before this plugin loads; the menu entry itself is right.
- the status bar gains the **Frontlight warmth** item.
- the stock warmth gesture actions and their swipe-distance handling work.

KOReader's warmth is 0 to 100 %. Here 0 % is 6500 K (no tint) and 100 % is
1800 K, 47 K per step; the menu shows both numbers. Setting a warmth through
any of these paths switches the tint on, like turning the warm LEDs up on a
real reader; 0 % simply posts untinted frames.

## How it works

On Android KOReader draws into a full-size shadow framebuffer and, on every
refresh, `framebuffer_android:_updateWindow()` copies the whole buffer into
the native window and posts it. The plugin wraps that one method on the live
`Screen` object:

1. copy the shadow buffer into a private buffer of the same size;
2. multiply every pixel by the tint colour using KOReader's C blitter
   (`multiplyRectRGB`, the primitive used for coloured highlights) — a few
   milliseconds for a phone screen;
3. hand that buffer to the original `_updateWindow` by exposing it as
   `Screen.full_bb` for the duration of the call (the original prefers
   `full_bb` over `bb`), then restore.

The shadow buffer is never modified, so partial repaints keep working and
switching the tint off is just "stop wrapping". White multiplied by the tint
colour becomes the new paper colour; black stays black; images and the UI
get the same treatment, exactly like an OS-level filter.

The tint colour comes from Tanner Helland's black-body approximation
(kelvin → RGB), blended towards white by the intensity setting:

| Kelvin | Multiplier (R, G, B) |
|-------:|----------------------|
| 6500   | 255, 255, 255 (off)  |
| 5000   | 255, 228, 206        |
| 4000   | 255, 206, 166        |
| 3400   | 255, 190, 135        |
| 2700   | 255, 167,  87        |
| 2000   | 255, 137,   0        |

Night mode: KOReader's software night mode sets an "inverse" flag on the
shadow buffer and inverts while copying to the window. Tinting before that
inversion would turn warm white into cold dark blue, so the plugin inverts
into its own buffer first, tints the inverted image, and presents it with
the flag cleared.

Safety: if the tint step fails three times in a row the plugin posts
untinted frames and switches itself off until re-enabled, so a broken build
can never leave the screen stuck.

## Limitations

- Android only (phones, tablets, non-e-ink). Nothing to hook on other
  platforms; the plugin stays disabled there.
- It is a display filter, not a hardware setting: it cannot reduce the
  panel's actual blue light output the way the OS Night Light does, and it
  slightly lowers the perceived brightness at warm settings.
- The tint is applied before the frame leaves KOReader, so Android's own
  system UI (status bar, navigation bar, dialogs drawn by Android such as
  the brightness dialog) is not affected.
- Screenshots taken by KOReader come from the untinted shadow buffer.

## Files

- `main.lua` — plugin: settings, menu, gesture actions, natural light
  emulation (`Device.hasNaturalLight` and the power device's warmth
  functions are replaced on the live objects at load time), one-time
  right-edge gesture assignment.
- `tint.lua` — kelvin → RGB maths and the screen hook; pure Lua, no Android
  dependency, so it can be tested on a desktop (see `tests/`).
- `_meta.lua` — plugin metadata.

## Development

Repository layout:

- `colourtemp.koplugin/` — the plugin; this folder is what gets zipped for a
  release and copied to the device.
- `tests/` — LuaJIT harnesses that run on a desktop with no KOReader
  install:
  - `test_tint.lua` — fake blitbuffer + fake Android screen; checks the
    kelvin maths, the hook, night mode, rotation, resize, failure fallback.
  - `test_main.lua` — stubs the KOReader modules the plugin requires and
    drives init, menu, settings, presets, spinners, dispatcher events, the
    natural light emulation and the gesture assignment.
- `.github/workflows/lint.yml` — CI: compiles every Lua file, runs the
  harnesses, and on `v*` tags checks the tag matches the `_meta.lua` version.

Run the tests:

```bash
luajit tests/test_tint.lua colourtemp.koplugin
luajit tests/test_main.lua colourtemp.koplugin android
```

`test_main.lua` also accepts `desktop` and `eink` to check that the plugin
disables itself on those platforms.

Build the install zip:

```bash
powershell -Command "Compress-Archive -Path colourtemp.koplugin -DestinationPath colourtemp.koplugin.zip -Force"
```

## License

GNU Affero General Public License v3.0 or later, like KOReader.
