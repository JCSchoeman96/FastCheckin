import { config } from "./config.js";

function metricValue(data, metricName, statName) {
  return data.metrics?.[metricName]?.values?.[statName];
}

function formatNumber(value, fallback = "n/a") {
  if (value === undefined || value === null || Number.isNaN(value)) {
    return fallback;
  }

  return value;
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

function capacitySection(data) {
  const blockedCount = Number(metricValue(data, "capacity_scan_response_blocked", "count") || 0);
  const blockedRate = Number(metricValue(data, "capacity_scan_blocked_rate", "rate") || 0);
  const requestCount = Number(metricValue(data, "capacity_scan_requests", "count") || 0);
  const blockedDevices = collectBlockedDevices(data);
  const topDevice = blockedDevices[0];
  const dominantBlockedShare =
    blockedCount > 0 && topDevice ? Number(topDevice.count) / blockedCount : 0;
  const gatePass =
    blockedRate <= config.capacityBlockedThreshold &&
    dominantBlockedShare <= config.dominantBlockedShareThreshold;

  const lines = [
    "**Capacity Findings**",
    `capacity scan requests: ${requestCount}`,
    `blocked/429 responses: ${blockedCount}`,
    `blocked rate: ${formatNumber(blockedRate)}`,
    `distortion gate (< ${(config.capacityBlockedThreshold * 100).toFixed(0)}% blocked): ${
      gatePass ? "PASS" : "FAIL"
    }`,
    `http_req_duration p(95): ${formatNumber(metricValue(data, "http_req_duration", "p(95)"))}`,
    `http_req_duration p(99): ${formatNumber(metricValue(data, "http_req_duration", "p(99)"))}`,
    `http_req_failed rate: ${formatNumber(metricValue(data, "http_req_failed", "rate"))}`,
    `auth bootstrap logins: ${formatNumber(metricValue(data, "auth_bootstrap_logins", "count"), 0)}`,
    `auth refreshes: ${formatNumber(metricValue(data, "auth_refreshes", "count"), 0)}`,
    `auth failures: ${formatNumber(metricValue(data, "auth_failures", "count"), 0)}`,
    `success results: ${formatNumber(metricValue(data, "scan_result_success", "count"), 0)}`,
    `replay duplicates: ${formatNumber(
      metricValue(data, "scan_result_idempotency_replay_duplicate", "count"),
      0
    )}`,
    `business duplicates: ${formatNumber(
      metricValue(data, "scan_result_business_duplicate", "count"),
      0
    )}`,
    `invalid results: ${formatNumber(metricValue(data, "scan_result_invalid", "count"), 0)}`,
    `retryable failures: ${formatNumber(
      metricValue(data, "scan_result_retryable_failure", "count"),
      0
    )}`,
  ];

  if (topDevice) {
    lines.push(
      `top blocked device: ${topDevice.deviceId} (${topDevice.count} blocked, ${(dominantBlockedShare * 100).toFixed(1)}% of blocked traffic)`
    );
  } else {
    lines.push("top blocked device: none");
  }

  if (blockedDevices.length > 0) {
    lines.push(
      `blocked devices: ${blockedDevices
        .slice(0, 5)
        .map(({ count, deviceId }) => `${deviceId}=${count}`)
        .join(", ")}`
    );
  }

  return lines.join("\n");
}

function abuseSection(data) {
  return [
    "**Abuse-Control Findings**",
    `login blocked responses: ${formatNumber(metricValue(data, "login_response_blocked", "count"), 0)}`,
    `scan blocked responses: ${formatNumber(metricValue(data, "abuse_scan_response_blocked", "count"), 0)}`,
    `auth failures: ${formatNumber(metricValue(data, "auth_failures", "count"), 0)}`,
  ].join("\n");
}

function diagnosticSection(data) {
  return [
    "**Diagnostics**",
    `auth bootstrap logins: ${formatNumber(metricValue(data, "auth_bootstrap_logins", "count"), 0)}`,
    `auth refreshes: ${formatNumber(metricValue(data, "auth_refreshes", "count"), 0)}`,
    `http_req_failed rate: ${formatNumber(metricValue(data, "http_req_failed", "rate"))}`,
  ].join("\n");
}

function renderSummary(data) {
  const sections = [
    `Target mode: ${config.targetMode}`,
    `Scenarios: ${config.selectedScenarios.join(", ")}`,
  ];

  if (config.selectedScenarios.some((name) => name.startsWith("capacity_"))) {
    sections.push(capacitySection(data));
  }

  if (config.selectedScenarios.some((name) => name.startsWith("abuse_"))) {
    sections.push(abuseSection(data));
  }

  if (
    config.selectedScenarios.some((name) => ["enqueue_failure", "legacy_smoke"].includes(name))
  ) {
    sections.push(diagnosticSection(data));
  }

  return `${sections.join("\n\n")}\n`;
}

export function buildSummary(data) {
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const summaryPath = __ENV.K6_SUMMARY_PATH || `performance/results/k6-summary-${timestamp}.json`;

  return {
    stdout: renderSummary(data),
    [summaryPath]: JSON.stringify(data, null, 2),
  };
}
