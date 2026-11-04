
/* ==========================================
   PFLS TRADER - COMMUNICATION BRIDGE
   Version 1.1
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

  let checking = false;
  let monitorTimer = null;

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

  function updateText(id, value) {
    const element = document.getElementById(id);

    if (element) {
      element.textContent = value;
    }
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
      "EA heartbeat: Not verified"
    );

    updateText(
      "pflsTerminalStatus",
      "MT5 terminal: Not confirmed"
    );

    updateText(
      "pflsHeartbeatAge",
      "Heartbeat age: Unknown"
    );

    updateText(
      "pflsBridgeUpdated",
      message
    );
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

  function displayHeartbeat(data) {
    const heartbeat = data.heartbeat;

    if (!heartbeat) {
      updateText(
        "pflsHeartbeatStatus",
        "EA heartbeat: WAITING FOR FIRST HEARTBEAT"
      );

      updateText(
        "pflsTerminalStatus",
        "MT5 terminal: NOT CONFIRMED"
      );

      updateText(
        "pflsEAVersion",
        "EA version: Unknown"
      );

      updateText(
        "pflsSymbol",
        "Trading symbol: Unknown"
      );

      updateText(
        "pflsTimeframe",
        "EA timeframe: Unknown"
      );

      updateText(
        "pflsHeartbeatAge",
        "Heartbeat age: No heartbeat received"
      );

      updateText(
        "pflsHeartbeatTime",
        "Last heartbeat: None"
      );

      return;
    }

    const online = data.ea_online === true;

    updateText(
      "pflsHeartbeatStatus",
      "EA heartbeat: " +
        (online ? "ONLINE" : "STALE")
    );

    updateText(
      "pflsTerminalStatus",
      "MT5 terminal: " +
        (online && heartbeat.terminal_connected
          ? "CONNECTED (reported by EA)"
          : "NOT CONFIRMED")
    );

    updateText(
      "pflsEAVersion",
      "EA version: " +
        (heartbeat.ea_version || "Unknown")
    );

    updateText(
      "pflsSymbol",
      "Trading symbol: " +
        (heartbeat.symbol || "Unknown")
    );

    updateText(
      "pflsTimeframe",
      "EA timeframe: " +
        (heartbeat.timeframe || "Unknown")
    );

    updateText(
      "pflsHeartbeatAge",
      "Heartbeat age: " +
        formatAge(data.heartbeat_age_ms)
    );

    const receivedAt = heartbeat.received_at
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

      updateText(
        "pflsBridgeStatus",
        "Bridge: ONLINE · Version " + data.version
      );

      updateText(
        "pflsStorageStatus",
        "Storage: " +
          (data.storage_available
            ? "AVAILABLE"
            : "UNAVAILABLE")
      );

      displayHeartbeat(data);

      updateText(
        "pflsBridgeUpdated",
        "Dashboard updated: " +
          new Date().toLocaleTimeString()
      );

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
      "PFLS Communication Bridge v1.1 started."
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
