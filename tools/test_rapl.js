const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const frontend = fs.readFileSync(path.join(root, 'app/main.js'), 'utf8');
const script = fs.readFileSync(path.join(root, 'device_tools/run_stressapp.sh'), 'utf8');
const helperEnd = script.indexOf('PHASE_FILE=/data/local/tmp/tpts_phase');
assert(helperEnd > 0);
const helpers = script.slice(0, helperEnd);

function section(start, end) {
    const begin = frontend.indexOf(start);
    const finish = frontend.indexOf(end, begin);
    assert(begin >= 0 && finish > begin, `Missing section: ${start}`);
    return frontend.slice(begin, finish);
}

const cards = new Map();
const context = {
    latestRaplSamples: {}, awaitingRaplSampleEnd: false, telemetryDebugEnabled: false,
    appendConsole: () => {}, namedRaplActive: false, latestPackagePower: 100,
    latestIaPower: 10, latestGtPower: 10, latestCpuFreqGhz: null,
    isPipelineRunning: false, chartingActive: true, chartingStartPending: false, telemetryHistoryReadyAt: 0,
    latestPl1: 18, latestPl2: 30, latestSocTemp: 32, latestTcc: 0, latestProchot: 0,
    detectedFanRpms: [], thermalZoneMetricKeys: new Map(), telemetryLog: [], MAX_TELEMETRY_LOG_ROWS: 3600,
    powerFilterWindow: [100], POWER_FILTER_WINDOW_SIZE: 4, maxDataPoints: 60,
    powerHistory: [], pl1PowerHistory: [], pl2PowerHistory: [], iaPowerHistory: [], gtPowerHistory: [],
    restPowerHistory: [], latestRestPower: null, latestLimitReasons: { raw: '0x1000', active: ['MAX_TURBO_LIMIT'], logged: ['THERMAL'] },
    redrawPowerChart: () => {}, isMetricEnabled: () => true,
    evaluateThermalTuneGuard: () => {},
    document: { getElementById: (key) => {
        if (!cards.has(key)) cards.set(key, { innerText: '' });
        return cards.get(key);
    } }
};
vm.createContext(context);
vm.runInContext(section('function renderRestPower(', 'function updateMonitorEvent('), context);
vm.runInContext(section('function updatePowerChart(', 'function initPowerChart('), context);
vm.runInContext(section('function recordTelemetrySample(', 'function updateThermalZoneChart('), context);
vm.runInContext(section('function captureTelemetryExportSelection(', 'function exportTelemetryLog('), context);
const parseDiagnostics = section('for (const raplMatch of rawLog.matchAll(', 'const namedRaplMatch =');
const parsePower = section('let discoveredPower;', 'const rawFanCountMatch =');
const complete = section('const raplSampleComplete =', '// 剩餘普通 MSR');
function receive(text) {
    context.rawLog = text;
    vm.runInContext(`{ ${parseDiagnostics} ${parsePower} const discoveredTemp = null; ${complete} }`, context);
}
function diagnostics(status) {
    return ['package', 'ia', 'gt'].map((domain) =>
        `RAPL_SAMPLE: DOMAIN=${domain} SOURCE=msr:0x611 E1=100 E2=200 T1_MS=1000 T2_MS=2500 RANGE=4294967296 UNIT=ticks_2^-14 STATUS=${status}`
    ).join('\n');
}
receive(diagnostics('reset'));
receive('TPTS_SAMPLE: PKG_POWER_MW: NA IA_MW: NA GT_MW: NA');
assert.equal(context.telemetryLog.length, 0);
assert.equal(cards.get('v-power').innerText, '-- W');
assert.equal(context.latestPackagePower, null);
assert.equal(context.latestIaPower, null);
assert.equal(context.latestGtPower, null);
assert.equal(context.powerHistory[0], null);
assert.equal(context.powerFilterWindow.length, 0);
receive('TPTS_SAMPLE_END');
assert.equal(context.telemetryLog.length, 1);
assert.equal(context.telemetryLog[0].pkg, null);
assert.equal(context.telemetryLog[0].rapl.package.status, 'reset');
receive(diagnostics('ok') + '\nTPTS_SAMPLE: PKG_POWER_MW: 2000 IA_MW: 500 GT_MW: 0\nTPTS_SAMPLE_END');
assert.equal(context.telemetryLog.length, 2);
assert.equal(context.telemetryLog[1].pkg, 2);
assert.equal(context.telemetryLog[1].ia, 0.5);
assert.equal(context.telemetryLog[1].gt, 0);
assert.equal(context.powerHistory[1], 2);
assert.equal(context.telemetryLog[0].rapl.package.status, 'reset');
let guardCalls = 0;
context.evaluateThermalTuneGuard = () => { guardCalls += 1; };
context.isPipelineRunning = true;
receive(diagnostics('ok'));
receive('TPTS_SAMPLE: PKG_POWER_MW: 3000 IA_MW: 1000 GT_MW: 100');
assert.equal(context.telemetryLog.length, 2);
receive('TPTS_SAMPLE_END');
assert.equal(context.telemetryLog.length, 3);
assert.equal(guardCalls, 1);
assert.equal(context.telemetryLog[2].pkg, 3);
assert.equal(context.telemetryLog[2].ia, 1);
assert.equal(context.telemetryLog[2].gt, 0.1);
const columns = context.captureTelemetryExportSelection();
assert.equal(columns.find((column) => column.header === 'package_energy_before').value(context.telemetryLog[1]), '100');
assert.equal(columns.find((column) => column.header === 'package_time_after_ms').value(context.telemetryLog[1]), '2500');
assert.equal(context.telemetryLog[1].rest, 1.5);
assert.equal(context.telemetryLog[2].rest, 1.9);
assert.equal(context.restPowerHistory.at(-1), 1.9);
assert.equal(columns.find((column) => column.header === 'rest_of_package_power_w').value(context.telemetryLog[2]), 1.9);
assert.equal(columns.find((column) => column.header === 'cpu_limit_reasons').value(context.telemetryLog[2]), 'MAX_TURBO_LIMIT');
assert.equal(columns.find((column) => column.header === 'cpu_limit_reasons_logged').value(context.telemetryLog[2]), 'THERMAL');
console.log('PASS frontend: NA gaps, recovery, live and stress-phase samples from one sampler, diagnostic CSV columns.');

const limitContext = { BigInt };
vm.createContext(limitContext);
vm.runInContext(section('const CORE_LIMIT_REASON_BITS', 'function renderRestPower('), limitContext);
const decode = (value) => JSON.parse(JSON.stringify(vm.runInContext(`decodeCoreLimitReasons(${JSON.stringify(value)})`, limitContext)));
assert.deepEqual(decode('0x0000000000001000'), { raw: '0x0000000000001000', active: ['MAX_TURBO_LIMIT'], logged: [] });
assert.deepEqual(decode('0x0000000013820000'), { raw: '0x0000000013820000', active: [], logged: ['THERMAL', 'VR_TDC', 'OTHER', 'MAX_TURBO_LIMIT'] });
assert.deepEqual(decode('0x0000000000000c03').active, ['PROCHOT', 'THERMAL', 'PBM_PL1', 'PBM_PL2']);
assert.equal(decode('not-hex'), null);
const cpuSample = JSON.parse(JSON.stringify(vm.runInContext(
    'decodeCpuLimitSample("CPU_LIMIT_SAMPLE: NOW=402657280 SEEN=6144 CORES=0:402653184,2:402657280,6:402657280")', limitContext)));
assert.deepEqual(cpuSample.active, ['MAX_TURBO_LIMIT']);
assert.deepEqual(cpuSample.seen, ['PBM_PL2', 'MAX_TURBO_LIMIT']);
assert.deepEqual(cpuSample.logged, ['PBM_PL2', 'MAX_TURBO_LIMIT']);
assert.deepEqual(cpuSample.cores, { MAX_TURBO_LIMIT: ['CPU2', 'CPU6'] });
assert.equal(vm.runInContext('decodeCpuLimitSample("CPU_LIMIT_SAMPLE: NOW=4096 SEEN=4096 CORES=0:4096,1:4096").cores', limitContext), null);
assert.equal(vm.runInContext('decodeCpuLimitSample("MSR_64F: 0x1000")', limitContext), null);

const restCards = new Map();
const restContext = {
    latestPackagePower: null, latestIaPower: null, latestGtPower: null, latestRestPower: null, restPowerHistory: [null],
    document: { getElementById: (key) => { if (!restCards.has(key)) restCards.set(key, { innerText: '' }); return restCards.get(key); } }
};
vm.createContext(restContext);
vm.runInContext(section('function renderRestPower(', 'function updateMonitorEvent('), restContext);
const rest = (pkg, ia, gt, patch = false) => {
    Object.assign(restContext, { latestPackagePower: pkg, latestIaPower: ia, latestGtPower: gt });
    vm.runInContext(`renderRestPower(${patch})`, restContext);
    return restContext.latestRestPower;
};
assert.equal(rest(2.5, 0.4, 0.1), 2);
assert.equal(restCards.get('v-rest-power').innerText, '2.00 W');
assert.equal(rest(0.48, 0.45, 0.06), 0);
assert.equal(rest(0.3, 0.45, 0.06), null);
assert.equal(restCards.get('v-rest-power').innerText, '-- W');
assert.equal(rest(null, 0.4, 0.1), null);
assert.equal(rest(3, 1, 0.5, true), 1.5);
assert.equal(restContext.restPowerHistory[0], 1.5);
console.log('PASS frontend: 0x64F decode (PTAT names, active/logged), Rest of Package calculation and history patching.');

const msrCards = new Map();
const msrContext = {
    BigInt, msrPowerUnitWatts: null, msrTjMaxC: null, latestPl1: null, latestPl2: null,
    tuningDefaults: { pl1: 55, pl2: null, pl4: null },
    currentPowerLimitRegister: '', currentPowerLimit4Register: '',
    document: { getElementById: (key) => {
        if (!msrCards.has(key)) {
            const card = { innerText: '', title: '', limited: false };
            card.classList = { toggle: (name, on) => { if (name === 'limited-hint') card.limited = on; } };
            msrCards.set(key, card);
        }
        return msrCards.get(key);
    } }
};
vm.createContext(msrContext);
vm.runInContext(section('function formatPowerWatts(', '\n}\n') + '\n}', msrContext);
vm.runInContext(section('function parseMsrUnits(', 'function sendAdb('), msrContext);
vm.runInContext('decodeAndRenderPLFrom610("0x0042820800dd81b8")', msrContext);
assert.equal(msrContext.latestPl1, null);
assert.equal(msrContext.currentPowerLimitRegister, '0x0042820800dd81b8');
assert.equal(vm.runInContext('powerLimitStep()', msrContext), 0.125);
vm.runInContext('parseMsrUnits("MSR_606: 0x00000000000a0e03 MSR_1A2: 0x000000000a6400e6")', msrContext);
assert.equal(msrContext.msrPowerUnitWatts, 0.125);
assert.equal(msrContext.msrTjMaxC, 100);
vm.runInContext('decodeAndRenderPLFrom610("0x0042820800dd81b8"); decodeAndRenderPL4From601("0x0000000000000518")', msrContext);
assert.equal(msrContext.latestPl1, 55);
assert.equal(msrContext.latestPl2, 65);
assert.match(msrCards.get('v-pl4').innerText, /^Now: 163(\.0+)? W$/);
assert.equal(msrCards.get('v-pl1').innerText, 'Now: 55 W');
vm.runInContext('parseMsrUnits("MSR_606: 0x00000000000a0e04 MSR_1A2: 0x00000000005f0000")', msrContext);
assert.equal(msrContext.msrPowerUnitWatts, 0.0625);
assert.equal(msrContext.msrTjMaxC, 95);
vm.runInContext('decodeAndRenderPLFrom610("0x0042820800dd81b8")', msrContext);
assert.equal(msrContext.latestPl1, 27.5);
assert.equal(msrContext.latestPl2, 32.5);
assert.equal(msrCards.get('v-pl1').innerText, 'Now: 27.5 W (limited)');
assert.equal(msrCards.get('v-pl1').limited, true);
console.log('PASS frontend: power unit from 0x606, TjMax from 0x1A2, PL decode waits for unit and follows it, Now/limited hint.');

const serialIndex = process.argv.indexOf('--serial');
if (serialIndex < 0) {
    console.log('SKIP Android shell checks; use --serial <adb-target> to run them.');
    process.exit(0);
}
const serial = process.argv[serialIndex + 1];
assert(serial, '--serial requires an ADB target');
const adb = process.env.ADB || (process.platform === 'win32' ? path.join(root, 'proxy/adb.exe') : 'adb');
function androidShell(input, syntaxOnly = false) {
    const args = ['-s', serial, 'shell', ...(syntaxOnly ? ['sh', '-n'] : ['su', '0', 'sh'])];
    const result = spawnSync(adb, args, { input, encoding: 'utf8', timeout: 20000 });
    assert.equal(result.status, 0, result.stderr || result.error?.message);
    return result.stdout.trim().split(/\r?\n/);
}
androidShell(script, true);
const methodB = script.slice(script.indexOf('    # Method B:'), script.indexOf('    # Final absolute safety'));
assert(methodB.includes('VAL_1B1') && methodB.includes('VAL_1A2'));
assert.deepEqual(androidShell([
    'SOC_TEMP=0 VAL_1B1=0x0000000088450002 VAL_1A2=0x000000000a6400e6', methodB, 'echo $SOC_TEMP',
    'SOC_TEMP=0 VAL_1B1=0x0000000088450002 VAL_1A2=0x00000000005f0000', methodB, 'echo $SOC_TEMP',
    'SOC_TEMP=0 VAL_1B1=0x00000000 VAL_1A2=0x000000000a6400e6', methodB, 'echo $SOC_TEMP',
    'SOC_TEMP=0 VAL_1B1=0x0000000088450002 VAL_1A2=', methodB, 'echo $SOC_TEMP',
    'SOC_TEMP=47 VAL_1B1=0x0000000088450002 VAL_1A2=0x000000000a6400e6', methodB, 'echo $SOC_TEMP'
].join('\n') + '\n'), ['31', '26', '0', '0', '47']);
const cases = [
    ['2000000', '0', '1000', '100000000', '1', '1', '2000 ok'],
    ['2000000', '0', '2000', '100000000', '1', '1', '1000 ok'],
    ['1000000', '90000000', '1000', '100000000', '1', '1', '11000 wrap'],
    ['144225', '1432064', '1000', '262143328850', '1', '1', 'NA reset'],
    ['1000', '2000', '1000', '0', '1', '1', 'NA reset'],
    ['32768', '16384', '1000', '4294967296', '1000000', '16384', '1000 ok'],
    ['16384', '4294950912', '1000', '4294967296', '1000000', '16384', '2000 wrap'],
    ['100', '200', '1000', '4294967296', '1000000', '16384', 'NA reset'],
    ['200', '100', '0', '1000', '1', '1', 'NA invalid_time'],
    ['200', 'NA', '1000', '1000', '1', '1', 'NA missing'],
    ['2000', '100', '1000', '1000', '1', '1', 'NA invalid_counter'],
    ['200', '100', '1000', '1000', '1', '0', 'NA invalid_unit'],
    ['200000000', '0', '1000', '1000000000', '1', '1', '200000 ok']
];
assert.deepEqual(androidShell(helpers + '\n' + cases.map((test) => `rapl_power_mw ${test.slice(0, 6).join(' ')}`).join('\n') + '\n'), cases.map((test) => test[6]));
assert.deepEqual(androidShell(helpers + '\nrapl_u32 -1035407538\nrapl_u32 2147483647\nrapl_init\nt=$(rapl_time_ms)\n[ "$t" -ge 0 ] && [ "$t" -lt 60000 ] && echo relative_time_ok\n'), ['3259559758', '2147483647', 'relative_time_ok']);
const stateTest = `
rapl_read_domain() {
    RAPL_TIME=$((1000 + RAPL_TEST_STEP * 1500))
    RAPL_ENERGY=$RAPL_TEST_ENERGY
    RAPL_SOURCE=$RAPL_TEST_SOURCE
    RAPL_RANGE=4294967296
    RAPL_SCALE=1000000
    RAPL_DIVISOR=16384
    RAPL_UNIT=ticks_2^-14
}
rapl_init
RAPL_TEST_SOURCE=msr:0x611
RAPL_TEST_STEP=0 RAPL_TEST_ENERGY=16384
rapl_collect
echo RESULT:$PKG_POWER_MW:$IA_POWER_MW:$GT_POWER_MW
RAPL_TEST_STEP=1 RAPL_TEST_ENERGY=65536
rapl_collect
echo RESULT:$PKG_POWER_MW:$IA_POWER_MW:$GT_POWER_MW
RAPL_TEST_STEP=2 RAPL_TEST_ENERGY=100
rapl_collect
echo RESULT:$PKG_POWER_MW:$IA_POWER_MW:$GT_POWER_MW
RAPL_TEST_STEP=3 RAPL_TEST_ENERGY=49252
rapl_collect
echo RESULT:$PKG_POWER_MW:$IA_POWER_MW:$GT_POWER_MW
RAPL_TEST_SOURCE=different-source
RAPL_TEST_STEP=4 RAPL_TEST_ENERGY=98404
rapl_collect
echo RESULT:$PKG_POWER_MW:$IA_POWER_MW:$GT_POWER_MW
`;
const results = androidShell(helpers + '\n' + stateTest).filter((line) => line.startsWith('RESULT:'));
assert.deepEqual(results, ['RESULT:NA:NA:NA', 'RESULT:2000:2000:2000', 'RESULT:NA:NA:NA', 'RESULT:2000:2000:2000', 'RESULT:NA:NA:NA']);
const windowTest = `
rapl_read_domain() {
    set -- $RAPL_TEST_READINGS
    RAPL_TIME=$1 RAPL_ENERGY=$2
    shift 2
    RAPL_TEST_READINGS="$*"
    RAPL_SOURCE=sysfs RAPL_RANGE=262143328850 RAPL_SCALE=1 RAPL_DIVISOR=1 RAPL_UNIT=uj
}
rapl_init
RAPL_TEST_READINGS="0 1000 0 0 0 0 100 201000 200 50 300 200050 400 400050 400 0 400 0"
rapl_collect >/dev/null
rapl_pkg_window_step
rapl_pkg_window_step
rapl_pkg_window_step
rapl_collect >/dev/null
echo RESULT:$PKG_POWER_MW:$RAPL_CSV
`;
const windowLines = androidShell(helpers + '\n' + windowTest);
assert(windowLines.some((line) => line.startsWith('RESULT:2000:sysfs,1000,400050,0,400,262143328850,uj,partial:1/300ms,')), windowLines.join('\n'));
const clipLines = androidShell(helpers + '\nrapl_init\nclip_collect\necho CPUS:$CLIP_CPUS\necho CSV:$CLIP_CSV\n');
const clipSample = clipLines.find((line) => line.startsWith('CPU_LIMIT_SAMPLE: '));
assert.match(clipSample || '', /^CPU_LIMIT_SAMPLE: NOW=\d+ SEEN=\d+ CORES=0:\d+(,\d+:(\d+|NA))*$/, clipLines.join('\n'));
assert.match(clipLines.find((line) => line.startsWith('CSV:')) || '', /^CSV:0x[0-9a-f]{8},0x[0-9a-f]{8}$/);
console.log('PASS Android: script/command syntax, 13 arithmetic cases, first sample, reset recovery, source changes.');