import { resolveNetworkProfile } from "./network_profile.js";
import { buildThresholdPackage } from "./thresholds.js";

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

function envFloat(name, fallback = null) {
  const value = envString(name, null);
  const candidate = value === null ? fallback : value;

  if (candidate === null || candidate === undefined || candidate === "") {
    return null;
  }

  return Number.parseFloat(candidate);
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

function parseDurationSeconds(duration) {
  if (typeof duration !== "string" || duration.length === 0) {
    return 0;
  }

  const match = duration.trim().match(/^(\d+)(ms|s|m|h)$/i);

  if (!match) {
    return 0;
  }

  const value = Number.parseInt(match[1], 10);
  const unit = match[2].toLowerCase();

  switch (unit) {
    case "ms":
      return value / 1000;
    case "m":
      return value * 60;
    case "h":
      return value * 3600;
    default:
      return value;
  }
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

const deprecatedAliases = {
  capacity_smoke: "perf_fresh_steady",
  capacity_baseline: "perf_fresh_steady",
  capacity_stress: "perf_duplicate_heavy",
  capacity_spike: "perf_spike_batch",
  capacity_soak: "perf_soak_endurance",
  enqueue_failure: "diagnostic_enqueue_failure",
  legacy_smoke: "diagnostic_legacy_smoke",
};

function deprecatedAliasWarning(invokedScenario, canonicalScenario) {
  return `${invokedScenario} is deprecated and now resolves to ${canonicalScenario}. Update the command before the event-window alias removal.`;
}

function parseScenarioNames() {
  return envString("SCENARIOS", "perf_fresh_steady")
    .split(",")
    .map((name) => name.trim())
    .filter(Boolean);
}

function buildConstantArrivalScenario(prefix, exec, fallbacks = {}) {
  return {
    executor: "constant-arrival-rate",
    rate: envInt(`${prefix}_RATE`, envInt(fallbacks.rate, 10)),
    timeUnit: "1s",
    duration: envString(`${prefix}_DURATION`, envString(fallbacks.duration, "5m")),
    preAllocatedVUs: envInt(
      `${prefix}_PREALLOCATED_VUS`,
      envInt(fallbacks.preAllocatedVUs, 20)
    ),
    maxVUs: envInt(`${prefix}_MAX_VUS`, envInt(fallbacks.maxVUs, 100)),
    exec,
  };
}

function buildConstantVusScenario(prefix, exec, fallbacks = {}) {
  return {
    executor: "constant-vus",
    vus: envInt(`${prefix}_VUS`, envInt(fallbacks.vus, 20)),
    duration: envString(`${prefix}_DURATION`, envString(fallbacks.duration, "5m")),
    exec,
  };
}

function buildRampingArrivalScenario(prefix, exec, defaults, fallbacks = {}) {
  return {
    executor: "ramping-arrival-rate",
    startRate: envInt(`${prefix}_START_RATE`, envInt(fallbacks.startRate, defaults.startRate)),
    timeUnit: "1s",
    preAllocatedVUs: envInt(
      `${prefix}_PREALLOCATED_VUS`,
      envInt(fallbacks.preAllocatedVUs, defaults.preAllocatedVUs)
    ),
    maxVUs: envInt(`${prefix}_MAX_VUS`, envInt(fallbacks.maxVUs, defaults.maxVUs)),
    stages: [
      {
        target: envInt(`${prefix}_STAGE_ONE_RATE`, defaults.stageOneRate),
        duration: envString(`${prefix}_STAGE_ONE_DURATION`, defaults.stageOneDuration),
      },
      {
        target: envInt(`${prefix}_STAGE_TWO_RATE`, defaults.stageTwoRate),
        duration: envString(`${prefix}_STAGE_TWO_DURATION`, defaults.stageTwoDuration),
      },
      {
        target: envInt(`${prefix}_STAGE_THREE_RATE`, defaults.stageThreeRate),
        duration: envString(`${prefix}_STAGE_THREE_DURATION`, defaults.stageThreeDuration),
      },
    ],
    exec,
  };
}

function buildSpikeScenario(exec) {
  return {
    executor: "ramping-arrival-rate",
    startRate: envInt("PERF_SPIKE_BATCH_START_RATE", envInt("SPIKE_START_RATE", 1)),
    timeUnit: "1s",
    preAllocatedVUs: envInt(
      "PERF_SPIKE_BATCH_PREALLOCATED_VUS",
      envInt("SPIKE_PREALLOCATED_VUS", 20)
    ),
    maxVUs: envInt("PERF_SPIKE_BATCH_MAX_VUS", envInt("SPIKE_MAX_VUS", 200)),
    stages: [
      {
        target: envInt("PERF_SPIKE_BATCH_PEAK_RATE", envInt("SPIKE_PEAK_RATE", 100)),
        duration: envString("PERF_SPIKE_BATCH_UP_DURATION", envString("SPIKE_UP_DURATION", "30s")),
      },
      {
        target: envInt("PERF_SPIKE_BATCH_PEAK_RATE", envInt("SPIKE_PEAK_RATE", 100)),
        duration: envString(
          "PERF_SPIKE_BATCH_HOLD_DURATION",
          envString("SPIKE_HOLD_DURATION", "2m")
        ),
      },
      {
        target: envInt("PERF_SPIKE_BATCH_RECOVERY_RATE", envInt("SPIKE_RECOVERY_RATE", 5)),
        duration: envString(
          "PERF_SPIKE_BATCH_DOWN_DURATION",
          envString("SPIKE_DOWN_DURATION", "1m")
        ),
      },
    ],
    exec,
  };
}

function buildScenarioCatalog() {
  return {
    perf_fresh_steady: {
      family: "performance",
      suite: "fresh_steady",
      requiresDeviceBootstrap: true,
      shouldPrimeDuplicates: true,
      networkProfile: resolveNetworkProfile("normal"),
      sections: [
        {
          key: "scan",
          label: "Scan Executor",
          requestType: "scan",
          scenarioKey: "perf_fresh_steady",
        },
      ],
      scenarios: {
        perf_fresh_steady: {
          definition: buildConstantArrivalScenario("PERF_FRESH_STEADY", "perfFreshSteady", {
            rate: "BASELINE_RATE",
            duration: "BASELINE_DURATION",
            preAllocatedVUs: "BASELINE_PREALLOCATED_VUS",
            maxVUs: "BASELINE_MAX_VUS",
          }),
          requestType: "scan",
          slice: "baseline_valid",
        },
      },
    },
    perf_duplicate_heavy: {
      family: "performance",
      suite: "duplicate_heavy",
      requiresDeviceBootstrap: true,
      shouldPrimeDuplicates: true,
      networkProfile: resolveNetworkProfile("normal"),
      sections: [
        {
          key: "scan",
          label: "Scan Executor",
          requestType: "scan",
          scenarioKey: "perf_duplicate_heavy",
        },
      ],
      scenarios: {
        perf_duplicate_heavy: {
          definition: buildConstantArrivalScenario("PERF_DUPLICATE_HEAVY", "perfDuplicateHeavy", {
            rate: "STRESS_STAGE_TWO_RATE",
            duration: "STRESS_STAGE_TWO_DURATION",
            preAllocatedVUs: "STRESS_PREALLOCATED_VUS",
            maxVUs: "STRESS_MAX_VUS",
          }),
          requestType: "scan",
          slice: "business_duplicate",
        },
      },
    },
    perf_auth_churn: {
      family: "performance",
      suite: "auth_churn",
      requiresDeviceBootstrap: true,
      shouldPrimeDuplicates: true,
      networkProfile: resolveNetworkProfile("normal"),
      sections: [
        {
          key: "scan",
          label: "Scan Executor",
          requestType: "scan",
          scenarioKey: "perf_auth_churn",
        },
      ],
      scenarios: {
        perf_auth_churn: {
          definition: buildConstantVusScenario("PERF_AUTH_CHURN", "perfAuthChurn", {
            vus: "SOAK_PREALLOCATED_VUS",
            duration: "SOAK_DURATION",
          }),
          requestType: "scan",
          slice: "baseline_valid",
        },
      },
    },
    perf_sync_scan_mixed: {
      family: "performance",
      suite: "sync_scan_mixed",
      requiresDeviceBootstrap: true,
      shouldPrimeDuplicates: true,
      networkProfile: resolveNetworkProfile("normal"),
      sections: [
        {
          key: "scan",
          label: "Scan Executor",
          requestType: "scan",
          scenarioKey: "perf_sync_scan_mixed_scan",
        },
        {
          key: "attendees",
          label: "Attendee Executor",
          requestType: "attendees",
          scenarioKey: "perf_sync_scan_mixed_attendees",
        },
      ],
      scenarios: {
        perf_sync_scan_mixed_scan: {
          definition: buildConstantArrivalScenario("PERF_SYNC_SCAN_MIXED_SCAN", "perfSyncScanMixedScan", {
            rate: "BASELINE_RATE",
            duration: "BASELINE_DURATION",
            preAllocatedVUs: "BASELINE_PREALLOCATED_VUS",
            maxVUs: "BASELINE_MAX_VUS",
          }),
          requestType: "scan",
          slice: "baseline_valid",
        },
        perf_sync_scan_mixed_attendees: {
          definition: buildConstantArrivalScenario(
            "PERF_SYNC_SCAN_MIXED_ATTENDEES",
            "perfSyncScanMixedAttendees",
            {
              rate: "ABUSE_LOGIN_RATE",
              duration: "BASELINE_DURATION",
              preAllocatedVUs: "ABUSE_LOGIN_PREALLOCATED_VUS",
              maxVUs: "ABUSE_LOGIN_MAX_VUS",
            }
          ),
          requestType: "attendees",
          slice: "baseline_valid",
        },
      },
    },
    perf_spike_batch: {
      family: "performance",
      suite: "spike_batch",
      requiresDeviceBootstrap: true,
      shouldPrimeDuplicates: false,
      networkProfile: resolveNetworkProfile("normal"),
      sections: [
        {
          key: "scan",
          label: "Scan Executor",
          requestType: "scan",
          scenarioKey: "perf_spike_batch",
        },
      ],
      scenarios: {
        perf_spike_batch: {
          definition: buildSpikeScenario("perfSpikeBatch"),
          requestType: "scan",
          slice: "offline_burst",
        },
      },
    },
    perf_soak_endurance: {
      family: "performance",
      suite: "soak_endurance",
      requiresDeviceBootstrap: true,
      shouldPrimeDuplicates: true,
      networkProfile: resolveNetworkProfile("normal"),
      sections: [
        {
          key: "scan",
          label: "Scan Executor",
          requestType: "scan",
          scenarioKey: "perf_soak_endurance",
        },
      ],
      scenarios: {
        perf_soak_endurance: {
          definition: buildConstantArrivalScenario("PERF_SOAK_ENDURANCE", "perfSoakEndurance", {
            rate: "SOAK_RATE",
            duration: "SOAK_DURATION",
            preAllocatedVUs: "SOAK_PREALLOCATED_VUS",
            maxVUs: "SOAK_MAX_VUS",
          }),
          requestType: "scan",
          slice: "soak",
        },
      },
    },
    abuse_login: {
      family: "abuse",
      suite: "login",
      requiresDeviceBootstrap: false,
      shouldPrimeDuplicates: false,
      networkProfile: resolveNetworkProfile("normal"),
      sections: [
        {
          key: "login",
          label: "Login Executor",
          requestType: "login",
          scenarioKey: "abuse_login",
        },
      ],
      scenarios: {
        abuse_login: {
          definition: buildConstantArrivalScenario("ABUSE_LOGIN", "abuseLogin", {
            rate: "ABUSE_LOGIN_RATE",
            duration: "ABUSE_LOGIN_DURATION",
            preAllocatedVUs: "ABUSE_LOGIN_PREALLOCATED_VUS",
            maxVUs: "ABUSE_LOGIN_MAX_VUS",
          }),
          requestType: "login",
          slice: "baseline_valid",
        },
      },
    },
    abuse_scans_single_device: {
      family: "abuse",
      suite: "single_device",
      requiresDeviceBootstrap: true,
      shouldPrimeDuplicates: false,
      networkProfile: resolveNetworkProfile("normal"),
      sections: [
        {
          key: "scan",
          label: "Scan Executor",
          requestType: "scan",
          scenarioKey: "abuse_scans_single_device",
        },
      ],
      scenarios: {
        abuse_scans_single_device: {
          definition: buildConstantArrivalScenario("ABUSE_SCAN", "abuseScansSingleDevice", {
            rate: "ABUSE_SCAN_RATE",
            duration: "ABUSE_SCAN_DURATION",
            preAllocatedVUs: "ABUSE_SCAN_PREALLOCATED_VUS",
            maxVUs: "ABUSE_SCAN_MAX_VUS",
          }),
          requestType: "scan",
          slice: "baseline_valid",
        },
      },
    },
    diagnostic_enqueue_failure: {
      family: "diagnostic",
      suite: "enqueue_failure",
      requiresDeviceBootstrap: true,
      shouldPrimeDuplicates: false,
      networkProfile: resolveNetworkProfile("normal"),
      sections: [
        {
          key: "scan",
          label: "Recovery Executor",
          requestType: "scan",
          scenarioKey: "diagnostic_enqueue_failure",
        },
      ],
      scenarios: {
        diagnostic_enqueue_failure: {
          definition: {
            executor: "per-vu-iterations",
            vus: 1,
            iterations: 1,
            exec: "diagnosticEnqueueFailure",
          },
          requestType: "scan",
          slice: "soak",
        },
      },
    },
    diagnostic_legacy_smoke: {
      family: "diagnostic",
      suite: "legacy_smoke",
      requiresDeviceBootstrap: true,
      shouldPrimeDuplicates: false,
      networkProfile: resolveNetworkProfile("normal"),
      sections: [
        {
          key: "scan",
          label: "Smoke Executor",
          requestType: "scan",
          scenarioKey: "diagnostic_legacy_smoke",
        },
      ],
      scenarios: {
        diagnostic_legacy_smoke: {
          definition: {
            executor: "per-vu-iterations",
            vus: 1,
            iterations: 1,
            exec: "diagnosticLegacySmoke",
          },
          requestType: "scan",
          slice: "baseline_valid",
        },
      },
    },
    network_latency_degraded: {
      family: "network",
      suite: "latency_degraded",
      requiresDeviceBootstrap: true,
      shouldPrimeDuplicates: true,
      networkProfile: resolveNetworkProfile("latency"),
      sections: [
        {
          key: "scan",
          label: "Scan Executor",
          requestType: "scan",
          scenarioKey: "network_latency_degraded",
        },
      ],
      scenarios: {
        network_latency_degraded: {
          definition: buildConstantArrivalScenario(
            "NETWORK_LATENCY_DEGRADED",
            "networkLatencyDegraded",
            {
              rate: "BASELINE_RATE",
              duration: "BASELINE_DURATION",
              preAllocatedVUs: "BASELINE_PREALLOCATED_VUS",
              maxVUs: "BASELINE_MAX_VUS",
            }
          ),
          requestType: "scan",
          slice: "baseline_valid",
        },
      },
    },
    network_jitter_degraded: {
      family: "network",
      suite: "jitter_degraded",
      requiresDeviceBootstrap: true,
      shouldPrimeDuplicates: true,
      networkProfile: resolveNetworkProfile("jitter"),
      sections: [
        {
          key: "scan",
          label: "Scan Executor",
          requestType: "scan",
          scenarioKey: "network_jitter_degraded",
        },
      ],
      scenarios: {
        network_jitter_degraded: {
          definition: buildConstantArrivalScenario(
            "NETWORK_JITTER_DEGRADED",
            "networkJitterDegraded",
            {
              rate: "BASELINE_RATE",
              duration: "BASELINE_DURATION",
              preAllocatedVUs: "BASELINE_PREALLOCATED_VUS",
              maxVUs: "BASELINE_MAX_VUS",
            }
          ),
          requestType: "scan",
          slice: "baseline_valid",
        },
      },
    },
    network_loss_recovery: {
      family: "network",
      suite: "loss_recovery",
      requiresDeviceBootstrap: true,
      shouldPrimeDuplicates: true,
      networkProfile: resolveNetworkProfile("loss_recovery"),
      sections: [
        {
          key: "scan",
          label: "Scan Executor",
          requestType: "scan",
          scenarioKey: "network_loss_recovery",
        },
      ],
      scenarios: {
        network_loss_recovery: {
          definition: buildConstantArrivalScenario(
            "NETWORK_LOSS_RECOVERY",
            "networkLossRecovery",
            {
              rate: "BASELINE_RATE",
              duration: "BASELINE_DURATION",
              preAllocatedVUs: "BASELINE_PREALLOCATED_VUS",
              maxVUs: "BASELINE_MAX_VUS",
            }
          ),
          requestType: "scan",
          slice: "baseline_valid",
        },
      },
    },
  };
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

function buildMixProfile(prefix, defaults) {
  return {
    attendee_sync: envInt(`${prefix}_ATTENDEE_SYNC_WEIGHT`, defaults.attendee_sync || 0) || 0,
    business_duplicate:
      envInt(`${prefix}_BUSINESS_DUPLICATE_WEIGHT`, defaults.business_duplicate || 0) || 0,
    force_refresh_success:
      envInt(`${prefix}_FORCE_REFRESH_SUCCESS_WEIGHT`, defaults.force_refresh_success || 0) || 0,
    invalid: envInt(`${prefix}_INVALID_WEIGHT`, defaults.invalid || 0) || 0,
    replay_duplicate:
      envInt(`${prefix}_REPLAY_DUPLICATE_WEIGHT`, defaults.replay_duplicate || 0) || 0,
    success: envInt(`${prefix}_SUCCESS_WEIGHT`, defaults.success || 0) || 0,
  };
}

function buildMixProfiles() {
  return {
    network_jitter_degraded: buildMixProfile("NETWORK_JITTER_DEGRADED_MIX", {
      success: 95,
      replay_duplicate: 2,
      business_duplicate: 2,
      invalid: 1,
    }),
    network_latency_degraded: buildMixProfile("NETWORK_LATENCY_DEGRADED_MIX", {
      success: 95,
      replay_duplicate: 2,
      business_duplicate: 2,
      invalid: 1,
    }),
    network_loss_recovery: buildMixProfile("NETWORK_LOSS_RECOVERY_MIX", {
      success: 92,
      replay_duplicate: 3,
      business_duplicate: 3,
      invalid: 2,
    }),
    perf_auth_churn: buildMixProfile("PERF_AUTH_CHURN_MIX", {
      success: 82,
      replay_duplicate: 5,
      business_duplicate: 3,
      invalid: 2,
      force_refresh_success: 8,
    }),
    perf_duplicate_heavy: buildMixProfile("PERF_DUPLICATE_HEAVY_MIX", {
      success: 45,
      replay_duplicate: 25,
      business_duplicate: 25,
      invalid: 5,
    }),
    perf_fresh_steady: buildMixProfile("PERF_FRESH_STEADY_MIX", {
      success: 97,
      replay_duplicate: 1,
      business_duplicate: 1,
      invalid: 1,
    }),
    perf_soak_endurance: buildMixProfile("PERF_SOAK_ENDURANCE_MIX", {
      success: 90,
      replay_duplicate: 3,
      business_duplicate: 3,
      invalid: 2,
      force_refresh_success: 1,
      attendee_sync: 1,
    }),
    perf_sync_scan_mixed: buildMixProfile("PERF_SYNC_SCAN_MIXED_MIX", {
      success: 90,
      replay_duplicate: 5,
      business_duplicate: 3,
      invalid: 2,
    }),
  };
}

function buildSelectedSuites(catalog, invokedScenarios) {
  const seenCanonicals = new Map();

  return invokedScenarios.map((invokedScenarioKey) => {
    const canonicalScenarioKey = deprecatedAliases[invokedScenarioKey] || invokedScenarioKey;
    const canonical = catalog[canonicalScenarioKey];

    if (!canonical) {
      throw new Error(`Unknown scenario: ${invokedScenarioKey}`);
    }

    if (seenCanonicals.has(canonicalScenarioKey)) {
      throw new Error(
        `Scenario ${invokedScenarioKey} duplicates canonical scenario ${canonicalScenarioKey}, already selected by ${seenCanonicals.get(canonicalScenarioKey)}`
      );
    }

    seenCanonicals.set(canonicalScenarioKey, invokedScenarioKey);

    return {
      aliasWarning: canonicalScenarioKey !== invokedScenarioKey,
      aliasWarningMessage:
        canonicalScenarioKey !== invokedScenarioKey
          ? deprecatedAliasWarning(invokedScenarioKey, canonicalScenarioKey)
          : null,
      canonicalScenarioKey,
      concreteScenarioKeys: Object.keys(canonical.scenarios),
      family: canonical.family,
      invokedScenarioKey,
      networkProfile: canonical.networkProfile.name,
      requiresDeviceBootstrap: canonical.requiresDeviceBootstrap,
      sections: canonical.sections,
      shouldPrimeDuplicates: canonical.shouldPrimeDuplicates,
      suite: canonical.suite,
    };
  });
}

function buildScenarios(selectedSuites, catalog) {
  return selectedSuites.reduce((acc, selection) => {
    const canonical = catalog[selection.canonicalScenarioKey];

    for (const [scenarioKey, scenarioConfig] of Object.entries(canonical.scenarios)) {
      acc[scenarioKey] = {
        ...scenarioConfig.definition,
        tags: {
          canonical_scenario: selection.canonicalScenarioKey,
          family: selection.family,
          network_profile: selection.networkProfile,
          request_type: scenarioConfig.requestType,
          scenario_key: scenarioKey,
          suite: selection.suite,
          slice: scenarioConfig.slice,
        },
      };
    }

    return acc;
  }, {});
}

function buildScenarioMetadata(selectedSuites, catalog) {
  return selectedSuites.reduce((acc, selection) => {
    const canonical = catalog[selection.canonicalScenarioKey];

    for (const [scenarioKey, scenarioConfig] of Object.entries(canonical.scenarios)) {
      acc[scenarioKey] = {
        canonicalScenario: selection.canonicalScenarioKey,
        family: selection.family,
        networkProfile: selection.networkProfile,
        requestType: scenarioConfig.requestType,
        slice: scenarioConfig.slice,
        suite: selection.suite,
      };
    }

    return acc;
  }, {});
}

function requiresDeviceBootstrap(selectedSuites) {
  return selectedSuites.some((selection) => selection.requiresDeviceBootstrap);
}

function requiredDeviceCount(selectedSuites, scenarios) {
  const required = selectedSuites.reduce((maxCount, selection) => {
    if (!selection.requiresDeviceBootstrap) {
      return maxCount;
    }

    return selection.concreteScenarioKeys.reduce((suiteMax, scenarioKey) => {
      return Math.max(suiteMax, scenarioMaxVus(scenarios[scenarioKey]));
    }, maxCount);
  }, 1);

  const configured = envInt("PERF_DEVICE_COUNT", required);

  if (!Number.isInteger(configured) || configured <= 0) {
    throw new Error("PERF_DEVICE_COUNT must be a positive integer");
  }

  if (requiresDeviceBootstrap(selectedSuites) && configured < required) {
    throw new Error(
      `PERF_DEVICE_COUNT (${configured}) must be at least the maximum selected scenario VUs (${required})`
    );
  }

  return configured;
}

const invokedScenarioKeys = parseScenarioNames();
const scenarioCatalog = buildScenarioCatalog();
const selectedSuites = buildSelectedSuites(scenarioCatalog, invokedScenarioKeys);
const scenarios = buildScenarios(selectedSuites, scenarioCatalog);
const scenarioMetadata = buildScenarioMetadata(selectedSuites, scenarioCatalog);
const ticketPrefix = requireString("TICKET_PREFIX", rawManifest?.ticket_prefix);
const ticketCount = requireInt("TICKET_COUNT", rawManifest?.ticket_count);
const ticketWidth = envInt(
  "TICKET_WIDTH",
  rawManifest?.ticket_width || Math.max(String(ticketCount).length, 6)
);
const fallbackSlices = buildFallbackSlices(ticketCount, ticketPrefix, ticketWidth);
const deviceCount = requiresDeviceBootstrap(selectedSuites)
  ? requiredDeviceCount(selectedSuites, scenarios)
  : 1;
const mixProfiles = buildMixProfiles();
const thresholdPackageConfig = {
  authChurn: {
    clientTtlSeconds: envInt("PERF_AUTH_CHURN_CLIENT_TTL_SECONDS", 45),
    minRefreshParticipationRatio: envFloat(
      "PERF_AUTH_CHURN_MIN_REFRESH_PARTICIPATION_RATIO",
      0.25
    ),
  },
  selectedSuites,
  scenarios,
};

export const config = {
  aliasWarnings: selectedSuites.filter((selection) => selection.aliasWarning),
  baseUrl: requireString("PERF_BASE_URL", envString("BASE_URL")),
  capacityBlockedThreshold: envFloat("PERF_BLOCKED_RATE_THRESHOLD", 0.02),
  controls: rawManifest?.control_ranges || {
    business_prime_count: Math.min(5, fallbackSlices.business_duplicate.count),
    recovery_ticket: null,
    replay_prime_count: Math.min(5, fallbackSlices.baseline_valid.count),
  },
  credential: requireString("CREDENTIAL", rawManifest?.credential),
  deprecatedAliases,
  deviceCount,
  deviceHeader: envString("PERF_DEVICE_HEADER", "x-perf-device-id"),
  deviceIpPrefix: envString("PERF_DEVICE_IP_PREFIX", "10.250"),
  dominantBlockedShareThreshold: envFloat("PERF_BLOCKED_DOMINANCE_THRESHOLD", 0.5),
  enableAttendeeSyncSmoke: envBool("ENABLE_ATTENDEE_SYNC_SMOKE", true),
  eventId: requireInt("EVENT_ID", rawManifest?.event_id),
  invalidPrefix: requireString("INVALID_PREFIX", rawManifest?.invalid_prefix || `INVALID-${ticketPrefix}`),
  manifest: rawManifest,
  mixProfiles,
  networkProfile: resolveNetworkProfile(envString("NETWORK_PROFILE", "normal")),
  recoveryBaseUrl: envString("RECOVERY_BASE_URL", null),
  replay: rawManifest?.idempotency_replay || {
    reserve_count: Math.min(5, fallbackSlices.baseline_valid.count),
    seed: `replay-${requireInt("EVENT_ID", rawManifest?.event_id)}`,
  },
  requiresDeviceBootstrap: requiresDeviceBootstrap(selectedSuites),
  scanBatchSize: envInt("SCAN_BATCH_SIZE", 25),
  scenarioCatalog,
  scenarioMetadata,
  scenarios,
  selectedScenarioKeys: selectedSuites.map((selection) => selection.canonicalScenarioKey),
  selectedSuites,
  shouldPrimeDuplicateDatasets: selectedSuites.some((selection) => selection.shouldPrimeDuplicates),
  slices: rawManifest?.slices || fallbackSlices,
  targetMode: envString("TARGET_MODE", rawManifest?.target_mode || "redis_authoritative"),
  thresholdPackageConfig,
  ticketCount,
  ticketPrefix,
  ticketWidth,
};

export function buildOptions() {
  const thresholdPackage = buildThresholdPackage({
    ...thresholdPackageConfig,
    capacityBlockedThreshold: config.capacityBlockedThreshold,
  });

  return {
    scenarios,
    tags: {
      target_mode: config.targetMode,
    },
    thresholds: thresholdPackage.thresholds,
  };
}

export { envBool, envFloat, envInt, envString, parseDurationSeconds };
