import { Counter, Rate } from "k6/metrics";

import { config } from "./config.js";
import { deviceMetricSuffix } from "./devices.js";

export const successResults = new Counter("scan_result_success");
export const replayDuplicateResults = new Counter("scan_result_idempotency_replay_duplicate");
export const businessDuplicateResults = new Counter("scan_result_business_duplicate");
export const invalidResults = new Counter("scan_result_invalid");
export const retryableFailureResults = new Counter("scan_result_retryable_failure");
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

function classifyResult(result) {
  const message = (result?.message || "").toLowerCase();
  const status = result?.status;

  if (status === "success") {
    return "success";
  }

  if (status === "duplicate") {
    return "replay_duplicate";
  }

  if (message.includes("already checked in")) {
    return "business_duplicate";
  }

  if (message.includes("ticket not found")) {
    return "invalid";
  }

  return "retryable_failure";
}

function incrementCategory(category) {
  switch (category) {
    case "success":
      successResults.add(1);
      break;
    case "replay_duplicate":
      replayDuplicateResults.add(1);
      break;
    case "business_duplicate":
      businessDuplicateResults.add(1);
      break;
    case "invalid":
      invalidResults.add(1);
      break;
    default:
      retryableFailureResults.add(1);
      break;
  }
}

function recordRequest(suite, blocked, deviceIndex) {
  switch (suite) {
    case "capacity":
      capacityScanRequests.add(1);
      capacityScanBlockedRate.add(blocked);

      if (blocked) {
        capacityScanBlockedResponses.add(1);

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
      abuseScanRequests.add(1);

      if (blocked) {
        abuseScanBlockedResponses.add(1);
      }

      break;

    default:
      break;
  }

  if (blocked) {
    scanBlockedResponses.add(1);
  }
}

export function recordResponse(response, context = {}) {
  const payload = maybeJson(response);
  const requestType = context.requestType || "scan";
  const isBlocked = response.status === 429;

  if (requestType === "scan") {
    recordRequest(context.suite, isBlocked, context.deviceIndex);
  }

  if (isBlocked) {
    return payload;
  }

  if (response.status >= 500) {
    retryableFailureResults.add(1);
    return payload;
  }

  const topLevelCode = payload?.error?.code;

  if (topLevelCode === "durability_enqueue_failed" || topLevelCode === "scan_ingestion_failed") {
    retryableFailureResults.add(1);
    return payload;
  }

  const results = payload?.data?.results || [];

  for (const result of results) {
    incrementCategory(classifyResult(result));
  }

  return payload;
}
