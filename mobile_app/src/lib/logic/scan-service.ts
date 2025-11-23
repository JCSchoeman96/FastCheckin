import {
  db,
  hasRecentReplay,
  markReplay,
  pruneReplayCache,
  deriveScanSlot,
  buildIdempotencyKey,
  getNextDeviceClock
} from '$lib/db';
import { REPLAY_CACHE_WINDOW_MS } from '$lib/config';
import { validateScan } from './validation';
import type { Attendee, ScanDirection, ScanErrorCode } from '$lib/types';
import type { ScanMetadata } from '$lib/stores/scan-settings';
import { DEFAULT_SCAN_METADATA } from '$lib/stores/scan-settings';

export interface ScanResult {
  success: boolean;
  message: string;
  attendee?: Attendee;
  error_code?: ScanErrorCode;
}

export interface NotificationIntent {
  type: 'success' | 'error';
  message: string;
}

export interface ScanServiceOutcome extends ScanResult {
  notifications: NotificationIntent[];
  syncRequested: boolean;
}

export interface ScanServiceDeps {
  notifier?: { success: (message: string) => void; error: (message: string) => void };
  triggerSync?: () => Promise<void>;
  defaults?: ScanMetadata;
}

export interface ProcessScanOptions {
  metadata?: ScanMetadata;
}

export function createScanService({
  notifier,
  triggerSync,
  defaults = DEFAULT_SCAN_METADATA
}: ScanServiceDeps = {}) {
  async function processScan(
    ticketCode: string,
    direction: ScanDirection,
    eventId: number,
    options?: ProcessScanOptions
  ): Promise<ScanServiceOutcome> {
    const notifications: NotificationIntent[] = [];
    const metadata = options?.metadata ?? defaults;

    const attendee = await db.attendees
      .where('[event_id+ticket_code]')
      .equals([eventId, ticketCode])
      .first();

    if (!attendee) {
      const message = 'Ticket not found';
      notifications.push({ type: 'error', message });
      return {
        success: false,
        message,
        error_code: 'INVALID_TICKET',
        notifications,
        syncRequested: false
      };
    }

    const validation = validateScan(attendee, direction);
    if (!validation.valid) {
      const message = validation.message;
      notifications.push({ type: 'error', message });
      return {
        success: false,
        message,
        attendee,
        error_code: validation.errorCode,
        notifications,
        syncRequested: false
      };
    }

    await pruneReplayCache(REPLAY_CACHE_WINDOW_MS);

    const isReplay = await hasRecentReplay(eventId, ticketCode, direction, REPLAY_CACHE_WINDOW_MS);
    if (isReplay) {
      const message = 'Duplicate scan';
      notifications.push({ type: 'error', message });
      return {
        success: false,
        message,
        attendee,
        error_code: 'DUPLICATE_SCAN',
        notifications,
        syncRequested: false
      };
    }

    const scannedAt = new Date().toISOString();
    const scanSlot = deriveScanSlot(scannedAt);
    const deviceClock = await getNextDeviceClock();
    const idempotencyKey = buildIdempotencyKey(eventId, ticketCode, direction, scanSlot);

    await import('$lib/db').then(m =>
      m.addScanToQueue({
        idempotency_key: idempotencyKey,
        event_id: eventId,
        ticket_code: ticketCode,
        direction,
        scanned_at: scannedAt,
        scan_slot: scanSlot,
        device_clock: deviceClock,
        entrance_name: metadata.entranceName,
        operator_name: metadata.operatorName
      })
    );

    await markReplay(eventId, ticketCode, direction, new Date(scannedAt));

    await db.attendees.update(attendee.id, {
      is_currently_inside: direction === 'in',
      checkins_remaining:
        direction === 'in' ? attendee.checkins_remaining - 1 : attendee.checkins_remaining,
      checked_in_at: direction === 'in' ? scannedAt : attendee.checked_in_at,
      checked_out_at: direction === 'out' ? scannedAt : attendee.checked_out_at,
      updated_at: scannedAt
    });

    const successMessage = direction === 'in' ? 'Checked In' : 'Checked Out';
    const attendeeName =
      attendee.first_name || attendee.last_name
        ? `${attendee.first_name || ''} ${attendee.last_name || ''}`.trim()
        : null;

    notifications.push({
      type: 'success',
      message: attendeeName ? `${successMessage}: ${attendeeName}` : successMessage
    });

    return {
      success: true,
      message: successMessage,
      attendee: {
        ...attendee,
        is_currently_inside: direction === 'in',
        checkins_remaining:
          direction === 'in' ? attendee.checkins_remaining - 1 : attendee.checkins_remaining
      },
      notifications,
      syncRequested: true
    };
  }

  async function applyEffects(outcome: ScanServiceOutcome): Promise<void> {
    if (notifier) {
      for (const note of outcome.notifications) {
        if (note.type === 'success') {
          notifier.success(note.message);
        } else {
          notifier.error(note.message);
        }
      }
    }

    if (outcome.syncRequested && triggerSync) {
      await triggerSync();
    }
  }

  return { processScan, applyEffects };
}
