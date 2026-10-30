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
   - Wait for status `[Connected]`, then open **Manual Tune** to load the real PL1/PL2/PL4 defaults.

3. **Pre-Test Setup**:
   - Verify device connection status shows `[Connected]` (system ready for tuning & monitoring)

4. **Tune or Test**:
        - Use **Live Monitor** to view real-time temperature, power, fan, and selected thermal-zone metrics.
        - Use **Manual Tune** to change CPU power limits, select automatic/manual fan control, or edit the thermal HAL JSON.
        - Use **Stress & Auto Tune**: step 1 selects the workload, step 2 sets the optional Auto Tune limits, step 3 has **Start Stress Test** (workload only) and **Start Auto Tune** (workload plus stepwise PL1 control).
        - Before a stress test, TPTS closes Chrome and Settings, returns to the Android launcher, and clears background app processes.
        - WebGL Aquarium runs Chrome in fullscreen; system bars are restored when the test completes or is stopped.
        - **WebGL Aquarium** runs in Chrome at 60 FPS with a 1024 × 1024 canvas; choose 1 to 30,000 fish.
        - Click **Start Stress Test** and review Temperature, Power, and Throttle Status for the selected duration.
        - To benchmark, switch the Workload mode to **Geekbench 7**, choose the CPU/GPU benchmark, and click **Start Geekbench**. Geekbench runs alone (other stress workloads are disabled; the backend also enforces this), and telemetry records until it completes.

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

#### Power limit setting vs Now

Each **PLx Setting** row in Thermal Tune shows two values:

- **Input box**: the value **Apply Power Limits** writes. It starts at the saved system default and changes only when you edit it, apply it, or Auto Tune adjusts PL1.
- **Now: X W** (right side, also the PL1/PL2 cards): the value the device is using now, read from MSR `0x610` / `0x601` every second.

`Now: 15 W (limited)` in amber means the device is below the value TPTS last applied (or the saved default if nothing was applied), so another controller lowered it. On Android desktop devices this is usually the thermal HAL: for example, on `10.225.75.53` (lapis), `init.lapis.rc` sets PL1 to 25 W at boot, and `/vendor/etc/thermal/lapis/thermal_info_config.json` defines a `package-0` power-cap cooling device (25 W down to 13 W in 0.5 W steps) bound to virtual sensors such as `VIRTUAL-SKIN-PL1` and `VIRTUAL-TOP-SOC`. During a stress test it lowered PL1 to 15 W and restored 25 W after cool-down. The firmware MMIO limit (`intel-rapl-mmio:0`) stays at 25 W; the CPU uses the lower of the two. Results recorded in this state include the thermal HAL's throttling; to test with a fixed PL1, change the thermal configuration first.

### Thermal Tune Fine-Tune Rules

Thermal Tune uses the following user-defined limits:

- **SOC Temperature Limit**: the SOC temperature is averaged over the configured **SOC Averaging Period**, which defaults to 5 seconds. PL1 reduction starts when this average exceeds the SOC limit.
- **TSR0 Temperature Limit**: TSR0 uses its current reading. PL1 reduction starts when the reading exceeds the TSR0 limit.
- **TSR1 Temperature Limit**: TSR1 uses its current reading. PL1 reduction starts when the reading exceeds the TSR1 limit.

Auto Tune uses `ectool autofanctrl` before it starts, so the EC remains the sole fan governor. It uses the configured SOC averaging period as its temperature reference, while TSR0/TSR1, TCC, and PROCHOT remain immediate protection inputs. When a limit is exceeded, TPTS reduces PL1 by the configured step, waits for the recovery hold period, and only restores one PL1 step after all available sensors stay below their limits with a 2 C hysteresis margin. PL1 never rises above the user-selected starting value or below the configured minimum.

Auto Tune does not modify `thermal_info_config.json`. On completion it exports a power profile containing the temperature limits, SOC averaging period, EC fan mode, final PL limits, and each PL1 adjustment. Thermal HAL JSON editing remains a separate, manual workflow.

Fan control is represented through thermal HAL cooling-device votes such as `CdevRequest`, `BindedCdevInfo`, and `LimitInfo`; these values are cooling-device states, not direct fan RPM values. The actual fan behavior depends on the device's thermal driver and `WritePath` mapping.

### Active Telemetry Sources

TPTS collects the following data from the connected Android device. Like PTAT, a single resident sampler on the device (`run_stressapp.sh --monitor`, run from the private copy `/data/local/tmp/tpts_monitor.sh`) takes one sample per second on a fixed schedule and streams it to the dashboard from connection until disconnect. The Live Data cards always update, whether or not **Start Monitoring** is pressed. The sampler is restarted after the device script is redeployed and stopped through `/data/local/tmp/tpts_monitor.pid` when the dashboard disconnects.

While **Start Monitoring** is active, the device appends every sample to `/data/local/tmp/tpts_monitor.csv` (about 400 bytes per second), and **Stop Monitoring** saves it as `logs/monitor_log_<timestamp>.csv`. The browser keeps only the last hour for **Export**, so long sessions do not grow browser memory.

Stress tests do not start a second sampler: `run_stressapp.sh <seconds> <0|1>` only drives the workload and writes the phase (`stress`, then `cooldown`) to `/data/local/tmp/tpts_phase`. Every CSV row has a `Phase` column (`idle`, `stress`, `cooldown`); rows in the `stress` phase are also copied to the stress log, saved as `logs/msr_log_<timestamp>.csv`. If monitoring was on before the test, the chart and the monitor log continue without a gap through the test and cool-down; otherwise charting stops when the test ends and the cards keep updating.

The dashboard and backend exchange a version string (`TPTS_APP_VERSION` / `tptsVersion`); a mismatch shows **Backend outdated - rerun start.bat**. Power uses the RAPL sampler in `device_tools/run_stressapp.sh`, with a separate monotonic `/proc/uptime` timestamp for each domain read, and is calculated from the measured elapsed milliseconds, not an assumed one-second interval.

RAPL samples remain unavailable on the first reading, when a source or energy unit changes, or when an energy counter resets. A decrease is treated as rollover only when the previous counter was in the top quarter of its range and the current counter is in the bottom quarter; sysfs uses `max_energy_range_uj`, while MSR uses the 32-bit counter range. Invalid Package Power samples display `-- W` and create a chart gap instead of reusing an old value. This detects anomalous readings but does not repair a device counter that repeatedly resets.

Some devices reset the package energy counter every few seconds (observed on `10.225.75.73`; both sysfs and MSR `0x611` drop to near zero while IA/GT counters keep counting). Package Power is therefore read about every 100 ms inside each one-second window; intervals that contain a reset are skipped, and power is the valid energy divided by the valid time. The status is `partial:<skipped>/<valid ms>` when intervals were skipped. On `10.225.75.23`, this method matched PTAT's `Power-Package Power` within about 3% on average over a synchronized 27-second idle comparison.

`RAPL_SAMPLE` diagnostics record each domain's source, raw energy before/after, monotonic timestamps, counter range, unit, and status. These fields are included in the stress CSV and in dashboard CSV exports for selected power metrics. Enable Telemetry Debug Log to also inspect them in System Log. Reconnect the device after updating the app so the backend deploys the matching script and restarts the sampler.

| Dashboard data | Primary source | Fallback / calculation | Unit | Used by |
| --- | --- | --- | --- | --- |
| Package Power | `/sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj` | Delta between samples. If unavailable: MSR `0x611` (package energy status) using energy unit from MSR `0x606`. | mW / W | Package Power card, live power chart, CSV log |
| IA / GT Power | Live Monitor and stress sampling read RAPL child domains named `core`/`pp0` and `gt`/`graphics`/`pp1`; if a domain is unavailable, they read MSR `0x639` (IA/PP0) or `0x641` (GT/PP1), using the energy unit from `0x606`. | Unavailable (`-- W`) when neither source exposes the domain. `uncore` is not assumed to be GT. These domains do not necessarily sum to Package Power. | W | Optional IA / GT cards and power chart |
| SoC Temp | Thermal zone whose `type` is `x86_pkg_temp` | `thermal_zone0/temp`, then package DTS from MSR `0x1B1` as TjMax − bits `[22:16]`, with TjMax from MSR `0x1A2` bits `[23:16]` (same registers PTAT uses as `MSR_PACKAGE_TEMP` / `MSR_TEMPERATURE_TARGET`); final safety value is 42 C when no usable source exists. | C | SoC Temp card, temperature chart, CSV log |
| Thermal-zone temperatures | `/sys/class/thermal/thermal_zone*/temp` and matching `type` | None; zones are shown when readable. Raw values above 1000 are converted from millidegrees C for display. | C | Optional thermal-zone cards and temperature chart |
| CPU frequency | Effective (busy) frequency per core = TSC rate × ΔAPERF (MSR `0xE8`) / ΔMPERF (MSR `0xE7`) over each one-second sample, the same definition as PTAT `Effective Frequency (UCC/UCR)`. The TSC rate is calibrated from MSR `0x10` against uptime after 5 seconds (MSR `0xCE` ratio × 100 MHz before that). The card shows CPU0; logs also record every core. | `scaling_cur_freq` (a few-millisecond snapshot) only when MSR counters are unavailable; a core that stayed idle for the whole second is `NA`. | kHz / MHz, displayed as GHz | CPU Freq card, CSV `CPU_Freq_kHz` / `CPU_Eff_MHz_all` |
| Fan count and RPM | `ectool pwmgetnumfans` and `ectool pwmgetfanrpm` | `/sys/class/hwmon/hwmon*/fan*_input` | RPM | Fan cards and CSV log |
| PL1 / PL2 | MSR `0x610` | Bits `[0:14]` for PL1 and `[32:46]` for PL2; each raw unit is 1/2^N W, where N is MSR `0x606` bits `[3:0]` (0.125 W on tested PTL devices). PL values are not shown or written until the unit has been read. | W | Thermal Tune defaults and applied-limit display |
| PL4 | MSR `0x601` | Bits `[12:0]`, using the same `0x606` power unit. | W | Thermal Tune defaults and applied-limit display |
| Thermal / PROCHOT / power-limit flags | MSR `0x1B1` (package thermal status) | Bit 0: thermal status, bit 2: PROCHOT, bit 10: power-limit status. Package scope, matching PTAT; CPU0-only `0x19C` is no longer used. | Boolean | Status lamps, Thermal Events, Auto Tune emergency guard |
| CPU Limit Reason | MSR `0x64F` (`MSR_CORE_PERF_LIMIT_REASONS`) | Bits 0–13 are current reasons, bits 16–29 are sticky logs; names follow PTAT `IA Clip Reason MSR` (`PROCHOT`, `THERMAL`, `RSR_LIMIT`, `RATL`, `VR_THERMALERT`, `VR_TDC`, `OTHER`, `PBM_PL1`, `PBM_PL2`, `MAX_TURBO_LIMIT`, `TURBO_ATTEN`). TPTS only reads the register and never clears logs. Live Monitor and stress sampling read `0x64F` on every CPU that has an MSR node, about every 100 ms inside each one-second sample window (about 1 ms per core read), and combine the results. When only `MAX_TURBO_LIMIT` / `TURBO_ATTEN` are present in the last second, Thermal Events shows `OK (at max turbo)` without a warning color; thermal reasons are red and other reasons are yellow. | Text | Thermal Events, live CSV `cpu_limit_reasons` / `cpu_limit_reasons_last_1s` / `cpu_limit_cores` / `cpu_limit_reasons_logged`, stress CSV `MSR_0x64F_all_cores` / `MSR_0x64F_active_last_1s` |
| Rest of Package Power | Package − IA − GT | Shown only when all three are valid. Values slightly below zero from timing differences are shown as 0 W; larger negatives are unavailable. Matched PTAT `Rest of Package Power` within about 1% on `10.225.75.23` at idle. | W | Optional card, power chart, CSV |
| Raw tuning registers | MSR `0x610`, `0x64F`, `0x6B0`, `0x1B1`, `0x1A2`, `0x606` | No fallback beyond zero placeholder when a read fails. | Hexadecimal | System Log and stress CSV |

#### Reading CPU Limit Reason

The text under **CPU Limit Reason** in Live Monitor can be selected and copied, or included in a screenshot. Click **What do these mean?** under it for a short summary.

- **Status (right side of the row)**: `OK` = no reason in the last second; `OK (at max turbo)` = only `MAX_TURBO_LIMIT` / `TURBO_ATTEN`, meaning the CPU is running as fast as allowed (normal, no warning color); otherwise the reasons are listed, red for thermal reasons and yellow for the rest.
- **Now**: reasons limiting CPU frequency at this sample, on any core. `Not limited` means no current limit. A CPU list such as `(CPU2)` appears only when cores report different values. Cores are read one after another about 1 ms apart, so a single listed CPU usually means the reason started or ended between those reads; on `10.225.75.23` the register is package-wide and all cores match when read at the same instant.
- **Last 1s**: every reason seen in the ~100 ms polls since the previous sample. It catches short events such as a brief `PBM_PL2` that **Now** misses, and each CSV row records when it happened. Events shorter than the poll interval can still appear only in **History**.
- **History (since boot, not current)**: reasons that occurred since boot or since another tool last cleared the register. They are not current; TPTS never clears them.
- **MSR 0x64F (all cores)**: raw value for analysis (OR of all cores). Bits 0–13 are current reasons, bits 16–29 are the History log for the same reasons (bit + 16).

Example: `Now: Not limited`, `History: PBM_PL2, MAX_TURBO_LIMIT` means the CPU is not limited now, but earlier it hit PL2 and the maximum turbo frequency, for example during a short burst. This is normal at low temperature.

Worked example:

```
CPU Limit Reason   OK (at max turbo)
Now: MAX_TURBO_LIMIT (CPU2)
Last 1s: MAX_TURBO_LIMIT
History (since boot, not current): THERMAL, PBM_PL2, MAX_TURBO_LIMIT
MSR 0x64F (all cores) 0x18021000
```

- `0x18021000` = bit 12 (`0x1000`, `MAX_TURBO_LIMIT` now) + bit 17 (`0x20000`, `THERMAL` log) + bit 27 (`0x8000000`, `PBM_PL2` log) + bit 28 (`0x10000000`, `MAX_TURBO_LIMIT` log).
- The CPU is currently only at its maximum turbo frequency, so the status is `OK (at max turbo)`.
- `(CPU2)`: CPU2 reported it at its read instant; the other cores were read just before or after the change.
- `THERMAL` and `PBM_PL2` in History happened earlier (for example during a stress test) and are not happening now. If `THERMAL` appears in **Now** or **Last 1s**, check temperature and cooling.

| Reason | Meaning | Usually a concern? |
| --- | --- | --- |
| `MAX_TURBO_LIMIT` | Reached the maximum allowed turbo frequency | No, common at idle or light load |
| `TURBO_ATTEN` | Turbo frequency changes were damped | No |
| `PBM_PL1` / `PBM_PL2` | Limited by package power limit PL1 / PL2 | Expected under load; check PL settings if performance is low |
| `THERMAL` / `PROCHOT` / `RATL` | Thermal limit or hot signal | Yes, check temperature and cooling |
| `VR_THERMALERT` / `VR_TDC` | Voltage regulator temperature or current limit | Yes, platform power delivery limit |
| `RSR_LIMIT` / `OTHER` | Residency-state or other platform limit | Investigate if it appears often |

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
├── stress_apk/            # Geekbench 7 package (in full release ZIP)
├── app/
│   ├── index.html         # Dashboard UI
│   └── main.js            # Frontend logic & WebSocket handler
├── device_tools/
│   ├── iotools
│   └── run_stressapp.sh
├── logs/                  # MSR telemetry CSV logs
└── proxy/
    ├── adb.exe            # Android Debug Bridge (Windows)
    ├── adb                # Android Debug Bridge (Linux, full release ZIP only)
    ├── AdbWinApi.dll
    ├── AdbWinUsbApi.dll
        ├── tpts_backend.exe                 # Windows backend
        ├── tpts_backend_linux_amd64         # Linux backend
        └── tpts_backend_android_arm64       # Android backend
```
