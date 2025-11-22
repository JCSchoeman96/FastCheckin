import { writable, derived } from 'svelte/store';
import { browser } from '$app/environment';
import { API_ENDPOINTS } from '$lib/config';
import { getJWT, setJWT } from '$lib/db';

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

    // Initialize from storage (async)
    init: async () => {
      if (browser) {
        try {
          const storedToken = await getJWT();
          if (storedToken) {
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
              await setJWT(null);
            }
          }
        } catch (e) {
          console.error('Auth init error:', e);
          await setJWT(null);
        }
      }
    },

    // Login action
    login: async (event_id: string, device_name: string, credential: string) => {
      update(s => ({ ...s, isLoading: true, error: null }));

      try {
        const response = await fetch(API_ENDPOINTS.LOGIN, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ event_id, device_name, credential })
        });

        const data = await response.json();

        if (!response.ok) {
          const message = data?.error?.message || data?.message || 'Login failed';
          throw new Error(message);
        }

        const responseBody = data.data ?? data;
        const token = responseBody.token;

        if (!token) {
          throw new Error('Login failed: missing token');
        }
        const payload = JSON.parse(atob(token.split('.')[1]));

        if (browser) {
          await setJWT(token);
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
    logout: async () => {
      if (browser) {
        await setJWT(null);
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
