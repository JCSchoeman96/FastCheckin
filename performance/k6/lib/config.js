function resolveManifestPath(path) {
  if (!path) {
    return null;
  }

  if (/^[A-Za-z]:[\\/]/.test(path) || path.startsWith("/")) {
    return path;
  }

  return `../../../${path}`;
}

const manifestPath = resolveManifestPath(__ENV.MANIFEST_PATH);
const rawManifest = manifestPath ? JSON.parse(open(manifestPath)) : null;

function envString(name, fallback = null) {
  const value = __ENV[name];

  if (value === undefined || value === null || value === "") {
    return fallback;
  }

  return value;
}

function envInt(name, fallback = null) {
  const value = envString(name, null);
  const candidate = value === null ? fallback : value;

  if (candidate === null || candidate === undefined || candidate === "") {
    return null;
  }

  return Number.parseInt(candidate, 10);
}

function envBool(name, fallback = false) {
  const value = envString(name, null);

  if (value === null) {
    return fallback;
  }

  return ["1", "true", "yes", "on"].includes(value.toLowerCase());
}

function requireString(name, fallback = null) {
  const value = envString(name, fallback);

  if (!value) {
    throw new Error(`${name} is required`);
  }

  return value;
}

function requireInt(name, fallback = null) {
  const value = envInt(name, fallback);

  if (!Number.isInteger(value) || value <= 0) {
    throw new Error(`${name} is required`);
  }

  return value;
}

function ticketCode(ticketPrefix, index, ticketWidth) {
  return `${ticketPrefix}-${String(index).padStart(ticketWidth, "0")}`;
}

function buildFallbackSlices(ticketCount, ticketPrefix, ticketWidth) {
  const extraAttendees = ticketCount - 20;
  const baselineCount = 8 + Math.floor(extraAttendees * 0.4);
  const businessCount = 2 + Math.floor(extraAttendees * 0.1);
  const offlineCount = 5 + Math.floor(extraAttendees * 0.2);
  const soakCount = ticketCount - baselineCount - businessCount - offlineCount;

  let startIndex = 1;
  const counts = {
    baseline_valid: baselineCount,
    business_duplicate: businessCount,
    offline_burst: offlineCount,
    soak: soakCount,
  };
  const slices = {};

  for (const sliceName of ["baseline_valid", "business_duplicate", "offline_burst", "soak"]) {
    const count = counts[sliceName];
    const endIndex = startIndex + count - 1;

    slices[sliceName] = {
      count,
      end_index: endIndex,
      end_ticket: ticketCode(ticketPrefix, endIndex, ticketWidth),
      start_index: startIndex,
      start_ticket: ticketCode(ticketPrefix, startIndex, ticketWidth),
    };

    startIndex = endIndex + 1;
  }

  return slices;
}

function parseScenarioNames() {
  return envString("SCENARIOS", "capacity_smoke")
    .split(",")
    .map((name) => name.trim())
    .filter(Boolean);
}

function scenarioFactories() {
  return {
    capacity_smoke: {
      executor: "per-vu-iterations",
      vus: 1,
      iterations: 1,
      exec: "capacitySmoke",
    },
    capacity_baseline: {
      executor: "constant-arrival-rate",
      rate: envInt("BASELINE_RATE", 10),
      timeUnit: "1s",
      duration: envString("BASELINE_DURATION", "5m"),
      preAllocatedVUs: envInt("BASELINE_PREALLOCATED_VUS", 20),
      maxVUs: envInt("BASELINE_MAX_VUS", 100),
      exec: "capacityBaseline",
    },
    capacity_stress: {
      executor: "ramping-arrival-rate",
      startRate: envInt("STRESS_START_RATE", 10),
      timeUnit: "1s",
      preAllocatedVUs: envInt("STRESS_PREALLOCATED_VUS", 40),
      maxVUs: envInt("STRESS_MAX_VUS", 200),
      stages: [
        { target: envInt("STRESS_STAGE_ONE_RATE", 25), duration: envString("STRESS_STAGE_ONE_DURATION", "5m") },
        { target: envInt("STRESS_STAGE_TWO_RATE", 50), duration: envString("STRESS_STAGE_TWO_DURATION", "5m") },
        { target: envInt("STRESS_STAGE_THREE_RATE", 75), duration: envString("STRESS_STAGE_THREE_DURATION", "5m") },
      ],
      exec: "capacityStress",
    },
    capacity_spike: {
      executor: "ramping-arrival-rate",
      startRate: envInt("SPIKE_START_RATE", 1),
      timeUnit: "1s",
      preAllocatedVUs: envInt("SPIKE_PREALLOCATED_VUS", 20),
      maxVUs: envInt("SPIKE_MAX_VUS", 200),
      stages: [
        { target: envInt("SPIKE_PEAK_RATE", 100), duration: envString("SPIKE_UP_DURATION", "30s") },
        { target: envInt("SPIKE_PEAK_RATE", 100), duration: envString("SPIKE_HOLD_DURATION", "2m") },
        { target: envInt("SPIKE_RECOVERY_RATE", 5), duration: envString("SPIKE_DOWN_DURATION", "1m") },
      ],
      exec: "capacitySpike",
    },
    capacity_soak: {
      executor: "constant-arrival-rate",
      rate: envInt("SOAK_RATE", 15),
      timeUnit: "1s",
      duration: envString("SOAK_DURATION", "30m"),
      preAllocatedVUs: envInt("SOAK_PREALLOCATED_VUS", 30),
      maxVUs: envInt("SOAK_MAX_VUS", 120),
      exec: "capacitySoak",
    },
    abuse_login: {
      executor: "constant-arrival-rate",
      rate: envInt("ABUSE_LOGIN_RATE", 5),
      timeUnit: "1s",
      duration: envString("ABUSE_LOGIN_DURATION", "30s"),
      preAllocatedVUs: envInt("ABUSE_LOGIN_PREALLOCATED_VUS", 1),
      maxVUs: envInt("ABUSE_LOGIN_MAX_VUS", 4),
      exec: "abuseLogin",
    },
    abuse_scans_single_device: {
      executor: "constant-arrival-rate",
      rate: envInt("ABUSE_SCAN_RATE", 10),
      timeUnit: "1s",
      duration: envString("ABUSE_SCAN_DURATION", "30s"),
      preAllocatedVUs: envInt("ABUSE_SCAN_PREALLOCATED_VUS", 1),
      maxVUs: envInt("ABUSE_SCAN_MAX_VUS", 4),
      exec: "abuseScansSingleDevice",
    },
    enqueue_failure: {
      executor: "per-vu-iterations",
      vus: 1,
      iterations: 1,
      exec: "enqueueFailure",
    },
    legacy_smoke: {
      executor: "per-vu-iterations",
      vus: 1,
      iterations: 1,
      exec: "legacySmoke",
    },
  };
}

function buildScenarios(selectedScenarios, factories) {
  return selectedScenarios.reduce((acc, scenarioName) => {
    if (!factories[scenarioName]) {
      throw new Error(`Unknown scenario: ${scenarioName}`);
    }

    acc[scenarioName] = factories[scenarioName];
    return acc;
  }, {});
}

function buildThresholds(selectedScenarios) {
  if (!envBool("K6_ENFORCE_THRESHOLDS", false)) {
    return {};
  }

  const thresholds = {};

  if (selectedScenarios.some((name) => name.startsWith("capacity_"))) {
    thresholds.capacity_scan_blocked_rate = ["rate<0.02"];
    thresholds.auth_failures = ["count<1"];
    thresholds.http_req_duration = ["p(95)<750", "p(99)<1500"];
  }

  return thresholds;
}

function scenarioMaxVus(definition) {
  if (definition.vus) {
    return definition.vus;
  }

  if (definition.maxVUs) {
    return definition.maxVUs;
  }

  return definition.preAllocatedVUs || 1;
}

function requiresDeviceBootstrap(selectedScenarios) {
  return selectedScenarios.some((name) =>
    [
      "capacity_smoke",
      "capacity_baseline",
      "capacity_stress",
      "capacity_spike",
      "capacity_soak",
      "abuse_scans_single_device",
      "enqueue_failure",
      "legacy_smoke",
    ].includes(name)
  );
}

function requiredDeviceCount(selectedScenarios, factories) {
  const required = selectedScenarios
    .filter((name) => name.startsWith("capacity_"))
    .reduce((maxCount, scenarioName) => {
      return Math.max(maxCount, scenarioMaxVus(factories[scenarioName]));
    }, 1);

  const configured = envInt("PERF_DEVICE_COUNT", required);

  if (!Number.isInteger(configured) || configured <= 0) {
    throw new Error("PERF_DEVICE_COUNT must be a positive integer");
  }

  if (selectedScenarios.some((name) => name.startsWith("capacity_")) && configured < required) {
    throw new Error(
      `PERF_DEVICE_COUNT (${configured}) must be at least the maximum capacity scenario VUs (${required})`
    );
  }

  return configured;
}

const selectedScenarios = parseScenarioNames();
const factories = scenarioFactories();
const scenarios = buildScenarios(selectedScenarios, factories);
const ticketPrefix = requireString("TICKET_PREFIX", rawManifest?.ticket_prefix);
const ticketCount = requireInt("TICKET_COUNT", rawManifest?.ticket_count);
const ticketWidth = envInt(
  "TICKET_WIDTH",
  rawManifest?.ticket_width || Math.max(String(ticketCount).length, 6)
);
const fallbackSlices = buildFallbackSlices(ticketCount, ticketPrefix, ticketWidth);
const deviceCount = requiresDeviceBootstrap(selectedScenarios)
  ? requiredDeviceCount(selectedScenarios, factories)
  : 1;

export const config = {
  baseUrl: requireString("PERF_BASE_URL", envString("BASE_URL")),
  capacityBlockedThreshold: 0.02,
  controls: rawManifest?.control_ranges || {
    business_prime_count: Math.min(5, fallbackSlices.business_duplicate.count),
    recovery_ticket: null,
    replay_prime_count: Math.min(5, fallbackSlices.baseline_valid.count),
  },
  credential: requireString("CREDENTIAL", rawManifest?.credential),
  deviceCount,
  deviceHeader: envString("PERF_DEVICE_HEADER", "x-perf-device-id"),
  deviceIpPrefix: envString("PERF_DEVICE_IP_PREFIX", "10.250"),
  dominantBlockedShareThreshold: Number.parseFloat(
    envString("PERF_BLOCKED_DOMINANCE_THRESHOLD", "0.5")
  ),
  enableAttendeeSyncSmoke: envBool("ENABLE_ATTENDEE_SYNC_SMOKE", true),
  eventId: requireInt("EVENT_ID", rawManifest?.event_id),
  invalidPrefix: requireString("INVALID_PREFIX", rawManifest?.invalid_prefix || `INVALID-${ticketPrefix}`),
  manifest: rawManifest,
  recoveryBaseUrl: envString("RECOVERY_BASE_URL", null),
  requiresDeviceBootstrap: requiresDeviceBootstrap(selectedScenarios),
  replay: rawManifest?.idempotency_replay || {
    reserve_count: Math.min(5, fallbackSlices.baseline_valid.count),
    seed: `replay-${requireInt("EVENT_ID", rawManifest?.event_id)}`,
  },
  scanBatchSize: envInt("SCAN_BATCH_SIZE", 25),
  selectedScenarios,
  scenarios,
  slices: rawManifest?.slices || fallbackSlices,
  targetMode: envString("TARGET_MODE", rawManifest?.target_mode || "redis_authoritative"),
  ticketCount,
  ticketPrefix,
  ticketWidth,
};

export function buildOptions() {
  return {
    scenarios,
    tags: {
      target_mode: config.targetMode,
    },
    thresholds: buildThresholds(selectedScenarios),
  };
}
