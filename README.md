# TPTS v1.0

Thermal & Power Tuning System for Android device thermal management, stress testing, and power optimization.

## Download

1. Open repository page: https://github.com/gracekao/TPTS_v1.0
2. Click `Code` -> `Download ZIP`
3. Extract ZIP

## End User Quick Start

### Windows

1. Install GitHub CLI (`gh`) and sign in with access to this repository (`gh auth login`). On first launch, `start.bat` downloads the Geekbench package from the `geekbench-7.0.0` Release if it is missing.
2. Double-click `start.bat` — it starts the local dashboard and opens `http://localhost:8080`.
3. Enter the Android target IP (for example, `10.225.75.45:5555`) and click **Establish ADB Link**.
4. When the status changes to `[Connected]`, use **Live Monitor** for real-time temperatures, package power, and fan speed. To view IA or GT power, select **IA Power** and/or **GT Power** in the metric list. Click **Start Monitoring** to draw the live charts and enable CSV logging. IA/GT readings require a supported Intel RAPL domain; a GT reading of `0 W` can mean no GT energy change during that sample.
5. Open **Thermal Tune** to manage:
	- **CPU Power Limits**: PL1, PL2, and PL4. Device values load as the starting defaults; use **Reset to System Default** to restore them.
	- **Fan Control**: leave Automatic selected or switch to Manual and set an RPM per detected fan.
	- **Auto Tune**: set the temperature limits, SoC averaging period, PL1 step, minimum PL1, and recovery hold. Select the workloads and duration before starting. Auto Tune leaves fan control to the EC, adjusts PL1 in steps, and exports a Power Profile when complete; it does not edit the device thermal JSON.
	- **Stress Test**: select workloads, enter a duration, then review thermal, power, and throttle status. Before starting, TPTS closes Chrome and Settings, returns Android to its launcher, and clears background app processes. WebGL Aquarium runs Chrome in fullscreen and restores system bars when complete. Options include `stressapptest`, WebGL Aquarium (1 to 30,000 fish), and Geekbench 7 CPU/GPU benchmarks. Geekbench runs with `--no-upload`; Duration is a minimum and telemetry continues until it completes.

### Linux

1. `chmod +x start.sh`
2. `./start.sh`
3. Open `http://localhost:8080`
4. Enter Android target IP and click **Establish ADB Link**
5. Geekbench is not auto-downloaded by `start.sh`; download the Geekbench Release ZIP and extract it under `stress_apk/` before selecting that workload.

### Android Local Mode

1. Copy this folder to device (recommended: `/data/local/tmp/TPTS_v1.0`)
2. Run `sh start_android.sh`
3. Open `http://127.0.0.1:8080`
4. Target IP field uses `local`
5. When a local stress test ends or is stopped, TPTS closes browser workload tabs and reopens this local dashboard automatically.
6. Geekbench is not auto-downloaded by `start_android.sh`; provide its package under `stress_apk/` before selecting that workload.

## What Is Included

- Frontend UI (`app/`)
- Device scripts/tools (`device_tools/`)
- Prebuilt backend binaries (`proxy/tpts_backend.exe`, `proxy/tpts_backend_linux_amd64`, `proxy/tpts_backend_android_arm64`)

## Notes

- Log files under `logs/` are not uploaded to repository.
- Go source/module files are not included for end users.

## Technical Documentation

For architecture and register mapping details, see `TPTS.md`.
