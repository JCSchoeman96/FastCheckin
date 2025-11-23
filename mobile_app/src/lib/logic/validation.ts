import type { Attendee, ScanDirection, ValidationErrorCode } from '$lib/types';

export interface ValidationResult {
  valid: boolean;
  message: string;
  errorCode?: ValidationErrorCode;
}

/**
 * Validates a scan attempt based on attendee state and direction.
 * Pure function: no side effects, no DB access.
 */
export function validateScan(
  attendee: Attendee | undefined,
  direction: ScanDirection
): ValidationResult {
  // 1. Existence Check
  if (!attendee) {
    return {
      valid: false,
      message: 'Ticket not found',
      errorCode: 'INVALID_TICKET'
    };
  }

  // 2. Payment Status Check
  // Allowed statuses: 'paid', 'free'
  // Invalid statuses: 'pending', 'refunded', 'cancelled'
  const validPaymentStatuses = ['paid', 'free'];
  if (!validPaymentStatuses.includes(attendee.payment_status)) {
    return {
      valid: false,
      message: `Payment ${attendee.payment_status}`,
      errorCode: 'PAYMENT_INVALID'
    };
  }

  if (direction === 'in') {
    // 3. Check-in Rules
    
    // Already Inside Check
    if (attendee.is_currently_inside) {
      return {
        valid: false,
        message: 'Already checked in',
        errorCode: 'ALREADY_CHECKED_IN'
      };
    }

    // Check-in Limit Check
    if (attendee.checkins_remaining <= 0) {
      return {
        valid: false,
        message: 'No check-ins remaining',
        errorCode: 'NO_CHECKINS_REMAINING'
      };
    }

  } else if (direction === 'out') {
    // 4. Check-out Rules
    
    // Not Inside Check
    if (!attendee.is_currently_inside) {
      return {
        valid: false,
        message: 'Not checked in',
        errorCode: 'NOT_CHECKED_IN'
      };
    }
  }

  return {
    valid: true,
    message: direction === 'in' ? 'Valid Check-in' : 'Valid Check-out'
  };
}
