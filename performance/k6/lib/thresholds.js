const TAG_ORDER = [
  "scenario",
  "scenario_key",
  "canonical_scenario",
  "family",
  "suite",
  "slice",
  "request_type",
  "network_profile",
  "auth_reason",
];

function durationSeconds(duration) {
  if (typeof duration !== "string") {
    return 0;
  }

  const match = duration.match(/^(\d+)(ms|s|m|h)$/i);

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

export function buildSelector(metricName, tags = {}) {
  const orderedEntries = Object.entries(tags).sort(([left], [right]) => {
    const leftIndex = TAG_ORDER.indexOf(left);
    const rightIndex = TAG_ORDER.indexOf(right);

    if (leftIndex === -1 && rightIndex === -1) {
      return left.localeCompare(right);
    }

    if (leftIndex === -1) {
      return 1;
    }

    if (rightIndex === -1) {
      return -1;
    }

    return leftIndex - rightIndex;
  });

  if (orderedEntries.length === 0) {
    return metricName;
  }

  const serialized = orderedEntries.map(([key, value]) => `${key}:${value}`).join(",");
  return `${metricName}{${serialized}}`;
}

function addThreshold(thresholds, selector, expression) {
  if (!thresholds[selector]) {
    thresholds[selector] = [];
  }

  if (!thresholds[selector].includes(expression)) {
    thresholds[selector].push(expression);
  }
}

function addVisibilityThresholds(thresholds, selectors = {}) {
  for (const selector of Object.values(selectors)) {
    if (!selector?.key || !selector?.visibility) {
      continue;
    }

    addThreshold(thresholds, selector.key, selector.visibility);
  }
}

function rule(label, selector, stat, comparator, target, visibility, fallbackStats = []) {
  return {
    comparator,
    expression: `${stat}${comparator}${target}`,
    fallbackStats,
    label,
    metricKey: selector,
    stat,
    target,
    visibility,
  };
}

function baseSection(selection, section) {
  const tags = {
    canonical_scenario: selection.canonicalScenarioKey,
    request_type: section.requestType,
    scenario: section.scenarioKey,
  };

  return {
    id: section.key,
    label: section.label,
    requestType: section.requestType,
    scenarioKey: section.scenarioKey,
    selectors: {
      droppedIterations: {
        key: buildSelector("dropped_iterations", { scenario: section.scenarioKey }),
        visibility: "count>=0",
      },
      httpFailed: {
        key: buildSelector("http_req_failed", tags),
        visibility: "rate>=0",
      },
      httpReqDuration: {
        key: buildSelector("http_req_duration", tags),
        visibility: "max>=0",
      },
      httpReqs: {
        key: buildSelector("http_reqs", tags),
        visibility: "count>=0",
      },
    },
  };
}

function scanSection(selection, section) {
  const base = baseSection(selection, section);
  const scanTags = {
    canonical_scenario: selection.canonicalScenarioKey,
    scenario_key: section.scenarioKey,
  };

  return {
    ...base,
    selectors: {
      ...base.selectors,
      blockedCount: {
        key: buildSelector("capacity_scan_response_blocked", scanTags),
        visibility: "count>=0",
      },
      blockedRate: {
        key: buildSelector("capacity_scan_blocked_rate", scanTags),
        visibility: "rate>=0",
      },
    },
  };
}

function familySelectors(selection) {
  const familyTags = { canonical_scenario: selection.canonicalScenarioKey };

  return {
    authBootstrapFailures: {
      key: buildSelector("auth_failures", { ...familyTags, auth_reason: "bootstrap" }),
      visibility: "count>=0",
    },
    authBootstrapLogins: {
      key: buildSelector("auth_bootstrap_logins", familyTags),
      visibility: "count>=0",
    },
    authFailures: {
      key: buildSelector("auth_failures", familyTags),
      visibility: "count>=0",
    },
    authRefreshFailures: {
      key: buildSelector("auth_failures", { ...familyTags, auth_reason: "refresh" }),
      visibility: "count>=0",
    },
    authRefreshes: {
      key: buildSelector("auth_refreshes", familyTags),
      visibility: "count>=0",
    },
    businessDuplicateResults: {
      key: buildSelector("scan_result_business_duplicate", familyTags),
      visibility: "count>=0",
    },
    invalidResults: {
      key: buildSelector("scan_result_invalid", familyTags),
      visibility: "count>=0",
    },
    replayDuplicateResults: {
      key: buildSelector("scan_result_idempotency_replay_duplicate", familyTags),
      visibility: "count>=0",
    },
    retryableFailureRate: {
      key: buildSelector("scan_retryable_failure_rate", familyTags),
      visibility: "rate>=0",
    },
    retryableFailures: {
      key: buildSelector("scan_result_retryable_failure", familyTags),
      visibility: "count>=0",
    },
    successResults: {
      key: buildSelector("scan_result_success", familyTags),
      visibility: "count>=0",
    },
  };
}

function authChurnMinimumRefreshes(config) {
  const scenario = config.scenarios.perf_auth_churn;

  if (!scenario) {
    return 1;
  }

  const vus = scenario.vus || scenario.preAllocatedVUs || 1;
  const duration = durationSeconds(scenario.duration);
  const ttlSeconds = Math.max(config.authChurn.clientTtlSeconds || 45, 1);
  const cyclesPerVu = Math.max(1, Math.floor(duration / ttlSeconds));
  const ratio = Math.min(
    1,
    Math.max(config.authChurn.minRefreshParticipationRatio || 0.25, 0.05)
  );

  return Math.max(1, Math.floor(vus * cyclesPerVu * ratio));
}

function suiteSections(selection) {
  return selection.sections.map((section) => {
    if (section.requestType === "scan") {
      return scanSection(selection, section);
    }

    return baseSection(selection, section);
  });
}

function suiteRules(selection, sections, family, config) {
  const scan = sections.find((section) => section.requestType === "scan");
  const attendees = sections.find((section) => section.requestType === "attendees");
  const suiteRuleset = [];

  switch (selection.canonicalScenarioKey) {
    case "perf_fresh_steady":
      suiteRuleset.push(
        rule("scan p95 latency", scan.selectors.httpReqDuration.key, "p(95)", "<", 500, "max>=0", ["max"]),
        rule(
          "scan p99 latency",
          scan.selectors.httpReqDuration.key,
          "p(99)",
          "<",
          1000,
          "max>=0",
          ["max", "p(95)"]
        ),
        rule(
          "scan blocked rate",
          scan.selectors.blockedRate.key,
          "rate",
          "<",
          config.capacityBlockedThreshold,
          "rate>=0"
        ),
        rule("auth failures", family.authFailures.key, "count", "<", 1, "count>=0")
      );
      break;
    case "perf_duplicate_heavy":
      suiteRuleset.push(
        rule("scan p95 latency", scan.selectors.httpReqDuration.key, "p(95)", "<", 750, "max>=0", ["max"]),
        rule(
          "scan p99 latency",
          scan.selectors.httpReqDuration.key,
          "p(99)",
          "<",
          1500,
          "max>=0",
          ["max", "p(95)"]
        ),
        rule(
          "retryable failure rate",
          family.retryableFailureRate.key,
          "rate",
          "<",
          0.02,
          "rate>=0"
        ),
        rule(
          "scan blocked rate",
          scan.selectors.blockedRate.key,
          "rate",
          "<",
          config.capacityBlockedThreshold,
          "rate>=0"
        ),
        rule("auth failures", family.authFailures.key, "count", "<", 1, "count>=0")
      );
      break;
    case "perf_auth_churn":
      suiteRuleset.push(
        rule("scan p95 latency", scan.selectors.httpReqDuration.key, "p(95)", "<", 750, "max>=0", ["max"]),
        rule(
          "scan p99 latency",
          scan.selectors.httpReqDuration.key,
          "p(99)",
          "<",
          1500,
          "max>=0",
          ["max", "p(95)"]
        ),
        rule("bootstrap auth failures", family.authBootstrapFailures.key, "count", "<", 1, "count>=0"),
        rule("refresh auth failures", family.authRefreshFailures.key, "count", "<", 1, "count>=0"),
        rule(
          "minimum refresh activity",
          family.authRefreshes.key,
          "count",
          ">=",
          authChurnMinimumRefreshes(config),
          "count>=0"
        )
      );
      break;
    case "perf_sync_scan_mixed":
      suiteRuleset.push(
        rule("scan p95 latency", scan.selectors.httpReqDuration.key, "p(95)", "<", 750, "max>=0", ["max"]),
        rule(
          "scan p99 latency",
          scan.selectors.httpReqDuration.key,
          "p(99)",
          "<",
          1500,
          "max>=0",
          ["max", "p(95)"]
        ),
        rule(
          "attendee p95 latency",
          attendees.selectors.httpReqDuration.key,
          "p(95)",
          "<",
          1000,
          "max>=0",
          ["max"]
        ),
        rule(
          "attendee p99 latency",
          attendees.selectors.httpReqDuration.key,
          "p(99)",
          "<",
          2000,
          "max>=0",
          ["max", "p(95)"]
        ),
        rule(
          "scan blocked rate",
          scan.selectors.blockedRate.key,
          "rate",
          "<",
          config.capacityBlockedThreshold,
          "rate>=0"
        ),
        rule("auth failures", family.authFailures.key, "count", "<", 1, "count>=0")
      );
      break;
    case "perf_soak_endurance":
      suiteRuleset.push(
        rule("scan p95 latency", scan.selectors.httpReqDuration.key, "p(95)", "<", 1000, "max>=0", ["max"]),
        rule(
          "scan p99 latency",
          scan.selectors.httpReqDuration.key,
          "p(99)",
          "<",
          2000,
          "max>=0",
          ["max", "p(95)"]
        ),
        rule(
          "scan blocked rate",
          scan.selectors.blockedRate.key,
          "rate",
          "<",
          config.capacityBlockedThreshold,
          "rate>=0"
        ),
        rule(
          "retryable failure rate",
          family.retryableFailureRate.key,
          "rate",
          "<",
          0.01,
          "rate>=0"
        ),
        rule("auth failures", family.authFailures.key, "count", "<", 1, "count>=0"),
        rule(
          "dropped iterations",
          scan.selectors.droppedIterations.key,
          "count",
          "<=",
          0,
          "count>=0"
        )
      );
      break;
    case "perf_spike_batch":
      suiteRuleset.push(
        rule("scan p95 latency", scan.selectors.httpReqDuration.key, "p(95)", "<", 1500, "max>=0", ["max"]),
        rule("auth failures", family.authFailures.key, "count", "<", 1, "count>=0")
      );
      break;
    case "network_latency_degraded":
    case "network_jitter_degraded":
    case "network_loss_recovery":
      suiteRuleset.push(
        rule("scan p95 latency", scan.selectors.httpReqDuration.key, "p(95)", "<", 2500, "max>=0", ["max"]),
        rule(
          "scan p99 latency",
          scan.selectors.httpReqDuration.key,
          "p(99)",
          "<",
          5000,
          "max>=0",
          ["max", "p(95)"]
        ),
        rule(
          "retryable failure rate",
          family.retryableFailureRate.key,
          "rate",
          "<",
          0.05,
          "rate>=0"
        ),
        rule("auth failures", family.authFailures.key, "count", "<", 1, "count>=0")
      );
      break;
    default:
      break;
  }

  return suiteRuleset;
}

function suiteSpec(selection, config) {
  const sections = suiteSections(selection);
  const family = familySelectors(selection);
  const rules = suiteRules(selection, sections, family, config);

  return {
    aliasWarning: selection.aliasWarning,
    aliasWarningMessage: selection.aliasWarningMessage,
    canonicalScenarioKey: selection.canonicalScenarioKey,
    family: selection.family,
    familySelectors: family,
    invokedScenarioKey: selection.invokedScenarioKey,
    networkProfile: selection.networkProfile,
    rules,
    sections,
    suite: selection.suite,
  };
}

export function buildThresholdPackage(config) {
  const enforce = !!__ENV.K6_ENFORCE_THRESHOLDS &&
    ["1", "true", "yes", "on"].includes(String(__ENV.K6_ENFORCE_THRESHOLDS).toLowerCase());
  const suiteSpecs = config.selectedSuites.map((selection) => suiteSpec(selection, config));
  const thresholds = {};

  for (const spec of suiteSpecs) {
    addVisibilityThresholds(thresholds, spec.familySelectors);

    for (const section of spec.sections) {
      addVisibilityThresholds(thresholds, section.selectors);
    }

    for (const suiteRule of spec.rules) {
      addThreshold(thresholds, suiteRule.metricKey, enforce ? suiteRule.expression : suiteRule.visibility);
    }
  }

  return {
    enforce,
    suiteSpecs,
    thresholds,
  };
}
