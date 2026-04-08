import { buildAcceptanceManifest, renderAcceptanceMarkdown } from "./result_manifest.js";

function formatNumber(value, digits = 2, fallback = "n/a") {
  if (value === undefined || value === null || Number.isNaN(value)) {
    return fallback;
  }

  return Number(value).toFixed(digits);
}

function renderSuite(result) {
  const lines = [
    `**${result.canonicalScenarioKey}**`,
    `invoked scenario: ${result.invokedScenarioKey}`,
    `canonical scenario: ${result.canonicalScenarioKey}`,
    `alias warning: ${result.aliasWarning ? "yes" : "no"}`,
    `family verdict: ${result.familyVerdict}`,
    `auth bootstrap logins: ${result.familyMetrics.authBootstrapLogins}`,
    `auth refreshes: ${result.familyMetrics.authRefreshes}`,
    `auth failures: ${result.familyMetrics.authFailures}`,
    `auth refresh failure rate: ${formatNumber(result.familyMetrics.authRefreshFailureRate, 4)}`,
    `retryable failures: ${result.familyMetrics.retryableFailures}`,
    `retryable failure rate: ${formatNumber(result.familyMetrics.retryableFailureRate, 4)}`,
    `success results: ${result.familyMetrics.successResults}`,
    `replay duplicates: ${result.familyMetrics.replayDuplicateResults}`,
    `business duplicates: ${result.familyMetrics.businessDuplicateResults}`,
    `invalid results: ${result.familyMetrics.invalidResults}`,
  ];

  if (result.aliasWarningMessage) {
    lines.push(`deprecation: ${result.aliasWarningMessage}`);
  }

  for (const section of result.sections) {
    lines.push(`${section.label}: ${section.verdict}`);
    lines.push(`  scenario key: ${section.scenarioKey}`);
    lines.push(`  request type: ${section.requestType}`);
    lines.push(`  executor: ${section.metrics.executor.executor}`);
    lines.push(`  configured VUs: ${section.metrics.executor.configuredVus}`);
    lines.push(`  configured max VUs: ${section.metrics.executor.maxVUs}`);
    lines.push(`  requests: ${section.metrics.requestCount}`);
    lines.push(`  p95 latency: ${formatNumber(section.metrics.p95)}`);
    lines.push(`  p99 latency: ${formatNumber(section.metrics.p99)}`);
    lines.push(`  http failure rate: ${formatNumber(section.metrics.httpFailedRate, 4)}`);
    lines.push(`  dropped iterations: ${section.metrics.droppedIterations}`);

    if (section.metrics.blockedCount !== undefined) {
      lines.push(`  blocked responses: ${section.metrics.blockedCount}`);
      lines.push(`  blocked rate: ${formatNumber(section.metrics.blockedRate, 4)}`);
    }
  }

  return lines.join("\n");
}

function renderSummary(manifest) {
  const sections = [
    `Target mode: ${manifest.targetMode}`,
    `Scenarios: ${manifest.selectedSuites.map((suite) => suite.canonicalScenarioKey).join(", ")}`,
    `Peak VUs: ${manifest.vus.peak}`,
    `Max VUs: ${manifest.vus.max}`,
  ];

  if (manifest.aliasWarnings.length > 0) {
    sections.push(
      [
        "**Deprecated Aliases**",
        ...manifest.aliasWarnings.map((warning) => warning.message),
      ].join("\n")
    );
  }

  for (const suite of manifest.selectedSuites) {
    sections.push(renderSuite(suite));
  }

  if (manifest.blockedDevices.length > 0) {
    sections.push(
      [
        "**Top Blocked Devices**",
        ...manifest.blockedDevices.map((blockedDevice) => `${blockedDevice.deviceId}: ${blockedDevice.count}`),
      ].join("\n")
    );
  }

  return `${sections.join("\n\n")}\n`;
}

export function buildSummary(data) {
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const summaryPath = __ENV.K6_SUMMARY_PATH || `performance/results/k6-summary-${timestamp}.json`;
  const acceptanceJsonPath =
    __ENV.K6_ACCEPTANCE_PATH || `performance/results/k6-acceptance-${timestamp}.json`;
  const acceptanceMarkdownPath =
    __ENV.K6_ACCEPTANCE_MARKDOWN_PATH || `performance/results/k6-acceptance-${timestamp}.md`;
  const manifest = buildAcceptanceManifest(data);

  return {
    stdout: renderSummary(manifest),
    [acceptanceJsonPath]: JSON.stringify(manifest, null, 2),
    [acceptanceMarkdownPath]: renderAcceptanceMarkdown(manifest),
    [summaryPath]: JSON.stringify(data, null, 2),
  };
}
