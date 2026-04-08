import { config } from "./config.js";

function normalizeOperation(operation) {
  return { kind: operation };
}

function operationEntries(profile) {
  return Object.entries(profile)
    .filter(([_operation, weight]) => Number(weight) > 0)
    .sort(([left], [right]) => left.localeCompare(right));
}

export function resolveScenarioOperation(canonicalScenario, iteration) {
  const profile = config.mixProfiles[canonicalScenario] || config.mixProfiles.perf_fresh_steady;
  const entries = operationEntries(profile);
  const totalWeight = entries.reduce((sum, [_operation, weight]) => sum + Number(weight), 0);

  if (totalWeight <= 0) {
    return { kind: "success" };
  }

  let cursor = iteration % totalWeight;

  for (const [operation, weight] of entries) {
    cursor -= Number(weight);

    if (cursor < 0) {
      return normalizeOperation(operation);
    }
  }

  return { kind: "success" };
}
