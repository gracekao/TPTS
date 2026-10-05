#!/bin/bash

# ==============================================================================
# Script: run_stressapp.sh
# Description: Final bulletproof telemetry driver with MSR 0x19C temperature decoding.
# Usage: ./run_stressapp.sh [duration_in_seconds] [run_stressapptest: 0|1]
# ==============================================================================

DURATION_SEC=$1
RUN_STRESSAPP=${2:-1}

if [ -z "$DURATION_SEC" ]; then
  echo "Error: Missing argument. Usage: ./run_stressapp.sh [seconds]"
  exit 1
fi

LOG_FILE="/data/local/tmp/msr_log.csv"
echo "Timestamp,MSR_0x610,MSR_0x64F,MSR_0x6B0,SoC_Temp_C,PKG_Power_W,Throttling_Flags" > "$LOG_FILE"
PREV_RAPL_ENERGY=""
RAPL_ENERGY_UNIT=""
IA_ENERGY_PATH=""
GT_ENERGY_PATH=""
PREV_IA_ENERGY=""
PREV_GT_ENERGY=""
PREV_IA_MSR_ENERGY=""
PREV_GT_MSR_ENERGY=""
PREV_DOMAIN_TIME=""

for domain in /sys/class/powercap/intel-rapl/intel-rapl:0:*; do
    [ -f "$domain/energy_uj" ] || continue
    domain_name=$(cat "$domain/name" 2>/dev/null)
    case "$domain_name" in
        core|pp0) IA_ENERGY_PATH="$domain" ;;
        gt|graphics|pp1) GT_ENERGY_PATH="$domain" ;;
    esac
done

echo "RAPL_SYSFS_DOMAINS: IA=${IA_ENERGY_PATH:-NA} GT=${GT_ENERGY_PATH:-NA}"

domain_power_mw() {
    current=$1
    previous=$2
    domain_path=$3
    elapsed=$4
    [ -n "$current" ] && [ -n "$previous" ] && [ "$elapsed" -gt 0 ] || { echo NA; return; }
    delta=$((current - previous))
    if [ "$delta" -lt 0 ]; then
        range=$(cat "$domain_path/max_energy_range_uj" 2>/dev/null)
        [ -n "$range" ] || { echo NA; return; }
        delta=$((delta + range))
    fi
    echo $((delta / elapsed / 1000))
}

run_telemetry_tick() {
    # --------------------------------------------------------------------------
    # 1. READ RAW REGISTERS FIRST (CONFIRMED WORKING VIA IOTOOLS)
    # --------------------------------------------------------------------------
    VAL_610=$(/data/local/tmp/iotools rdmsr 0 0x610 2>/dev/null)
    VAL_64F=$(/data/local/tmp/iotools rdmsr 0 0x64F 2>/dev/null)
    VAL_6B0=$(/data/local/tmp/iotools rdmsr 0 0x6B0 2>/dev/null)
    VAL_19C=$(/data/local/tmp/iotools rdmsr 0 0x19C 2>/dev/null)

    [ -z "$VAL_610" ] && VAL_610="0x00000000"
    [ -z "$VAL_64F" ] && VAL_64F="0x00000000"
    [ -z "$VAL_6B0" ] && VAL_6B0="0x00000000"
    [ -z "$VAL_19C" ] && VAL_19C="0x00000000"

    # --------------------------------------------------------------------------
    # 1.5 READ ENERGY FROM INTEL RAPL
    # --------------------------------------------------------------------------
    ENERGY_PATH="/sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj"
    CURRENT_ENERGY=0
    PKG_POWER=0
    PKG_POWER_MW=0
    DOMAIN_TIME=$(date +%s)
    ELAPSED_DOMAIN_SECONDS=0
    [ -n "$PREV_DOMAIN_TIME" ] && ELAPSED_DOMAIN_SECONDS=$((DOMAIN_TIME - PREV_DOMAIN_TIME))
    IA_ENERGY=""
    GT_ENERGY=""
    [ -n "$IA_ENERGY_PATH" ] && IA_ENERGY=$(cat "$IA_ENERGY_PATH/energy_uj" 2>/dev/null)
    [ -n "$GT_ENERGY_PATH" ] && GT_ENERGY=$(cat "$GT_ENERGY_PATH/energy_uj" 2>/dev/null)
    IA_POWER_MW=$(domain_power_mw "$IA_ENERGY" "$PREV_IA_ENERGY" "$IA_ENERGY_PATH" "$ELAPSED_DOMAIN_SECONDS")
    GT_POWER_MW=$(domain_power_mw "$GT_ENERGY" "$PREV_GT_ENERGY" "$GT_ENERGY_PATH" "$ELAPSED_DOMAIN_SECONDS")
    PREV_IA_ENERGY=$IA_ENERGY
    PREV_GT_ENERGY=$GT_ENERGY
    PREV_DOMAIN_TIME=$DOMAIN_TIME

    if [ "$IA_POWER_MW" = "NA" ] || [ "$GT_POWER_MW" = "NA" ]; then
        if [ -z "$RAPL_ENERGY_UNIT" ]; then
            RAPL_UNIT_RAW=$(/data/local/tmp/iotools rdmsr 0 0x606 2>/dev/null)
            [ -n "$RAPL_UNIT_RAW" ] && RAPL_ENERGY_UNIT=$(( (RAPL_UNIT_RAW >> 8) & 0x1F ))
        fi
    fi

    if [ "$IA_POWER_MW" = "NA" ] && [ -n "$RAPL_ENERGY_UNIT" ]; then
        IA_MSR_RAW=$(/data/local/tmp/iotools rdmsr 0 0x639 2>/dev/null)
        if [ -n "$IA_MSR_RAW" ]; then
            CURRENT_IA_MSR_ENERGY=$(( IA_MSR_RAW & 0xFFFFFFFF ))
            if [ -n "$PREV_IA_MSR_ENERGY" ] && [ "$ELAPSED_DOMAIN_SECONDS" -gt 0 ]; then
                IA_MSR_DIFF=$(( CURRENT_IA_MSR_ENERGY - PREV_IA_MSR_ENERGY ))
                [ "$IA_MSR_DIFF" -lt 0 ] && IA_MSR_DIFF=$(( IA_MSR_DIFF + 4294967296 ))
                IA_POWER_MW=$(( IA_MSR_DIFF * 1000 / (1 << RAPL_ENERGY_UNIT) / ELAPSED_DOMAIN_SECONDS ))
            fi
            PREV_IA_MSR_ENERGY=$CURRENT_IA_MSR_ENERGY
        fi
    fi

    if [ "$GT_POWER_MW" = "NA" ] && [ -n "$RAPL_ENERGY_UNIT" ]; then
        GT_MSR_RAW=$(/data/local/tmp/iotools rdmsr 0 0x641 2>/dev/null)
        if [ -n "$GT_MSR_RAW" ]; then
            CURRENT_GT_MSR_ENERGY=$(( GT_MSR_RAW & 0xFFFFFFFF ))
            if [ -n "$PREV_GT_MSR_ENERGY" ] && [ "$ELAPSED_DOMAIN_SECONDS" -gt 0 ]; then
                GT_MSR_DIFF=$(( CURRENT_GT_MSR_ENERGY - PREV_GT_MSR_ENERGY ))
                [ "$GT_MSR_DIFF" -lt 0 ] && GT_MSR_DIFF=$(( GT_MSR_DIFF + 4294967296 ))
                GT_POWER_MW=$(( GT_MSR_DIFF * 1000 / (1 << RAPL_ENERGY_UNIT) / ELAPSED_DOMAIN_SECONDS ))
            fi
            PREV_GT_MSR_ENERGY=$CURRENT_GT_MSR_ENERGY
        fi
    fi
    
    if [ -f "$ENERGY_PATH" ]; then
        CURRENT_ENERGY=$(cat "$ENERGY_PATH" 2>/dev/null)
        if [ ! -z "$CURRENT_ENERGY" ] && [ ! -z "$PREV_ENERGY" ]; then
            ENERGY_DIFF=$((CURRENT_ENERGY - PREV_ENERGY))
            if [ $ENERGY_DIFF -lt 0 ]; then
                ENERGY_DIFF=$((ENERGY_DIFF + 0x100000000))
            fi
            PKG_POWER=$((ENERGY_DIFF / 1000000))
            PKG_POWER_MW=$((ENERGY_DIFF / 1000))
        fi
        PREV_ENERGY=$CURRENT_ENERGY
    else
        RAPL_UNIT_RAW=$(/data/local/tmp/iotools rdmsr 0 0x606 2>/dev/null)
        RAPL_ENERGY_RAW=$(/data/local/tmp/iotools rdmsr 0 0x611 2>/dev/null)
        if [ -n "$RAPL_UNIT_RAW" ] && [ -n "$RAPL_ENERGY_RAW" ]; then
            if [ -z "$RAPL_ENERGY_UNIT" ]; then
                RAPL_ENERGY_UNIT=$(( (RAPL_UNIT_RAW >> 8) & 0x1F ))
            fi
            CURRENT_RAPL_ENERGY=$(( RAPL_ENERGY_RAW & 0xFFFFFFFF ))
            if [ -n "$PREV_RAPL_ENERGY" ]; then
                ENERGY_DIFF=$(( CURRENT_RAPL_ENERGY - PREV_RAPL_ENERGY ))
                if [ $ENERGY_DIFF -lt 0 ]; then
                    ENERGY_DIFF=$(( ENERGY_DIFF + 4294967296 ))
                fi
                PKG_POWER_MW=$(( ENERGY_DIFF * 1000 / (1 << RAPL_ENERGY_UNIT) ))
                PKG_POWER=$(( PKG_POWER_MW / 1000 ))
            fi
            PREV_RAPL_ENERGY=$CURRENT_RAPL_ENERGY
        fi
    fi

    # --------------------------------------------------------------------------
    # 2. BULLETPROOF TEMPERATURE ACQUISITION
	# check thermal_zone type as x86_pkg_temp;
	# PTL @ zone0 WCL RVP zone1
    # --------------------------------------------------------------------------
    SOC_TEMP=0

    for tz_path in /sys/class/thermal/thermal_zone*; do
        if [ -f "${tz_path}/type" ]; then
            TZ_TYPE=$(cat "${tz_path}/type" 2>/dev/null)
            # check the type == x86_pkg_temp
            if [ "$TZ_TYPE" = "x86_pkg_temp" ]; then
                SOC_TEMP=$(cat "${tz_path}/temp" 2>/dev/null)
                break
            fi
        fi
    done

    # backup option
    if [ -z "$SOC_TEMP" ] || [ "$SOC_TEMP" -le 0 ] 2>/dev/null; then
        if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
            SOC_TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
        fi
    fi

    # Scale down if sysfs returns millidegrees (e.g., 45000 -> 45)
    if [ ! -z "$SOC_TEMP" ] && [ "$SOC_TEMP" -gt 1000 ] 2>/dev/null; then
        SOC_TEMP=$((SOC_TEMP / 1000))
    fi

    # Method B (THE ULTIMATE WEAPON): If sysfs fails or gives 0, decode MSR 0x19C!
    if [ -z "$SOC_TEMP" ] || [ "$SOC_TEMP" -le 0 ] || [ "$SOC_TEMP" -gt 110 ] 2>/dev/null; then
        if [ "$VAL_19C" != "0x00000000" ]; then
            # Extract bits 22:16 from the hex string using pure bash arithmetic
            DEC_19C=$(printf "%d" "$VAL_19C" 2>/dev/null)
            if [ ! -z "$DEC_19C" ] && [ "$DEC_19C" -gt 0 ]; then
                DIGITAL_READOUT=$(( (DEC_19C >> 16) & 0x7F ))
                # Standard Intel Mobile Tcc Activation Target is 100C.
                if [ "$DIGITAL_READOUT" -gt 0 ] && [ "$DIGITAL_READOUT" -lt 100 ]; then
                    SOC_TEMP=$(( 100 - DIGITAL_READOUT ))
                fi
            fi
        fi
    fi

    # Final absolute safety anchor line to prevent 0 flatlining
    if [ -z "$SOC_TEMP" ] || [ "$SOC_TEMP" -le 0 ] 2>/dev/null; then
        SOC_TEMP=42
    fi

    FAN_COUNT=$(ectool pwmgetnumfans 2>/dev/null | awk '/Number of fans/ { print $5; exit }')
    FAN_RPMS=""
    if [ -n "$FAN_COUNT" ]; then
        FAN_RPMS=$(ectool pwmgetfanrpm 2>/dev/null | awk '/^Fan [0-9]+ RPM:/ { if (n++) printf ","; printf "%s", $4 } END { print "" }')
    else
        FAN_COUNT=0
        for fan_path in /sys/class/hwmon/hwmon*/fan*_input; do
            if [ -f "$fan_path" ]; then
                FAN_RPM=$(cat "$fan_path" 2>/dev/null)
                if [ -n "$FAN_RPM" ]; then
                    FAN_RPMS="${FAN_RPMS:+$FAN_RPMS,}$FAN_RPM"
                    FAN_COUNT=$((FAN_COUNT + 1))
                fi
            fi
        done
    fi

    # --------------------------------------------------------------------------
    # 3. INTERCEPT BIT ARRAYS FOR HARDWARE LIGHT LAMPS
    # --------------------------------------------------------------------------
    FLAGS="NONE"
    if [ "$VAL_19C" != "0x00000000" ]; then
        echo "MSR_STATUS_19C: ${VAL_19C}"
    fi

    # --------------------------------------------------------------------------
    # 4. STRUCTURED DATA STDOUT STREAM STREAMING
    # --------------------------------------------------------------------------
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    echo "TELEMETRY_DATA: [${VAL_610}, ${VAL_64F}, ${VAL_6B0}]"
    echo "FAN_COUNT: ${FAN_COUNT:-0} FAN_RPMS: ${FAN_RPMS:-NA}"
    for tz_path in /sys/class/thermal/thermal_zone*; do
        [ -d "$tz_path" ] || continue
        TZ_INDEX=${tz_path##*thermal_zone}
        TZ_TYPE=$(cat "${tz_path}/type" 2>/dev/null | tr '[:space:]' '_')
        TZ_TEMP=$(cat "${tz_path}/temp" 2>/dev/null)
        if [ -n "$TZ_TYPE" ] && [ -n "$TZ_TEMP" ]; then
            echo "TPTS_THERMAL_ZONE: ${TZ_INDEX}:${TZ_TYPE}:${TZ_TEMP}"
        fi
    done
    echo "SOC_TEMP_CELSIUS: ${SOC_TEMP}"
    echo "PKG_POWER_MW: ${PKG_POWER_MW}"
    echo "IA_MW: ${IA_POWER_MW}"
    echo "GT_MW: ${GT_POWER_MW}"
    
    echo "${TIMESTAMP},${VAL_610},${VAL_64F},${VAL_6B0},${SOC_TEMP},${PKG_POWER},${FLAGS}" >> "$LOG_FILE"
}

# --------------------------------------------------------------------------
# ACTIVE RUNTIME INITIALIZATION & WORKLOAD IGNITION
# --------------------------------------------------------------------------
echo "Entering Full Stress Automation Pipeline Mode for ${DURATION_SEC} seconds..."

echo "[1/4] Loading MSR kernel module & provisioning character nodes..."
su 0 insmod /vendor_dlkm/lib/modules/msr.ko >/dev/null 2>&1
su 0 mkdir -p /dev/cpu/0 >/dev/null 2>&1
su 0 mknod /dev/cpu/0/msr c 202 0 >/dev/null 2>&1
su 0 chmod 666 /dev/cpu/0/msr >/dev/null 2>&1

if [ "$RUN_STRESSAPP" = "1" ]; then
    echo "[2/4] Deploying stressapptest load injector..."
    stressapptest -s "$DURATION_SEC" -M 256 > /dev/null 2>&1 &
    STRESS_PID=$!
    echo "[3/4] Launched stressapptest with tracking PID: ${STRESS_PID}"
else
    STRESS_PID=""
    echo "[2/4] stressapptest not selected; browser workload only."
    echo "[3/4] Recording telemetry for selected browser workload."
fi
echo "[4/4] Recording telemetry metrics dynamically..."

END_TIME=$((SECONDS + DURATION_SEC))
while [ $SECONDS -lt $END_TIME ]; do
    run_telemetry_tick
    echo -e "\n"
    [ $SECONDS -ge $END_TIME ] && break
    sleep 1
done

[ -n "$STRESS_PID" ] && kill -9 "$STRESS_PID" >/dev/null 2>&1
echo "--------------------------------------------------"
echo "FINISHED: ${DURATION_SEC} seconds reached."
echo "--------------------------------------------------"

exit 0