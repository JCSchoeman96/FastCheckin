import jsQR from "jsqr";

export const QrCameraScanner = {
  mounted() {
    this.videoElement = null;
    this.canvasElement = null;
    this.canvasContext = null;
    this.statusElement = null;
    this.lastElement = null;
    this.startButton = null;
    this.stopButton = null;
    this.ticketInput = null;

    this.running = false;
    this.stream = null;
    this.detector = null;
    this.loopTimer = null;
    this.lastCode = null;
    this.lastCodeAt = 0;
    this.cooldownMs = 1500;
    this.scansDisabled = this.el.dataset.scansDisabled === "true";

    this.cameraSupported =
      !!navigator.mediaDevices && typeof navigator.mediaDevices.getUserMedia === "function";
    this.barcodeDetectorSupported = "BarcodeDetector" in window;

    this.handleStartClick = this.handleStartClick.bind(this);
    this.handleStopClick = this.handleStopClick.bind(this);
    this.handlePermissionGranted = this.handlePermissionGranted.bind(this);

    this.refreshDomReferences();
    window.addEventListener("fastcheck:camera-permission-granted", this.handlePermissionGranted);

    if (!this.cameraSupported) {
      this.updateStatus(
        "Camera scanning is unavailable in this browser. Manual code entry is still available.",
      );
    } else if (!this.barcodeDetectorSupported) {
      this.updateStatus("Camera ready with jsQR fallback decoder. Start scanning when ready.");
    } else {
      this.updateStatus("Camera is idle. Start scanning when ready.");
    }

    this.syncButtonState();
  },

  updated() {
    this.refreshDomReferences();

    const nextDisabled = this.el.dataset.scansDisabled === "true";

    if (nextDisabled !== this.scansDisabled) {
      this.scansDisabled = nextDisabled;

      if (this.scansDisabled && this.running) {
        this.stopScanner("Scanning is disabled for archived events.");
      }
    }

    this.syncButtonState();
  },

  destroyed() {
    this.unbindControlListeners();
    window.removeEventListener("fastcheck:camera-permission-granted", this.handlePermissionGranted);
    this.stopScanner();
  },

  refreshDomReferences() {
    this.ticketInput = document.getElementById("scanner-ticket-code");

    const nextVideoElement = this.el.querySelector("[data-qr-video]");
    const nextCanvasElement = this.el.querySelector("[data-qr-canvas]");
    const nextStatusElement = this.el.querySelector("[data-qr-status]");
    const nextLastElement = this.el.querySelector("[data-qr-last]");
    const nextStartButton = this.el.querySelector("[data-qr-start]");
    const nextStopButton = this.el.querySelector("[data-qr-stop]");

    const controlsChanged =
      nextStartButton !== this.startButton || nextStopButton !== this.stopButton;

    if (controlsChanged) {
      this.unbindControlListeners();
    }

    this.videoElement = nextVideoElement;
    this.canvasElement = nextCanvasElement;
    this.statusElement = nextStatusElement;
    this.lastElement = nextLastElement;
    this.startButton = nextStartButton;
    this.stopButton = nextStopButton;
    this.canvasContext = this.canvasElement
      ? this.canvasElement.getContext("2d", { willReadFrequently: true })
      : null;

    if (controlsChanged) {
      this.bindControlListeners();
    }

    if (this.running && this.stream && this.videoElement && this.videoElement.srcObject !== this.stream) {
      this.prepareVideoElement();
      this.videoElement.srcObject = this.stream;
      this.videoElement.play().catch(() => {});
    }
  },

  bindControlListeners() {
    this.startButton?.addEventListener("click", this.handleStartClick);
    this.stopButton?.addEventListener("click", this.handleStopClick);
  },

  unbindControlListeners() {
    this.startButton?.removeEventListener("click", this.handleStartClick);
    this.stopButton?.removeEventListener("click", this.handleStopClick);
  },

  handleStartClick(event) {
    event.preventDefault();
    this.startScanner();
  },

  handleStopClick(event) {
    event.preventDefault();
    this.stopScanner("Camera stopped.");
  },

  handlePermissionGranted() {
    if (this.running || this.scansDisabled || !this.cameraSupported) {
      return;
    }

    this.startScanner();
  },

  syncButtonState() {
    const startDisabled = this.scansDisabled || !this.cameraSupported || this.running;

    if (this.startButton) {
      this.startButton.disabled = startDisabled;
    }

    if (this.stopButton) {
      this.stopButton.disabled = !this.running;
    }
  },

  async startScanner() {
    if (this.running || this.scansDisabled) {
      return;
    }

    if (!this.cameraSupported) {
      this.updateStatus(
        "Camera scanning is unavailable in this browser. Manual code entry is still available.",
      );
      this.syncButtonState();
      return;
    }

    this.updateStatus("Starting camera...");

    try {
      this.stream = await this.requestCameraStream();
    } catch (error) {
      const denied = ["NotAllowedError", "PermissionDeniedError"].includes(error?.name);
      const message = denied
        ? "Camera permission denied. Enable camera access in browser settings."
        : this.cameraStartErrorMessage(error);

      this.updateStatus(message);
      this.pushEvent("camera_permission_sync", {
        status: denied ? "denied" : "error",
        message,
        remembered: true,
      });
      this.syncButtonState();
      return;
    }

    if (!this.videoElement) {
      this.stopScanner("Camera preview was not found on the page.");
      return;
    }

    this.prepareVideoElement();
    this.videoElement.srcObject = this.stream;

    try {
      await this.videoElement.play();
    } catch (_error) {
      this.stopScanner("Camera stream started but playback was blocked.");
      return;
    }

    const hasPreviewFrames = await this.waitForVideoDimensions();

    if (!hasPreviewFrames) {
      this.stopScanner("Camera opened, but no preview frames arrived. Try starting again.");
      return;
    }

    this.detector = this.buildBarcodeDetector();

    this.running = true;
    this.syncButtonState();

    const decoderName = this.detector ? "BarcodeDetector" : "jsQR fallback";
    this.updateStatus(`Camera running with ${decoderName}. Point the QR code at the preview.`);
    this.updateLastScan("Waiting for first code...");

    this.pushEvent("camera_permission_sync", {
      status: "granted",
      message: "Camera access granted. Live QR scanning is active.",
      remembered: true,
    });

    this.runDetectionLoop();
  },

  async requestCameraStream() {
    const profiles = this.cameraConstraintProfiles();
    let lastError = null;

    for (const videoConstraints of profiles) {
      try {
        return await navigator.mediaDevices.getUserMedia({
          video: videoConstraints,
          audio: false,
        });
      } catch (error) {
        lastError = error;

        if (["NotAllowedError", "PermissionDeniedError"].includes(error?.name)) {
          throw error;
        }
      }
    }

    throw lastError || new Error("Could not open a camera stream.");
  },

  cameraConstraintProfiles() {
    return [
      {
        facingMode: { ideal: "environment" },
        width: { ideal: 1280 },
        height: { ideal: 720 },
      },
      {
        facingMode: { ideal: "environment" },
      },
      true,
    ];
  },

  cameraStartErrorMessage(error) {
    switch (error?.name) {
      case "NotReadableError":
      case "TrackStartError":
        return "Camera is already in use by another app. Close it and try again.";
      case "OverconstrainedError":
      case "ConstraintNotSatisfiedError":
        return "This device could not satisfy the camera profile. Try again.";
      case "NotFoundError":
      case "DevicesNotFoundError":
        return "No camera was found on this device.";
      default:
        return "Could not start the camera. Check browser permissions and try again.";
    }
  },

  prepareVideoElement() {
    if (!this.videoElement) {
      return;
    }

    this.videoElement.muted = true;
    this.videoElement.setAttribute("autoplay", "");
    this.videoElement.setAttribute("playsinline", "");
  },

  waitForVideoDimensions(timeoutMs = 2000) {
    if (!this.videoElement) {
      return Promise.resolve(false);
    }

    if ((this.videoElement.videoWidth || 0) > 0 && (this.videoElement.videoHeight || 0) > 0) {
      return Promise.resolve(true);
    }

    return new Promise((resolve) => {
      let settled = false;

      const cleanup = () => {
        if (!this.videoElement) {
          return;
        }

        this.videoElement.removeEventListener("loadedmetadata", onReady);
        this.videoElement.removeEventListener("playing", onReady);
      };

      const finish = (result) => {
        if (settled) {
          return;
        }

        settled = true;
        cleanup();
        window.clearTimeout(timeoutId);
        resolve(result);
      };

      const onReady = () => {
        const width = this.videoElement?.videoWidth || 0;
        const height = this.videoElement?.videoHeight || 0;

        if (width > 0 && height > 0) {
          finish(true);
        }
      };

      const timeoutId = window.setTimeout(() => finish(false), timeoutMs);
      this.videoElement.addEventListener("loadedmetadata", onReady);
      this.videoElement.addEventListener("playing", onReady);
      onReady();
    });
  },

  buildBarcodeDetector() {
    if (!this.barcodeDetectorSupported) {
      return null;
    }

    try {
      return new window.BarcodeDetector({ formats: ["qr_code"] });
    } catch (_error) {
      try {
        return new window.BarcodeDetector();
      } catch (_error2) {
        return null;
      }
    }
  },

  runDetectionLoop() {
    if (!this.running) {
      return;
    }

    this.loopTimer = window.setTimeout(async () => {
      if (!this.running) {
        return;
      }

      try {
        const rawValue = await this.decodeOnce();

        if (rawValue) {
          this.processDetectedCode(rawValue);
        }
      } catch (_error) {
        // Keep scanning on decoder/frame errors.
      }

      this.runDetectionLoop();
    }, 120);
  },

  async decodeOnce() {
    if (this.detector && this.videoElement) {
      const barcodes = await this.detector.detect(this.videoElement);

      if (Array.isArray(barcodes) && barcodes.length > 0) {
        const firstMatch = barcodes.find((entry) => typeof entry?.rawValue === "string");
        const rawValue = firstMatch?.rawValue;

        if (rawValue && rawValue.trim() !== "") {
          return rawValue;
        }
      }
    }

    return this.decodeWithJsQr();
  },

  decodeWithJsQr() {
    if (!this.videoElement || !this.canvasElement || !this.canvasContext) {
      return null;
    }

    const width = this.videoElement.videoWidth || 0;
    const height = this.videoElement.videoHeight || 0;

    if (width <= 0 || height <= 0) {
      return null;
    }

    if (this.canvasElement.width !== width || this.canvasElement.height !== height) {
      this.canvasElement.width = width;
      this.canvasElement.height = height;
    }

    this.canvasContext.drawImage(this.videoElement, 0, 0, width, height);
    const imageData = this.canvasContext.getImageData(0, 0, width, height);

    const decoded = jsQR(imageData.data, width, height, {
      inversionAttempts: "attemptBoth",
    });

    return decoded?.data || null;
  },

  processDetectedCode(rawValue) {
    const ticketCode = `${rawValue}`.trim();

    if (ticketCode.length === 0) {
      return;
    }

    const now = Date.now();
    const duplicateInCooldown =
      this.lastCode === ticketCode && now - this.lastCodeAt < this.cooldownMs;

    if (duplicateInCooldown) {
      return;
    }

    this.lastCode = ticketCode;
    this.lastCodeAt = now;

    if (this.ticketInput) {
      this.ticketInput.value = ticketCode;
      this.ticketInput.dispatchEvent(new Event("input", { bubbles: true }));
    }

    this.pushEvent("scan_camera_decoded", { ticket_code: ticketCode });
    this.updateStatus(`Scanned ${ticketCode}. Ready for next code.`);
    this.updateLastScan(`Last: ${ticketCode}`);
  },

  stopScanner(statusMessage) {
    this.running = false;

    if (this.loopTimer) {
      window.clearTimeout(this.loopTimer);
      this.loopTimer = null;
    }

    if (this.videoElement) {
      this.videoElement.pause();
      this.videoElement.srcObject = null;
    }

    if (this.stream) {
      this.stream.getTracks().forEach((track) => track.stop());
      this.stream = null;
    }

    this.syncButtonState();

    if (statusMessage) {
      this.updateStatus(statusMessage);
    }
  },

  updateStatus(message) {
    if (this.statusElement) {
      this.statusElement.textContent = message;
    }
  },

  updateLastScan(message) {
    if (this.lastElement) {
      this.lastElement.textContent = message;
    }
  },
};
