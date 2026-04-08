import { config } from "./config.js";
import { buildThresholdPackage } from "./thresholds.js";

function metricValue(data, metricKey, statName) {
  return data.metrics?.[metricKey]?.values?.[statName];
}

function metricStat(data, metricKey, statName, fallbacks = []) {
  const candidates = [statName, ...fallbacks];

  for (const candidate of candidates) {
    const value = metricValue(data, metricKey, candidate);

    if (value !== undefined && value !== null && !Number.isNaN(Number(value))) {
      return Number(value);
    }
  }

  return null;
}

function formatNumber(value, digits = 2, fallback = "n/a") {
  if (value === undefined || value === null || Number.isNaN(value)) {
    return fallback;
  }

  return Number(value).toFixed(digits);
}

function compare(value, comparator, target) {
  switch (comparator) {
    case "<":
      return value < target;
    case "<=":
      return value <= target;
    case ">=":
      return value >= target;
    default:
      return false;
  }
}

function evaluateRule(data, suiteRule) {
  const actual = metricStat(data, suiteRule.metricKey, suiteRule.stat, suiteRule.fallbackStats || []);

  return {
    actual: Number.isNaN(actual) ? null : actual,
    comparator: suiteRule.comparator,
    label: suiteRule.label,
    metricKey: suiteRule.metricKey,
    passed: Number.isFinite(actual) ? compare(actual, suiteRule.comparator, suiteRule.target) : false,
    stat: suiteRule.stat,
    target: suiteRule.target,
  };
}

function sectionMetrics(data, section) {
  const scenarioConfig = config.scenarios[section.scenarioKey] || {};

  const metrics = {
    droppedIterations: Number(metricValue(data, section.selectors.droppedIterations.key, "count") || 0),
    executor: {
      configuredVus: Number(scenarioConfig.vus || scenarioConfig.preAllocatedVUs || 0),
      duration: scenarioConfig.duration || null,
      executor: scenarioConfig.executor || null,
      maxVUs: Number(scenarioConfig.maxVUs || scenarioConfig.vus || scenarioConfig.preAllocatedVUs || 0),
      rate: Number(scenarioConfig.rate || scenarioConfig.startRate || 0),
    },
    httpFailedRate: Number(metricValue(data, section.selectors.httpFailed.key, "rate") || 0),
    p95: metricStat(data, section.selectors.httpReqDuration.key, "p(95)", ["max"]) || 0,
    p99: metricStat(data, section.selectors.httpReqDuration.key, "p(99)", ["max", "p(95)"]) || 0,
    requestCount: Number(metricValue(data, section.selectors.httpReqs.key, "count") || 0),
  };

  if (section.selectors.blockedCount) {
    metrics.blockedCount = Number(metricValue(data, section.selectors.blockedCount.key, "count") || 0);
  }

  if (section.selectors.blockedRate) {
    metrics.blockedRate = Number(metricValue(data, section.selectors.blockedRate.key, "rate") || 0);
  }

  return metrics;
}

function familyMetrics(data, familySelectors) {
  const authRefreshes = Number(metricValue(data, familySelectors.authRefreshes.key, "count") || 0);
  const refreshFailures = Number(metricValue(data, familySelectors.authRefreshFailures.key, "count") || 0);
  const globalBootstrapLogins =
    config.selectedSuites.length === 1 ? Number(data.metrics?.auth_bootstrap_logins?.values?.count || 0) : 0;
  const bootstrapLogins =
    Number(metricValue(data, familySelectors.authBootstrapLogins.key, "count") || 0) || globalBootstrapLogins;

  return {
    authBootstrapFailures: Number(metricValue(data, familySelectors.authBootstrapFailures.key, "count") || 0),
    authBootstrapLogins: bootstrapLogins,
    authFailures: Number(metricValue(data, familySelectors.authFailures.key, "count") || 0),
    authRefreshFailureRate: authRefreshes > 0 ? refreshFailures / authRefreshes : 0,
    authRefreshFailures: refreshFailures,
    authRefreshes,
    businessDuplicateResults: Number(
      metricValue(data, familySelectors.businessDuplicateResults.key, "count") || 0
    ),
    invalidResults: Number(metricValue(data, familySelectors.invalidResults.key, "count") || 0),
    replayDuplicateResults: Number(
      metricValue(data, familySelectors.replayDuplicateResults.key, "count") || 0
    ),
    retryableFailureRate: Number(
      metricValue(data, familySelectors.retryableFailureRate.key, "rate") || 0
    ),
    retryableFailures: Number(metricValue(data, familySelectors.retryableFailures.key, "count") || 0),
    successResults: Number(metricValue(data, familySelectors.successResults.key, "count") || 0),
  };
}

function collectBlockedDevices(data) {
  return Object.entries(data.metrics || {})
    .filter(([metricName]) => metricName.startsWith("capacity_blocked_device_"))
    .map(([metricName, metric]) => {
      const suffix = metricName.replace("capacity_blocked_device_", "");
      const count = Number(metric?.values?.count || 0);

      return {
        count,
        deviceId: `device-${suffix}`,
      };
    })
    .filter(({ count }) => count > 0)
    .sort((left, right) => right.count - left.count);
}

function evaluateSuite(data, spec) {
  const rules = spec.rules.map((suiteRule) => evaluateRule(data, suiteRule));
  const sections = spec.sections.map((section) => {
    const sectionRules = rules.filter((rule) =>
      Object.values(section.selectors).some((selector) => selector.key === rule.metricKey)
    );
    const verdict =
      sectionRules.length === 0 ? "INFO" : sectionRules.every((rule) => rule.passed) ? "PASS" : "FAIL";

    return {
      id: section.id,
      label: section.label,
      metrics: sectionMetrics(data, section),
      requestType: section.requestType,
      rules: sectionRules,
      scenarioKey: section.scenarioKey,
      verdict,
    };
  });

  const familyVerdict =
    rules.length === 0 ? "INFO" : rules.every((suiteRule) => suiteRule.passed) ? "PASS" : "FAIL";

  return {
    aliasWarning: spec.aliasWarning,
    aliasWarningMessage: spec.aliasWarningMessage,
    canonicalScenarioKey: spec.canonicalScenarioKey,
    family: spec.family,
    familyMetrics: familyMetrics(data, spec.familySelectors),
    familyVerdict,
    invokedScenarioKey: spec.invokedScenarioKey,
    networkProfile: spec.networkProfile,
    rules,
    sections,
    suite: spec.suite,
  };
}

function suiteMarkdown(result) {
  const lines = [
    `## ${result.canonicalScenarioKey}`,
    `- invoked scenario: ${result.invokedScenarioKey}`,
    `- canonical scenario: ${result.canonicalScenarioKey}`,
    `- alias warning: ${result.aliasWarning ? "yes" : "no"}`,
    `- verdict: ${result.familyVerdict}`,
    `- auth bootstrap logins: ${result.familyMetrics.authBootstrapLogins}`,
    `- auth refreshes: ${result.familyMetrics.authRefreshes}`,
    `- auth failures: ${result.familyMetrics.authFailures}`,
    `- auth refresh failure rate: ${formatNumber(result.familyMetrics.authRefreshFailureRate, 4)}`,
    `- retryable failures: ${result.familyMetrics.retryableFailures}`,
    `- retryable failure rate: ${formatNumber(result.familyMetrics.retryableFailureRate, 4)}`,
  ];

  if (result.aliasWarningMessage) {
    lines.push(`- deprecation: ${result.aliasWarningMessage}`);
  }

  for (const section of result.sections) {
    lines.push(`### ${section.label}`);
    lines.push(`- scenario key: ${section.scenarioKey}`);
    lines.push(`- request type: ${section.requestType}`);
    lines.push(`- executor: ${section.metrics.executor.executor}`);
    lines.push(`- configured VUs: ${section.metrics.executor.configuredVus}`);
    lines.push(`- configured max VUs: ${section.metrics.executor.maxVUs}`);
    lines.push(`- verdict: ${section.verdict}`);
    lines.push(`- requests: ${section.metrics.requestCount}`);
    lines.push(`- p95 latency: ${formatNumber(section.metrics.p95)}`);
    lines.push(`- p99 latency: ${formatNumber(section.metrics.p99)}`);
    lines.push(`- http failure rate: ${formatNumber(section.metrics.httpFailedRate, 4)}`);
    lines.push(`- dropped iterations: ${section.metrics.droppedIterations}`);

    if (section.metrics.blockedCount !== undefined) {
      lines.push(`- blocked responses: ${section.metrics.blockedCount}`);
      lines.push(`- blocked rate: ${formatNumber(section.metrics.blockedRate, 4)}`);
    }
  }

  return lines.join("\n");
}

export function buildAcceptanceManifest(data) {
  const thresholdPackage = buildThresholdPackage({
    ...config.thresholdPackageConfig,
    capacityBlockedThreshold: config.capacityBlockedThreshold,
  });
  const suites = thresholdPackage.suiteSpecs.map((spec) => evaluateSuite(data, spec));
  const blockedDevices = collectBlockedDevices(data);

  return {
    aliasWarnings: config.aliasWarnings.map((selection) => ({
      aliasWarning: selection.aliasWarning,
      canonicalScenarioKey: selection.canonicalScenarioKey,
      invokedScenarioKey: selection.invokedScenarioKey,
      message: selection.aliasWarningMessage,
    })),
    blockedDevices: blockedDevices.slice(0, 5),
    selectedSuites: suites,
    targetMode: config.targetMode,
    timestamp: new Date().toISOString(),
    vus: {
      max: Number(data.metrics?.vus_max?.values?.max || 0),
      peak: Number(data.metrics?.vus?.values?.max || 0),
    },
  };
}

export function renderAcceptanceMarkdown(manifest) {
  const lines = [
    "# k6 Acceptance Report",
    "",
    `- target mode: ${manifest.targetMode}`,
    `- selected suites: ${manifest.selectedSuites.map((suite) => suite.canonicalScenarioKey).join(", ")}`,
    `- peak vus: ${manifest.vus.peak}`,
    `- max vus: ${manifest.vus.max}`,
  ];

  if (manifest.aliasWarnings.length > 0) {
    lines.push("", "## Deprecated Aliases");

    for (const warning of manifest.aliasWarnings) {
      lines.push(`- ${warning.message}`);
    }
  }

  if (manifest.blockedDevices.length > 0) {
    lines.push("", "## Top Blocked Devices");

    for (const blockedDevice of manifest.blockedDevices) {
      lines.push(`- ${blockedDevice.deviceId}: ${blockedDevice.count}`);
    }
  }

  for (const suite of manifest.selectedSuites) {
    lines.push("", suiteMarkdown(suite));
  }

  return `${lines.join("\n")}\n`;
}
