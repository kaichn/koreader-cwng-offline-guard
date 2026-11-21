# ⚡ CWNG Offline Guard

**A [KOReader](https://github.com/koreader/koreader) user patch for the Calibre-Web NextGen sync plugin that stops it freezing the UI when the server is offline.**

| Before | After |
|---|---|
| Every sync call blocks the UI, up to 60 s each | After one failure, sync pauses for 3 → 30 min |
| No timeout on annotation and sleep-screen calls | 3 s connect / 10 s total |
| Corner taps and gestures dead on the CWNG Library | File-browser gestures work there too |

Skipped syncs report "unreachable", so progress is queued, not lost. The pause resets when Wi-Fi connects or you tap *Sync now*.

## Install
Copy `2-cwng-offline-guard.lua` to `koreader/patches/` and restart KOReader.

## Test
```sh
luajit tests/test_guard.lua 2-cwng-offline-guard.lua
```

Tested with KOReader 2026.07.2 and cwngsync 4.1.48. MIT license.
