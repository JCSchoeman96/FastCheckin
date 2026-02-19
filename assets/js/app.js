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
