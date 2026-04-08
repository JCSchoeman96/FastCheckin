import exec from "k6/execution";
import { check } from "k6";

import {
  bootstrapDevicePool,
  forceRefreshDevice,
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
import { resolveScenarioOperation } from "./lib/scenario_mix.js";
import { buildSummary } from "./lib/summary.js";

export const options = buildOptions();

function currentScenarioContext() {
  const scenarioKey = exec.scenario.name;
  const metadata = config.scenarioMetadata[scenarioKey];

  if (!metadata) {
    throw new Error(`Missing scenario metadata for ${scenarioKey}`);
  }

  return {
    canonical_scenario: metadata.canonicalScenario,
    family: metadata.family,
    network_profile: metadata.networkProfile,
    request_type: metadata.requestType,
    scenario_key: scenarioKey,
    slice: metadata.slice,
    suite: metadata.suite,
  };
}

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

function requestTags(context, overrides = {}) {
  return {
    canonical_scenario: context.canonical_scenario,
    family: context.family,
    network_profile: context.network_profile,
    request_type: overrides.request_type || context.request_type,
    scenario_key: context.scenario_key,
    slice: overrides.slice || context.slice,
    suite: context.suite,
  };
}

function recordContext(context, device, requestType) {
  return {
    canonicalScenario: context.canonical_scenario,
    deviceIndex: device?.device_index,
    family: context.family,
    networkProfile: context.network_profile,
    requestType,
    scenarioKey: context.scenario_key,
    suite: context.suite,
  };
}

function postSingleScan(baseUrl, scan, context, device, extraHeaders = {}) {
  const response = postScans(
    baseUrl,
    [scan],
    requestTags(context, { request_type: "scan" }),
    device,
    extraHeaders
  );
  const payload = recordResponse(response, recordContext(context, device, "scan"));

  requireNonAuthStatus(response, context.scenario_key);

  return { payload, response };
}

function requestAttendees(baseUrl, context, device) {
  const response = getAttendees(baseUrl, device, requestTags(context, { request_type: "attendees" }));
  recordResponse(response, recordContext(context, device, "attendees"));
  requireNonAuthStatus(response, context.scenario_key);

  return response;
}

function primeDuplicateDatasets(baseUrl, setupData) {
  for (let index = 0; index < config.controls.replay_prime_count; index += 1) {
    const device = indexedDevice(setupData, index);
    const response = postScans(baseUrl, [buildReplayPrimeScan(index)], { scenario_key: "setup_prime" }, device);
    requireNonAuthStatus(response, "setup_prime_replay");
  }

  for (let index = 0; index < config.controls.business_prime_count; index += 1) {
    const device = indexedDevice(setupData, index + config.controls.replay_prime_count);
    const response = postScans(
      baseUrl,
      [buildBusinessPrimeScan(index)],
      { scenario_key: "setup_prime" },
      device
    );
    requireNonAuthStatus(response, "setup_prime_business_duplicate");
  }
}

function buildOperationScan(context, iteration, operation) {
  switch (operation.kind) {
    case "replay_duplicate":
      return buildReplayDuplicateScan(iteration);
    case "business_duplicate":
      return buildBusinessDuplicateScan(iteration);
    case "invalid":
      return buildInvalidScan(iteration);
    default:
      return buildSuccessScan(context.slice, iteration, context.scenario_key);
  }
}

function runProfiledScenario(setupData) {
  const context = currentScenarioContext();
  const device = currentCapacityDevice(setupData);
  const iteration = exec.scenario.iterationInTest;
  const operation = resolveScenarioOperation(context.canonical_scenario, iteration);

  if (operation.forceRefresh) {
    forceRefreshDevice(device);
  }

  if (operation.kind === "attendee_sync") {
    requestAttendees(config.baseUrl, context, device);
    return;
  }

  postSingleScan(config.baseUrl, buildOperationScan(context, iteration, operation), context, device);
}

export function setup() {
  resetAuthState();

  if (!config.requiresDeviceBootstrap) {
    return { devices: [] };
  }

  const devices = bootstrapDevicePool(config.baseUrl);
  const setupData = { devices };

  if (config.shouldPrimeDuplicateDatasets) {
    primeDuplicateDatasets(config.baseUrl, setupData);
  }

  return setupData;
}

export function perfFreshSteady(setupData) {
  runProfiledScenario(setupData);
}

export function perfDuplicateHeavy(setupData) {
  runProfiledScenario(setupData);
}

export function perfAuthChurn(setupData) {
  runProfiledScenario(setupData);
}

export function perfSyncScanMixedScan(setupData) {
  runProfiledScenario(setupData);
}

export function perfSyncScanMixedAttendees(setupData) {
  const context = currentScenarioContext();
  const device = currentCapacityDevice(setupData);
  requestAttendees(config.baseUrl, context, device);
}

export function perfSpikeBatch(setupData) {
  const context = currentScenarioContext();
  const device = currentCapacityDevice(setupData);
  const response = postScans(
    config.baseUrl,
    buildOfflineBurstBatch(exec.scenario.iterationInTest),
    requestTags(context, { request_type: "scan" }),
    device
  );

  recordResponse(response, recordContext(context, device, "scan"));
  requireNonAuthStatus(response, context.scenario_key);
}

export function perfSoakEndurance(setupData) {
  runProfiledScenario(setupData);
}

export function abuseLogin() {
  const context = currentScenarioContext();
  const response = rawLogin(config.baseUrl, deviceIdFromIndex(0), requestTags(context, { request_type: "login" }));

  check(response, {
    "abuse login returned a throttled or handled response": (res) => [200, 401, 403, 429].includes(res.status),
  });
}

export function abuseScansSingleDevice(setupData) {
  const context = currentScenarioContext();
  const device = hotDevice(setupData);
  const response = postSingleScan(
    config.baseUrl,
    buildSuccessScan(context.slice, exec.scenario.iterationInTest, context.scenario_key),
    context,
    device
  );

  check(response.response, {
    "abuse scan returned a handled response": (res) => [200, 429, 401].includes(res.status),
  });
}

export function diagnosticEnqueueFailure(setupData) {
  const context = currentScenarioContext();
  const device = hotDevice(setupData);
  const recoveryScan = buildRecoveryScan();
  const failureResponse = postSingleScan(config.baseUrl, recoveryScan, context, device);

  check(failureResponse.response, {
    "enqueue failure returned retryable status": (res) => res.status >= 500 || res.status === 503,
  });

  if (config.recoveryBaseUrl) {
    const recoverySuccess = postSingleScan(config.recoveryBaseUrl, recoveryScan, context, device);

    check(recoverySuccess.payload, {
      "recovery replay succeeded": (payload) => payload?.data?.results?.[0]?.status === "success",
    });

    const recoveryDuplicate = postSingleScan(config.recoveryBaseUrl, recoveryScan, context, device);

    check(recoveryDuplicate.payload, {
      "recovery duplicate returned duplicate": (payload) =>
        payload?.data?.results?.[0]?.status === "duplicate",
    });
  }
}

export function diagnosticLegacySmoke(setupData) {
  const context = currentScenarioContext();
  const device = hotDevice(setupData);
  const response = postSingleScan(
    config.baseUrl,
    buildSuccessScan(context.slice, 1, context.scenario_key),
    context,
    device
  );

  check(response.payload, {
    "legacy smoke request returned a result": (payload) => Array.isArray(payload?.data?.results),
  });
}

export function handleSummary(data) {
  return buildSummary(data);
}
