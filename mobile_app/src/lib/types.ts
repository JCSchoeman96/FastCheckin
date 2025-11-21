export type PaymentStatus = 'paid' | 'free' | 'pending' | 'refunded' | 'cancelled';
export type ScanDirection = 'in' | 'out';
export type SyncStatus = 'pending' | 'synced' | 'error';

export interface Attendee {
  id: number;
  event_id: number;
  ticket_code: string;
  first_name: string;
  last_name: string;
  email: string;
  ticket_type: string;
  allowed_checkins: number;
  checkins_remaining: number;
  payment_status: PaymentStatus;
  is_currently_inside: boolean;
  checked_in_at: string | null;
  checked_out_at: string | null;
  updated_at: string | null;
}

export interface ScanQueueItem {
  id?: number; // Auto-incremented by Dexie
  event_id: number;
  idempotency_key: string;
  ticket_code: string;
  direction: ScanDirection;
  scanned_at: string; // ISO 8601
  entrance_name?: string;
  operator_name?: string;
  sync_status: SyncStatus;
  error_message?: string;
}

export interface SyncResponse {
  server_time: string;
  attendees: Attendee[];
  count: number;
  sync_type: 'full' | 'incremental';
}

export interface ScanUploadResponse {
  results: {
    idempotency_key: string;
    status: 'success' | 'duplicate' | 'error';
    message: string;
  }[];
  processed: number;
}
