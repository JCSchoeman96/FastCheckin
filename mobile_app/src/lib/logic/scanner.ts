import { db, hasRecentReplay, markReplay, pruneReplayCache } from '$lib/db';
import { sync } from '$lib/stores/sync';
import { v4 as uuidv4 } from 'uuid';
import type { ScanDirection } from '$lib/types';
import { validateScan } from './validation';
import { notifications } from '$lib/stores/notifications';
import { REPLAY_CACHE_WINDOW_MS } from '$lib/config';

export interface ScanResult {
  success: boolean;
  message: string;
  attendee?: any;
  error_code?: string;
}

/**
 * Processes a scan locally (offline-first).
 * 
 * 1. Validates ticket exists and is valid for check-in/out
 * 2. Queues the scan for sync
 * 3. Optimistically updates local attendee state
 * 4. Triggers background sync
 */
export async function processScan(
  ticketCode: string, 
  direction: ScanDirection,
  eventId: number
): Promise<ScanResult> {
  
  // 1. Find Attendee
  const attendee = await db.attendees
    .where('[event_id+ticket_code]')
    .equals([eventId, ticketCode])
    .first();

  if (!attendee) {
    notifications.error('Ticket not found');
    return {
      success: false,
      message: 'Ticket not found',
      error_code: 'INVALID_TICKET'
    };
  }

  // 2. Validate Scan (Business Logic)
  const validation = validateScan(attendee, direction);
  if (!validation.valid) {
    notifications.error(validation.message);
    return {
      success: false,
      message: validation.message,
      attendee,
      error_code: validation.errorCode
    };
  }

  await pruneReplayCache(REPLAY_CACHE_WINDOW_MS);

  const isReplay = await hasRecentReplay(eventId, ticketCode, direction, REPLAY_CACHE_WINDOW_MS);
  if (isReplay) {
    notifications.error('Duplicate scan');
    return {
      success: false,
      message: 'Duplicate scan',
      attendee,
      error_code: 'DUPLICATE_SCAN'
    };
  }

  // 3. Queue Scan
  const idempotencyKey = uuidv4();
  const scannedAt = new Date().toISOString();

  await import('$lib/db').then(m => m.addScanToQueue({
    idempotency_key: idempotencyKey,
    event_id: eventId,
    ticket_code: ticketCode,
    direction,
    scanned_at: scannedAt,
    entrance_name: 'Mobile', // Default
    operator_name: 'Mobile Scanner' // Default
  }));

  await markReplay(eventId, ticketCode, direction, new Date(scannedAt));

  // 4. Optimistic Update
  await db.attendees.update(attendee.id, {
    is_currently_inside: direction === 'in',
    checkins_remaining: direction === 'in' 
      ? attendee.checkins_remaining - 1 
      : attendee.checkins_remaining, // Check-out doesn't refund check-ins usually, but logic can vary
    checked_in_at: direction === 'in' ? scannedAt : attendee.checked_in_at,
    checked_out_at: direction === 'out' ? scannedAt : attendee.checked_out_at,
    updated_at: scannedAt // Local update time
  });

  // 5. Trigger Sync (Fire and Forget)
  sync.syncUp().catch(console.error);

  const successMessage = direction === 'in' ? 'Checked In' : 'Checked Out';
  const attendeeName = attendee.first_name || attendee.last_name 
    ? `${attendee.first_name || ''} ${attendee.last_name || ''}`.trim()
    : null;
  
  notifications.success(
    attendeeName ? `${successMessage}: ${attendeeName}` : successMessage
  );

  return {
    success: true,
    message: successMessage,
    attendee: {
      ...attendee,
      is_currently_inside: direction === 'in',
      checkins_remaining: direction === 'in' ? attendee.checkins_remaining - 1 : attendee.checkins_remaining
    }
  };
}
