import encoding from "k6/encoding";
import http from "k6/http";
import { Counter } from "k6/metrics";

import { config } from "./config.js";

export const authFailures = new Counter("auth_failures");
export const authBootstrapLogins = new Counter("auth_bootstrap_logins");
export const authRefreshes = new Counter("auth_refreshes");
export const loginBlockedResponses = new Counter("login_response_blocked");

const deviceSessions = new Map();

function decodeJwtPayload(token) {
  const segments = String(token || "").split(".");

  if (segments.length < 2) {
    return {};
  }

  try {
    const decoded = encoding.b64decode(segments[1], "rawurl", "s");
    return JSON.parse(decoded);
  } catch (_error) {
    return {};
  }
}

function buildMetricTags(authContext = {}, reason = "bootstrap") {
  return {
    auth_reason: reason,
    canonical_scenario: authContext.canonical_scenario || "setup",
    family: authContext.family || "setup",
    network_profile: authContext.network_profile || "normal",
    request_type: "login",
    scenario_key: authContext.scenario_key || "setup",
    suite: authContext.suite || "setup",
  };
}

function computeRefreshAt(expiresAt, now = Date.now()) {
  const ttlMs = Math.max(expiresAt - now, 1_000);
  const maxLeadMs = Math.min(300_000, Math.max(30_000, Math.floor(ttlMs * 0.05)));
  const minLeadMs = Math.max(5_000, Math.floor(maxLeadMs / 2));
  const jitterWindowMs = Math.max(maxLeadMs - minLeadMs, 1_000);
  const refreshLeadMs = minLeadMs + Math.floor(Math.random() * jitterWindowMs);

  return expiresAt - refreshLeadMs;
}

function buildHeaders(deviceId, extraHeaders = {}) {
  return {
    "Content-Type": "application/json",
    ...extraHeaders,
    [config.deviceHeader]: deviceId,
  };
}

function effectiveRefreshExpiry(expiresAt, authContext = {}, now = Date.now()) {
  if (authContext.canonical_scenario !== "perf_auth_churn") {
    return expiresAt;
  }

  const clientTtlMs = Math.max(config.thresholdPackageConfig.authChurn.clientTtlSeconds, 1) * 1000;
  return Math.min(expiresAt, now + clientTtlMs);
}

function applySession(deviceBootstrap, token, expiresInSeconds, authContext = {}) {
  const now = Date.now();
  const expiresAt = now + Math.max(Number(expiresInSeconds || 0), 1) * 1000;
  const claims = decodeJwtPayload(token);

  const session = {
    device_id: deviceBootstrap.device_id,
    device_index: deviceBootstrap.device_index,
    expires_at: expiresAt,
    jti: claims.jti || deviceBootstrap.jti || null,
    refresh_at: computeRefreshAt(effectiveRefreshExpiry(expiresAt, authContext, now), now),
    synthetic_ip: deviceBootstrap.synthetic_ip || null,
    token,
  };

  deviceSessions.set(deviceBootstrap.device_id, session);

  return session;
}

function importBootstrapSession(deviceBootstrap) {
  if (!deviceBootstrap?.device_id || deviceSessions.has(deviceBootstrap.device_id)) {
    return;
  }

  const session = {
    device_id: deviceBootstrap.device_id,
    device_index: deviceBootstrap.device_index,
    expires_at: deviceBootstrap.expires_at,
    jti: deviceBootstrap.jti || null,
    refresh_at: computeRefreshAt(deviceBootstrap.expires_at),
    synthetic_ip: deviceBootstrap.synthetic_ip || null,
    token: deviceBootstrap.token,
  };

  deviceSessions.set(deviceBootstrap.device_id, session);
}

function maybeTightenRefreshWindow(session, authContext = {}) {
  if (authContext.canonical_scenario !== "perf_auth_churn") {
    return session;
  }

  const now = Date.now();
  const desiredRefreshAt = computeRefreshAt(effectiveRefreshExpiry(session.expires_at, authContext, now), now);

  if (desiredRefreshAt < session.refresh_at) {
    session.refresh_at = desiredRefreshAt;
    deviceSessions.set(session.device_id, session);
  }

  return session;
}

function loginDevice(baseUrl, deviceBootstrap, reason = "bootstrap", authContext = {}) {
  const metricTags = buildMetricTags(authContext, reason);

  if (reason === "bootstrap") {
    authBootstrapLogins.add(1, metricTags);
  } else {
    authRefreshes.add(1, metricTags);
  }

  const response = http.post(
    `${baseUrl}/api/v1/mobile/login`,
    JSON.stringify({
      credential: config.credential,
      event_id: config.eventId,
    }),
    {
      headers: buildHeaders(deviceBootstrap.device_id),
      tags: {
        canonical_scenario: authContext.canonical_scenario || "setup",
        endpoint: "mobile_login",
        family: authContext.family || "setup",
        network_profile: authContext.network_profile || "normal",
        reason,
        request_type: "login",
        scenario_key: authContext.scenario_key || "setup",
        suite: authContext.suite || "setup",
      },
    }
  );

  if (response.status === 429) {
    loginBlockedResponses.add(1, metricTags);
  }

  if (response.status !== 200) {
    authFailures.add(1, metricTags);
    return { response, session: null };
  }

  const payload = response.json();
  const token = payload?.data?.token;
  const expiresIn = Number(payload?.data?.expires_in || 3600);

  if (!token) {
    authFailures.add(1, metricTags);
    return { response, session: null };
  }

  const syntheticIp = response.headers?.["X-Perf-Client-Ip"]?.[0] || deviceBootstrap.synthetic_ip;
  const session = applySession({ ...deviceBootstrap, synthetic_ip: syntheticIp }, token, expiresIn, authContext);

  return { response, session };
}

function ensureDeviceSession(baseUrl, deviceBootstrap, authContext = {}) {
  importBootstrapSession(deviceBootstrap);

  const current = maybeTightenRefreshWindow(
    deviceSessions.get(deviceBootstrap.device_id) || null,
    authContext
  );

  if (!current?.token) {
    const { session } = loginDevice(baseUrl, deviceBootstrap, "bootstrap", authContext);
    return session;
  }

  if (Date.now() < current.refresh_at) {
    return current;
  }

  const previous = { ...current };
  const { session } = loginDevice(baseUrl, deviceBootstrap, "refresh", authContext);

  if (!session && previous.token && Date.now() < previous.expires_at) {
    deviceSessions.set(deviceBootstrap.device_id, previous);
    return previous;
  }

  return session;
}

export function forceRefreshDevice(deviceBootstrap) {
  const current = deviceSessions.get(deviceBootstrap.device_id);

  if (!current) {
    return;
  }

  current.refresh_at = 0;
  deviceSessions.set(deviceBootstrap.device_id, current);
}

export function resetAuthState() {
  deviceSessions.clear();
}

export function buildDevicePool() {
  return Array.from({ length: config.deviceCount }, (_unused, index) => ({
    device_id: `device-${String(index + 1).padStart(4, "0")}`,
    device_index: index,
    expires_at: 0,
    jti: null,
    synthetic_ip: null,
    token: null,
  }));
}

export function bootstrapDevicePool(baseUrl) {
  resetAuthState();

  return buildDevicePool().map((deviceBootstrap) => {
    const { response, session } = loginDevice(baseUrl, deviceBootstrap, "bootstrap");

    if (response.status !== 200 || !session?.token) {
      throw new Error(
        `Unable to bootstrap auth session for ${deviceBootstrap.device_id}: HTTP ${response.status}`
      );
    }

    return session;
  });
}

export function rawLogin(baseUrl, deviceId, authContext = {}) {
  const deviceBootstrap = {
    device_id: deviceId,
    device_index: 0,
    expires_at: 0,
    jti: null,
    synthetic_ip: null,
    token: null,
  };

  return loginDevice(baseUrl, deviceBootstrap, "bootstrap", authContext).response;
}

export function requestWithDeviceAuth(
  method,
  baseUrl,
  path,
  payload = null,
  params = {},
  deviceBootstrap
) {
  const authContext = params.tags || {};
  const session = ensureDeviceSession(baseUrl, deviceBootstrap, authContext);

  if (!session?.token) {
    throw new Error(`No auth session available for ${deviceBootstrap.device_id}`);
  }

  const requestParams = {
    ...params,
    headers: {
      Authorization: `Bearer ${session.token}`,
      ...buildHeaders(deviceBootstrap.device_id, params.headers || {}),
    },
  };

  let response = http.request(
    method,
    `${baseUrl}${path}`,
    payload ? JSON.stringify(payload) : null,
    requestParams
  );

  if (response.status === 401) {
    const refreshed = loginDevice(baseUrl, deviceBootstrap, "refresh", authContext).session;

    if (!refreshed?.token) {
      authFailures.add(1, buildMetricTags(authContext, "refresh"));
      return response;
    }

    response = http.request(
      method,
      `${baseUrl}${path}`,
      payload ? JSON.stringify(payload) : null,
      {
        ...requestParams,
        headers: {
          ...requestParams.headers,
          Authorization: `Bearer ${refreshed.token}`,
        },
      }
    );

    if (response.status === 401) {
      authFailures.add(1, buildMetricTags(authContext, "refresh"));
    }
  }

  return response;
}

export function getAttendees(baseUrl, deviceBootstrap, requestTags = {}) {
  return requestWithDeviceAuth(
    "GET",
    baseUrl,
    "/api/v1/mobile/attendees",
    null,
    {
      tags: { endpoint: "mobile_attendees", ...requestTags },
    },
    deviceBootstrap
  );
}

export function postScans(baseUrl, scans, requestTags = {}, deviceBootstrap, extraHeaders = {}) {
  return requestWithDeviceAuth(
    "POST",
    baseUrl,
    "/api/v1/mobile/scans",
    { scans },
    {
      headers: extraHeaders,
      tags: { endpoint: "mobile_scans", ...requestTags },
    },
    deviceBootstrap
  );
}
