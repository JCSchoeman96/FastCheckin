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

/**
 * Helper to construct full API URLs if needed for dynamic paths
 */
export function getApiUrl(path: string): string {
  const cleanPath = path.startsWith('/') ? path.substring(1) : path;
  return `${API_BASE_URL}/${cleanPath}`;
}
