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

export function responseHeaderValue(response, headerName) {
  const headers = response?.headers;

  if (!headers || !headerName) {
    return null;
  }

  const directMatch = headers[headerName] ?? headers[String(headerName).toLowerCase()];
  let rawValue = directMatch;

  if (rawValue === undefined) {
    const matchedKey = Object.keys(headers).find(
      (key) => String(key).toLowerCase() === String(headerName).toLowerCase()
    );

    rawValue = matchedKey ? headers[matchedKey] : null;
  }

  if (Array.isArray(rawValue)) {
    return rawValue.length > 0 ? rawValue[0] : null;
  }

  if (typeof rawValue === "string") {
    return rawValue;
  }

  return rawValue === undefined || rawValue === null ? null : String(rawValue);
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

function applySession(deviceBootstrap, token, expiresInSeconds) {
  const now = Date.now();
  const expiresAt = now + Math.max(Number(expiresInSeconds || 0), 1) * 1000;
  const claims = decodeJwtPayload(token);

  const session = {
    device_id: deviceBootstrap.device_id,
    device_index: deviceBootstrap.device_index,
    expires_at: expiresAt,
    jti: claims.jti || deviceBootstrap.jti || null,
    refresh_at: computeRefreshAt(expiresAt, now),
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

function poisonBearerToken(token) {
  return `poisoned-${String(token || "token")}`;
}

function initialAuthorizationToken(session, authOptions = {}) {
  if (authOptions.poisonToken) {
    return poisonBearerToken(session.token);
  }

  return session.token;
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

  const syntheticIp =
    responseHeaderValue(response, "X-Perf-Client-Ip") || deviceBootstrap.synthetic_ip;
  const session = applySession({ ...deviceBootstrap, synthetic_ip: syntheticIp }, token, expiresIn);

  return { response, session };
}

function ensureDeviceSession(baseUrl, deviceBootstrap, authContext = {}) {
  importBootstrapSession(deviceBootstrap);

  const current = deviceSessions.get(deviceBootstrap.device_id) || null;

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
  const authOptions = params.auth || {};
  const session = ensureDeviceSession(baseUrl, deviceBootstrap, authContext);

  if (!session?.token) {
    throw new Error(`No auth session available for ${deviceBootstrap.device_id}`);
  }

  const requestParams = {
    ...params,
    headers: {
      Authorization: `Bearer ${initialAuthorizationToken(session, authOptions)}`,
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

export function getAttendees(baseUrl, deviceBootstrap, requestTags = {}, requestOptions = {}) {
  return requestWithDeviceAuth(
    "GET",
    baseUrl,
    "/api/v1/mobile/attendees",
    null,
    {
      ...requestOptions,
      tags: { endpoint: "mobile_attendees", ...requestTags },
    },
    deviceBootstrap
  );
}

export function postScans(
  baseUrl,
  scans,
  requestTags = {},
  deviceBootstrap,
  extraHeaders = {},
  requestOptions = {}
) {
  return requestWithDeviceAuth(
    "POST",
    baseUrl,
    "/api/v1/mobile/scans",
    { scans },
    {
      ...requestOptions,
      headers: extraHeaders,
      tags: { endpoint: "mobile_scans", ...requestTags },
    },
    deviceBootstrap
  );
}
