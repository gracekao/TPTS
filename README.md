# TPTS

Thermal & Power Tuning System for Android device thermal management, stress testing, and power optimization.

## Download

1. Open the [latest TPTS Release](https://github.com/gracekao/TPTS/releases/latest).
2. Download `TPTS-<version>-full.zip`. It contains everything for Windows, Linux, and Android local mode, including the Geekbench 7 package and `adb`. No other installs or downloads are needed.
3. Extract it. You get one `TPTS` folder.

## End User Quick Start

### Windows

1. Double-click `TPTS\start.bat` — it starts the local dashboard and opens `http://localhost:8080`.
2. Enter the Android target IP (for example, `10.225.75.45:5555`) and click **Establish ADB Link**.
3. When the status changes to `[Connected]`, use **Live Monitor** for real-time temperatures, package power, and fan speed. To view IA or GT power, select **IA Power** and/or **GT Power** in the metric list. Click **Start Monitoring** to draw the live charts and enable CSV logging. IA/GT readings require a supported Intel RAPL domain; a GT reading of `0 W` can mean no GT energy change during that sample.
4. Open **Thermal Tune** to manage:
	- **CPU Power Limits**: PL1, PL2, and PL4. Device values load as the starting defaults; use **Reset to System Default** to restore them.
	- **Fan Control**: leave Automatic selected or switch to Manual and set an RPM per detected fan.
	- **Auto Tune**: set the temperature limits, SoC averaging period, PL1 step, minimum PL1, and recovery hold. Select the workloads and duration before starting. Auto Tune leaves fan control to the EC, adjusts PL1 in steps, and exports a Power Profile when complete; it does not edit the device thermal JSON.
	- **Stress Test**: choose a mode at the top. In **Stress Workloads** mode, select workloads, enter a duration, then review thermal, power, and throttle status. Before starting, TPTS closes Chrome and Settings, returns Android to its launcher, and clears background app processes. WebGL Aquarium runs Chrome in fullscreen and restores system bars when complete. Workloads are `stressapptest` and WebGL Aquarium (1 to 30,000 fish). **Geekbench 7** mode runs only the Geekbench CPU/GPU benchmark (no other stress workloads, so scores are not distorted). It runs with `--no-upload`, has no duration setting, and telemetry continues until the benchmark completes. Auto Tune is unavailable in Geekbench 7 mode.

### Linux (x86_64)

1. In the extracted folder, run `bash start.sh`.
2. The dashboard opens at `http://localhost:8080` (open it manually if no browser starts).
3. Enter the Android target IP and click **Establish ADB Link**. The bundled `proxy/adb` is used; a system `adb` on `PATH` also works.

### Android Local Mode (no internet needed on the device)

TPTS runs on the device itself. Copy the extracted `TPTS` folder to the device, then run `start_android.sh` once:

- From a PC with `adb`:
	```
	adb push TPTS /data/local/tmp/
	adb shell sh /data/local/tmp/TPTS/start_android.sh
	```
- Or copy the folder to device storage (for example `/sdcard/Download/TPTS`) and run `sh /sdcard/Download/TPTS/start_android.sh` from a device shell. Shared storage cannot run programs, so the script copies itself to `/data/local/tmp/TPTS` (using `su` if needed) and starts from there.

Then:

1. The dashboard opens at `http://127.0.0.1:8080` in the device browser.
2. Enter `local` as the target and click **Establish ADB Link**.
3. When a local stress test ends or is stopped, TPTS closes browser workload tabs and reopens this local dashboard automatically.

## What Is Included

- Frontend UI (`app/`)
- Device scripts/tools (`device_tools/`)
- Prebuilt backend binaries (`proxy/tpts_backend.exe`, `proxy/tpts_backend_linux_amd64`, `proxy/tpts_backend_android_arm64`)
- `adb` for Windows (`proxy/adb.exe`) and Linux (`proxy/adb`)
- Geekbench 7 package (`stress_apk/Geekbench-7.0.0-Android-Corporate/`)

If you use the source ZIP instead of the full package, `stress_apk/` and `proxy/adb` are missing. On Windows, TPTS downloads Geekbench automatically the first time you select the **Geekbench 7** mode. On Linux or Android, extract the [Geekbench ZIP](https://github.com/gracekao/TPTS/releases/download/geekbench-7.0.0/Geekbench-7.0.0-Android-Corporate.zip) under `stress_apk/` yourself.

## Notes

- Log files under `logs/` are not uploaded to repository.
- Go source/module files are not included for end users.

## Technical Documentation

For architecture and register mapping details, see `TPTS.md`.
