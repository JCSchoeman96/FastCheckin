import jsQR from "jsqr";

export const QrCameraScanner = {
  mounted() {
    this.videoElement = null;
    this.canvasElement = null;
    this.canvasContext = null;
    this.statusElement = null;
    this.lastElement = null;
    this.startButton = null;
    this.reconnectButton = null;
    this.stopButton = null;
    this.ticketInput = null;

    this.running = false;
    this.starting = false;
    this.stream = null;
    this.detector = null;
    this.loopTimer = null;
    this.streamCleanup = [];
    this.lastCode = null;
    this.lastCodeAt = 0;
    this.cooldownMs = 1500;
    this.scansDisabled = this.el.dataset.scansDisabled === "true";
    this.resumeKey = this.el.dataset.resumeKey || `${this.el.id}:desired-active`;
    this.desiredActive = this.readDesiredActive();
    this.runtimeState = "idle";
    this.runtimeMessage = null;
    this.recoverable = true;

    this.cameraSupported =
      !!navigator.mediaDevices && typeof navigator.mediaDevices.getUserMedia === "function";
    this.barcodeDetectorSupported = "BarcodeDetector" in window;

    this.handleStartClick = this.handleStartClick.bind(this);
    this.handleReconnectClick = this.handleReconnectClick.bind(this);
    this.handleStopClick = this.handleStopClick.bind(this);
    this.handlePermissionGranted = this.handlePermissionGranted.bind(this);
    this.handleVisibilityChange = this.handleVisibilityChange.bind(this);
    this.handlePageHide = this.handlePageHide.bind(this);
    this.handlePageShow = this.handlePageShow.bind(this);
    this.handlePageLoadingStart = this.handlePageLoadingStart.bind(this);

    this.refreshDomReferences();
    window.addEventListener("fastcheck:camera-permission-granted", this.handlePermissionGranted);
    document.addEventListener("visibilitychange", this.handleVisibilityChange);
    window.addEventListener("pagehide", this.handlePageHide);
    window.addEventListener("pageshow", this.handlePageShow);
    window.addEventListener("phx:page-loading-start", this.handlePageLoadingStart);

    if (!this.cameraSupported) {
      this.setRuntimeState(
        "error",
        "Camera scanning is unavailable in this browser. Manual code entry is still available.",
        false,
      );
    } else if (this.desiredActive) {
      this.setRuntimeState(
        "paused",
        "Camera was previously active. The scanner will reconnect when this page is ready.",
        true,
      );
      this.attemptResume("Restoring the camera session...");
    } else {
      this.setRuntimeState("idle", this.idleMessage(), true);
    }

    this.syncButtonState();
  },

  updated() {
    this.refreshDomReferences();

    const nextDisabled = this.el.dataset.scansDisabled === "true";

    if (nextDisabled !== this.scansDisabled) {
      this.scansDisabled = nextDisabled;

      if (this.scansDisabled) {
        this.stopScanner("Scanning is disabled for archived events.", {
          clearDesiredActive: true,
          runtimeState: "error",
          recoverable: false,
        });
      } else if (this.desiredActive) {
        this.attemptResume("Restoring the camera session...");
      }
    }

    if (!this.scansDisabled && this.desiredActive && !this.running && !this.starting) {
      this.attemptResume("Restoring the camera session...");
    }

    this.syncButtonState();
  },

  destroyed() {
    this.unbindControlListeners();
    window.removeEventListener("fastcheck:camera-permission-granted", this.handlePermissionGranted);
    document.removeEventListener("visibilitychange", this.handleVisibilityChange);
    window.removeEventListener("pagehide", this.handlePageHide);
    window.removeEventListener("pageshow", this.handlePageShow);
    window.removeEventListener("phx:page-loading-start", this.handlePageLoadingStart);
    this.teardownStream();
  },

  refreshDomReferences() {
    this.ticketInput = document.getElementById("scanner-ticket-code");

    const nextVideoElement = this.el.querySelector("[data-qr-video]");
    const nextCanvasElement = this.el.querySelector("[data-qr-canvas]");
    const nextStatusElement = this.el.querySelector("[data-qr-status]");
    const nextLastElement = this.el.querySelector("[data-qr-last]");
    const nextStartButton = this.el.querySelector("[data-qr-start]");
    const nextReconnectButton = this.el.querySelector("[data-qr-reconnect]");
    const nextStopButton = this.el.querySelector("[data-qr-stop]");

    const controlsChanged =
      nextStartButton !== this.startButton ||
      nextReconnectButton !== this.reconnectButton ||
      nextStopButton !== this.stopButton;

    if (controlsChanged) {
      this.unbindControlListeners();
    }

    this.videoElement = nextVideoElement;
    this.canvasElement = nextCanvasElement;
    this.statusElement = nextStatusElement;
    this.lastElement = nextLastElement;
    this.startButton = nextStartButton;
    this.reconnectButton = nextReconnectButton;
    this.stopButton = nextStopButton;
    this.canvasContext = this.canvasElement
      ? this.canvasElement.getContext("2d", { willReadFrequently: true })
      : null;

    if (controlsChanged) {
      this.bindControlListeners();
    }

    if (this.stream && this.videoElement && this.videoElement.srcObject !== this.stream) {
      this.prepareVideoElement();
      this.videoElement.srcObject = this.stream;

      if (this.running) {
        this.videoElement.play().catch(() => {});
      }
    }
  },

  bindControlListeners() {
    this.startButton?.addEventListener("click", this.handleStartClick);
    this.reconnectButton?.addEventListener("click", this.handleReconnectClick);
    this.stopButton?.addEventListener("click", this.handleStopClick);
  },

  unbindControlListeners() {
    this.startButton?.removeEventListener("click", this.handleStartClick);
    this.reconnectButton?.removeEventListener("click", this.handleReconnectClick);
    this.stopButton?.removeEventListener("click", this.handleStopClick);
  },

  handleStartClick(event) {
    event.preventDefault();
    this.setDesiredActive(true);
    this.startScanner({ trigger: "start" });
  },

  handleReconnectClick(event) {
    event.preventDefault();
    this.setDesiredActive(true);
    this.restartScanner("Reconnecting the camera...");
  },

  handleStopClick(event) {
    event.preventDefault();
    this.stopScanner("Camera stopped. Start scanning again when you’re ready.", {
      clearDesiredActive: true,
      runtimeState: "idle",
      recoverable: true,
    });
  },

  handlePermissionGranted() {
    if (!this.cameraSupported || this.scansDisabled) {
      return;
    }

    if (this.desiredActive) {
      this.attemptResume("Camera permission is available again. Reconnecting...");
      return;
    }

    if (!this.running && !this.starting) {
      this.setRuntimeState("idle", "Camera permission is available. Start scanning when ready.", true);
    }
  },

  handleVisibilityChange() {
    if (document.hidden) {
      if (this.running || this.starting || this.desiredActive) {
        this.pauseScanner("Camera paused while the browser was in the background.");
      }

      return;
    }

    this.attemptResume("Restoring camera after returning to the scanner...");
  },

  handlePageHide() {
    if (this.running || this.starting || this.desiredActive) {
      this.pauseScanner("Camera paused while this page was hidden.");
    }
  },

  handlePageShow() {
    this.attemptResume("Restoring camera after returning to the page...");
  },

  handlePageLoadingStart() {
    if (this.running || this.starting || this.desiredActive) {
      this.pauseScanner("Camera paused while changing screens.");
    }
  },

  readDesiredActive() {
    try {
      return window.sessionStorage?.getItem(this.resumeKey) === "true";
    } catch (_error) {
      return false;
    }
  },

  setDesiredActive(value) {
    this.desiredActive = !!value;

    try {
      window.sessionStorage?.setItem(this.resumeKey, this.desiredActive ? "true" : "false");
    } catch (_error) {
      // Session storage is a best-effort hint only.
    }
  },

  pageCanUseCamera() {
    return !document.hidden && !!this.videoElement;
  },

  idleMessage() {
    if (!this.cameraSupported) {
      return "Camera scanning is unavailable in this browser. Manual code entry is still available.";
    }

    if (!this.barcodeDetectorSupported) {
      return "Camera ready with jsQR fallback decoder. Start scanning when ready.";
    }

    return "Camera is idle. Start scanning when ready.";
  },

  syncButtonState() {
    const busy = this.running || this.starting;
    const reconnectAllowed =
      this.recoverable &&
      this.cameraSupported &&
      !this.scansDisabled &&
      ["paused", "recovering", "error"].includes(this.runtimeState);

    if (this.startButton) {
      this.startButton.disabled = this.scansDisabled || !this.cameraSupported || busy || this.desiredActive;
    }

    if (this.reconnectButton) {
      this.reconnectButton.disabled = !reconnectAllowed || busy;
    }

    if (this.stopButton) {
      this.stopButton.disabled = !busy && this.runtimeState !== "running";
    }
  },

  setRuntimeState(state, message, recoverable = true) {
    this.runtimeState = state;
    this.runtimeMessage = message;
    this.recoverable = recoverable;
    this.updateStatus(message);
    this.syncButtonState();
    this.pushEvent("camera_runtime_sync", {
      state,
      message,
      recoverable,
      desired_active: this.desiredActive,
    });
  },

  pushPermissionStatus(status, message, remembered = true) {
    this.pushEvent("camera_permission_sync", {
      status,
      message,
      remembered,
    });
  },

  async attemptResume(message) {
    if (!this.desiredActive || this.running || this.starting) {
      return;
    }

    if (this.scansDisabled || !this.cameraSupported) {
      this.syncButtonState();
      return;
    }

    if (!this.pageCanUseCamera()) {
      this.setRuntimeState(
        "paused",
        "Camera will reconnect when this scanner page becomes active again.",
        true,
      );
      return;
    }

    await this.startScanner({ trigger: "resume", preflightMessage: message });
  },

  async restartScanner(message) {
    this.teardownStream();
    this.running = false;
    this.starting = false;
    await this.startScanner({ trigger: "reconnect", preflightMessage: message });
  },

  async startScanner({ trigger = "start", preflightMessage = null } = {}) {
    if (this.running || this.starting || this.scansDisabled) {
      return;
    }

    if (!this.cameraSupported) {
      this.setRuntimeState(
        "error",
        "Camera scanning is unavailable in this browser. Manual code entry is still available.",
        false,
      );
      return;
    }

    if (!this.pageCanUseCamera()) {
      this.setRuntimeState(
        "paused",
        "Camera will reconnect when this scanner page becomes active again.",
        true,
      );
      return;
    }

    const recoveryTrigger = trigger === "resume" || trigger === "reconnect";
    this.starting = true;
    this.setRuntimeState(
      recoveryTrigger ? "recovering" : "starting",
      preflightMessage || (recoveryTrigger ? "Reconnecting the camera..." : "Starting camera..."),
      true,
    );

    let stream = null;

    try {
      stream = await this.requestCameraStream();
    } catch (error) {
      this.starting = false;
      this.handleStartFailure(error, recoveryTrigger);
      return;
    }

    if (!this.videoElement) {
      stream.getTracks().forEach((track) => track.stop());
      this.starting = false;
      this.setRuntimeState(
        "error",
        "Camera preview was not found on the page. Reopen the scanner tab and try reconnecting.",
        true,
      );
      return;
    }

    this.stream = stream;
    this.attachStreamObservers(stream);
    this.prepareVideoElement();
    this.videoElement.srcObject = stream;

    try {
      await this.videoElement.play();
    } catch (_error) {
      this.starting = false;
      this.teardownStream();
      this.setRuntimeState(
        "error",
        "Camera stream started but playback was blocked. Reconnect the camera to try again.",
        true,
      );
      return;
    }

    const hasPreviewFrames = await this.waitForVideoDimensions();

    if (!hasPreviewFrames) {
      this.starting = false;
      this.teardownStream();
      this.setRuntimeState(
        "error",
        "Camera opened, but no preview frames arrived. Reconnect the camera or re-check permission.",
        true,
      );
      return;
    }

    this.detector = this.buildBarcodeDetector();
    this.running = true;
    this.starting = false;

    const decoderName = this.detector ? "BarcodeDetector" : "jsQR fallback";
    this.setRuntimeState(
      "running",
      `Camera running with ${decoderName}. Point the QR code at the preview.`,
      true,
    );
    this.updateLastScan("Waiting for first code...");
    this.pushPermissionStatus(
      "granted",
      "Camera access granted. Live QR scanning is active in this scanner tab.",
      true,
    );

    this.runDetectionLoop();
  },

  handleStartFailure(error, recoveryTrigger) {
    const denied = ["NotAllowedError", "PermissionDeniedError"].includes(error?.name);

    if (denied) {
      this.pushPermissionStatus(
        "denied",
        "Camera permission denied. Update your browser settings, then re-check permission.",
        true,
      );
    }

    this.setRuntimeState(
      "error",
      denied
        ? "Camera permission is blocked. Re-check permission after updating browser settings."
        : this.cameraStartErrorMessage(error, recoveryTrigger),
      true,
    );
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

  cameraStartErrorMessage(error, recoveryTrigger) {
    switch (error?.name) {
      case "NotReadableError":
      case "TrackStartError":
        return recoveryTrigger
          ? "The camera is busy in another app or tab. Close the other camera session, then reconnect."
          : "Camera is already in use by another app or tab. Close it and try again.";
      case "OverconstrainedError":
      case "ConstraintNotSatisfiedError":
        return "This device could not satisfy the camera profile. Reconnect the camera to try again.";
      case "NotFoundError":
      case "DevicesNotFoundError":
        return "No camera was found on this device.";
      case "AbortError":
        return "Camera startup was interrupted. Reconnect the camera to continue scanning.";
      default:
        return recoveryTrigger
          ? "Camera reconnect failed. Re-check permission or reconnect again."
          : "Could not start the camera. Check browser permissions and try again.";
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

  attachStreamObservers(stream) {
    this.detachStreamObservers();

    const handleUnexpectedStop = () => {
      if (document.hidden) {
        this.pauseScanner("Camera paused while the browser was in the background.");
        return;
      }

      if (this.desiredActive) {
        this.restartScanner("Camera feed was interrupted. Reconnecting...");
      } else {
        this.stopScanner("Camera feed ended. Reconnect the camera to continue scanning.", {
          clearDesiredActive: false,
          runtimeState: "error",
          recoverable: true,
        });
      }
    };

    stream.addEventListener("inactive", handleUnexpectedStop);
    this.streamCleanup.push(() => stream.removeEventListener("inactive", handleUnexpectedStop));

    stream.getTracks().forEach((track) => {
      const onEnded = () => handleUnexpectedStop();
      track.addEventListener("ended", onEnded);
      this.streamCleanup.push(() => track.removeEventListener("ended", onEnded));
    });
  },

  detachStreamObservers() {
    this.streamCleanup.forEach((cleanup) => cleanup());
    this.streamCleanup = [];
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

  pauseScanner(statusMessage) {
    this.stopScanner(statusMessage, {
      clearDesiredActive: false,
      runtimeState: "paused",
      recoverable: true,
    });
  },

  stopScanner(
    statusMessage,
    { clearDesiredActive = false, runtimeState = null, recoverable = true } = {},
  ) {
    if (clearDesiredActive) {
      this.setDesiredActive(false);
    }

    this.running = false;
    this.starting = false;
    this.teardownStream();

    const nextState = runtimeState || (this.desiredActive ? "paused" : "idle");
    const nextMessage =
      statusMessage || (nextState === "idle" ? this.idleMessage() : this.runtimeMessage);

    this.setRuntimeState(nextState, nextMessage, recoverable);
  },

  teardownStream() {
    if (this.loopTimer) {
      window.clearTimeout(this.loopTimer);
      this.loopTimer = null;
    }

    if (this.videoElement) {
      this.videoElement.pause();
      this.videoElement.srcObject = null;
    }

    this.detachStreamObservers();

    if (this.stream) {
      this.stream.getTracks().forEach((track) => track.stop());
      this.stream = null;
    }

    this.detector = null;
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
