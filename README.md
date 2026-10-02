# KOReader Colour Temperature Plugin

Development folder for `colourtemp.koplugin`, a software warm-tint plugin
for KOReader on Android. The plugin itself (and its own README with install
instructions) lives in [colourtemp.koplugin/](colourtemp.koplugin/README.md).

## Layout

- `colourtemp.koplugin/` — the plugin; copy this folder to
  `koreader/plugins/` on the device.
- `tests/` — LuaJIT harnesses that run on a desktop with no KOReader
  install:
  - `test_tint.lua` — fake blitbuffer + fake Android screen; checks the
    kelvin maths, the hook, night mode, rotation, resize, failure fallback.
  - `test_main.lua` — stubs the KOReader modules the plugin requires and
    drives init, menu, settings, presets, spinners and dispatcher events.

## Run the tests

```bash
luajit tests/test_tint.lua colourtemp.koplugin
```

```bash
luajit tests/test_main.lua colourtemp.koplugin android
```

`test_main.lua` also accepts `desktop` and `eink` to check that the plugin
disables itself on those platforms.

## Build the install zip

```bash
powershell -Command "Compress-Archive -Path colourtemp.koplugin -DestinationPath colourtemp.koplugin.zip -Force"
```
