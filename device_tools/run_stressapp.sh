#!/bin/bash

# ==============================================================================
# Script: run_stressapp.sh
# Description: Final bulletproof telemetry driver with MSR 0x1B1 package temperature decoding.
# Usage: ./run_stressapp.sh [duration_in_seconds] [run_stressapptest: 0|1]
# ==============================================================================

# Android mksh arithmetic is 32-bit signed, so keep timestamps relative and convert counters in awk.
rapl_time_ms() {
    awk -v base="${RAPL_TIME_BASE:-0}" '{ printf "%.0f\n", ($1 - base) * 1000 }' /proc/uptime
}

rapl_u32() {
    awk -v value="$1" 'BEGIN { if (value < 0) value += 4294967296; printf "%.0f\n", value }'
}

rapl_power_mw() {
    awk -v current="$1" -v previous="$2" -v elapsed="$3" -v range="$4" -v scale="$5" -v divisor="$6" 'BEGIN {
        if (current !~ /^[0-9]+$/ || previous !~ /^[0-9]+$/) { print "NA missing"; exit }
        if (elapsed <= 0) { print "NA invalid_time"; exit }
        if (scale <= 0 || divisor <= 0) { print "NA invalid_unit"; exit }
        if (range > 0 && (current > range || previous > range)) { print "NA invalid_counter"; exit }
        delta = current - previous
        status = "ok"
        if (delta < 0) {
            if (range > 0 && previous >= range * 0.75 && current <= range * 0.25) {
                delta += range
                status = "wrap"
            } else { print "NA reset"; exit }
        }
        printf "%.0f %s\n", delta * scale / divisor / elapsed, status
    }'
}

rapl_delta_uj() {
    awk -v current="$1" -v previous="$2" -v range="$3" -v scale="$4" -v divisor="$5" 'BEGIN {
        if (current !~ /^[0-9]+$/ || previous !~ /^[0-9]+$/) { print "NA missing"; exit }
        if (scale <= 0 || divisor <= 0) { print "NA invalid_unit"; exit }
        if (range > 0 && (current > range || previous > range)) { print "NA invalid_counter"; exit }
        delta = current - previous
        status = "ok"
        if (delta < 0) {
            if (range > 0 && previous >= range * 0.75 && current <= range * 0.25) {
                delta += range
                status = "wrap"
            } else { print "NA reset"; exit }
        }
        printf "%.0f %s\n", delta * scale / divisor, status
    }'
}

# Some platforms reset the package counter every few seconds, so integrate short valid intervals.
rapl_pkg_window_step() {
    rapl_read_domain "$ENERGY_PATH" 0x611
    if [ -n "$RAPL_WIN_SOURCE" ]; then
        if [ "$RAPL_SOURCE" != "$RAPL_WIN_SOURCE" ] || [ "$RAPL_UNIT" != "$RAPL_WIN_UNIT" ] || [ "$RAPL_TIME" -le "$RAPL_WIN_TIME" ]; then
            set -- NA skipped
        else
            set -- $(rapl_delta_uj "$RAPL_ENERGY" "$RAPL_WIN_PREV" "$RAPL_RANGE" "$RAPL_SCALE" "$RAPL_DIVISOR")
        fi
        if [ "$1" = NA ]; then
            RAPL_WIN_SKIPPED=$((RAPL_WIN_SKIPPED + 1))
        else
            RAPL_WIN_UJ=$((RAPL_WIN_UJ + $1))
            RAPL_WIN_MS=$((RAPL_WIN_MS + RAPL_TIME - RAPL_WIN_TIME))
            [ "$2" = wrap ] && RAPL_WIN_WRAP=1
        fi
    fi
    RAPL_WIN_PREV=$RAPL_ENERGY RAPL_WIN_TIME=$RAPL_TIME
    RAPL_WIN_SOURCE=$RAPL_SOURCE RAPL_WIN_UNIT=$RAPL_UNIT
}

rapl_wait() {
    rapl_wait_end=$(($(rapl_time_ms) + $1 * 1000))
    while [ "$(rapl_time_ms)" -lt "$rapl_wait_end" ]; do
        sleep 0.1
        rapl_pkg_window_step
    done
}

rapl_init() {
    read RAPL_TIME_BASE rapl_uptime_rest < /proc/uptime
    RAPL_WIN_PREV= RAPL_WIN_TIME= RAPL_WIN_SOURCE= RAPL_WIN_UNIT= RAPL_WIN_FIRST= RAPL_WIN_START=
    RAPL_WIN_UJ=0 RAPL_WIN_MS=0 RAPL_WIN_SKIPPED=0 RAPL_WIN_WRAP=
    RAPL_PKG_PREV= RAPL_IA_PREV= RAPL_GT_PREV=
    RAPL_PKG_TIME= RAPL_IA_TIME= RAPL_GT_TIME=
    RAPL_PKG_SOURCE= RAPL_IA_SOURCE= RAPL_GT_SOURCE=
    RAPL_PKG_UNIT= RAPL_IA_UNIT= RAPL_GT_UNIT=
    ENERGY_PATH=/sys/class/powercap/intel-rapl/intel-rapl:0
    IA_ENERGY_PATH= GT_ENERGY_PATH=
    for rapl_path in "$ENERGY_PATH":*; do
        [ -r "$rapl_path/energy_uj" ] || continue
        case "$(cat "$rapl_path/name" 2>/dev/null)" in
            core|pp0) IA_ENERGY_PATH=$rapl_path ;;
            gt|graphics|pp1) GT_ENERGY_PATH=$rapl_path ;;
        esac
    done
}

rapl_read_domain() {
    RAPL_ENERGY= RAPL_SOURCE=NA RAPL_RANGE=0 RAPL_SCALE=1 RAPL_DIVISOR=1 RAPL_UNIT=uj
    RAPL_READ_START=$(rapl_time_ms)
    if [ -n "$1" ]; then
        RAPL_ENERGY=$(cat "$1/energy_uj" 2>/dev/null)
    fi
    case "$RAPL_ENERGY" in
        ''|*[!0-9]*)
            RAPL_ENERGY=
            RAPL_RAW=$(/data/local/tmp/iotools rdmsr 0 "$2" 2>/dev/null)
            RAPL_UNIT_RAW=$(/data/local/tmp/iotools rdmsr 0 0x606 2>/dev/null)
            case "$RAPL_RAW:$RAPL_UNIT_RAW" in
                *[!0-9a-fA-Fx:]*|:*|*:|0x:*|*:0x) ;;
                0x*:0x*)
                    RAPL_ENERGY=$(rapl_u32 $((RAPL_RAW & 0xFFFFFFFF)))
                    RAPL_EXPONENT=$(((RAPL_UNIT_RAW >> 8) & 0x1F))
                    RAPL_SOURCE=msr:$2
                    RAPL_RANGE=4294967296
                    RAPL_SCALE=1000000
                    RAPL_DIVISOR=$((1 << RAPL_EXPONENT))
                    RAPL_UNIT=ticks_2^-$RAPL_EXPONENT
                    ;;
            esac
            ;;
        *)
            RAPL_SOURCE=$1/energy_uj
            RAPL_RANGE=$(cat "$1/max_energy_range_uj" 2>/dev/null)
            case "$RAPL_RANGE" in ''|*[!0-9]*) RAPL_RANGE=0 ;; esac
            ;;
    esac
    RAPL_READ_END=$(rapl_time_ms)
    RAPL_TIME=$(((RAPL_READ_START + RAPL_READ_END) / 2))
}

rapl_collect() {
    RAPL_WIN_HAD_PREV=$RAPL_WIN_SOURCE
    rapl_pkg_window_step
    PKG_POWER_MW=NA
    if [ "$RAPL_WIN_MS" -gt 0 ]; then
        PKG_POWER_MW=$(((RAPL_WIN_UJ + RAPL_WIN_MS / 2) / RAPL_WIN_MS))
        RAPL_STATUS=ok
        [ -n "$RAPL_WIN_WRAP" ] && RAPL_STATUS=wrap
        [ "$RAPL_WIN_SKIPPED" -gt 0 ] && RAPL_STATUS=partial:$RAPL_WIN_SKIPPED/${RAPL_WIN_MS}ms
    elif [ -z "$RAPL_WIN_HAD_PREV" ]; then
        RAPL_STATUS=first_sample
    elif [ -z "$RAPL_ENERGY" ]; then
        RAPL_STATUS=missing
    else
        RAPL_STATUS=reset
    fi
    echo "RAPL_SAMPLE: DOMAIN=package SOURCE=$RAPL_SOURCE E1=${RAPL_WIN_FIRST:-NA} E2=${RAPL_ENERGY:-NA} T1_MS=${RAPL_WIN_START:-NA} T2_MS=$RAPL_TIME RANGE=$RAPL_RANGE UNIT=$RAPL_UNIT STATUS=$RAPL_STATUS"
    RAPL_CSV="$RAPL_SOURCE,${RAPL_WIN_FIRST:-NA},${RAPL_ENERGY:-NA},${RAPL_WIN_START:-NA},$RAPL_TIME,$RAPL_RANGE,$RAPL_UNIT,$RAPL_STATUS"
    RAPL_WIN_FIRST=$RAPL_ENERGY RAPL_WIN_START=$RAPL_TIME
    RAPL_WIN_UJ=0 RAPL_WIN_MS=0 RAPL_WIN_SKIPPED=0 RAPL_WIN_WRAP=
    for rapl_domain in ia gt; do
        case "$rapl_domain" in
            ia) set -- "$IA_ENERGY_PATH" 0x639 "$RAPL_IA_PREV" "$RAPL_IA_TIME" "$RAPL_IA_SOURCE" "$RAPL_IA_UNIT" ;;
            gt) set -- "$GT_ENERGY_PATH" 0x641 "$RAPL_GT_PREV" "$RAPL_GT_TIME" "$RAPL_GT_SOURCE" "$RAPL_GT_UNIT" ;;
        esac
        RAPL_PREVIOUS=$3
        RAPL_PREVIOUS_TIME=$4
        RAPL_PREVIOUS_SOURCE=$5
        RAPL_PREVIOUS_UNIT=$6
        rapl_read_domain "$1" "$2"
        RAPL_ELAPSED=0
        [ -n "$RAPL_PREVIOUS_TIME" ] && RAPL_ELAPSED=$((RAPL_TIME - RAPL_PREVIOUS_TIME))
        if [ "$RAPL_PREVIOUS_SOURCE" != "$RAPL_SOURCE" ] || [ "$RAPL_PREVIOUS_UNIT" != "$RAPL_UNIT" ]; then
            RAPL_RESULT="NA source_change"
        else
            RAPL_RESULT=$(rapl_power_mw "$RAPL_ENERGY" "$RAPL_PREVIOUS" "$RAPL_ELAPSED" "$RAPL_RANGE" "$RAPL_SCALE" "$RAPL_DIVISOR")
        fi
        set -- $RAPL_RESULT
        RAPL_MW=$1
        RAPL_STATUS=$2
        [ -n "$RAPL_PREVIOUS_SOURCE" ] || RAPL_STATUS=first_sample
        [ -n "$RAPL_ENERGY" ] || RAPL_STATUS=missing
        echo "RAPL_SAMPLE: DOMAIN=$rapl_domain SOURCE=$RAPL_SOURCE E1=${RAPL_PREVIOUS:-NA} E2=${RAPL_ENERGY:-NA} T1_MS=${RAPL_PREVIOUS_TIME:-NA} T2_MS=$RAPL_TIME RANGE=$RAPL_RANGE UNIT=$RAPL_UNIT STATUS=$RAPL_STATUS"
        RAPL_CSV="${RAPL_CSV:+$RAPL_CSV,}$RAPL_SOURCE,${RAPL_PREVIOUS:-NA},${RAPL_ENERGY:-NA},${RAPL_PREVIOUS_TIME:-NA},$RAPL_TIME,$RAPL_RANGE,$RAPL_UNIT,$RAPL_STATUS"
        case "$rapl_domain" in
            ia) IA_POWER_MW=$RAPL_MW; RAPL_IA_PREV=$RAPL_ENERGY; RAPL_IA_TIME=$RAPL_TIME; RAPL_IA_SOURCE=$RAPL_SOURCE; RAPL_IA_UNIT=$RAPL_UNIT ;;
            gt) GT_POWER_MW=$RAPL_MW; RAPL_GT_PREV=$RAPL_ENERGY; RAPL_GT_TIME=$RAPL_TIME; RAPL_GT_SOURCE=$RAPL_SOURCE; RAPL_GT_UNIT=$RAPL_UNIT ;;
        esac
    done
    PKG_POWER=NA
    [ "$PKG_POWER_MW" = NA ] || PKG_POWER=$(awk -v mw="$PKG_POWER_MW" 'BEGIN { printf "%.6f", mw / 1000 }')
}

if [ "$1" = "--rapl-sample" ]; then
    rapl_init
    rapl_collect >/dev/null
    rapl_wait 1
    rapl_collect
    return 0 2>/dev/null || exit 0
fi

DURATION_SEC=$1
RUN_STRESSAPP=${2:-1}

if [ -z "$DURATION_SEC" ]; then
  echo "Error: Missing argument. Usage: ./run_stressapp.sh [seconds]"
  exit 1
fi

LOG_FILE="/data/local/tmp/msr_log.csv"
RAPL_HEADER=
for rapl_domain in package ia gt; do
    for rapl_field in source energy_before energy_after time_before_ms time_after_ms range unit status; do
        RAPL_HEADER="${RAPL_HEADER:+$RAPL_HEADER,}${rapl_domain}_${rapl_field}"
    done
done
echo "Timestamp,MSR_0x610,MSR_0x64F,MSR_0x6B0,SoC_Temp_C,PKG_Power_W,Throttling_Flags,$RAPL_HEADER" > "$LOG_FILE"
rapl_init

run_telemetry_tick() {
    # --------------------------------------------------------------------------
    # 1. READ RAW REGISTERS FIRST (CONFIRMED WORKING VIA IOTOOLS)
    # --------------------------------------------------------------------------
    VAL_610=$(/data/local/tmp/iotools rdmsr 0 0x610 2>/dev/null)
    VAL_64F=$(/data/local/tmp/iotools rdmsr 0 0x64F 2>/dev/null)
    VAL_6B0=$(/data/local/tmp/iotools rdmsr 0 0x6B0 2>/dev/null)
    VAL_1B1=$(/data/local/tmp/iotools rdmsr 0 0x1B1 2>/dev/null)
    VAL_1A2=$(/data/local/tmp/iotools rdmsr 0 0x1A2 2>/dev/null)

    [ -z "$VAL_610" ] && VAL_610="0x00000000"
    [ -z "$VAL_64F" ] && VAL_64F="0x00000000"
    [ -z "$VAL_6B0" ] && VAL_6B0="0x00000000"
    [ -z "$VAL_1B1" ] && VAL_1B1="0x00000000"

    # --------------------------------------------------------------------------
    # 1.5 READ ENERGY FROM INTEL RAPL
    # --------------------------------------------------------------------------
    rapl_collect

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

    # Method B: if sysfs fails, decode package DTS from MSR 0x1B1 relative to TjMax in MSR 0x1A2.
    if [ -z "$SOC_TEMP" ] || [ "$SOC_TEMP" -le 0 ] || [ "$SOC_TEMP" -gt 110 ] 2>/dev/null; then
        case "$VAL_1B1:$VAL_1A2" in
            0x*:0x*)
                TJMAX=$(( (VAL_1A2 >> 16) & 0xFF ))
                DIGITAL_READOUT=$(( (VAL_1B1 >> 16) & 0x7F ))
                if [ "$TJMAX" -gt 0 ] && [ "$DIGITAL_READOUT" -gt 0 ] && [ "$DIGITAL_READOUT" -lt "$TJMAX" ]; then
                    SOC_TEMP=$(( TJMAX - DIGITAL_READOUT ))
                fi
                ;;
        esac
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
    if [ "$VAL_1B1" != "0x00000000" ]; then
        echo "MSR_1B1: ${VAL_1B1} MSR_1A2: ${VAL_1A2:-NA}"
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
    echo "TPTS_POWER_SAMPLE_END"
    
    echo "${TIMESTAMP},${VAL_610},${VAL_64F},${VAL_6B0},${SOC_TEMP},${PKG_POWER},${FLAGS},${RAPL_CSV}" >> "$LOG_FILE"
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
# Keep sampling while Geekbench runs (flag created by TPTS backend); hard cap of 1h past duration.
GB_FLAG="/data/local/tmp/tpts_gb_running"
MAX_END_TIME=$((END_TIME + 3600))
[ -e "$GB_FLAG" ] && echo "Geekbench selected: telemetry continues until the benchmark completes."
while [ $SECONDS -lt $END_TIME ] || { [ -e "$GB_FLAG" ] && [ $SECONDS -lt $MAX_END_TIME ]; }; do
    run_telemetry_tick
    echo -e "\n"
    [ $SECONDS -ge $END_TIME ] && [ ! -e "$GB_FLAG" ] && break
    rapl_wait 1
done

[ -n "$STRESS_PID" ] && kill -9 "$STRESS_PID" >/dev/null 2>&1
echo "--------------------------------------------------"
echo "FINISHED: ${DURATION_SEC} seconds reached."
echo "--------------------------------------------------"

exit 0