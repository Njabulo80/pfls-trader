
/* ==========================================
   PFLS TRADER - COMMUNICATION BRIDGE
   Version 1.2
   Cloudflare + MT5 heartbeat monitoring
   READ ONLY - NO TRADE EXECUTION
========================================== */

(() => {
  "use strict";

  const BRIDGE_URL =
    "https://pfls-communication-bridge-v2.dlamininjabulombhodziya.workers.dev";

  const STATUS_URL =
    BRIDGE_URL + "/api/dashboard/status";

  const POLL_INTERVAL = 15000;
  const HEARTBEAT_TIMEOUT = 90000;

  let checking = false;
  let monitorTimer = null;

  function updateText(id, value) {
    const element = document.getElementById(id);

    if (element) {
      element.textContent = value;
    }
  }

  function updateStatusClass(element, online) {
    if (!element) return;

    element.classList.remove(
      "status-pending",
      "status-built"
    );

    element.classList.add(
      online ? "status-built" : "status-pending"
    );
  }

  function createMonitor() {
    const panel = document.querySelector(".execution-panel");

    if (!panel) return null;

    let box = document.getElementById("pflsBridgeMonitor");

    if (box) return box;

    box = document.createElement("div");
    box.id = "pflsBridgeMonitor";
    box.className = "execution-message";

    box.style.marginTop = "16px";
    box.style.border = "1px solid rgba(80, 160, 200, 0.25)";

    box.innerHTML = `
      <strong>PFLS COMMUNICATION BRIDGE</strong>

      <p id="pflsBridgeStatus">Checking bridge...</p>
      <p id="pflsStorageStatus">Storage: Checking...</p>
      <p id="pflsHeartbeatStatus">EA heartbeat: Waiting...</p>
      <p id="pflsTerminalStatus">MT5 terminal: Not confirmed</p>

      <hr>

      <p id="pflsEAVersion">EA version: Unknown</p>
      <p id="pflsSymbol">Trading symbol: Unknown</p>
      <p id="pflsTimeframe">EA timeframe: Unknown</p>
      <p id="pflsHeartbeatAge">Heartbeat age: Unknown</p>
      <p id="pflsHeartbeatTime">Last heartbeat: Unknown</p>

      <small id="pflsBridgeUpdated">
        Waiting for first response.
      </small>
    `;

    const existingMessage =
      panel.querySelector(".execution-message");

    if (existingMessage) {
      panel.insertBefore(box, existingMessage);
    } else {
      panel.appendChild(box);
    }

    return box;
  }

  function formatAge(milliseconds) {
    if (
      typeof milliseconds !== "number" ||
      !Number.isFinite(milliseconds) ||
      milliseconds < 0
    ) {
      return "Unknown";
    }

    const seconds = Math.floor(milliseconds / 1000);

    if (seconds < 60) {
      return seconds + " seconds ago";
    }

    const minutes = Math.floor(seconds / 60);

    if (minutes < 60) {
      return minutes + " minutes ago";
    }

    const hours = Math.floor(minutes / 60);

    return hours + " hours ago";
  }

  function showOffline(message) {
    updateText(
      "pflsBridgeStatus",
      "Bridge: UNAVAILABLE"
    );

    updateText(
      "pflsStorageStatus",
      "Storage: Not verified"
    );

    updateText(
      "pflsHeartbeatStatus",
      "EA heartbeat: NOT VERIFIED"
    );

    updateText(
      "pflsTerminalStatus",
      "MT5 terminal: NOT CONFIRMED"
    );

    updateText(
      "pflsHeartbeatAge",
      "Heartbeat age: Unknown"
    );

    updateText(
      "pflsBridgeUpdated",
      message
    );

    updateText(
      "eaConnectionStatus",
      "CONNECTION UNAVAILABLE"
    );

    updateStatusClass(
      document.getElementById("eaConnectionStatus"),
      false
    );

    updateText(
      "pflsConnectionHeadline",
      "Cloudflare status could not be retrieved."
    );

    updateText(
      "pflsConnectionDescription",
      "The PWA could not verify the latest EA heartbeat. This does not prove that MT5 is disconnected."
    );

    updateText(
      "pflsConnectionSafety",
      "● MARKET RESEARCH ACTIVE · CONNECTION NOT VERIFIED · EA CONTROL DISABLED"
    );

    updateText(
      "pflsHeartbeatModuleStatus",
      "NOT VERIFIED"
    );

    updateStatusClass(
      document.getElementById("pflsHeartbeatModuleStatus"),
      false
    );
  }

  function displayHeartbeat(data) {
    const heartbeat = data.heartbeat || null;

    const storageAvailable =
      data.storage_available === true;

    const age = data.heartbeat_age_ms;

    const fresh =
      typeof age === "number" &&
      Number.isFinite(age) &&
      age >= 0 &&
      age <= HEARTBEAT_TIMEOUT;

    const eaOnline =
      data.ea_online === true &&
      fresh &&
      !!heartbeat;

    const terminalConnected =
      eaOnline &&
      data.mt5_connected === true &&
      heartbeat.terminal_connected === true;

    updateText(
      "pflsBridgeStatus",
      "Bridge: ONLINE · Version " +
        (data.version || "Unknown")
    );

    updateText(
      "pflsStorageStatus",
      "Storage: " +
        (storageAvailable ? "AVAILABLE" : "UNAVAILABLE")
    );

    updateText(
      "pflsHeartbeatStatus",
      "EA heartbeat: " +
        (eaOnline ? "RECEIVED · ONLINE" : "NOT ONLINE")
    );

    updateText(
      "pflsTerminalStatus",
      "MT5 terminal: " +
        (terminalConnected
          ? "CONNECTED (reported by EA)"
          : "NOT CONFIRMED")
    );

    updateText(
      "pflsHeartbeatAge",
      "Heartbeat age: " + formatAge(age)
    );

    updateText(
      "pflsEAVersion",
      "EA version: " +
        (heartbeat?.ea_version || "Unknown")
    );

    updateText(
      "pflsSymbol",
      "Trading symbol: " +
        (heartbeat?.symbol || "Unknown")
    );

    updateText(
      "pflsTimeframe",
      "EA timeframe: " +
        (heartbeat?.timeframe || "Unknown")
    );

    const receivedAt = heartbeat?.received_at
      ? new Date(heartbeat.received_at)
      : null;

    updateText(
      "pflsHeartbeatTime",
      "Last heartbeat: " +
        (
          receivedAt &&
          !Number.isNaN(receivedAt.getTime())
            ? receivedAt.toLocaleString()
            : "Unknown"
        )
    );

    updateText(
      "pflsBridgeUpdated",
      "Last checked: " +
        new Date().toLocaleTimeString()
    );

    if (eaOnline && terminalConnected && storageAvailable) {
      updateText(
        "eaConnectionStatus",
        "HEARTBEAT CONNECTED"
      );

      updateStatusClass(
        document.getElementById("eaConnectionStatus"),
        true
      );

      updateText(
        "pflsConnectionHeadline",
        "EA heartbeat connection established."
      );

      updateText(
        "pflsConnectionDescription",
        "Cloudflare is receiving and storing live heartbeat reports from EA " +
          (heartbeat.ea_version || "Unknown") +
          " on " +
          (heartbeat.symbol || "the reported symbol") +
          ". MT5 terminal connectivity is reported by the EA. The PWA has read-only status access; two-way EA control and trade commands are not implemented."
      );

      updateText(
        "pflsConnectionSafety",
        "● MARKET RESEARCH ACTIVE · EA HEARTBEAT CONNECTED · EA CONTROL DISABLED"
      );

      updateText(
        "pflsHeartbeatModuleStatus",
        "HEARTBEAT CONNECTED"
      );

      updateStatusClass(
        document.getElementById("pflsHeartbeatModuleStatus"),
        true
      );

    } else {
      updateText(
        "eaConnectionStatus",
        "HEARTBEAT NOT VERIFIED"
      );

      updateStatusClass(
        document.getElementById("eaConnectionStatus"),
        false
      );

      updateText(
        "pflsConnectionHeadline",
        "A current EA and MT5 heartbeat is not confirmed."
      );

      updateText(
        "pflsConnectionDescription",
        "Check that the EA is running, the terminal is connected and Cloudflare storage is available. The PWA only reads heartbeat status; two-way EA control is not implemented."
      );

      updateText(
        "pflsConnectionSafety",
        "● MARKET RESEARCH ACTIVE · HEARTBEAT NOT VERIFIED · EA CONTROL DISABLED"
      );

      updateText(
        "pflsHeartbeatModuleStatus",
        "NOT VERIFIED"
      );

      updateStatusClass(
        document.getElementById("pflsHeartbeatModuleStatus"),
        false
      );
    }
  }

  async function checkBridge() {
    if (checking) return;

    checking = true;

    try {
      const response = await fetch(STATUS_URL, {
        method: "GET",
        cache: "no-store",
        credentials: "omit",
        headers: {
          "Accept": "application/json"
        }
      });

      if (!response.ok) {
        throw new Error(
          "Bridge returned HTTP " + response.status
        );
      }

      const data = await response.json();

      if (
        !data ||
        data.service !== "PFLS Communication Bridge"
      ) {
        throw new Error("Invalid bridge response");
      }

      displayHeartbeat(data);

    } catch (error) {
      console.error(
        "PFLS bridge check failed:",
        error
      );

      showOffline(
        "Last check failed: " + error.message
      );

    } finally {
      checking = false;
    }
  }

  function start() {
    const monitor = createMonitor();

    if (!monitor) {
      console.error(
        "PFLS execution panel was not found."
      );
      return;
    }

    checkBridge();

    if (monitorTimer !== null) {
      window.clearInterval(monitorTimer);
    }

    monitorTimer = window.setInterval(
      checkBridge,
      POLL_INTERVAL
    );

    console.log(
      "PFLS Communication Bridge v1.2 started. READ ONLY."
    );
  }

  if (document.readyState === "loading") {
    document.addEventListener(
      "DOMContentLoaded",
      start,
      { once: true }
    );
  } else {
    start();
  }

})();
