
/*
  PFLS TRADER
  Price Flow Ladder Sequence
  Market: Deriv Volatility 75 Standard (R_75)

  Research prototype:
  - Reads public market data
  - Builds candles and timeframe analysis
  - Identifies heuristic supply/demand candidates
  - Does not execute trades
*/

(() => {
  "use strict";

  const SYMBOL = "R_75";
  const WS_URL = "wss://api.derivws.com/trading/v1/options/ws/public";

  const TIMEFRAMES = [
    { label: "1M", value: "1m", seconds: 60 },
    { label: "5M", value: "5m", seconds: 300 },
    { label: "15M", value: "15m", seconds: 900 },
    { label: "30M", value: "30m", seconds: 1800 },
    { label: "1H", value: "1h", seconds: 3600 },
    { label: "4H", value: "4h", seconds: 14400 },
    { label: "1D", value: "1d", seconds: 86400 },
    { label: "1W", value: "1w", seconds: 604800 }
  ];

  const $ = (id) => document.getElementById(id);

  const find = (...ids) => {
    for (const id of ids) {
      const element = $(id);
      if (element) return element;
    }
    return null;
  };

  const elements = {
    connect: find("connectBtn", "connectMarket", "connect"),
    refresh: find("refreshBtn", "refreshAnalysis", "refresh"),
    timeframe: find("timeframeSelect", "timeframe", "chartTimeframe"),
    status: find("connectionStatus", "connection-status", "status"),
    chart: find("chart", "priceChart"),
    empty: find("emptyState", "chartEmpty", "empty-state"),
    price: find("currentPrice", "marketPrice", "price"),
    demand: find("nearestDemand", "demandValue", "demand"),
    supply: find("nearestSupply", "supplyValue", "supply"),
    opposing: find("nextOpposing", "opposingZone"),
    ladder: find("tfGrid", "timeframeLadder", "ladder"),
    zones: find("zonesBody", "zonesTableBody", "zones"),
    structure: find("structureText", "marketStructure", "structure"),
    confirm: find("confirmBtn", "manualConfirm", "confirmTrade")
  };

  let socket = null;
  let candles = [];
  let currentPrice = null;
  let selectedTimeframe = "1m";
  let detectedZones = [];
  let latestTickTime = null;

  function setText(element, value) {
    if (element) element.textContent = value;
  }

  function setStatus(message) {
    setText(elements.status, message);
  }

  function timeframeInfo(value) {
    return TIMEFRAMES.find(item => item.value === value) || TIMEFRAMES[0];
  }

  function send(payload) {
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      setStatus("Not connected");
      return false;
    }

    socket.send(JSON.stringify(payload));
    return true;
  }

  function connectMarket() {
    if (socket && socket.readyState === WebSocket.OPEN) {
      socket.close();
    }

    setStatus("Connecting to Deriv...");

    try {
      socket = new WebSocket(WS_URL);
    } catch (error) {
      setStatus("Connection could not start");
      console.error(error);
      return;
    }

    socket.onopen = () => {
      setStatus("Connected — requesting market data");

      requestCandles();

      send({
        ticks: SYMBOL,
        subscribe: 1,
        req_id: 2
      });
    };

    socket.onmessage = (event) => {
      let data;

      try {
        data = JSON.parse(event.data);
      } catch (error) {
        console.error("Invalid server response", error);
        return;
      }

      if (data.error) {
        setStatus("API error: " + data.error.message);
        console.error("Deriv API error:", data.error);
        return;
      }

      if (data.msg_type === "history" && data.candles) {
        candles = data.candles.map(candle => ({
          epoch: Number(candle.epoch),
          open: Number(candle.open),
          high: Number(candle.high),
          low: Number(candle.low),
          close: Number(candle.close)
        }));

        candles.sort((a, b) => a.epoch - b.epoch);
        renderAnalysis();
        setStatus("Live market data connected");
      }

      if (data.msg_type === "tick" && data.tick) {
        updateFromTick(data.tick);
      }
    };

    socket.onerror = () => {
      setStatus("Connection error — check internet");
    };

    socket.onclose = () => {
      setStatus("Disconnected — tap Connect");
    };
  }

  function requestCandles() {
    const tf = timeframeInfo(selectedTimeframe);

    // Deriv supports daily candles up to 1 day.
    // Weekly candles are created from daily candles locally.
    const weekly = selectedTimeframe === "1w";

    send({
      ticks_history: SYMBOL,
      style: "candles",
      granularity: weekly ? 86400 : tf.seconds,
      count: weekly ? 500 : 350,
      end: "latest",
      req_id: 1
    });
  }

  function updateFromTick(tick) {
    const price = Number(tick.quote);
    const epoch = Number(tick.epoch);

    if (!Number.isFinite(price)) return;

    currentPrice = price;
    latestTickTime = epoch;

    setText(elements.price, price.toFixed(2));

    if (candles.length) {
      const tf = timeframeInfo(selectedTimeframe);
      const candleSeconds = selectedTimeframe === "1w"
        ? 604800
        : tf.seconds;

      const candleStart = Math.floor(epoch / candleSeconds) * candleSeconds;
      const last = candles[candles.length - 1];

      if (last && last.epoch === candleStart) {
        last.close = price;
        last.high = Math.max(last.high, price);
        last.low = Math.min(last.low, price);
      } else if (last && candleStart > last.epoch) {
        candles.push({
          epoch: candleStart,
          open: last.close,
          high: price,
          low: price,
          close: price
        });

        if (candles.length > 350) candles.shift();
      }

      renderAnalysis();
    }
  }

  function aggregateWeekly(dailyCandles) {
    const groups = new Map();

    dailyCandles.forEach(candle => {
      const date = new Date(candle.epoch * 1000);
      const day = date.getUTCDay();
      const mondayOffset = (day + 6) % 7;

      const monday = new Date(date);
      monday.setUTCDate(date.getUTCDate() - mondayOffset);
      monday.setUTCHours(0, 0, 0, 0);

      const start = Math.floor(monday.getTime() / 1000);

      if (!groups.has(start)) {
        groups.set(start, {
          epoch: start,
          open: candle.open,
          high: candle.high,
          low: candle.low,
          close: candle.close
        });
      } else {
        const group = groups.get(start);
        group.high = Math.max(group.high, candle.high);
        group.low = Math.min(group.low, candle.low);
        group.close = candle.close;
      }
    });

    return [...groups.values()];
  }

  function getAnalysisCandles() {
    if (selectedTimeframe === "1w") {
      return aggregateWeekly(candles);
    }
    return candles;
  }

  /*
    Experimental zone detector.

    It searches for a small candle/base followed by a
    relatively strong move away from that price area.

    This is a research heuristic, not proof of institutional
    orders, actual order flow, or future price direction.
  */
  function detectZones(data) {
    const zones = [];

    if (!data || data.length < 15) return zones;

    const recent = data.slice(-180);

    for (let i = 3; i < recent.length - 2; i++) {
      const base = recent[i];
      const before = recent[i - 1];
      const after = recent[i + 1];

      const range = base.high - base.low;
      if (range <= 0) continue;

      const body = Math.abs(base.close - base.open);
      const nextBody = Math.abs(after.close - after.open);

      const averageRange = recent
        .slice(Math.max(0, i - 10), i)
        .reduce((sum, candle) =>
          sum + (candle.high - candle.low), 0) / Math.min(i, 10);

      if (!averageRange || range > averageRange * 1.5) continue;

      const strongMove = nextBody > averageRange * 1.15;
      if (!strongMove) continue;

      const bullish = after.close > after.open;
      const bearish = after.close < after.open;

      if (bullish && after.close > base.high) {
        zones.push({
          type: "Demand",
          low: Math.min(base.low, before.low),
          high: Math.max(base.open, base.close),
          epoch: base.epoch,
          score: Math.min(95, Math.round(
            55 + (nextBody / averageRange) * 10
          ))
        });
      }

      if (bearish && after.close < base.low) {
        zones.push({
          type: "Supply",
          low: Math.min(base.open, base.close),
          high: Math.max(base.high, before.high),
          epoch: base.epoch,
          score: Math.min(95, Math.round(
            55 + (nextBody / averageRange) * 10
          ))
        });
      }
    }

    return zones;
  }

  function analyseZones() {
    const data = getAnalysisCandles();
    detectedZones = detectZones(data);

    if (currentPrice === null && data.length) {
      currentPrice = data[data.length - 1].close;
    }

    const demands = detectedZones
      .filter(zone => zone.type === "Demand" && zone.high < currentPrice)
      .sort((a, b) => b.high - a.high);

    const supplies = detectedZones
      .filter(zone => zone.type === "Supply" && zone.low > currentPrice)
      .sort((a, b) => a.low - b.low);

    const nearestDemand = demands[0];
    const nearestSupply = supplies[0];

    setText(elements.demand, nearestDemand
      ? `${nearestDemand.low.toFixed(2)} – ${nearestDemand.high.toFixed(2)}`
      : "No candidate found");

    setText(elements.supply, nearestSupply
      ? `${nearestSupply.low.toFixed(2)} – ${nearestSupply.high.toFixed(2)}`
      : "No candidate found");

    let opposing = null;

    if (nearestDemand) opposing = nearestSupply;
    else if (nearestSupply) opposing = nearestDemand;

    setText(elements.opposing, opposing
      ? `${opposing.type}: ${opposing.low.toFixed(2)} – ${opposing.high.toFixed(2)}`
      : "No opposing zone identified");

    renderZoneTable();
    renderLadder();
    renderStructure();
  }

  function renderZoneTable() {
    if (!elements.zones) return;

    elements.zones.innerHTML = "";

    const sorted = [...detectedZones].slice(-25).reverse();

    if (!sorted.length) {
      elements.zones.innerHTML =
        '<tr><td colspan="5">No candidate zones detected yet.</td></tr>';
      return;
    }

    sorted.forEach(zone => {
      const row = document.createElement("tr");

      const values = [
        zone.type,
        zone.low.toFixed(2),
        zone.high.toFixed(2),
        zone.score + "/100",
        new Date(zone.epoch * 1000).toLocaleString()
      ];

      values.forEach(value => {
        const cell = document.createElement("td");
        cell.textContent = value;
        row.appendChild(cell);
      });

      elements.zones.appendChild(row);
    });
  }

  function renderLadder() {
    if (!elements.ladder) return;

    elements.ladder.innerHTML = "";

    TIMEFRAMES.forEach(tf => {
      const item = document.createElement("div");
      item.className = "tf-item";

      const label = document.createElement("strong");
      label.textContent = tf.label;

      const detail = document.createElement("span");
      detail.textContent = selectedTimeframe === tf.value
        ? "Selected chart"
        : "Awaiting scan";

      item.append(label, detail);
      elements.ladder.appendChild(item);
    });
  }

  function renderStructure() {
    const data = getAnalysisCandles();

    if (data.length < 5) {
      setText(elements.structure, "Waiting for sufficient candle data.");
      return;
    }

    const recent = data.slice(-12);
    const first = recent[0];
    const last = recent[recent.length - 1];

    let message = "Structure is not yet classified.";

    if (last.close > first.close) {
      message = "Recent price progression is upward. Watch for higher highs and higher lows.";
    } else if (last.close < first.close) {
      message = "Recent price progression is downward. Watch for lower highs and lower lows.";
    }

    setText(elements.structure, message);
  }

  function renderChart() {
    const canvas = elements.chart;
    if (!canvas) return;

    const ctx = canvas.getContext("2d");
    const rect = canvas.getBoundingClientRect();

    if (!rect.width || !rect.height) return;

    const ratio = window.devicePixelRatio || 1;
    canvas.width = rect.width * ratio;
    canvas.height = rect.height * ratio;
    ctx.scale(ratio, ratio);

    const width = rect.width;
    const height = rect.height;

    ctx.clearRect(0, 0, width, height);

    const data = getAnalysisCandles().slice(-65);

    if (elements.empty) {
      elements.empty.style.display = data.length ? "none" : "block";
    }

    if (data.length < 2) return;

    const highest = Math.max(...data.map(c => c.high));
    const lowest = Math.min(...data.map(c => c.low));
    const spread = highest - lowest || 1;
    const padding = 15;

    const y = price =>
      height - padding - ((price - lowest) / spread) *
      (height - padding * 2);

    const candleWidth = Math.max(3, (width - 20) / data.length * 0.58);
    const gap = (width - 20) / data.length;

    // Grid
    ctx.strokeStyle = "rgba(150,170,190,0.13)";
    ctx.lineWidth = 1;

    for (let i = 1; i <= 4; i++) {
      const gy = (height / 5) * i;
      ctx.beginPath();
      ctx.moveTo(0, gy);
      ctx.lineTo(width, gy);
      ctx.stroke();
    }

    // Zone overlays
    detectedZones.forEach(zone => {
      const top = y(zone.high);
      const bottom = y(zone.low);

      ctx.fillStyle = zone.type === "Demand"
        ? "rgba(27,190,130,0.10)"
        : "rgba(235,75,85,0.10)";

      ctx.fillRect(0, top, width, Math.max(2, bottom - top));
    });

    // Candles
    data.forEach((candle, index) => {
      const x = 10 + index * gap + gap / 2;
      const bullish = candle.close >= candle.open;

      ctx.strokeStyle = bullish ? "#23c58e" : "#ef5965";
      ctx.fillStyle = bullish ? "#23c58e" : "#ef5965";
      ctx.lineWidth = 1.2;

      ctx.beginPath();
      ctx.moveTo(x, y(candle.high));
      ctx.lineTo(x, y(candle.low));
      ctx.stroke();

      const top = y(Math.max(candle.open, candle.close));
      const bottom = y(Math.min(candle.open, candle.close));

      ctx.fillRect(
        x - candleWidth / 2,
        top,
        candleWidth,
        Math.max(1, bottom - top)
      );
    });
  }

  function renderAnalysis() {
    analyseZones();
    renderChart();
  }

  function refreshAnalysis() {
    if (socket && socket.readyState === WebSocket.OPEN) {
      requestCandles();
    } else {
      setStatus("Connect to Deriv before refreshing");
    }
  }

  function changeTimeframe(value) {
    if (!TIMEFRAMES.some(tf => tf.value === value)) return;

    selectedTimeframe = value;
    renderLadder();

    if (socket && socket.readyState === WebSocket.OPEN) {
      requestCandles();
    } else {
      renderAnalysis();
    }
  }

  function manualConfirmation() {
    const message =
      "Manual review only. PFLS has not placed a trade. " +
      "Check the chart, zone boundaries, risk and your own trade plan.";

    alert(message);
  }

  if (elements.connect) {
    elements.connect.addEventListener("click", connectMarket);
  }

  if (elements.refresh) {
    elements.refresh.addEventListener("click", refreshAnalysis);
  }

  if (elements.timeframe) {
    selectedTimeframe = elements.timeframe.value || "1m";
    elements.timeframe.addEventListener("change", event => {
      changeTimeframe(event.target.value);
    });
  }

  if (elements.confirm) {
    elements.confirm.addEventListener("click", manualConfirmation);
  }

  window.addEventListener("resize", renderChart);

  // Initial screen
  setStatus("Not connected — tap Connect");
  renderLadder();
  renderChart();

  console.log("PFLS Trader prototype loaded for", SYMBOL);
})();
