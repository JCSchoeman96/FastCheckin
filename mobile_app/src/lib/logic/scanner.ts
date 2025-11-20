import { db } from '$lib/db';
import { sync } from '$lib/stores/sync';
import { v4 as uuidv4 } from 'uuid';
import type { ScanDirection } from '$lib/types';

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
    return {
      success: false,
      message: 'Ticket not found',
      error_code: 'INVALID_TICKET'
    };
  }

  // 2. Validate Scan (Business Logic)
  if (direction === 'in') {
    // Payment Check
    const invalidPayments = ['refunded', 'cancelled', 'pending'];
    if (invalidPayments.includes(attendee.payment_status)) {
      return {
        success: false,
        message: `Payment ${attendee.payment_status}`,
        attendee,
        error_code: 'PAYMENT_INVALID'
      };
    }

    // Already Inside Check (optional, depending on strictness)
    if (attendee.is_currently_inside) {
      return {
        success: false,
        message: 'Already checked in',
        attendee,
        error_code: 'ALREADY_CHECKED_IN'
      };
    }

    // Check-in Limit Check
    if (attendee.checkins_remaining <= 0) {
      return {
        success: false,
        message: 'No check-ins remaining',
        attendee,
        error_code: 'NO_CHECKINS_REMAINING'
      };
    }
  } else if (direction === 'out') {
    // Not Inside Check
    if (!attendee.is_currently_inside) {
      return {
        success: false,
        message: 'Not checked in',
        attendee,
        error_code: 'NOT_CHECKED_IN'
      };
    }
  }

  // 3. Queue Scan
  const idempotencyKey = uuidv4();
  const scannedAt = new Date().toISOString();

  await db.queue.add({
    idempotency_key: idempotencyKey,
    ticket_code: ticketCode,
    direction,
    scanned_at: scannedAt,
    sync_status: 'pending'
  });

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

  return {
    success: true,
    message: direction === 'in' ? 'Checked In' : 'Checked Out',
    attendee: {
      ...attendee,
      is_currently_inside: direction === 'in',
      checkins_remaining: direction === 'in' ? attendee.checkins_remaining - 1 : attendee.checkins_remaining
    }
  };
}
