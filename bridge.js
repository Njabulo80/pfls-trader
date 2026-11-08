
/* ==========================================
   PFLS TRADER - COMMUNICATION BRIDGE
   Version 1.3
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

  function getElement(id) {
    return document.getElementById(id);
  }

  function updateText(id, value) {
    const element = getElement(id);
    if (element) element.textContent = value;
  }

  function updateStatusClass(element, online) {
    if (!element) return;

    element.classList.remove("status-pending", "status-built");
    element.classList.add(
      online ? "status-built" : "status-pending"
    );
  }

  function createMonitor() {
    const panel = document.querySelector(".execution-panel");
    if (!panel) return null;

    let box = getElement("pflsBridgeMonitor");
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
      <small id="pflsBridgeUpdated">Waiting for first response.</small>
    `;

    const existing = panel.querySelector(".execution-message");

    if (existing) {
      panel.insertBefore(box, existing);
    } else {
      panel.appendChild(box);
    }

    return box;
  }

  function formatAge(milliseconds) {
    const ms = Number(milliseconds);

    if (!Number.isFinite(ms) || ms < 0) {
      return "Unknown";
    }

    const seconds = Math.floor(ms / 1000);

    if (seconds < 60) return seconds + " seconds ago";

    const minutes = Math.floor(seconds / 60);

    if (minutes < 60) return minutes + " minutes ago";

    return Math.floor(minutes / 60) + " hours ago";
  }

  function setMainStatus(connected, headline, description, safety) {
    updateText(
      "eaConnectionStatus",
      connected ? "HEARTBEAT CONNECTED" : "HEARTBEAT NOT VERIFIED"
    );

    updateStatusClass(
      getElement("eaConnectionStatus"),
      connected
    );

    updateText("pflsConnectionHeadline", headline);
    updateText("pflsConnectionDescription", description);
    updateText("pflsConnectionSafety", safety);

    updateText(
      "pflsHeartbeatModuleStatus",
      connected ? "HEARTBEAT CONNECTED" : "NOT VERIFIED"
    );

    updateStatusClass(
      getElement("pflsHeartbeatModuleStatus"),
      connected
    );
  }

  function showOffline(message) {
    updateText("pflsBridgeStatus", "Bridge: UNAVAILABLE");
    updateText("pflsStorageStatus", "Storage: NOT VERIFIED");
    updateText("pflsHeartbeatStatus", "EA heartbeat: NOT VERIFIED");
    updateText("pflsTerminalStatus", "MT5 terminal: NOT CONFIRMED");
    updateText("pflsHeartbeatAge", "Heartbeat age: Unknown");
    updateText("pflsBridgeUpdated", message);

    setMainStatus(
      false,
      "Cloudflare status could not be retrieved.",
      "The PWA could not retrieve the latest heartbeat response. This does not prove MT5 is disconnected.",
      "● MARKET RESEARCH ACTIVE · CONNECTION NOT VERIFIED · EA CONTROL DISABLED"
    );
  }

  function displayHeartbeat(data) {
    const heartbeat =
      data.heartbeat && typeof data.heartbeat === "object"
        ? data.heartbeat
        : null;

    const storageAvailable =
      data.storage_available === true;

    const age = Number(data.heartbeat_age_ms);

    const fresh =
      Number.isFinite(age) &&
      age >= 0 &&
      age <= HEARTBEAT_TIMEOUT;

    const eaOnline =
      data.ea_online === true &&
      data.ea_heartbeat_received === true &&
      fresh &&
      heartbeat !== null;

    const terminalConnected =
      eaOnline &&
      data.mt5_connected === true &&
      heartbeat.terminal_connected === true;

    const connected =
      storageAvailable &&
      eaOnline &&
      terminalConnected;

    updateText(
      "pflsBridgeStatus",
      "Bridge: ONLINE · Version " + (data.version || "Unknown")
    );

    updateText(
      "pflsStorageStatus",
      "Storage: " + (storageAvailable ? "AVAILABLE" : "UNAVAILABLE")
    );

    updateText(
      "pflsHeartbeatStatus",
      "EA heartbeat: " + (eaOnline ? "RECEIVED · ONLINE" : "NOT VERIFIED")
    );

    updateText(
      "pflsTerminalStatus",
      "MT5 terminal: " +
        (terminalConnected ? "CONNECTED (reported by EA)" : "NOT CONFIRMED")
    );

    updateText(
      "pflsEAVersion",
      "EA version: " + (heartbeat?.ea_version || "Unknown")
    );

    updateText(
      "pflsSymbol",
      "Trading symbol: " + (heartbeat?.symbol || "Unknown")
    );

    updateText(
      "pflsTimeframe",
      "EA timeframe: " + (heartbeat?.timeframe || "Unknown")
    );

    updateText(
      "pflsHeartbeatAge",
      "Heartbeat age: " + formatAge(data.heartbeat_age_ms)
    );

    const receivedAt = heartbeat?.received_at
      ? new Date(heartbeat.received_at)
      : null;

    updateText(
      "pflsHeartbeatTime",
      "Last heartbeat: " +
        (
          receivedAt && !Number.isNaN(receivedAt.getTime())
            ? receivedAt.toLocaleString()
            : "Unknown"
        )
    );

    updateText(
      "pflsBridgeUpdated",
      "Last checked: " + new Date().toLocaleTimeString()
    );

    if (connected) {
      setMainStatus(
        true,
        "EA heartbeat connection established.",
        "Cloudflare is receiving and storing recent heartbeat reports from EA " +
          heartbeat.ea_version +
          " on " +
          heartbeat.symbol +
          ". MT5 connectivity is reported by the EA. PWA access is read-only; remote trading commands are not implemented.",
        "● MARKET RESEARCH ACTIVE · EA HEARTBEAT CONNECTED · EA CONTROL DISABLED"
      );
    } else {
      const reasons = [];

      if (!storageAvailable) reasons.push("storage unavailable");
      if (!data.ea_heartbeat_received) reasons.push("heartbeat not received");
      if (data.ea_online !== true) reasons.push("EA not online");
      if (!fresh) reasons.push("heartbeat is stale or age is unavailable");
      if (!terminalConnected) reasons.push("terminal not confirmed");

      setMainStatus(
        false,
        "Heartbeat received, but full connection is not verified.",
        "Check: " + reasons.join("; ") +
          ". The bridge monitor shows the raw connection details above.",
        "● MARKET RESEARCH ACTIVE · CONNECTION PARTIALLY VERIFIED · EA CONTROL DISABLED"
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
        headers: { "Accept": "application/json" }
      });

      if (!response.ok) {
        throw new Error("HTTP " + response.status);
      }

      const data = await response.json();

      if (!data || data.service !== "PFLS Communication Bridge") {
        throw new Error("Invalid bridge response");
      }

      displayHeartbeat(data);

    } catch (error) {
      console.error("PFLS bridge check failed:", error);
      showOffline("Last check failed: " + error.message);

    } finally {
      checking = false;
    }
  }

  function start() {
    if (!createMonitor()) {
      console.error("PFLS execution panel was not found.");
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

    console.log("PFLS Communication Bridge v1.3 started. READ ONLY.");
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    start();
  }
})();
