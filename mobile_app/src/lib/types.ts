export type PaymentStatus = 'paid' | 'free' | 'pending' | 'refunded' | 'cancelled';
export type ScanDirection = 'in' | 'out';
export type SyncStatus = 'pending' | 'synced' | 'error' | 'conflict';

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
  created_at?: string;
  updated_at: string;
  conflict?: boolean;
  server_state?: Partial<Attendee>;
  local_state?: Partial<Attendee>;
}

export type ValidationErrorCode =
  | 'INVALID_TICKET'
  | 'PAYMENT_INVALID'
  | 'ALREADY_CHECKED_IN'
  | 'NO_CHECKINS_REMAINING'
  | 'NOT_CHECKED_IN';

export type ScanErrorCode =
  | ValidationErrorCode
  | 'DUPLICATE_SCAN'
  | 'CACHE_EMPTY'
  | 'NOT_FOUND'
  | 'NO_EVENT'
  | 'UNKNOWN_ERROR';

export interface ScanQueueItem {
  id?: number; // Auto-incremented by Dexie
  event_id: number;
  idempotency_key: string;
  ticket_code: string;
  direction: ScanDirection;
  scanned_at: string; // ISO 8601
  scan_version?: string;
  scan_slot?: string;
  entrance_name?: string;
  operator_name?: string;
  device_clock?: number;
  sync_status: SyncStatus;
  error_message?: string;
  server_state?: Record<string, any>;
  local_state?: Record<string, any>;
}

export interface ApiResponse<T> {
  data: T;
  error: {
    code: string;
    message: string;
  } | null;
}

export interface LoginResponseData {
  token: string;
  event_id: number;
  device_name?: string;
  role?: string;
}

export type LoginResponse = ApiResponse<LoginResponseData>;

export interface SyncData {
  server_time: string;
  attendees: Attendee[];
  count: number;
  sync_type: 'full' | 'incremental';
}

export type SyncResponse = ApiResponse<SyncData>;
export type AttendeeSyncResponse = SyncResponse;

export interface ScanUploadData {
  results: {
    idempotency_key: string;
    status: 'success' | 'duplicate' | 'error' | 'conflict' | 'already_processed' | 'stale';
    message: string;
    server_state?: Record<string, any>;
    server_version?: string;
    device_clock?: number;
  }[];
  processed: number;
}

export type ScanUploadResponse = ApiResponse<ScanUploadData>;
export type BatchCheckinResponse = ScanUploadResponse;

export interface ConflictTask {
  type: 'scan' | 'attendee';
  queue_id?: number;
  attendee_id?: number;
  ticket_code?: string;
  event_id?: number;
  idempotency_key?: string;
  local_state?: Record<string, any>;
  server_state?: Record<string, any>;
  detected_at: string;
}
