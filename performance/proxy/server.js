const http = require("http");

const port = Number.parseInt(process.env.PORT || "4100", 10);
const targetBaseUrl = new URL(process.env.TARGET_BASE_URL || "http://app-perf:4000");
const deviceHeaderName = (process.env.PERF_DEVICE_HEADER || "x-perf-device-id").toLowerCase();
const ipPrefix = process.env.PERF_DEVICE_IP_PREFIX || "10.250";
const deviceMap = new Map();

function hashString(value) {
  let hash = 0;

  for (let index = 0; index < value.length; index += 1) {
    hash = (hash * 31 + value.charCodeAt(index)) >>> 0;
  }

  return hash >>> 0;
}

function deterministicIpForDevice(deviceId) {
  if (!deviceMap.has(deviceId)) {
    const index = hashString(deviceId) % (256 * 254);
    const octet3 = Math.floor(index / 254);
    const octet4 = (index % 254) + 1;
    const ip = `${ipPrefix}.${octet3}.${octet4}`;

    deviceMap.set(deviceId, ip);
    console.log(`[perf-proxy] mapped ${deviceId} -> ${ip}`);
  }

  return deviceMap.get(deviceId);
}

function proxyRequest(req, res) {
  const deviceId = String(req.headers[deviceHeaderName] || "direct-unknown");
  const syntheticIp = deterministicIpForDevice(deviceId);
  const headers = { ...req.headers };

  delete headers.host;
  delete headers["x-forwarded-for"];
  delete headers["x-real-ip"];

  headers["x-forwarded-for"] = syntheticIp;
  headers["x-real-ip"] = syntheticIp;
  headers["x-forwarded-proto"] = "http";
  headers["x-forwarded-host"] = req.headers.host || `127.0.0.1:${port}`;

  const proxyReq = http.request(
    {
      protocol: targetBaseUrl.protocol,
      hostname: targetBaseUrl.hostname,
      port: targetBaseUrl.port,
      method: req.method,
      path: req.url,
      headers,
    },
    (proxyRes) => {
      res.writeHead(proxyRes.statusCode || 502, {
        ...proxyRes.headers,
        "x-perf-client-ip": syntheticIp,
        "x-perf-device-id": deviceId,
      });

      proxyRes.pipe(res);
    }
  );

  proxyReq.on("error", (error) => {
    console.error(`[perf-proxy] request failed for ${deviceId}: ${error.message}`);

    res.writeHead(502, { "content-type": "application/json" });
    res.end(
      JSON.stringify({
        error: "perf_proxy_error",
        message: error.message,
      })
    );
  });

  req.pipe(proxyReq);
}

http
  .createServer((req, res) => {
    proxyRequest(req, res);
  })
  .listen(port, "0.0.0.0", () => {
    console.log(
      `[perf-proxy] listening on 0.0.0.0:${port}, forwarding to ${targetBaseUrl.toString()} using ${deviceHeaderName}`
    );
  });
