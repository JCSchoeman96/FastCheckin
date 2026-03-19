import { config } from "./config.js";

function ticketCode(index) {
  return `${config.ticketPrefix}-${String(index).padStart(config.ticketWidth, "0")}`;
}

function sliceBounds(sliceName) {
  const slice = config.slices[sliceName];

  if (!slice) {
    throw new Error(`Unknown slice: ${sliceName}`);
  }

  return slice;
}

function ticketFromSlice(sliceName, iteration, reserveCount = 0) {
  const slice = sliceBounds(sliceName);
  const startIndex = slice.start_index + reserveCount;
  const usableCount = slice.end_index - startIndex + 1;

  if (usableCount <= 0) {
    throw new Error(`Slice ${sliceName} has no usable tickets after reserves`);
  }

  return ticketCode(startIndex + (iteration % usableCount));
}

function buildScan(ticketCodeValue, idempotencyKey, entranceName = "Main Gate") {
  return {
    direction: "in",
    entrance_name: entranceName,
    idempotency_key: idempotencyKey,
    operator_name: "k6-perf",
    scanned_at: new Date().toISOString(),
    ticket_code: ticketCodeValue,
  };
}

export function buildSuccessScan(sliceName, iteration, tag = "success") {
  const reserveCount = sliceName === "baseline_valid" ? config.replay.reserve_count : 0;
  const ticketCodeValue = ticketFromSlice(sliceName, iteration, reserveCount);

  return buildScan(
    ticketCodeValue,
    `${tag}-${config.eventId}-${iteration}-${ticketCodeValue}`
  );
}

export function buildReplayPrimeScan(iteration) {
  const index = iteration % config.controls.replay_prime_count;
  const ticketCodeValue = ticketFromSlice("baseline_valid", index, 0);
  const idempotencyKey = `${config.replay.seed}-${ticketCodeValue}`;

  return buildScan(ticketCodeValue, idempotencyKey);
}

export function buildReplayDuplicateScan(iteration) {
  return buildReplayPrimeScan(iteration);
}

export function buildBusinessPrimeScan(iteration) {
  const index = iteration % config.controls.business_prime_count;
  const ticketCodeValue = ticketFromSlice("business_duplicate", index, 0);

  return buildScan(
    ticketCodeValue,
    `prime-business-${config.eventId}-${ticketCodeValue}`
  );
}

export function buildBusinessDuplicateScan(iteration) {
  const index = iteration % config.controls.business_prime_count;
  const ticketCodeValue = ticketFromSlice("business_duplicate", index, 0);

  return buildScan(
    ticketCodeValue,
    `business-duplicate-${config.eventId}-${iteration}-${ticketCodeValue}`
  );
}

export function buildInvalidScan(iteration) {
  return buildScan(
    `${config.invalidPrefix}-${String(iteration).padStart(config.ticketWidth, "0")}`,
    `invalid-${config.eventId}-${iteration}`
  );
}

export function buildOfflineBurstBatch(iteration) {
  const slice = sliceBounds("offline_burst");
  const count = slice.end_index - slice.start_index + 1;
  const offset = (iteration * config.scanBatchSize) % count;

  return Array.from({ length: config.scanBatchSize }, (_unused, batchIndex) => {
    const ticketIndex = slice.start_index + ((offset + batchIndex) % count);
    const ticketCodeValue = ticketCode(ticketIndex);

    return buildScan(
      ticketCodeValue,
      `offline-${config.eventId}-${iteration}-${batchIndex}-${ticketCodeValue}`
    );
  });
}

export function buildRecoveryScan() {
  const recovery = config.controls.recovery_ticket;

  if (!recovery) {
    return buildSuccessScan("soak", 0, "recovery");
  }

  return buildScan(recovery.ticket_code, recovery.idempotency_key);
}
