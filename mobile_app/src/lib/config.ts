/**
 * Mobile Client Configuration
 * 
 * Centralizes API URLs and environment-specific settings.
 * Reads from Vite environment variables (VITE_*) with sensible defaults.
 */

// Base API URL - defaults to local Phoenix server
// To override in production: VITE_API_BASE_URL=https://api.fastcheckin.com
export const API_BASE_URL = import.meta.env.VITE_API_BASE_URL || 'http://localhost:4000';

// API Endpoints
export const API_ENDPOINTS = {
  LOGIN: `${API_BASE_URL}/api/v1/mobile/login`,
  ATTENDEES: `${API_BASE_URL}/api/v1/mobile/attendees`, // Sync Down
  SCANS: `${API_BASE_URL}/api/v1/mobile/scans`,         // Sync Up (Legacy)
  BATCH_CHECKIN: `${API_BASE_URL}/api/v1/check-in/batch`, // Batch Sync Up
} as const;

// Local cache TTL (e.g., 12 hours)
export const CACHE_TTL_MS = Number(import.meta.env.VITE_CACHE_TTL_MS) || 12 * 60 * 60 * 1000;

// Prevents rapid duplicate scans within this window
export const REPLAY_CACHE_WINDOW_MS = Number(import.meta.env.VITE_REPLAY_CACHE_WINDOW_MS) || 10_000;

/**
 * Helper to construct full API URLs if needed for dynamic paths
 */
export function getApiUrl(path: string): string {
  const cleanPath = path.startsWith('/') ? path.substring(1) : path;
  return `${API_BASE_URL}/${cleanPath}`;
}
