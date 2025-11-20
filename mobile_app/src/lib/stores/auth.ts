import { writable, derived } from 'svelte/store';
import { browser } from '$app/environment';
import { API_ENDPOINTS } from '$lib/config';

// Types for the auth state
export interface AuthState {
  token: string | null;
  isAuthenticated: boolean;
  event_id: number | null;
  device_name: string | null;
  role: string | null;
  error: string | null;
  isLoading: boolean;
}

const initialState: AuthState = {
  token: null,
  isAuthenticated: false,
  event_id: null,
  device_name: null,
  role: null,
  error: null,
  isLoading: false
};

// Create the store
function createAuthStore() {
  const { subscribe, set, update } = writable<AuthState>(initialState);

  return {
    subscribe,

    // Initialize from localStorage if available
    init: () => {
      if (browser) {
        const storedToken = localStorage.getItem('fastcheck_token');
        if (storedToken) {
          try {
            const payload = JSON.parse(atob(storedToken.split('.')[1]));
            // Check expiration
            if (payload.exp * 1000 > Date.now()) {
              update(s => ({
                ...s,
                token: storedToken,
                isAuthenticated: true,
                event_id: payload.event_id,
                device_name: payload.device_name,
                role: payload.role
              }));
            } else {
              localStorage.removeItem('fastcheck_token');
            }
          } catch (e) {
            localStorage.removeItem('fastcheck_token');
          }
        }
      }
    },

    // Login action
    login: async (event_id: string, device_name: string) => {
      update(s => ({ ...s, isLoading: true, error: null }));

      try {
        const response = await fetch(API_ENDPOINTS.LOGIN, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ event_id, device_name })
        });

        const data = await response.json();

        if (!response.ok) {
          throw new Error(data.message || 'Login failed');
        }

        const token = data.token;
        const payload = JSON.parse(atob(token.split('.')[1]));

        if (browser) {
          localStorage.setItem('fastcheck_token', token);
        }

        update(s => ({
          ...s,
          token,
          isAuthenticated: true,
          event_id: payload.event_id,
          device_name: payload.device_name,
          role: payload.role,
          isLoading: false
        }));

        return true;
      } catch (err: any) {
        update(s => ({
          ...s,
          isLoading: false,
          error: err.message || 'An unexpected error occurred'
        }));
        return false;
      }
    },

    // Logout action
    logout: () => {
      if (browser) {
        localStorage.removeItem('fastcheck_token');
      }
      set(initialState);
    }
  };
}

export const auth = createAuthStore();

// Initialize immediately if in browser
if (browser) {
  auth.init();
}
