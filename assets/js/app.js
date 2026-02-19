// Import Alpine.js
import Alpine from "alpinejs";
window.Alpine = Alpine;
Alpine.start();
// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"
// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.
// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
// ----------------------------------------------------------------------------
// [PHOENIX-COLOCATED BUILD WARNING]
//
// This import is currently DISABLED because the project has ZERO colocated
// hooks (LiveView <script> tags). This means the compiler does not generate
// the "phoenix-colocated" directory, causing esbuild to fail in CI/Prod.
//
// WHEN TO ENABLE:
// As soon as you add your first colocated hook, you must:
// 1. Uncomment the import below.
// 2. Remove the empty `const colocatedHooks = {};`.
//
// The `mix.exs` pipeline is already configured correctly ("compile" first),
// and `config/config.exs` has the correct `NODE_PATH` setup.
//
// import { hooks as colocatedHooks } from "phoenix-colocated/fastcheck";
const colocatedHooks = {};
// ----------------------------------------------------------------------------
import topbar from "../vendor/topbar";
import MishkaComponents from "../vendor/mishka_components.js";

const ScannerKeyboardShortcuts = {
  mounted() {
    this.handleKeyDown = this.handleKeyDown.bind(this);
    this.scannerContainer = this.el;
    this.ticketInput = this.el.querySelector('input[type="text"][name*="ticket_code"]');
    this.directionButtons = this.el.querySelectorAll('button[phx-click="set_check_in_type"]');
    
    // Only enable on desktop (not mobile)
    if (window.innerWidth >= 640) {
      document.addEventListener("keydown", this.handleKeyDown);
    }
  },

  destroyed() {
    document.removeEventListener("keydown", this.handleKeyDown);
  },

  handleKeyDown(event) {
    // Don't interfere if user is typing in an input/textarea
    const activeElement = document.activeElement;
    const isInputFocused = activeElement && (
      activeElement.tagName === "INPUT" ||
      activeElement.tagName === "TEXTAREA" ||
      activeElement.isContentEditable
    );

    // Enter key: Trigger scan if ticket code input has focus and value
    if (event.key === "Enter" && !event.shiftKey && !event.ctrlKey && !event.metaKey) {
      if (isInputFocused && this.ticketInput && this.ticketInput.value.trim() !== "") {
        // Only trigger if the focused input is the ticket code input
        if (activeElement === this.ticketInput || activeElement.name?.includes("ticket_code")) {
          event.preventDefault();
          event.stopPropagation();
          this.triggerScan();
          return;
        }
      }
    }

    // Tab key: Toggle check-in direction (only when not in input)
    if (event.key === "Tab" && !isInputFocused) {
      // Check if scanner is disabled
      const isDisabled = this.scannerContainer.querySelector('[disabled][aria-disabled="true"]');
      if (!isDisabled && this.directionButtons.length >= 2) {
        event.preventDefault();
        event.stopPropagation();
        this.toggleDirection();
        return;
      }
    }
  },

  triggerScan() {
    const form = this.scannerContainer.querySelector('form[phx-submit="scan"]');
    if (form) {
      // Trigger form submit
      const submitEvent = new Event("submit", { bubbles: true, cancelable: true });
      form.dispatchEvent(submitEvent);
    }
  },

  toggleDirection() {
    // Find the currently active direction button
    const activeButton = Array.from(this.directionButtons).find(btn => 
      btn.classList.contains("bg-green-600") || btn.classList.contains("bg-orange-600")
    );
    
    if (activeButton) {
      // Find the other button and click it
      const otherButton = Array.from(this.directionButtons).find(btn => btn !== activeButton);
      if (otherButton) {
        otherButton.click();
      }
    } else {
      // If no active button, click the first one (entry)
      if (this.directionButtons[0]) {
        this.directionButtons[0].click();
      }
    }
  },
};

const CameraPermission = {
  mounted() {
    this.storageKey = this.el.dataset.storageKey || "fastcheck:camera-permission";
    this.handleCameraRequest = this.handleCameraRequest.bind(this);
    this.el.addEventListener("click", this.handleCameraRequest);
    this.syncStoredPreference();
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleCameraRequest);
  },

  syncStoredPreference() {
    const storedStatus = this.readStoredStatus();

    if (storedStatus) {
      this.pushStatus(storedStatus, this.defaultMessage(storedStatus), true);
    } else {
      this.pushStatus("unknown", null, false);
    }
  },

  handleCameraRequest(event) {
    const trigger = event.target.closest("[data-camera-request]");

    if (!trigger) {
      return;
    }

    event.preventDefault();
    this.requestCameraPermission();
  },

  requestCameraPermission() {
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      this.reportStatus(
        "unsupported",
        "This browser doesn't support the camera features required for scanning.",
      );
      return;
    }

    navigator.mediaDevices
      .getUserMedia({ video: { facingMode: "environment" } })
      .then((stream) => {
        stream.getTracks().forEach((track) => track.stop());
        this.reportStatus("granted", "Camera access granted. You can start scanning.");
      })
      .catch((error) => {
        const deniedErrors = ["NotAllowedError", "PermissionDeniedError"];
        const status = deniedErrors.includes(error?.name) ? "denied" : "error";
        const fallback =
          status === "denied"
            ? "Camera access was denied. Enable it in your browser settings."
            : "Something went wrong while attempting to access the camera.";

        this.reportStatus(status, error?.message || fallback);
      });
  },

  reportStatus(status, message) {
    const remembered = this.writeStoredStatus(status);
    this.pushStatus(status, message, remembered);
  },

  pushStatus(status, message, remembered) {
    this.pushEvent("camera_permission_sync", {
      status,
      message: message || this.defaultMessage(status),
      remembered: !!remembered,
    });
  },

  readStoredStatus() {
    try {
      return window.localStorage?.getItem(this.storageKey);
    } catch (_error) {
      return null;
    }
  },

  writeStoredStatus(status) {
    try {
      window.localStorage?.setItem(this.storageKey, status);
      return true;
    } catch (_error) {
      return false;
    }
  },

  defaultMessage(status) {
    switch (status) {
      case "granted":
        return "Camera access granted. You can start scanning.";
      case "denied":
        return "Camera access was denied. Enable it in your browser settings.";
      case "error":
        return "Something went wrong while attempting to access the camera.";
      case "unsupported":
        return "This browser doesn't support the camera features required for scanning.";
      default:
        return "Enable your device camera to speed up QR scanning.";
    }
  },
};

const QrCameraScanner = {
  mounted() {
    this.videoElement = null;
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
    this.detectionSupported =
      "BarcodeDetector" in window &&
      !!navigator.mediaDevices &&
      typeof navigator.mediaDevices.getUserMedia === "function";

    this.handleStartClick = this.handleStartClick.bind(this);
    this.handleStopClick = this.handleStopClick.bind(this);

    this.refreshDomReferences();

    if (!this.detectionSupported) {
      this.updateStatus(
        "QR camera decoding is unavailable in this browser. Use Chrome or Edge on a modern device.",
      );
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
    this.stopScanner();
  },

  refreshDomReferences() {
    this.ticketInput = document.getElementById("scanner-ticket-code");

    const nextVideoElement = this.el.querySelector("[data-qr-video]");
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
    this.statusElement = nextStatusElement;
    this.lastElement = nextLastElement;
    this.startButton = nextStartButton;
    this.stopButton = nextStopButton;

    if (controlsChanged) {
      this.bindControlListeners();
    }

    if (this.running && this.stream && this.videoElement && this.videoElement.srcObject !== this.stream) {
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

  syncButtonState() {
    const startDisabled = this.scansDisabled || !this.detectionSupported || this.running;

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

    if (!this.detectionSupported) {
      this.updateStatus(
        "QR camera decoding is unavailable in this browser. Use Chrome or Edge on a modern device.",
      );
      this.syncButtonState();
      return;
    }

    try {
      this.stream = await navigator.mediaDevices.getUserMedia({
        video: {
          facingMode: { ideal: "environment" },
          width: { ideal: 1280 },
          height: { ideal: 720 },
        },
      });
    } catch (error) {
      const denied = ["NotAllowedError", "PermissionDeniedError"].includes(error?.name);
      const message = denied
        ? "Camera permission denied. Enable camera access in browser settings."
        : "Could not start the camera. Check browser permissions and try again.";

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

    this.videoElement.srcObject = this.stream;

    try {
      await this.videoElement.play();
    } catch (_error) {
      this.stopScanner("Camera stream started but playback was blocked.");
      return;
    }

    this.detector = this.detector || this.buildDetector();

    if (!this.detector) {
      this.stopScanner(
        "This browser started the camera but cannot decode QR codes. Use Chrome or Edge.",
      );
      return;
    }

    this.running = true;
    this.syncButtonState();
    this.updateStatus("Camera running. Point the QR code at the preview.");
    this.updateLastScan("Waiting for first code...");
    this.pushEvent("camera_permission_sync", {
      status: "granted",
      message: "Camera access granted. Live QR scanning is active.",
      remembered: true,
    });
    this.runDetectionLoop();
  },

  buildDetector() {
    if (!("BarcodeDetector" in window)) {
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
        const barcodes = await this.detector.detect(this.videoElement);

        if (Array.isArray(barcodes) && barcodes.length > 0) {
          const firstMatch = barcodes.find((entry) => typeof entry?.rawValue === "string");
          const rawValue = firstMatch?.rawValue;

          if (rawValue) {
            this.processDetectedCode(rawValue);
          }
        }
      } catch (_error) {
        // Keep looping; temporary decode errors are expected while frames warm up.
      }

      this.runDetectionLoop();
    }, 180);
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

    this.pushEvent("scan", { ticket_code: ticketCode });

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
const SoundFeedback = {
  storageKey: "fastcheck:sound-enabled",
  audioContext: null,
  
  init() {
    // Check if sounds are enabled (default: true)
    this.enabled = this.isEnabled();
    this.setupAudioContext();
  },
  
  setupAudioContext() {
    // Create AudioContext lazily to respect browser autoplay policies
    try {
      this.audioContext = new (window.AudioContext || window.webkitAudioContext)();
    } catch (e) {
      console.warn("AudioContext not supported:", e);
    }
  },
  
  isEnabled() {
    try {
      const stored = localStorage.getItem(this.storageKey);
      return stored !== "false"; // Default to true if not set
    } catch (e) {
      return true; // Default to enabled
    }
  },
  
  setEnabled(enabled) {
    this.enabled = enabled;
    try {
      localStorage.setItem(this.storageKey, enabled ? "true" : "false");
    } catch (e) {
      console.warn("Failed to save sound preference:", e);
    }
  },
  
  toggle() {
    this.setEnabled(!this.enabled);
    return this.enabled;
  },
  
  playSuccess() {
    if (!this.enabled) return;
    this.playTone(800, 0.1, 0.2); // 800Hz, 0.1s duration, 0.2s fade
  },
  
  playError() {
    if (!this.enabled) return;
    // Descending error tone: 600Hz -> 400Hz over 0.3s
    this.playTone(600, 0.15, 0.1);
    setTimeout(() => {
      this.playTone(400, 0.15, 0.1);
    }, 150);
  },
  
  playTone(frequency, duration, fadeDuration) {
    if (!this.audioContext) {
      this.setupAudioContext();
      if (!this.audioContext) return;
    }
    
    try {
      const oscillator = this.audioContext.createOscillator();
      const gainNode = this.audioContext.createGain();
      
      oscillator.connect(gainNode);
      gainNode.connect(this.audioContext.destination);
      
      oscillator.frequency.value = frequency;
      oscillator.type = "sine";
      
      // Fade in/out for smoother sound
      const now = this.audioContext.currentTime;
      gainNode.gain.setValueAtTime(0, now);
      gainNode.gain.linearRampToValueAtTime(0.3, now + fadeDuration);
      gainNode.gain.linearRampToValueAtTime(0.3, now + duration - fadeDuration);
      gainNode.gain.linearRampToValueAtTime(0, now + duration);
      
      oscillator.start(now);
      oscillator.stop(now + duration);
    } catch (e) {
      // Silently fail if audio can't play (e.g., autoplay restrictions)
      console.debug("Could not play sound:", e);
    }
  }
};

// Initialize sound feedback
SoundFeedback.init();

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

// Sound Toggle Hook
const SoundToggle = {
  mounted() {
    // Store reference to click handler for cleanup
    this.handleClick = () => {
      const enabled = SoundFeedback.toggle();
      this.updateButton(enabled);
      // Sync with LiveView if needed
      this.pushEvent("sound_toggle", { enabled: enabled });
    };
    
    this.el.addEventListener("click", this.handleClick);
    
    // Initialize button state from localStorage
    const enabled = SoundFeedback.isEnabled();
    this.updateButton(enabled);
  },
  
  destroyed() {
    // Remove click listener to prevent memory leaks and duplicate handlers
    if (this.handleClick) {
      this.el.removeEventListener("click", this.handleClick);
    }
  },
  
  updateButton(enabled) {
    // Regex pattern matches both plain and prefixed Tailwind classes (hover:, focus:, etc.)
    const classCleanupPattern = /(?:hover:|focus:)?(?:bg-slate-700\/\d+|text-slate-\d+|bg-green-600\/\d+|text-green-\d+)/g;
    
    if (enabled) {
      this.el.textContent = "🔊 Sound On";
      this.el.className = this.el.className.replace(classCleanupPattern, "").replace(/\s+/g, " ").trim();
      this.el.classList.add("bg-green-600/20", "text-green-300", "hover:bg-green-600/30");
      this.el.setAttribute("aria-label", "Disable sound feedback");
    } else {
      this.el.textContent = "🔇 Sound Off";
      this.el.className = this.el.className.replace(classCleanupPattern, "").replace(/\s+/g, " ").trim();
      this.el.classList.add("bg-slate-700/50", "text-slate-400", "hover:bg-slate-700/70");
      this.el.setAttribute("aria-label", "Enable sound feedback");
    }
  }
};

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {
    _csrf_token: csrfToken,
  },
  hooks: {
    ...colocatedHooks,
    ...MishkaComponents,
    CameraPermission,
    QrCameraScanner,
    ScannerKeyboardShortcuts,
    SoundToggle,
  },
});

// Listen for scan results to play sounds
liveSocket.on("phx:event", (event) => {
  if (event.detail && event.detail.type === "scan_result") {
    if (event.detail.status === "success") {
      SoundFeedback.playSuccess();
    } else if (event.detail.status === "error" || event.detail.status === "invalid") {
      SoundFeedback.playError();
    }
  }
});

// Expose SoundFeedback globally for LiveView hooks
window.SoundFeedback = SoundFeedback;
// Show progress bar on live navigation and form submits
topbar.config({
  barColors: {
    0: "#29d",
  },
  shadowColor: "rgba(0, 0, 0, .3)",
});
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());
// connect if there are any LiveViews on the page
liveSocket.connect();
// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;
// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener(
    "phx:live_reload:attached",
    ({ detail: reloader }) => {
      // Enable server log streaming to client.
      // Disable with reloader.disableServerLogs()
      reloader.enableServerLogs();
      // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
      //
      //   * click with "c" key pressed to open at caller location
      //   * click with "d" key pressed to open at function component definition location
      let keyDown;
      window.addEventListener("keydown", (e) => (keyDown = e.key));
      window.addEventListener("keyup", (e) => (keyDown = null));
      window.addEventListener(
        "click",
        (e) => {
          if (keyDown === "c") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtCaller(e.target);
          } else if (keyDown === "d") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtDef(e.target);
          }
        },
        true,
      );
      window.liveReloader = reloader;
    },
  );
}
