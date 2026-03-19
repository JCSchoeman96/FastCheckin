export function deviceIdFromIndex(index) {
  return `device-${String(index + 1).padStart(4, "0")}`;
}

export function deviceMetricSuffix(index) {
  return String(index + 1).padStart(4, "0");
}
