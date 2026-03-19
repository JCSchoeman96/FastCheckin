import exec from "k6/execution";
import { check } from "k6";

import {
  bootstrapDevicePool,
  getAttendees,
  postScans,
  rawLogin,
  resetAuthState,
} from "./lib/auth.js";
import { recordResponse } from "./lib/classify.js";
import { buildOptions, config } from "./lib/config.js";
import { deviceIdFromIndex } from "./lib/devices.js";
import {
  buildBusinessDuplicateScan,
  buildBusinessPrimeScan,
  buildInvalidScan,
  buildOfflineBurstBatch,
  buildRecoveryScan,
  buildReplayDuplicateScan,
  buildReplayPrimeScan,
  buildSuccessScan,
} from "./lib/payloads.js";
import { buildSummary } from "./lib/summary.js";

export const options = buildOptions();

function currentCapacityDevice(setupData) {
  const deviceIndex = (exec.vu.idInTest - 1) % setupData.devices.length;
  return setupData.devices[deviceIndex];
}

function indexedDevice(setupData, index) {
  return setupData.devices[index % setupData.devices.length];
}

function hotDevice(setupData) {
  return setupData.devices[0];
}

function requireNonAuthStatus(response, description) {
  return check(response, {
    [`${description} returned a non-auth response`]: (res) => res.status !== 401,
  });
}

function assertTrustedProxyHeaders(response, device, description) {
  const proxiedDeviceId = response.headers?.["X-Perf-Device-Id"]?.[0];
  const proxiedIp = response.headers?.["X-Perf-Client-Ip"]?.[0];

  return check(response, {
    [`${description} preserved device identity via proxy`]: () => proxiedDeviceId === device.device_id,
    [`${description} used synthetic 10.250/16 client IP`]: () =>
      typeof proxiedIp === "string" &&
      proxiedIp.startsWith(`${config.deviceIpPrefix}.`) &&
      proxiedIp === device.synthetic_ip,
  });
}

function postSingleScan(baseUrl, scan, scenarioName, suite, device, extraHeaders = {}) {
  const response = postScans(baseUrl, [scan], { scenario: scenarioName, suite }, device, extraHeaders);
  const payload = recordResponse(response, {
    deviceIndex: device.device_index,
    requestType: "scan",
    suite,
  });

  requireNonAuthStatus(response, scenarioName);

  return { payload, response };
}

function primeDuplicateDatasets(baseUrl, setupData) {
  for (let index = 0; index < config.controls.replay_prime_count; index += 1) {
    const device = indexedDevice(setupData, index);
    postSingleScan(baseUrl, buildReplayPrimeScan(index), "setup_prime_replay", "capacity", device);
  }

  for (let index = 0; index < config.controls.business_prime_count; index += 1) {
    const device = indexedDevice(setupData, index + config.controls.replay_prime_count);
    postSingleScan(
      baseUrl,
      buildBusinessPrimeScan(index),
      "setup_prime_business_duplicate",
      "capacity",
      device
    );
  }
}

function mixedOnlineRequest(sliceName, scenarioName, setupData) {
  const iteration = exec.scenario.iterationInTest;
  const bucket = iteration % 20;
  const device = currentCapacityDevice(setupData);

  if (bucket === 0) {
    postSingleScan(
      config.baseUrl,
      buildInvalidScan(iteration),
      `${scenarioName}_invalid`,
      "capacity",
      device
    );
    return;
  }

  if (bucket === 1) {
    postSingleScan(
      config.baseUrl,
      buildReplayDuplicateScan(iteration),
      `${scenarioName}_replay_duplicate`,
      "capacity",
      device
    );
    return;
  }

  if (bucket === 2) {
    postSingleScan(
      config.baseUrl,
      buildBusinessDuplicateScan(iteration),
      `${scenarioName}_business_duplicate`,
      "capacity",
      device
    );
    return;
  }

  postSingleScan(
    config.baseUrl,
    buildSuccessScan(sliceName, iteration, scenarioName),
    `${scenarioName}_success`,
    "capacity",
    device
  );
}

export function setup() {
  resetAuthState();

  if (!config.requiresDeviceBootstrap) {
    return { devices: [] };
  }

  const devices = bootstrapDevicePool(config.baseUrl);
  const setupData = { devices };
  const shouldPrime = config.selectedScenarios.some((name) =>
    ["capacity_baseline", "capacity_stress", "capacity_spike"].includes(name)
  );

  if (shouldPrime) {
    primeDuplicateDatasets(config.baseUrl, setupData);
  }

  return setupData;
}

export function capacitySmoke(setupData) {
  const device = currentCapacityDevice(setupData);

  if (config.enableAttendeeSyncSmoke) {
    const attendeeResponse = getAttendees(config.baseUrl, device);
    recordResponse(attendeeResponse, { requestType: "attendees", suite: "capacity" });

    check(attendeeResponse, {
      "capacity attendee sync returned 200": (res) => res.status === 200,
    });
  }

  const trustedHeaders = {
    "X-Forwarded-For": "198.51.100.77",
  };

  const validResponse = postSingleScan(
    config.baseUrl,
    buildSuccessScan("soak", 0, "capacity_smoke"),
    "capacity_smoke_valid",
    "capacity",
    device,
    trustedHeaders
  );

  assertTrustedProxyHeaders(validResponse.response, device, "capacity smoke");

  check(validResponse.payload, {
    "capacity smoke valid scan succeeded": (payload) =>
      payload?.data?.results?.[0]?.status === "success",
  });

  postSingleScan(
    config.baseUrl,
    buildReplayPrimeScan(0),
    "capacity_smoke_replay_prime",
    "capacity",
    device
  );

  const replayResponse = postSingleScan(
    config.baseUrl,
    buildReplayDuplicateScan(0),
    "capacity_smoke_replay_duplicate",
    "capacity",
    device
  );

  check(replayResponse.payload, {
    "capacity smoke replay duplicate returned duplicate": (payload) =>
      payload?.data?.results?.[0]?.status === "duplicate",
  });

  postSingleScan(
    config.baseUrl,
    buildBusinessPrimeScan(0),
    "capacity_smoke_business_prime",
    "capacity",
    device
  );

  const businessResponse = postSingleScan(
    config.baseUrl,
    buildBusinessDuplicateScan(0),
    "capacity_smoke_business_duplicate",
    "capacity",
    device
  );

  check(businessResponse.payload, {
    "capacity smoke business duplicate returned already checked in": (payload) =>
      (payload?.data?.results?.[0]?.message || "").includes("Already checked in"),
  });

  const invalidResponse = postSingleScan(
    config.baseUrl,
    buildInvalidScan(0),
    "capacity_smoke_invalid",
    "capacity",
    device
  );

  check(invalidResponse.payload, {
    "capacity smoke invalid ticket returned ticket not found": (payload) =>
      (payload?.data?.results?.[0]?.message || "").includes("Ticket not found"),
  });
}

export function capacityBaseline(setupData) {
  mixedOnlineRequest("baseline_valid", "capacity_baseline", setupData);
}

export function capacityStress(setupData) {
  mixedOnlineRequest("baseline_valid", "capacity_stress", setupData);
}

export function capacitySpike(setupData) {
  const device = currentCapacityDevice(setupData);
  const response = postScans(
    config.baseUrl,
    buildOfflineBurstBatch(exec.scenario.iterationInTest),
    { scenario: "capacity_spike_batch", suite: "capacity" },
    device
  );

  recordResponse(response, {
    deviceIndex: device.device_index,
    requestType: "scan",
    suite: "capacity",
  });

  requireNonAuthStatus(response, "capacity_spike");
}

export function capacitySoak(setupData) {
  mixedOnlineRequest("soak", "capacity_soak", setupData);
}

export function abuseLogin() {
  const response = rawLogin(config.baseUrl, deviceIdFromIndex(0));

  check(response, {
    "abuse login returned a throttled or handled response": (res) => [200, 401, 403, 429].includes(res.status),
  });
}

export function abuseScansSingleDevice(setupData) {
  const device = hotDevice(setupData);
  const response = postSingleScan(
    config.baseUrl,
    buildSuccessScan("baseline_valid", exec.scenario.iterationInTest, "abuse_single_device"),
    "abuse_scans_single_device",
    "abuse",
    device
  );

  check(response.response, {
    "abuse scan returned a handled response": (res) => [200, 429, 401].includes(res.status),
  });
}

export function enqueueFailure(setupData) {
  const device = hotDevice(setupData);
  const recoveryScan = buildRecoveryScan();
  const failureResponse = postSingleScan(
    config.baseUrl,
    recoveryScan,
    "enqueue_failure",
    "diagnostic",
    device
  );

  check(failureResponse.response, {
    "enqueue failure returned retryable status": (res) => res.status >= 500 || res.status === 503,
  });

  if (config.recoveryBaseUrl) {
    const recoverySuccess = postSingleScan(
      config.recoveryBaseUrl,
      recoveryScan,
      "enqueue_failure_recovery_success",
      "diagnostic",
      device
    );

    check(recoverySuccess.payload, {
      "recovery replay succeeded": (payload) => payload?.data?.results?.[0]?.status === "success",
    });

    const recoveryDuplicate = postSingleScan(
      config.recoveryBaseUrl,
      recoveryScan,
      "enqueue_failure_recovery_duplicate",
      "diagnostic",
      device
    );

    check(recoveryDuplicate.payload, {
      "recovery duplicate returned duplicate": (payload) =>
        payload?.data?.results?.[0]?.status === "duplicate",
    });
  }
}

export function legacySmoke(setupData) {
  const device = hotDevice(setupData);
  const response = postSingleScan(
    config.baseUrl,
    buildSuccessScan("baseline_valid", 1, "legacy_smoke"),
    "legacy_smoke",
    "diagnostic",
    device
  );

  check(response.payload, {
    "legacy smoke request returned a result": (payload) => Array.isArray(payload?.data?.results),
  });
}

export function handleSummary(data) {
  return buildSummary(data);
}
