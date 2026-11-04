
/* ==========================================
   PFLS TRADER - COMMUNICATION BRIDGE
   Version 1.0
   Cloudflare Worker status integration
   READ ONLY - NO TRADE EXECUTION
========================================== */

(() => {
  "use strict";

  const BRIDGE_URL =
    "https://pfls-communication-bridge-v2.dlamininjabulombhodziya.workers.dev";

  const STATUS_URL =
    BRIDGE_URL + "/api/dashboard/status";

  const POLL_INTERVAL = 15000;

  let monitor;
  let checking = false;

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
      <p id="pflsBridgeStatus">Checking Cloudflare bridge...</p>
      <p id="pflsStorageStatus">Storage: Checking...</p>
      <p id="pflsHeartbeatStatus">EA heartbeat: Waiting...</p>
      <p id="pflsTerminalStatus">MT5 terminal: Not confirmed</p>
      <small id="pflsBridgeUpdated">Waiting for first response.</small>
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
      "pflsBridgeUpdated",
      message
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

      updateText(
        "pflsHeartbeatStatus",
        "EA heartbeat: " +
          (data.ea_heartbeat_received
            ? "RECEIVED"
            : "WAITING")
      );

      updateText(
        "pflsTerminalStatus",
        "MT5 terminal: " +
          (data.heartbeat &&
           data.heartbeat.terminal_connected
            ? "CONNECTED (reported by EA)"
            : "NOT CONFIRMED")
      );

      updateText(
        "pflsBridgeUpdated",
        "Last checked: " +
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
    monitor = createMonitor();

    if (!monitor) {
      console.error(
        "PFLS execution panel was not found."
      );
      return;
    }

    checkBridge();

    window.setInterval(
      checkBridge,
      POLL_INTERVAL
    );

    console.log(
      "PFLS Communication Bridge monitor started."
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
