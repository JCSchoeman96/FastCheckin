import { writable } from 'svelte/store';

export interface Notification {
  id: string;
  type: 'error' | 'success' | 'info' | 'warning';
  message: string;
  duration?: number; // ms, default 5000
  persistent?: boolean;
  actions?: { label: string; handler: () => void }[];
}

function createNotificationStore() {
  const { subscribe, update } = writable<Notification[]>([]);

  let nextId = 0;

  function add(notification: Omit<Notification, 'id'>): string {
    const id = `notification-${nextId++}`;
    const duration = notification.persistent ? 0 : notification.duration ?? 5000;
    const fullNotification: Notification = {
      ...notification,
      id,
      duration
    };

    update(notifications => [...notifications, fullNotification]);

    // Auto-dismiss after duration
    if (duration > 0) {
      setTimeout(() => {
        remove(id);
      }, duration);
    }

    return id;
  }

  function remove(id: string) {
    update(notifications => notifications.filter(n => n.id !== id));
  }

  function clear() {
    update(() => []);
  }

  // Convenience methods
  function error(message: string, duration?: number) {
    return add({ type: 'error', message, duration });
  }

  function success(message: string, duration?: number) {
    return add({ type: 'success', message, duration });
  }

  function info(message: string, duration?: number) {
    return add({ type: 'info', message, duration });
  }

  function warning(message: string, duration?: number) {
    return add({ type: 'warning', message, duration });
  }

  function conflict(message: string, actions?: { label: string; handler: () => void }[]) {
    return add({ type: 'warning', message, actions, persistent: true, duration: 0 });
  }

  return {
    subscribe,
    add,
    remove,
    clear,
    error,
    success,
    info,
    warning,
    conflict
  };
}

export const notifications = createNotificationStore();
