# Bubble 🫧

An ultra-lightweight macOS system monitor that lives around the MacBook camera.

Pure black, tiny, and quiet: it reads as part of the notch rather than as an app window.

```
 ┌────────────────────────────────────────────────────────────┐
 │  ▭ 4h 32m   CPU (41)   [  camera  ]   (27) GPU   ▬ 64°      │
 └────────────────────────────────────────────────────────────┘
```

## Using Bubble

| Action | Result |
| --- | --- |
| **⌃⌥⌘B** | Expand / collapse |
| Click Bubble | Open Preferences |
| Right-click Bubble | Preferences… / Quit Bubble |

**Collapsed** — CPU and GPU load rings either side of the camera, battery time remaining on the far left and CPU temperature on the far right.

**Expanded** — the same shape grows wider and slightly taller to show CPU (user/system split), GPU, memory (`11.2 / 16 GB`), CPU temperature, network (`↑ 2.1 MB/s  ↓ 840 KB/s`), system power draw (`18.4 W`), battery percentage, charge state and time remaining.

**Preferences** — launch at login, refresh rate (1 / 2 / 5 s), battery time and temperature in the compact view, and display (built-in camera display or primary display). On displays without a notch Bubble sits at the top center.

Unavailable metrics show `—`.

## Lightweight by design

No dependencies, no subprocesses, no Accessibility permission.

- One utility-QoS timer with generous leeway; sampling pauses while the displays sleep.
- Collapsed mode only reads CPU, GPU and (every 5 s) temperature. Memory, power and network are read only while expanded.
- Battery state is event-driven via `IOPSNotificationCreateRunLoopSource`.
- Metric changes are not animated, and values are quantized to display precision so unchanged samples don't re-render.

Sources:

- **CPU** — `host_statistics(HOST_CPU_LOAD_INFO)`
- **GPU** — IOKit `IOAccelerator` → `PerformanceStatistics`
- **Temperature** — IOHIDEventSystem die sensors (Apple Silicon)
- **Memory** — `host_statistics64(HOST_VM_INFO64)`, Activity Monitor's "Memory Used" definition
- **Power** — `AppleSmartBattery` power telemetry
- **Battery** — `IOPSCopyPowerSourcesInfo`
- **Network** — `sysctl(NET_RT_IFLIST2)` 64-bit counters for Wi-Fi/Ethernet
- **Hotkey** — Carbon `RegisterEventHotKey`

## Build & run

```bash
./build.sh run
```

`./build.sh` alone packages `Bubble.app` without launching. Drag it into `/Applications` to keep it; launch at login requires the bundled app.

## Requirements

- macOS 14 or later
- Apple Silicon recommended (temperature is unavailable on Intel)
- Swift 5.9+

## License

MIT
