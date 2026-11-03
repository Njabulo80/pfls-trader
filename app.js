
/* ==========================================
   PFLS TRADER v1.30
   Price Flow Ladder Sequence

   Market: Deriv Volatility 75
   Symbol: R_75

   RESEARCH BUILD
   - Public market data
   - Eight timeframe analysis
   - Experimental supply/demand detection
   - Nearest-zone calculations
   - Zone interaction states
   - Multi-timeframe zone confluence
   - No automatic trade execution
========================================== */

(() => {
  "use strict";

  const SYMBOL = "R_75";

  const WS_URL =
    "wss://api.derivws.com/trading/v1/options/ws/public";

  const TIMEFRAMES = [
    { id: "1w", label: "1W", seconds: 604800, source: 86400 },
    { id: "1d", label: "1D", seconds: 86400, source: 86400 },
    { id: "4h", label: "4H", seconds: 14400, source: 14400 },
    { id: "1h", label: "1H", seconds: 3600, source: 3600 },
    { id: "30m", label: "30M", seconds: 1800, source: 1800 },
    { id: "15m", label: "15M", seconds: 900, source: 900 },
    { id: "5m", label: "5M", seconds: 300, source: 300 },
    { id: "1m", label: "1M", seconds: 60, source: 60 }
  ];

  const $ = id => document.getElementById(id);

  const elements = {
    connect: $("connectBtn"),
    refresh: $("refreshBtn"),
    timeframe: $("chartTf"),
    status: $("connection"),
    chart: $("chart"),
    empty: $("chartEmpty"),
    price: $("price"),
    priceChange: $("priceChange"),
    demand: $("nearestDemand"),
    demandMeta: $("demandMeta"),
    supply: $("nearestSupply"),
    supplyMeta: $("supplyMeta"),
    opposing: $("nextTarget"),
    targetMeta: $("targetMeta"),
    ladder: $("tfGrid"),
    zones: $("zoneRows"),
    zoneCount: $("zoneCount"),
    structure: $("structure"),
    chartTitle: $("chartTitle")
  };

  let socket = null;
  let currentPrice = null;

  let selectedTimeframe = elements.timeframe
    ? elements.timeframe.value
    : "1m";

  let requestCounter = 100;

  const marketData = {};
  const requestMap = {};

  TIMEFRAMES.forEach(tf => {
    marketData[tf.id] = [];
  });

  /* ==========================================
     BASIC HELPERS
  ========================================== */

  function setText(element, value) {
    if (element) {
      element.textContent = value;
    }
  }

  function setStatus(message, online = false) {
    if (!elements.status) return;

    elements.status.textContent = "● " + message;

    elements.status.classList.toggle("online", online);
    elements.status.classList.toggle("offline", !online);
  }

  function send(payload) {
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      return false;
    }

    socket.send(JSON.stringify(payload));
    return true;
  }

  function getSeries(timeframe) {
    return marketData[timeframe] || [];
  }

  function formatPrice(value) {
    return Number(value).toFixed(2);
  }

  function average(values) {
    if (!values.length) return 0;

    return values.reduce((sum, value) => sum + value, 0) /
      values.length;
  }

  function getTimeframeLabel(id) {
    const tf = TIMEFRAMES.find(item => item.id === id);
    return tf ? tf.label : id.toUpperCase();
  }

  /* ==========================================
     DERIV CONNECTION
  ========================================== */

  function connectMarket() {
    if (socket) {
      socket.onclose = null;
      socket.close();
      socket = null;
    }

    setStatus("CONNECTING TO DERIV");

    try {
      socket = new WebSocket(WS_URL);
    } catch (error) {
      console.error("Connection error:", error);
      setStatus("CONNECTION FAILED");
      return;
    }

    socket.onopen = () => {
      setStatus("CONNECTED", true);

      requestAllTimeframes();

      send({
        ticks: SYMBOL,
        subscribe: 1,
        req_id: 2
      });
    };

    socket.onmessage = event => {
      let data;

      try {
        data = JSON.parse(event.data);
      } catch (error) {
        console.error("Invalid API response:", error);
        return;
      }

      if (data.error) {
        console.error("Deriv API error:", data.error);

        setStatus(
          "API ERROR: " + data.error.message
        );

        return;
      }

      handleMarketMessage(data);
    };

    socket.onerror = error => {
      console.error("WebSocket error:", error);
      setStatus("CONNECTION ERROR");
    };

    socket.onclose = () => {
      setStatus("DISCONNECTED");
    };
  }

  /* ==========================================
     REQUEST ALL TIMEFRAMES
  ========================================== */

  function requestAllTimeframes() {
    TIMEFRAMES.forEach(tf => {
      const reqId = ++requestCounter;

      requestMap[reqId] = tf.id;

      const sent = send({
        ticks_history: SYMBOL,
        style: "candles",
        granularity: tf.source,
        count: tf.id === "1w" ? 500 : 300,
        end: "latest",
        req_id: reqId
      });

      if (!sent) {
        delete requestMap[reqId];
      }
    });
  }

  /* ==========================================
     HANDLE MARKET MESSAGES
  ========================================== */

  function handleMarketMessage(data) {

    // Historical candle response
    if (
      data.msg_type === "candles" &&
      Array.isArray(data.candles)
    ) {
      const timeframe = requestMap[data.req_id];

      if (!timeframe) {
        console.warn("Unknown candle request:", data.req_id);
        return;
      }

      delete requestMap[data.req_id];

      marketData[timeframe] = data.candles
        .map(candle => ({
          epoch: Number(candle.epoch),
          open: Number(candle.open),
          high: Number(candle.high),
          low: Number(candle.low),
          close: Number(candle.close)
        }))
        .filter(candle =>
          Number.isFinite(candle.epoch) &&
          Number.isFinite(candle.open) &&
          Number.isFinite(candle.high) &&
          Number.isFinite(candle.low) &&
          Number.isFinite(candle.close)
        )
        .sort((a, b) => a.epoch - b.epoch);

      if (timeframe === "1d") {
        rebuildWeeklyCandles();
      }

      renderEverything();

      const loaded = TIMEFRAMES.filter(tf =>
        marketData[tf.id].length > 0
      ).length;

      setStatus(
        "CONNECTED · " + loaded + "/8 TIMEFRAMES",
        true
      );

      return;
    }

    // Live tick response
    if (data.msg_type === "tick" && data.tick) {
      updateLivePrice(data.tick);
    }
  }

  /* ==========================================
     WEEKLY CANDLE AGGREGATION
  ========================================== */

  function rebuildWeeklyCandles() {
    const daily = marketData["1d"];
    const groups = new Map();

    daily.forEach(candle => {
      const date = new Date(candle.epoch * 1000);

      const day = date.getUTCDay();
      const offset = (day + 6) % 7;

      const monday = new Date(date);

      monday.setUTCDate(
        date.getUTCDate() - offset
      );

      monday.setUTCHours(0, 0, 0, 0);

      const start = Math.floor(
        monday.getTime() / 1000
      );

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

        group.high = Math.max(
          group.high,
          candle.high
        );

        group.low = Math.min(
          group.low,
          candle.low
        );

        group.close = candle.close;
      }
    });

    marketData["1w"] = [...groups.values()];
  }

  /* ==========================================
     LIVE PRICE AND CANDLE UPDATES
  ========================================== */

  function updateLivePrice(tick) {
    const price = Number(tick.quote);
    const epoch = Number(tick.epoch);

    if (
      !Number.isFinite(price) ||
      !Number.isFinite(epoch)
    ) {
      return;
    }

    currentPrice = price;

    setText(elements.price, formatPrice(price));
    setText(elements.priceChange, "Live Deriv market quote");

    TIMEFRAMES
      .filter(tf => tf.id !== "1w")
      .forEach(tf => {
        const series = marketData[tf.id];

        if (!series.length) return;

        const start =
          Math.floor(epoch / tf.seconds) * tf.seconds;

        const last = series[series.length - 1];

        if (last.epoch === start) {
          last.close = price;

          last.high = Math.max(
            last.high,
            price
          );

          last.low = Math.min(
            last.low,
            price
          );

        } else if (start > last.epoch) {
          series.push({
            epoch: start,
            open: last.close,
            high: price,
            low: price,
            close: price
          });

          if (series.length > 500) {
            series.shift();
          }
        }
      });

    rebuildWeeklyCandles();
    renderEverything();
  }

  /* ==========================================
     ZONE INTERACTION STATUS
  ========================================== */

  function getZoneStatus(zone, price) {
    if (
      price >= zone.low &&
      price <= zone.high
    ) {
      return "INSIDE";
    }

    if (zone.type === "Demand") {

      if (price < zone.low) {
        return "BELOW ZONE";
      }

      return zone.touches > 0
        ? "DEPARTED"
        : "APPROACHING";
    }

    if (zone.type === "Supply") {

      if (price > zone.high) {
        return "ABOVE ZONE";
      }

      return zone.touches > 0
        ? "DEPARTED"
        : "APPROACHING";
    }

    return "UNKNOWN";
  }

  /* ==========================================
     EXPERIMENTAL ZONE DETECTION
  ========================================== */

  function detectZones(series, timeframe) {
    const zones = [];

    if (!series || series.length < 20) {
      return zones;
    }

    const data = series.slice(-180);

    // The final candle may still be forming.
    // Do not use it as an impulse confirmation.
    for (let i = 10; i < data.length - 2; i++) {

      const base = data[i];
      const previous = data[i - 1];
      const impulse = data[i + 1];

      const baseRange = base.high - base.low;

      if (baseRange <= 0) continue;

      const recentRanges = data
        .slice(i - 10, i)
        .map(candle => candle.high - candle.low)
        .filter(range => range > 0);

      const averageRange = average(recentRanges);

      if (!averageRange) continue;

      // Look for a relatively compact base candle.
      if (baseRange > averageRange * 1.5) {
        continue;
      }

      const impulseBody = Math.abs(
        impulse.close - impulse.open
      );

      if (impulseBody < averageRange * 1.15) {
        continue;
      }

      const bullish =
        impulse.close > impulse.open &&
        impulse.close > base.high;

      const bearish =
        impulse.close < impulse.open &&
        impulse.close < base.low;

      let candidate = null;

      if (bullish) {
        candidate = {
          type: "Demand",
          timeframe,
          low: base.low,
          high: Math.max(base.open, base.close),
          epoch: base.epoch,
          impulseRatio: impulseBody / averageRange
        };
      }

      if (bearish) {
        candidate = {
          type: "Supply",
          timeframe,
          low: Math.min(base.open, base.close),
          high: base.high,
          epoch: base.epoch,
          impulseRatio: impulseBody / averageRange
        };
      }

      if (!candidate) continue;

      if (candidate.high <= candidate.low) {
        continue;
      }

      // Examine candles formed after the zone.
      let invalidated = false;
      let touches = 0;
      let wasInside = false;

      for (
        let j = i + 2;
        j < data.length;
        j++
      ) {
        const candle = data[j];

        // Demand invalidation
        if (
          candidate.type === "Demand" &&
          candle.close < candidate.low
        ) {
          invalidated = true;
          break;
        }

        // Supply invalidation
        if (
          candidate.type === "Supply" &&
          candle.close > candidate.high
        ) {
          invalidated = true;
          break;
        }

        const overlaps =
          candle.high >= candidate.low &&
          candle.low <= candidate.high;

        if (overlaps && !wasInside) {
          touches++;
        }

        wasInside = overlaps;
      }

      if (invalidated) continue;

      // Experimental structural score.
      // This is NOT a probability of success.
      const impulseScore = Math.min(
        35,
        Math.max(
          0,
          (candidate.impulseRatio - 1) * 20
        )
      );

      const touchPenalty = Math.min(
        45,
        touches * 15
      );

      const score = Math.max(
        0,
        Math.min(
          95,
          Math.round(60 + impulseScore - touchPenalty)
        )
      );

      const zone = {
        ...candidate,
        touches,
        score,
        invalidated: false
      };

      if (currentPrice !== null) {
        zone.status = getZoneStatus(
          zone,
          currentPrice
        );
      } else {
        zone.status = "WAITING";
      }

      zones.push(zone);
    }

    return zones;
  }

  /* ==========================================
     COLLECT ALL TIMEFRAME ZONES
  ========================================== */

  function collectAllZones() {
    let zones = [];

    TIMEFRAMES.forEach(tf => {
      zones = zones.concat(
        detectZones(
          getSeries(tf.id),
          tf.id
        )
      );
    });

    return zones;
  }

  /* ==========================================
     DISTANCE TO ZONE
  ========================================== */

  function getZoneDistance(zone, price) {
    if (
      price >= zone.low &&
      price <= zone.high
    ) {
      return 0;
    }

    if (price < zone.low) {
      return zone.low - price;
    }

    return price - zone.high;
  }

  /* ==========================================
     NEAREST ZONE SELECTION
  ========================================== */

  function getNearestZones(zones) {
    if (currentPrice === null) {
      return {
        demand: null,
        supply: null
      };
    }

    const demandZones = zones
      .filter(zone => zone.type === "Demand")
      .map(zone => ({
        ...zone,
        distance: getZoneDistance(zone, currentPrice)
      }))
      .sort((a, b) => a.distance - b.distance);

    const supplyZones = zones
      .filter(zone => zone.type === "Supply")
      .map(zone => ({
        ...zone,
        distance: getZoneDistance(zone, currentPrice)
      }))
      .sort((a, b) => a.distance - b.distance);

    return {
      demand: demandZones[0] || null,
      supply: supplyZones[0] || null
    };
  }

  /* ==========================================
     MULTI-TIMEFRAME ZONE CONFLUENCE
     MTZC
  ========================================== */

  function detectConfluence(zones) {
    const results = [];

    const validZones = zones.filter(zone =>
      !zone.invalidated
    );

    validZones.forEach((zone, index) => {
      const matches = validZones.filter((other, otherIndex) => {

        if (index === otherIndex) return false;

        if (zone.type !== other.type) {
          return false;
        }

        if (zone.timeframe === other.timeframe) {
          return false;
        }

        return (
          zone.low <= other.high &&
          other.low <= zone.high
        );
      });

      if (!matches.length) return;

      const uniqueTimeframes = [
        ...new Set([
          zone.timeframe,
          ...matches.map(item => item.timeframe)
        ])
      ];

      results.push({
        type: zone.type,
        low: zone.low,
        high: zone.high,
        timeframes: uniqueTimeframes,
        count: uniqueTimeframes.length
      });
    });

    return results;
  }

  /* ==========================================
     ZONE SUMMARY
  ========================================== */

  function renderZoneSummary(zones) {
    const nearest = getNearestZones(zones);

    if (nearest.demand) {
      setText(
        elements.demand,
        formatPrice(nearest.demand.low) +
        " – " +
        formatPrice(nearest.demand.high)
      );

      setText(
        elements.demandMeta,
        getTimeframeLabel(nearest.demand.timeframe) +
        " · " +
        nearest.demand.status +
        " · " +
        nearest.demand.touches +
        " touches"
      );

    } else {
      setText(elements.demand, "No candidate found");
      setText(elements.demandMeta, "Awaiting a qualifying zone");
    }

    if (nearest.supply) {
      setText(
        elements.supply,
        formatPrice(nearest.supply.low) +
        " – " +
        formatPrice(nearest.supply.high)
      );

      setText(
        elements.supplyMeta,
        getTimeframeLabel(nearest.supply.timeframe) +
        " · " +
        nearest.supply.status +
        " · " +
        nearest.supply.touches +
        " touches"
      );

    } else {
      setText(elements.supply, "No candidate found");
      setText(elements.supplyMeta, "Awaiting a qualifying zone");
    }

    // The opposing zone is the nearest candidate
    // of the opposite type to the nearest zone.
    let opposing = null;

    if (nearest.demand && nearest.supply) {
      opposing = nearest.demand.distance <= nearest.supply.distance
        ? nearest.supply
        : nearest.demand;

    } else if (nearest.demand) {
      opposing = nearest.supply;

    } else if (nearest.supply) {
      opposing = nearest.demand;
    }

    setText(
      elements.opposing,
      opposing
        ? opposing.type + " · " +
          formatPrice(opposing.low) + " – " +
          formatPrice(opposing.high)
        : "Not determined"
    );

    setText(
      elements.targetMeta,
      "Nearest opposing candidate · Manual confirmation required"
    );
  }

  /* ==========================================
     ZONE TABLE
  ========================================== */

  function renderZoneTable(zones) {
    if (!elements.zones) return;

    elements.zones.innerHTML = "";

    const sorted = zones
      .filter(zone => currentPrice !== null)
      .map(zone => ({
        ...zone,
        distance: getZoneDistance(
          zone,
          currentPrice
        )
      }))
      .sort((a, b) => a.distance - b.distance)
      .slice(0, 25);

    setText(
      elements.zoneCount,
      zones.length + " zones"
    );

    if (!sorted.length) {
      const row = document.createElement("tr");
      const cell = document.createElement("td");

      cell.colSpan = 6;
      cell.className = "empty-row";
      cell.textContent = "No qualifying zones detected yet.";

      row.appendChild(cell);
      elements.zones.appendChild(row);

      return;
    }

    sorted.forEach(zone => {
      const row = document.createElement("tr");

      const values = [
        zone.type,
        getTimeframeLabel(zone.timeframe),
        formatPrice(zone.low) + " – " + formatPrice(zone.high),
        formatPrice(zone.distance),
        zone.status,
        zone.score + "/100*"
      ];

      values.forEach((value, index) => {
        const cell = document.createElement("td");

        cell.textContent = value;

        if (index === 0) {
          cell.className = zone.type === "Demand"
            ? "type-demand"
            : "type-supply";
        }

        row.appendChild(cell);
      });

      elements.zones.appendChild(row);
    });
  }

  /* ==========================================
     TIMEFRAME LADDER
  ========================================== */

  function renderLadder() {
    if (!elements.ladder) return;

    elements.ladder.innerHTML = "";

    TIMEFRAMES.forEach(tf => {
      const series = getSeries(tf.id);

      const item = document.createElement("div");
      item.className = "tf-card";

      const heading = document.createElement("b");
      heading.textContent = tf.label;

      const direction = document.createElement("span");
      const small = document.createElement("small");

      if (series.length >= 2) {
        const first = series[0];
        const last = series[series.length - 1];

        if (last.close > first.close) {
          direction.textContent = "↑ Bullish";
          item.classList.add("up");

        } else if (last.close < first.close) {
          direction.textContent = "↓ Bearish";
          item.classList.add("down");

        } else {
          direction.textContent = "→ Neutral";
        }

        small.textContent = series.length + " candles";

      } else {
        direction.textContent = "—";
        small.textContent = "Awaiting data";
      }

      item.append(
        heading,
        direction,
        small
      );

      if (tf.id === selectedTimeframe) {
        item.style.outline = "1px solid #23c58e";
      }

      elements.ladder.appendChild(item);
    });
  }

  /* ==========================================
     STRUCTURE OBSERVATION
  ========================================== */

  function renderStructure(zones) {
    const series = getSeries(selectedTimeframe);

    if (series.length < 12) {
      setText(
        elements.structure,
        "Waiting for sufficient candle history."
      );
      return;
    }

    const recent = series.slice(-12);

    const first = recent[0];
    const last = recent[recent.length - 1];

    let message;

    if (last.close > first.close) {
      message =
        "Recent price progression is upward. " +
        "Observe possible higher highs and higher lows.";

    } else if (last.close < first.close) {
      message =
        "Recent price progression is downward. " +
        "Observe possible lower highs and lower lows.";

    } else {
      message =
        "Recent price is relatively unchanged. " +
        "Observe the next structural development.";
    }

    const confluences = detectConfluence(zones);

    const relevant = confluences.filter(item =>
      item.timeframes.includes(selectedTimeframe)
    );

    message +=
      " MTZC overlaps detected on this timeframe: " +
      relevant.length + ".";

    setText(elements.structure, message);
  }

  /* ==========================================
     CANDLE CHART
  ========================================== */

  function renderChart(zones) {
    const canvas = elements.chart;

    if (!canvas) return;

    const ctx = canvas.getContext("2d");
    const rect = canvas.getBoundingClientRect();

    if (!rect.width || !rect.height) return;

    const ratio = window.devicePixelRatio || 1;

    canvas.width = Math.floor(rect.width * ratio);
    canvas.height = Math.floor(rect.height * ratio);

    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);

    const width = rect.width;
    const height = rect.height;

    ctx.clearRect(0, 0, width, height);

    const series = getSeries(selectedTimeframe);
    const data = series.slice(-65);

    if (elements.empty) {
      elements.empty.style.display =
        data.length >= 2 ? "none" : "block";
    }

    if (data.length < 2) return;

    const highest = Math.max(
      ...data.map(candle => candle.high)
    );

    const lowest = Math.min(
      ...data.map(candle => candle.low)
    );

    const spread = highest - lowest || 1;
    const padding = 18;

    const y = price =>
      height - padding -
      ((price - lowest) / spread) *
      (height - padding * 2);

    // Background grid
    ctx.strokeStyle = "rgba(150,170,190,0.15)";
    ctx.lineWidth = 1;

    for (let i = 1; i <= 4; i++) {
      const gy = height * i / 5;

      ctx.beginPath();
      ctx.moveTo(0, gy);
      ctx.lineTo(width, gy);
      ctx.stroke();
    }

    // Draw selected timeframe zones
    zones
      .filter(zone =>
        zone.timeframe === selectedTimeframe
      )
      .forEach(zone => {
        const top = y(zone.high);
        const bottom = y(zone.low);

        ctx.fillStyle = zone.type === "Demand"
          ? "rgba(35,197,142,0.12)"
          : "rgba(239,89,101,0.12)";

        ctx.fillRect(
          0,
          top,
          width,
          Math.max(2, bottom - top)
        );
      });

    // Candles
    const gap = (width - 20) / data.length;
    const candleWidth = Math.max(2, gap * 0.58);

    data.forEach((candle, index) => {
      const x = 10 + index * gap + gap / 2;

      const bullish =
        candle.close >= candle.open;

      const candleColor = bullish
        ? "#23c58e"
        : "#ef5965";

      ctx.strokeStyle = candleColor;
      ctx.fillStyle = candleColor;
      ctx.lineWidth = 1.2;

      // Wick
      ctx.beginPath();
      ctx.moveTo(x, y(candle.high));
      ctx.lineTo(x, y(candle.low));
      ctx.stroke();

      // Body
      const top = y(
        Math.max(candle.open, candle.close)
      );

      const bottom = y(
        Math.min(candle.open, candle.close)
      );

      ctx.fillRect(
        x - candleWidth / 2,
        top,
        candleWidth,
        Math.max(1, bottom - top)
      );
    });
  }

  /* ==========================================
     RENDER EVERYTHING
  ========================================== */

  function renderEverything() {
    const zones = collectAllZones();

    renderChart(zones);
    renderZoneSummary(zones);
    renderZoneTable(zones);
    renderLadder();
    renderStructure(zones);

    if (elements.chartTitle) {
      const tf = TIMEFRAMES.find(
        item => item.id === selectedTimeframe
      );

      elements.chartTitle.textContent =
        "Volatility 75 · " +
        (tf ? tf.label : selectedTimeframe);
    }
  }

  /* ==========================================
     USER CONTROLS
  ========================================== */

  function refreshAnalysis() {
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      setStatus("CONNECT BEFORE REFRESHING");
      return;
    }

    setStatus("REFRESHING MARKET HISTORY", true);

    requestAllTimeframes();
  }

  function changeTimeframe(value) {
    if (!TIMEFRAMES.some(tf => tf.id === value)) {
      return;
    }

    selectedTimeframe = value;
    renderEverything();
  }

  if (elements.connect) {
    elements.connect.addEventListener(
      "click",
      connectMarket
    );
  }

  if (elements.refresh) {
    elements.refresh.addEventListener(
      "click",
      refreshAnalysis
    );
  }

  if (elements.timeframe) {
    elements.timeframe.addEventListener(
      "change",
      event => changeTimeframe(event.target.value)
    );
  }

  window.addEventListener(
    "resize",
    () => renderEverything()
  );

  /* ==========================================
     INITIAL SCREEN
  ========================================== */

  setStatus("DISCONNECTED");

  renderEverything();

  console.log(
    "PFLS Trader v1.30 loaded.",
    "Market:", SYMBOL,
    "| Timeframes:", TIMEFRAMES.length,
    "| Mode: READ ONLY"
  );

})();
