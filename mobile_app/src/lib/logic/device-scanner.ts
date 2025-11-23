import { Html5QrcodeScanner, Html5QrcodeSupportedFormats, type Html5QrcodeResult } from 'html5-qrcode';
import { BarcodeScanner, BarcodeFormat, LensFacing, type BarcodesScannedEvent } from '@capacitor-mlkit/barcode-scanning';
import { Capacitor, type PluginListenerHandle } from '@capacitor/core';
import { Haptics, NotificationType } from '@capacitor/haptics';

export interface DeviceScanner {
  start(): Promise<void>;
  stop(): Promise<void>;
  subscribe(handler: (code: string) => void): () => void;
  isActive(): boolean;
  handleResult?(success: boolean): Promise<void> | void;
}

function createEmitter() {
  const listeners = new Set<(code: string) => void>();

  return {
    emit: (code: string) => {
      for (const listener of listeners) {
        listener(code);
      }
    },
    subscribe: (handler: (code: string) => void) => {
      listeners.add(handler);
      return () => listeners.delete(handler);
    }
  };
}

export function createHtml5Scanner(): DeviceScanner {
  const emitter = createEmitter();
  let scanner: Html5QrcodeScanner | null = null;

  return {
    async start() {
      if (scanner) return;

      const config = {
        fps: 10,
        qrbox: { width: 250, height: 250 },
        aspectRatio: 1.0,
        formatsToSupport: [Html5QrcodeSupportedFormats.QR_CODE]
      };

      scanner = new Html5QrcodeScanner('reader', config, false);
      scanner.render(
        (decodedText: string, _decodedResult: Html5QrcodeResult) => emitter.emit(decodedText),
        () => {}
      );
    },
    async stop() {
      if (!scanner) return;
      await scanner.clear().catch(console.error);
      scanner = null;
    },
    subscribe: emitter.subscribe,
    isActive() {
      return !!scanner;
    },
    async handleResult(success: boolean) {
      if (typeof navigator !== 'undefined' && navigator.vibrate) {
        if (success) {
          navigator.vibrate(200);
        } else {
          navigator.vibrate([100, 50, 100, 50, 100]);
        }
      }
    }
  };
}

export function createCapacitorScanner(): DeviceScanner {
  const emitter = createEmitter();
  let listener: PluginListenerHandle | null = null;
  let active = false;

  return {
    async start() {
      if (active) return;

      try {
        const { camera } = await BarcodeScanner.requestPermissions();
        if (camera !== 'granted' && camera !== 'limited') {
          active = false;
          return;
        }

        document.body.classList.add('scanner-active');
        active = true;

        if (listener) {
          await listener.remove();
          listener = null;
        }

        listener = await BarcodeScanner.addListener('barcodesScanned', async (event: BarcodesScannedEvent) => {
          const firstBarcode = event.barcodes?.[0];
          const code = firstBarcode?.displayValue || firstBarcode?.rawValue;

          if (code) {
            emitter.emit(code);
          }
        });

        await BarcodeScanner.startScan({
          formats: [BarcodeFormat.QrCode],
          lensFacing: LensFacing.Back
        });
      } catch (error) {
        console.error('Failed to start native scanner', error);
        active = false;
        document.body.classList.remove('scanner-active');
        await BarcodeScanner.stopScan();
        await BarcodeScanner.removeAllListeners();
      }
    },
    async stop() {
      if (!active) return;

      active = false;
      document.body.classList.remove('scanner-active');

      if (listener) {
        await listener.remove();
        listener = null;
      }

      await BarcodeScanner.stopScan();
      await BarcodeScanner.removeAllListeners();
    },
    subscribe: emitter.subscribe,
    isActive() {
      return active;
    },
    async handleResult(success: boolean) {
      try {
        await Haptics.notification({
          type: success ? NotificationType.Success : NotificationType.Error
        });
      } catch (error) {
        console.error('Haptics error', error);
      }
    }
  };
}

export function createDeviceScanner(): DeviceScanner {
  return Capacitor.isNativePlatform() ? createCapacitorScanner() : createHtml5Scanner();
}
