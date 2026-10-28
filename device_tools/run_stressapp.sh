#!/bin/bash

# ==============================================================================
# Script: run_stressapp.sh
# Description: TPTS device-side telemetry sampler and stress workload driver.
# Usage: ./run_stressapp.sh --monitor                                   (resident 1 s sampler)
#        ./run_stressapp.sh [duration_in_seconds] [run_stressapptest: 0|1]  (workload; needs --monitor running)
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

# Read-only: polls MSR 0x64F on every core; sticky log bits are never cleared.
clip_poll() {
    CLIP_NOW=0 CLIP_CORES=
    for clip_cpu in $CLIP_CPUS; do
        clip_raw=$(/data/local/tmp/iotools rdmsr "$clip_cpu" 0x64F 2>/dev/null)
        case "$clip_raw" in
            0x*[!0-9a-fA-F]*|0x|'') clip_value= ;;
            0x*) clip_value=$((clip_raw & 0x3FFF3FFF)) ;;
            *) clip_value= ;;
        esac
        if [ -n "$clip_value" ]; then
            CLIP_NOW=$((CLIP_NOW | clip_value))
            CLIP_SEEN=$((CLIP_SEEN | (clip_value & 0x3FFF)))
        fi
        CLIP_CORES="${CLIP_CORES:+$CLIP_CORES,}$clip_cpu:${clip_value:-NA}"
    done
}

clip_collect() {
    clip_poll
    echo "CPU_LIMIT_SAMPLE: NOW=$CLIP_NOW SEEN=$CLIP_SEEN CORES=$CLIP_CORES"
    CLIP_CSV=$(printf '0x%08x,0x%08x' "$CLIP_NOW" "$CLIP_SEEN")
    CLIP_SEEN=0
}

rapl_wait_until() {
    while [ "$(rapl_time_ms)" -lt "$1" ]; do
        sleep 0.1
        rapl_pkg_window_step
        clip_poll
    done
}

# Effective (busy) frequency per core = TSC rate x dAPERF/dMPERF over the sample window,
# matching PTAT "Effective Frequency (UCC/UCR)". 64-bit counters are handled in awk.
freq_init() {
    FREQ_PREV=
    FREQ_TSC0=$(/data/local/tmp/iotools rdmsr 0 0x10 2>/dev/null)
    FREQ_T0=$(rapl_time_ms)
    freq_ce=$(/data/local/tmp/iotools rdmsr 0 0xCE 2>/dev/null)
    case "$freq_ce" in
        0x*) FREQ_NOMINAL_MHZ=$(( (freq_ce >> 8 & 0xFF) * 100 )) ;;
        *) FREQ_NOMINAL_MHZ=0 ;;
    esac
}

freq_collect() {
    freq_now=$(rapl_time_ms)
    freq_raw="T $(/data/local/tmp/iotools rdmsr 0 0x10 2>/dev/null)"
    for freq_cpu in $CLIP_CPUS; do
        freq_raw="$freq_raw
$freq_cpu $(/data/local/tmp/iotools rdmsr "$freq_cpu" 0xE8 2>/dev/null) $(/data/local/tmp/iotools rdmsr "$freq_cpu" 0xE7 2>/dev/null)"
    done
    freq_out=$(printf '%s\n' "$freq_raw" | awk -v prev="$FREQ_PREV" -v tsc0="$FREQ_TSC0" -v t0="$FREQ_T0" -v now="$freq_now" -v nominal="$FREQ_NOMINAL_MHZ" '
        function hex(s,   i, n, c) {
            s = tolower(s); if (s !~ /^0x[0-9a-f]+$/) return -1
            n = 0; for (i = 3; i <= length(s); i++) { c = index("0123456789abcdef", substr(s, i, 1)); n = n * 16 + c - 1 }
            return n
        }
        BEGIN { k = split(prev, items, ";"); for (i = 1; i <= k; i++) { split(items[i], f, " "); pa[f[1]] = f[2]; pm[f[1]] = f[3] } }
        $1 == "T" { tsc = hex($2); next }
        { ra[$1] = $2; rm[$1] = $3; order[++n] = $1 }
        END {
            # Calibrate the TSC rate against uptime once the baseline is long enough; MSR 0xCE ratio until then.
            mhz = nominal
            if (tsc > 0 && hex(tsc0) > 0 && now - t0 >= 5000) mhz = (tsc - hex(tsc0)) / (now - t0) / 1000
            out = ""; state = ""
            for (i = 1; i <= n; i++) {
                c = order[i]; a = hex(ra[c]); m = hex(rm[c]); v = "NA"
                if (a >= 0 && m >= 0 && (c in pa) && mhz > 0) {
                    da = a - hex(pa[c]); dm = m - hex(pm[c])
                    if (da >= 0 && dm > 0) v = sprintf("%.0f", mhz * da / dm)
                }
                out = out (out == "" ? "" : ";") c ":" v
                if (a >= 0 && m >= 0) state = state (state == "" ? "" : ";") c " " ra[c] " " rm[c]
            }
            print out; print state
        }')
    FREQ_ALL=$(printf '%s\n' "$freq_out" | sed -n 1p)
    FREQ_PREV=$(printf '%s\n' "$freq_out" | sed -n 2p)
    FREQ_CPU0_KHZ=NA
    case ";$FREQ_ALL" in
        *";0:"[0-9]*) freq_cpu0=${FREQ_ALL#0:}; FREQ_CPU0_KHZ=$(( ${freq_cpu0%%;*} * 1000 )) ;;
    esac
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
    CLIP_SEEN=0 CLIP_CPUS=
    for clip_dir in /dev/cpu/[0-9]*; do
        [ -e "$clip_dir/msr" ] && CLIP_CPUS="$CLIP_CPUS ${clip_dir##*/}"
    done
    [ -n "$CLIP_CPUS" ] || CLIP_CPUS=0
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
    clip_collect
}

PHASE_FILE=/data/local/tmp/tpts_phase
STRESS_LOG=/data/local/tmp/msr_log.csv
TPTS_CSV_HEADER="Timestamp,MSR_0x610,MSR_0x64F,MSR_0x6B0,SoC_Temp_C,PKG_Power_W,Throttling_Flags"
for rapl_domain in package ia gt; do
    for rapl_field in source energy_before energy_after time_before_ms time_after_ms range unit status; do
        TPTS_CSV_HEADER="$TPTS_CSV_HEADER,${rapl_domain}_${rapl_field}"
    done
done
TPTS_CSV_HEADER="$TPTS_CSV_HEADER,MSR_0x64F_all_cores,MSR_0x64F_active_last_1s,CPU_Freq_kHz,CPU_Eff_MHz_all,Phase"

# Resident Live Monitor sampler (like PTAT): the only telemetry sampler, one sample per second until killed.
# Rows go to MONITOR_LOG while MONITOR_FLAG exists, and also to STRESS_LOG while the phase is "stress".
if [ "$1" = "--monitor" ]; then
    MONITOR_LOG=/data/local/tmp/tpts_monitor.csv
    MONITOR_FLAG=/data/local/tmp/tpts_monitor_logging

    monitor_tick() {
        rapl_collect
        freq_collect
        temp_value=
        for z in /sys/class/thermal/thermal_zone*; do
            if [ "$(cat "$z/type" 2>/dev/null)" = "x86_pkg_temp" ]; then temp_value=$(cat "$z/temp" 2>/dev/null); break; fi
        done
        [ -z "$temp_value" ] && temp_value=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
        freq_value=$FREQ_CPU0_KHZ
        [ "$freq_value" = NA ] && freq_value=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
        fan_count=$(ectool pwmgetnumfans 2>/dev/null | sed -n "s/.*= *//p")
        fan_values=
        if [ -n "$fan_count" ]; then
            fan_values=$(ectool pwmgetfanrpm 2>/dev/null | sed -n "s/.*RPM: *//p" | tr "\n" ",")
        else
            fan_count=0
            for fan in /sys/class/hwmon/hwmon*/fan*_input; do
                [ -f "$fan" ] || continue
                rpm=$(cat "$fan" 2>/dev/null)
                if [ -n "$rpm" ]; then fan_values="${fan_values:+$fan_values,}$rpm"; fan_count=$((fan_count + 1)); fi
            done
        fi
        m606=$(/data/local/tmp/iotools rdmsr 0 0x606 2>/dev/null)
        m1a2=$(/data/local/tmp/iotools rdmsr 0 0x1A2 2>/dev/null)
        m1b1=$(/data/local/tmp/iotools rdmsr 0 0x1B1 2>/dev/null)
        m610=$(/data/local/tmp/iotools rdmsr 0 0x610 2>/dev/null)
        m601=$(/data/local/tmp/iotools rdmsr 0 0x601 2>/dev/null)
        m64f=$(/data/local/tmp/iotools rdmsr 0 0x64F 2>/dev/null)
        m6b0=$(/data/local/tmp/iotools rdmsr 0 0x6B0 2>/dev/null)
        echo "TPTS_SAMPLE: TARGET_SYSFS_TEMP: ${temp_value:-NA} CPU_FREQ_KHZ: ${freq_value:-NA} FAN_COUNT: ${fan_count:-0} FAN_RPMS: ${fan_values:-NA} PKG_POWER_MW: $PKG_POWER_MW IA_MW: $IA_POWER_MW GT_MW: $GT_POWER_MW MSR_606: $m606 MSR_1A2: $m1a2 MSR_1B1: $m1b1 MSR_610: $m610 MSR_601: $m601 MSR_64F: $m64f MSR_6B0: $m6b0"
        for z in /sys/class/thermal/thermal_zone*; do
            [ -d "$z" ] || continue
            tz_type=$(cat "$z/type" 2>/dev/null | tr "[:space:]" "_")
            tz_temp=$(cat "$z/temp" 2>/dev/null)
            [ -n "$tz_type" ] && [ -n "$tz_temp" ] && echo "TPTS_THERMAL_ZONE: ${z##*thermal_zone}:$tz_type:$tz_temp"
        done
        echo "TPTS_SAMPLE_END"
        SOC_TEMP=${temp_value:-0}
        [ "$SOC_TEMP" -gt 1000 ] 2>/dev/null && SOC_TEMP=$((SOC_TEMP / 1000))
        VAL_1B1=$m1b1 VAL_1A2=$m1a2
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
        # Final absolute safety: without a usable source the CSV records NA.
        [ "$SOC_TEMP" -gt 0 ] 2>/dev/null || SOC_TEMP=NA
        phase=$(cat "$PHASE_FILE" 2>/dev/null)
        [ -n "$phase" ] || phase=idle
        row="$(date +"%Y%m%d_%H%M%S"),${m610:-NA},${m64f:-NA},${m6b0:-NA},$SOC_TEMP,$PKG_POWER,NONE,$RAPL_CSV,$CLIP_CSV,$FREQ_CPU0_KHZ,$FREQ_ALL,$phase"
        if [ -e "$MONITOR_FLAG" ]; then
            [ -s "$MONITOR_LOG" ] || echo "$TPTS_CSV_HEADER" > "$MONITOR_LOG"
            echo "$row" >> "$MONITOR_LOG"
        fi
        [ "$phase" = stress ] && [ -f "$STRESS_LOG" ] && echo "$row" >> "$STRESS_LOG"
    }

    rapl_init
    freq_init
    echo $$ > /data/local/tmp/tpts_monitor.pid
    rapl_collect >/dev/null
    freq_collect
    TICK_DEADLINE=$(($(rapl_time_ms) + 1000))
    rapl_wait_until "$TICK_DEADLINE"
    # The loop ends when the backend kills it or stdout closes (SIGPIPE).
    while :; do
        monitor_tick
        TICK_DEADLINE=$((TICK_DEADLINE + 1000))
        TICK_NOW=$(rapl_time_ms)
        [ "$TICK_DEADLINE" -lt "$TICK_NOW" ] && TICK_DEADLINE=$TICK_NOW
        rapl_wait_until "$TICK_DEADLINE"
    done
fi

DURATION_SEC=$1
RUN_STRESSAPP=${2:-1}

if [ -z "$DURATION_SEC" ]; then
  echo "Error: Missing argument. Usage: ./run_stressapp.sh [seconds]"
  exit 1
fi

# --------------------------------------------------------------------------
# ACTIVE RUNTIME INITIALIZATION & WORKLOAD IGNITION
# --------------------------------------------------------------------------
echo "Entering Full Stress Automation Pipeline Mode for ${DURATION_SEC} seconds..."

echo "[1/4] Loading MSR kernel module & provisioning character nodes..."
su 0 insmod /vendor_dlkm/lib/modules/msr.ko >/dev/null 2>&1
su 0 mkdir -p /dev/cpu/0 >/dev/null 2>&1
su 0 mknod /dev/cpu/0/msr c 202 0 >/dev/null 2>&1
su 0 chmod 666 /dev/cpu/0/msr >/dev/null 2>&1

# Telemetry comes from the resident --monitor sampler, which copies its rows into
# STRESS_LOG while PHASE_FILE says "stress"; this mode only drives the workload.
echo "$TPTS_CSV_HEADER" > "$STRESS_LOG"
echo stress > "$PHASE_FILE"

if [ "$RUN_STRESSAPP" = "1" ]; then
    echo "[2/4] Deploying stressapptest load injector..."
    stressapptest -s "$DURATION_SEC" -M 256 > /dev/null 2>&1 &
    STRESS_PID=$!
    echo "[3/4] Launched stressapptest with tracking PID: ${STRESS_PID}"
else
    STRESS_PID=""
    echo "[2/4] stressapptest not selected; browser workload only."
    echo "[3/4] Running selected browser workload."
fi
echo "[4/4] Workload running; the live sampler records telemetry every second."

END_TIME=$((SECONDS + DURATION_SEC))
# Keep the stress phase while Geekbench runs (flag created by TPTS backend); hard cap of 1h past duration.
GB_FLAG="/data/local/tmp/tpts_gb_running"
MAX_END_TIME=$((END_TIME + 3600))
[ -e "$GB_FLAG" ] && echo "Geekbench selected: the stress phase continues until the benchmark completes."
while [ $SECONDS -lt $END_TIME ] || { [ -e "$GB_FLAG" ] && [ $SECONDS -lt $MAX_END_TIME ]; }; do
    sleep 1
done

[ -n "$STRESS_PID" ] && kill -9 "$STRESS_PID" >/dev/null 2>&1
echo cooldown > "$PHASE_FILE"
echo "--------------------------------------------------"
echo "FINISHED: ${DURATION_SEC} seconds reached."
echo "--------------------------------------------------"

exit 0