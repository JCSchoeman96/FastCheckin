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
import { QrCameraScanner } from "./qr_scanner_hook";

const ScannerKeyboardShortcuts = {
  refreshRefs() {
    this.ticketInput =
      this.el.querySelector("#scanner-ticket-code") || document.getElementById("scanner-ticket-code");
    this.directionButtons = this.el.querySelectorAll("button[data-check-in-type]");
    this.scanForm = this.el.querySelector('form[phx-submit="scan"]');
    this.scanButton = this.el.querySelector("#process-scan-button");
  },

  mounted() {
    this.handleKeyDown = this.handleKeyDown.bind(this);
    this.scannerContainer = this.el;
    this.refreshRefs();
    
    // Only enable on desktop (not mobile)
    if (window.innerWidth >= 640) {
      document.addEventListener("keydown", this.handleKeyDown);
    }
  },

  updated() {
    this.refreshRefs();
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
      const isDisabled = this.scanButton?.disabled === true;
      if (!isDisabled && this.directionButtons.length >= 2) {
        event.preventDefault();
        event.stopPropagation();
        this.toggleDirection();
        return;
      }
    }
  },

  triggerScan() {
    const form = this.scanForm || this.scannerContainer.querySelector('form[phx-submit="scan"]');
    if (form && !this.scanButton?.disabled) {
      // Trigger form submit
      const submitEvent = new Event("submit", { bubbles: true, cancelable: true });
      form.dispatchEvent(submitEvent);
    }
  },

  toggleDirection() {
    // Find the currently active direction button
    const activeButton = Array.from(this.directionButtons).find(
      (btn) => btn.getAttribute("aria-pressed") === "true"
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
    this.permissionStatus = null;
    this.handleCameraRequest = this.handleCameraRequest.bind(this);
    this.handleVisibilityChange = this.handleVisibilityChange.bind(this);
    this.handlePageShow = this.handlePageShow.bind(this);
    this.handlePermissionRefresh = this.handlePermissionRefresh.bind(this);

    this.el.addEventListener("click", this.handleCameraRequest);
    document.addEventListener("visibilitychange", this.handleVisibilityChange);
    window.addEventListener("pageshow", this.handlePageShow);
    window.addEventListener("fastcheck:camera-permission-refresh", this.handlePermissionRefresh);

    this.syncPermissionState();
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleCameraRequest);
    document.removeEventListener("visibilitychange", this.handleVisibilityChange);
    window.removeEventListener("pageshow", this.handlePageShow);
    window.removeEventListener("fastcheck:camera-permission-refresh", this.handlePermissionRefresh);
    this.detachPermissionWatcher();
  },

  handleVisibilityChange() {
    if (!document.hidden) {
      this.syncPermissionState();
    }
  },

  handlePageShow() {
    this.syncPermissionState();
  },

  handlePermissionRefresh() {
    this.syncPermissionState();
  },

  cameraSupported() {
    return !!navigator.mediaDevices && typeof navigator.mediaDevices.getUserMedia === "function";
  },

  async syncPermissionState() {
    if (!this.cameraSupported()) {
      this.reportStatus("unsupported", "Camera unavailable. Use manual entry.");
      return;
    }

    const state = await this.queryPermissionState();

    switch (state) {
      case "granted":
        this.reportStatus("granted", "Camera ready.");
        return;
      case "denied":
        this.reportStatus("denied", "Camera blocked. Check browser permission.");
        return;
      case "prompt":
        this.pushPromptStatus();
        return;
      default:
        this.pushFallbackStatus();
    }
  },

  async queryPermissionState() {
    if (!navigator.permissions || typeof navigator.permissions.query !== "function") {
      this.detachPermissionWatcher();
      return null;
    }

    try {
      const permissionStatus = await navigator.permissions.query({ name: "camera" });
      this.attachPermissionWatcher(permissionStatus);
      return permissionStatus.state;
    } catch (_error) {
      this.detachPermissionWatcher();
      return null;
    }
  },

  attachPermissionWatcher(permissionStatus) {
    if (this.permissionStatus === permissionStatus) {
      return;
    }

    this.detachPermissionWatcher();
    this.permissionStatus = permissionStatus;
    this.permissionStatusHandler = () => this.syncPermissionState();

    if (typeof permissionStatus.addEventListener === "function") {
      permissionStatus.addEventListener("change", this.permissionStatusHandler);
    } else {
      permissionStatus.onchange = this.permissionStatusHandler;
    }
  },

  detachPermissionWatcher() {
    if (!this.permissionStatus || !this.permissionStatusHandler) {
      this.permissionStatus = null;
      this.permissionStatusHandler = null;
      return;
    }

    if (typeof this.permissionStatus.removeEventListener === "function") {
      this.permissionStatus.removeEventListener("change", this.permissionStatusHandler);
    } else if (this.permissionStatus.onchange === this.permissionStatusHandler) {
      this.permissionStatus.onchange = null;
    }

    this.permissionStatus = null;
    this.permissionStatusHandler = null;
  },

  pushPromptStatus() {
    const hint = this.readStoredStatus();

    if (hint?.status === "granted") {
      this.pushStatus("unknown", "Camera ready. Recheck permission if needed.", true);
    } else if (hint?.status === "denied") {
      this.pushStatus("unknown", "Camera blocked. Check browser permission.", true);
    } else {
      this.pushStatus("unknown", null, false);
    }
  },

  pushFallbackStatus() {
    const hint = this.readStoredStatus();

    if (!hint) {
      this.pushStatus("unknown", null, false);
      return;
    }

    const fallbackMessage =
      hint.status === "granted"
        ? "Camera ready. Recheck permission if needed."
        : hint.status === "denied"
          ? "Camera blocked. Check browser permission."
          : this.defaultMessage(hint.status);

    this.pushStatus(hint.status === "unsupported" ? "unsupported" : "unknown", fallbackMessage, true);
  },

  handleCameraRequest(event) {
    const trigger = event.target.closest("[data-camera-request], [data-camera-recheck]");

    if (!trigger) {
      return;
    }

    event.preventDefault();
    this.requestCameraPermission(trigger.hasAttribute("data-camera-recheck"));
  },

  async requestCameraPermission(syncFirst = false) {
    if (!this.cameraSupported()) {
      this.reportStatus("unsupported", "Camera unavailable. Use manual entry.");
      return;
    }

    if (syncFirst) {
      await this.syncPermissionState();
    }

    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: { ideal: "environment" } },
        audio: false,
      });

      stream.getTracks().forEach((track) => track.stop());
      this.reportStatus("granted", "Camera ready.");
      window.dispatchEvent(new CustomEvent("fastcheck:camera-permission-granted"));
      window.dispatchEvent(new CustomEvent("fastcheck:camera-permission-refresh"));
    } catch (error) {
      const deniedErrors = ["NotAllowedError", "PermissionDeniedError"];
      const status = deniedErrors.includes(error?.name) ? "denied" : "error";
      const fallback =
        status === "denied"
          ? "Camera blocked. Check browser permission."
          : "Camera error.";

      this.reportStatus(status, error?.message || fallback);
      window.dispatchEvent(new CustomEvent("fastcheck:camera-permission-refresh"));
    }
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
      const stored = window.localStorage?.getItem(this.storageKey);

      if (!stored) {
        return null;
      }

      const parsed = JSON.parse(stored);

      if (parsed && typeof parsed.status === "string") {
        return parsed;
      }

      if (typeof parsed === "string") {
        return { status: parsed };
      }

      return null;
    } catch (_error) {
      try {
        const legacyValue = window.localStorage?.getItem(this.storageKey);
        return legacyValue ? { status: legacyValue } : null;
      } catch (_fallbackError) {
        return null;
      }
    }
  },

  writeStoredStatus(status) {
    try {
      window.localStorage?.setItem(
        this.storageKey,
        JSON.stringify({
          status,
          checked_at: new Date().toISOString(),
        }),
      );
      return true;
    } catch (_error) {
      return false;
    }
  },

  defaultMessage(status) {
    switch (status) {
      case "granted":
        return "Camera ready.";
      case "denied":
        return "Camera blocked. Check browser permission.";
      case "error":
        return "Camera error.";
      case "unsupported":
        return "Camera unavailable. Use manual entry.";
      default:
        return "Check camera permission.";
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

  playWarning() {
    if (!this.enabled) return;
    this.playTone(520, 0.12, 0.08);
    setTimeout(() => {
      this.playTone(520, 0.12, 0.08);
    }, 150);
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
    if (enabled) {
      this.el.textContent = "Sound on";
      this.el.setAttribute("aria-label", "Disable sound feedback");
      this.el.dataset.soundEnabled = "true";
    } else {
      this.el.textContent = "Sound off";
      this.el.setAttribute("aria-label", "Enable sound feedback");
      this.el.dataset.soundEnabled = "false";
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
    if (event.detail.sound === "success") {
      SoundFeedback.playSuccess();
    } else if (event.detail.sound === "warning") {
      SoundFeedback.playWarning();
    } else if (event.detail.sound === "error") {
      SoundFeedback.playError();
    } else if (event.detail.status === "success" || event.detail.status === "accepted") {
      SoundFeedback.playSuccess();
    } else if (
      event.detail.status === "warning" ||
      event.detail.status === "already_used" ||
      event.detail.status === "already_inside" ||
      event.detail.status === "busy_retry"
    ) {
      SoundFeedback.playWarning();
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
