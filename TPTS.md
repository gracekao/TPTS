# TPTS v1.0 - Technical Documentation

Thermal & Power Tuning System for Android device thermal management, stress testing, and power optimization.

> End-user quick start is in `README.md`.

## Quick Start (Windows, Technical)

1. **Run TPTS**: Double-click `start.bat`.
   - Starts the local backend server and opens the dashboard at `http://localhost:8080`.
   - This starts the dashboard only; it does not yet connect an Android device.

2. **Connect Device**:
   - Enter the device IP in the **Device Connection** panel.
   - Click **Establish ADB Link**.
   - The Go backend prepares `iotools` and the MSR device node.
   - Wait for status `[Connected]`, then open **Thermal Tune** to load the real PL1/PL2/PL4 defaults.

3. **Pre-Test Setup**:
   - Verify device connection status shows `[Connected]` (system ready for tuning & monitoring)

4. **Tune or Test**:
        - Use **Live Monitor** to view real-time temperature, power, fan, and selected thermal-zone metrics.
        - Use **Thermal Tune** to change CPU power limits, select automatic/manual fan control, or select one or more stress workloads.
        - Before a stress test, TPTS closes Chrome and Settings, returns to the Android launcher, and clears background app processes.
        - WebGL Aquarium runs Chrome in fullscreen; system bars are restored when the test completes or is stopped.
        - **WebGL Aquarium** runs in Chrome at 60 FPS with a 1024 × 1024 canvas; choose 1 to 30,000 fish.
        - Click **Start Stress Test** and review Temperature, Power, and Throttle Status for the selected duration.
        - To benchmark, switch the Stress Test mode to **Geekbench 7**, choose the CPU/GPU benchmark, and click **Start Geekbench**. Geekbench runs alone (other stress workloads are disabled; the backend also enforces this), and telemetry records until it completes.

## Quick Start (Linux, Technical)

1. Extract the full release ZIP and run `bash start.sh`.
        - `start.sh` restores exec bits (some unzip tools drop them), starts `proxy/tpts_backend_linux_amd64` with `nohup`, waits for `/healthz`, and writes `logs/backend.log`.
        - The backend uses `proxy/adb` when present, otherwise `adb` on `PATH`.
2. In dashboard, set device target IP (for example `10.225.75.45:5555`) and click **Establish ADB Link**.

## Quick Start (Android Local Device, Technical)

1. Copy the extracted `TPTS` folder to the device, for example `adb push TPTS /data/local/tmp/`.
2. Start local backend on Android:
        - `sh /data/local/tmp/TPTS/start_android.sh`
        - If run from another location (such as noexec `/sdcard`), the script first copies the folder to `/data/local/tmp/TPTS` (falling back to `su 0`) and re-runs from there.
        - The backend runs under `nohup` (log: `logs/backend.log`), so it keeps running after `adb shell` exits.
3. The script opens `http://127.0.0.1:8080` in the device browser.
4. In dashboard target input, enter `local`, then click **Establish ADB Link**.

## Release Packaging

Build the all-in-one package (requires Go and Python; needs the Go source under `proxy/`):

```
python tools/build_release.py v1.0.1
gh release create v1.0.1 dist/TPTS-v1.0.1-full.zip --repo gracekao/TPTS --title "TPTS v1.0.1"
```

The script rebuilds all three backends with `-trimpath`, adds the Geekbench package (from `stress_apk/` or the `geekbench-7.0.0` Release), adds Linux `adb` from Google platform-tools, and writes `dist/TPTS-<version>-full.zip` with one top-level `TPTS/` folder and Unix exec permissions.

Windows fallback: if `stress_apk/` is missing, selecting the **Geekbench 7** mode runs `download_geekbench.bat`, which downloads the public Release asset with the built-in `curl.exe` (no GitHub CLI or sign-in needed).

### Cross-Platform Runtime Rules

- **Windows/Linux host mode**: backend uses ADB to connect and control Android target device.
- **Android local mode**: backend executes local shell commands directly on the same device (no ADB hop).
- **Android local stress tests**: TPTS closes Chrome for a clean workload run, then closes all workload tabs and reopens `http://127.0.0.1:8080` when the test finishes or is stopped.
- UI is the same `app/index.html`; it must be opened through backend server, not by opening file directly.

### Tuning Default Value Load and Reset

- After device connection, the UI auto-runs `iotools` reads from the device. On the first successful read, it saves the complete original `0x610` and `0x601` values to `/data/local/tmp/tpts_power_limit_defaults` on the device.
- This device-side baseline remains available after an ADB disconnect or dashboard reconnection. **Reset to System Default** writes both complete saved registers back without requiring a system reboot.
- Register decode mapping:
  - **MSR 0x610** bits **[0:14]** ➔ **PL1**
  - **MSR 0x610** bits **[32:46]** ➔ **PL2**
        - **MSR 0x601** bits **[12:0]** ➔ **PL4**
- Parsed values are shown beside each input and used as the initial tuning defaults.

### Thermal Tune Fine-Tune Rules

Thermal Tune uses the following user-defined limits:

- **SOC Temperature Limit**: the SOC temperature is averaged over the configured **SOC Averaging Period**, which defaults to 5 seconds. PL1 reduction starts when this average exceeds the SOC limit.
- **TSR0 Temperature Limit**: TSR0 uses its current reading. PL1 reduction starts when the reading exceeds the TSR0 limit.
- **TSR1 Temperature Limit**: TSR1 uses its current reading. PL1 reduction starts when the reading exceeds the TSR1 limit.

Auto Tune uses `ectool autofanctrl` before it starts, so the EC remains the sole fan governor. It uses the configured SOC averaging period as its temperature reference, while TSR0/TSR1, TCC, and PROCHOT remain immediate protection inputs. When a limit is exceeded, TPTS reduces PL1 by the configured step, waits for the recovery hold period, and only restores one PL1 step after all available sensors stay below their limits with a 2 C hysteresis margin. PL1 never rises above the user-selected starting value or below the configured minimum.

Auto Tune does not modify `thermal_info_config.json`. On completion it exports a power profile containing the temperature limits, SOC averaging period, EC fan mode, final PL limits, and each PL1 adjustment. Thermal HAL JSON editing remains a separate, manual workflow.

Fan control is represented through thermal HAL cooling-device votes such as `CdevRequest`, `BindedCdevInfo`, and `LimitInfo`; these values are cooling-device states, not direct fan RPM values. The actual fan behavior depends on the device's thermal driver and `WritePath` mapping.

### Active Telemetry Sources

TPTS collects the following data from the connected Android device. Live Monitor requests samples at approximately one-second intervals; stress sampling waits one second between ticks. Both paths use the RAPL sampler in `device_tools/run_stressapp.sh`, with a separate monotonic `/proc/uptime` timestamp for each domain read. Power is calculated from the measured elapsed milliseconds, not an assumed one-second interval.

RAPL samples remain unavailable on the first reading, when a source or energy unit changes, or when an energy counter resets. A decrease is treated as rollover only when the previous counter was in the top quarter of its range and the current counter is in the bottom quarter; sysfs uses `max_energy_range_uj`, while MSR uses the 32-bit counter range. Invalid Package Power samples display `-- W` and create a chart gap instead of reusing an old value. This detects anomalous readings but does not repair a device counter that repeatedly resets.

Some devices reset the package energy counter every few seconds (observed on `10.225.75.73`; both sysfs and MSR `0x611` drop to near zero while IA/GT counters keep counting). Package Power is therefore read about every 100 ms inside each one-second window; intervals that contain a reset are skipped, and power is the valid energy divided by the valid time. The status is `partial:<skipped>/<valid ms>` when intervals were skipped. On `10.225.75.23`, this method matched PTAT's `Power-Package Power` within about 3% on average over a synchronized 27-second idle comparison.

`RAPL_SAMPLE` diagnostics record each domain's source, raw energy before/after, monotonic timestamps, counter range, unit, and status. These fields are included in the stress CSV and in dashboard CSV exports for selected power metrics. Enable Telemetry Debug Log to also inspect them in System Log. Reconnect the device after updating the app so the backend deploys the matching script; an older script is not executed by the new live sampler.

Run frontend regression checks with `node tools/test_rapl.js`. Add `--serial <adb-target>` to also validate shell arithmetic and sample-state transitions on a rooted Android device without starting workloads or changing hardware settings. On Linux, set `ADB` to the ADB executable path if it is not on `PATH`.

| Dashboard data | Primary source | Fallback / calculation | Unit | Used by |
| --- | --- | --- | --- | --- |
| Package Power | `/sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj` | Delta between samples. If unavailable: MSR `0x611` (package energy status) using energy unit from MSR `0x606`. | mW / W | Package Power card, live power chart, CSV log |
| IA / GT Power | Live Monitor and stress sampling read RAPL child domains named `core`/`pp0` and `gt`/`graphics`/`pp1`; if a domain is unavailable, they read MSR `0x639` (IA/PP0) or `0x641` (GT/PP1), using the energy unit from `0x606`. | Unavailable (`-- W`) when neither source exposes the domain. `uncore` is not assumed to be GT. These domains do not necessarily sum to Package Power. | W | Optional IA / GT cards and power chart |
| SoC Temp | Thermal zone whose `type` is `x86_pkg_temp` | `thermal_zone0/temp`, then package DTS from MSR `0x1B1` as TjMax − bits `[22:16]`, with TjMax from MSR `0x1A2` bits `[23:16]` (same registers PTAT uses as `MSR_PACKAGE_TEMP` / `MSR_TEMPERATURE_TARGET`); final safety value is 42 C when no usable source exists. | C | SoC Temp card, temperature chart, CSV log |
| Thermal-zone temperatures | `/sys/class/thermal/thermal_zone*/temp` and matching `type` | None; zones are shown when readable. Raw values above 1000 are converted from millidegrees C for display. | C | Optional thermal-zone cards and temperature chart |
| CPU frequency | `/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq` | None | kHz, displayed as GHz | CPU Freq card and CSV log |
| Fan count and RPM | `ectool pwmgetnumfans` and `ectool pwmgetfanrpm` | `/sys/class/hwmon/hwmon*/fan*_input` | RPM | Fan cards and CSV log |
| PL1 / PL2 | MSR `0x610` | Bits `[0:14]` for PL1 and `[32:46]` for PL2; each raw unit is 1/2^N W, where N is MSR `0x606` bits `[3:0]` (0.125 W on tested PTL devices). PL values are not shown or written until the unit has been read. | W | Thermal Tune defaults and applied-limit display |
| PL4 | MSR `0x601` | Bits `[12:0]`, using the same `0x606` power unit. | W | Thermal Tune defaults and applied-limit display |
| Thermal / PROCHOT / power-limit flags | MSR `0x1B1` (package thermal status) | Bit 0: thermal status, bit 2: PROCHOT, bit 10: power-limit status. Package scope, matching PTAT; CPU0-only `0x19C` is no longer used. | Boolean | Status lamps, Thermal Events, Auto Tune emergency guard |
| CPU Limit Reason | MSR `0x64F` (`MSR_CORE_PERF_LIMIT_REASONS`) | Bits 0–13 are current reasons, bits 16–29 are sticky logs; names follow PTAT `IA Clip Reason MSR` (`PROCHOT`, `THERMAL`, `RSR_LIMIT`, `RATL`, `VR_THERMALERT`, `VR_TDC`, `OTHER`, `PBM_PL1`, `PBM_PL2`, `MAX_TURBO_LIMIT`, `TURBO_ATTEN`). TPTS only reads the register and never clears logs. `MAX_TURBO_LIMIT` is common at idle and is shown as a warning, not a fault. | Text | Thermal Events and CSV `cpu_limit_reasons` / `cpu_limit_reasons_logged` |
| Rest of Package Power | Package − IA − GT | Shown only when all three are valid. Values slightly below zero from timing differences are shown as 0 W; larger negatives are unavailable. Matched PTAT `Rest of Package Power` within about 1% on `10.225.75.23` at idle. | W | Optional card, power chart, CSV |
| Raw tuning registers | MSR `0x610`, `0x64F`, `0x6B0`, `0x1B1`, `0x1A2`, `0x606` | No fallback beyond zero placeholder when a read fails. | Hexadecimal | System Log and stress CSV |

## Architecture Overview

**Frontend** (`app/`: HTML/JS dashboard with WebSocket communication to Go backend)  
**Backend** (`proxy/main.go`: Go server source; outputs platform binaries) + **Tools** (`device_tools/`: stress/tuning tools) + **Logs** (`logs/`: MSR telemetry CSV files)

### System Flow: Establish ADB Link

```
【Web Click】 ➔ Emit 'connect' signal
        ↓
【Go Backend】 ➔ Execute 'adb connect' (physical network link)
        ↓
【Environment Init】 ➔ Push iotools + Mount msr.ko + Create /dev/cpu/0/msr channel
        ↓
【Hardware Query】 ➔ Read MSR registers (0x610 / 0x601) from device via iotools
        ↓
【Decode Display】 ➔ Decode bits [0:14], [32:46], [12:0] as PL1/PL2/PL4
        ↓
【Default Fill】 ➔ Tuning page fills initial PL1/PL2/PL4 defaults from device values
```

**Result**: System is now armed and ready for real-time power tuning & thermal monitoring

## Project Structure

```
TPTS/
├── start.bat              # Launcher - runs backend & opens dashboard
├── start.sh               # Linux launcher
├── start_android.sh       # Android launcher (local mode)
├── download_geekbench.bat # Windows fallback Geekbench download
├── TPTS.md                # Documentation
├── tools/
│   └── build_release.py   # Builds dist/TPTS-<version>-full.zip
├── stress_apk/            # Geekbench 7 package (in full release ZIP)
├── app/
│   ├── index.html         # Dashboard UI
│   └── main.js            # Frontend logic & WebSocket handler
├── device_tools/
│   ├── iotools
│   └── run_stressapp.sh
├── logs/                  # MSR telemetry CSV logs
└── proxy/
        ├── main.go            # Cross-platform backend source
        ├── go.mod
        ├── go.sum
    ├── adb.exe            # Android Debug Bridge (Windows)
    ├── adb                # Android Debug Bridge (Linux, full release ZIP only)
    ├── AdbWinApi.dll
    ├── AdbWinUsbApi.dll
        ├── tpts_backend.exe                 # Windows backend
        ├── tpts_backend_linux_amd64         # Linux backend
        └── tpts_backend_android_arm64       # Android backend
```
