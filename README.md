# Bubble 🫧

An ultra-lightweight, minimalist macOS system performance overlay designed to hug the MacBook camera/notch.

Pitch black, zero clutter, and near-zero CPU footprint (< 0.1% CPU, < 20MB RAM).

```
   ┌────────────────────────────────────────────────────────┐
   │                       [ CAMERA ]                       │
   │       [ CPU 12% ]  |  [ GPU 8% ]  |  [ ⚡ 3h 45m ]  | [⚙]│
   └────────────────────────────────────────────────────────┘
```

---

## Features

- **Top Camera / Notch Placement**: Positioned right at the top center of the display adjacent to the MacBook camera/notch. Snaps cleanly and blends directly into the black bezel.
- **Dual Display Modes**:
  - **Basic Mode (Default Pill)**:
    - **CPU %** (all-core aggregate load)
    - **GPU %** (hardware utilization from Apple Silicon GPU)
    - **Battery Time / Status** (time remaining or charge state)
    - **Settings Icon** (quick expand & preferences)
  - **Expanded Mode (Detailed HUD)**:
    - **CPU**: All-core total %, core count, dynamic load indicators.
    - **GPU**: Hardware utilization %, renderer utilization, model info.
    - **RAM**: Memory used vs total (e.g. `13.1 / 16.0 GB`), memory pressure indicator.
    - **Power & Battery**: Real-time wattage consumption (e.g. `14.2 W`), battery %, health state, time remaining.
    - **Network**: Real-time download (↓ KB/s or MB/s) and upload (↑ KB/s or MB/s) rates across active interfaces.
    - **Preferences**: Configurable refresh rate (0.5s, 1.0s, 2.0s eco mode), shortcut info, and quit action.
- **Constant Overlay**: Floats on top of all spaces and full-screen apps without stealing focus or interrupting your workflow.
- **Global Toggle Shortcut**:
  - **`⌘ ⌥ ⌃ B`** (`Command + Option + Control + B`): Instantly pull up or hide Bubble from anywhere on macOS.
- **Companion Menu Bar Extra**: Subtle menu bar status icon as a fallback control point.

---

## Zero-Overhead Native Engine

Bubble runs zero external dependencies, zero shell commands, and zero spawned subprocesses (`top`, `ps`, `netstat`, etc.):
- **CPU**: Mach host statistics (`host_statistics` with `HOST_CPU_LOAD_INFO`).
- **GPU**: IOKit `IOAccelerator` registry `PerformanceStatistics`.
- **Power**: IOKit `AppleSmartBattery` (`Voltage` $\times$ `Amperage` for true wattage) & `IOPSCopyPowerSourcesInfo`.
- **Memory**: Darwin `host_statistics64` (`HOST_VM_INFO64`) + `sysctlbyname("hw.memsize")`.
- **Network**: Darwin `getifaddrs` reading hardware interface byte counters (`ifi_ibytes`, `ifi_obytes`).
- **Global Hotkey**: Carbon `RegisterEventHotKey` (requires **zero** Accessibility permissions).

---

## Build & Run

### Quick Build & Launch
```bash
./build.sh run
```

### Manual Build
```bash
# Build executable
swift build -c release

# Package into macOS .app bundle
./build.sh
```

To install permanently, simply drag `Bubble.app` into `/Applications`.

---

## Requirements
- macOS 14.0 or later (Sonoma, Sequoia, and future versions)
- Apple Silicon or Intel Mac
- Xcode / Swift 5.9+

---

## License
MIT
