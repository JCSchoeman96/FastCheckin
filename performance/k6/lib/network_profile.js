const PROFILES = {
  jitter: {
    description: "Transport jitter injected outside k6",
    name: "jitter",
  },
  latency: {
    description: "Fixed transport latency injected outside k6",
    name: "latency",
  },
  loss_recovery: {
    description: "Loss or recovery injected outside k6",
    name: "loss_recovery",
  },
  normal: {
    description: "No external degradation layer selected",
    name: "normal",
  },
};

export function resolveNetworkProfile(defaultProfile = "normal") {
  const requested = String(__ENV.NETWORK_PROFILE || defaultProfile || "normal").trim();

  if (!PROFILES[requested]) {
    throw new Error(
      `Unknown network profile: ${requested}. Expected one of ${Object.keys(PROFILES).join(", ")}`
    );
  }

  return PROFILES[requested];
}
