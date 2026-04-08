import { Counter, Rate } from "k6/metrics";

import { config } from "./config.js";
import { deviceMetricSuffix } from "./devices.js";

export const successResults = new Counter("scan_result_success");
export const replayDuplicateResults = new Counter("scan_result_idempotency_replay_duplicate");
export const businessDuplicateResults = new Counter("scan_result_business_duplicate");
export const invalidResults = new Counter("scan_result_invalid");
export const retryableFailureResults = new Counter("scan_result_retryable_failure");
export const scanRetryableFailureRate = new Rate("scan_retryable_failure_rate");
export const scanBlockedResponses = new Counter("scan_response_blocked");
export const capacityScanBlockedResponses = new Counter("capacity_scan_response_blocked");
export const abuseScanBlockedResponses = new Counter("abuse_scan_response_blocked");
export const capacityScanRequests = new Counter("capacity_scan_requests");
export const abuseScanRequests = new Counter("abuse_scan_requests");
export const capacityScanBlockedRate = new Rate("capacity_scan_blocked_rate");

const blockedDeviceCounters = Array.from({ length: config.deviceCount }, (_unused, index) => {
  return new Counter(`capacity_blocked_device_${deviceMetricSuffix(index)}`);
});

function maybeJson(response) {
  try {
    return response.json();
  } catch (_error) {
    return null;
  }
}

function metricTags(context = {}) {
  return {
    canonical_scenario: context.canonicalScenario || "setup",
    family: context.family || "setup",
    network_profile: context.networkProfile || "normal",
    request_type: context.requestType || "scan",
    scenario_key: context.scenarioKey || "setup",
    suite: context.suite || "setup",
  };
}

function classifyResult(result) {
  const message = (result?.message || "").toLowerCase();
  const status = result?.status;

  if (message.includes("already checked in")) {
    return "business_duplicate";
  }

  if (status === "success") {
    return "success";
  }

  if (status === "duplicate") {
    return "replay_duplicate";
  }

  if (message.includes("ticket not found")) {
    return "invalid";
  }

  return "retryable_failure";
}

function incrementCategory(category, tags) {
  switch (category) {
    case "success":
      successResults.add(1, tags);
      scanRetryableFailureRate.add(false, tags);
      break;
    case "replay_duplicate":
      replayDuplicateResults.add(1, tags);
      scanRetryableFailureRate.add(false, tags);
      break;
    case "business_duplicate":
      businessDuplicateResults.add(1, tags);
      scanRetryableFailureRate.add(false, tags);
      break;
    case "invalid":
      invalidResults.add(1, tags);
      scanRetryableFailureRate.add(false, tags);
      break;
    default:
      retryableFailureResults.add(1, tags);
      scanRetryableFailureRate.add(true, tags);
      break;
  }
}

function recordRequest(suite, blocked, deviceIndex, tags) {
  switch (suite) {
    case "performance":
    case "network":
      capacityScanRequests.add(1, tags);
      capacityScanBlockedRate.add(blocked, tags);

      if (blocked) {
        capacityScanBlockedResponses.add(1, tags);

        if (
          Number.isInteger(deviceIndex) &&
          deviceIndex >= 0 &&
          deviceIndex < blockedDeviceCounters.length
        ) {
          blockedDeviceCounters[deviceIndex].add(1);
        }
      }

      break;
    case "abuse":
      abuseScanRequests.add(1, tags);

      if (blocked) {
        abuseScanBlockedResponses.add(1, tags);
      }

      break;
    default:
      break;
  }

  if (blocked) {
    scanBlockedResponses.add(1, tags);
  }
}

export function recordResponse(response, context = {}) {
  const payload = maybeJson(response);
  const requestType = context.requestType || "scan";
  const isBlocked = response.status === 429;
  const tags = metricTags(context);

  if (requestType === "scan") {
    recordRequest(context.family, isBlocked, context.deviceIndex, tags);
  }

  if (isBlocked) {
    scanRetryableFailureRate.add(false, tags);
    return payload;
  }

  if (response.status >= 500) {
    retryableFailureResults.add(1, tags);
    scanRetryableFailureRate.add(true, tags);
    return payload;
  }

  const topLevelCode = payload?.error?.code;

  if (topLevelCode === "durability_enqueue_failed" || topLevelCode === "scan_ingestion_failed") {
    retryableFailureResults.add(1, tags);
    scanRetryableFailureRate.add(true, tags);
    return payload;
  }

  const results = payload?.data?.results || [];

  if (results.length === 0 && requestType === "scan") {
    scanRetryableFailureRate.add(false, tags);
  }

  for (const result of results) {
    incrementCategory(classifyResult(result), tags);
  }

  return payload;
}
