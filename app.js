
/* ==========================================
   PFLS TRADER v1.40
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
   - Confirmed HH/HL and LH/LL observations
   - Lower dashboard intelligence
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
    chartTitle: $("chartTitle"),

    zoneFilter: $("zoneFilter"),
    confluenceFilter: $("confluenceFilter"),

    structureTf: $("structureTf"),
    syncStructureTf: $("syncStructureTf"),
    marketDirection: $("marketDirection"),
    structureState: $("structureState"),
    structureTimeframe: $("structureTimeframe"),

    confluenceCount: $("confluenceCount"),
    confluenceSummary: $("confluenceSummary"),
    confluenceRows: $("confluenceRows"),

    eaConnectionStatus: $("eaConnectionStatus")
  };

  let socket = null;
  let currentPrice = null;

  let selectedTimeframe = elements.timeframe
    ? elements.timeframe.value
    : "1m";

  let selectedStructureTimeframe = elements.structureTf
    ? elements.structureTf.value
    : selectedTimeframe;

  let requestCounter = 100;

  const marketData = {};
  const requestMap = {};

  let latestZones = [];
  let latestConfluences = [];

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
    return tf ? tf.label : String(id).toUpperCase();
  }

  function createCell(row, value, className = "") {
    const cell = document.createElement("td");
    cell.textContent = value;

    if (className) {
      cell.className = className;
    }

    row.appendChild(cell);
    return cell;
  }

  function showEmptyRow(container, message, columns = 1) {
    if (!container) return;

    container.innerHTML = "";

    const row = document.createElement("div");
    row.className = "empty-row";
    row.textContent = message;

    if (columns > 1) {
      row.style.gridColumn = "1 / -1";
    }

    container.appendChild(row);
  }

  /* ==========================================
     DERIV CONNECTION
  ========================================== */

  function connectMarket() {
    if (
      socket &&
      socket.readyState === WebSocket.OPEN
    ) {
      socket.close();
    }

    if (
      socket &&
      socket.readyState === WebSocket.CONNECTING
    ) {
      return;
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
          last.high = Math.max(last.high, price);
          last.low = Math.min(last.low, price);

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

    for (let i = 10; i < data.length - 2; i++) {
      const base = data[i];
      const impulse = data[i + 1];

      const baseRange = base.high - base.low;

      if (baseRange <= 0) continue;

      const recentRanges = data
        .slice(i - 10, i)
        .map(candle => candle.high - candle.low)
        .filter(range => range > 0);

      const averageRange = average(recentRanges);

      if (!averageRange) continue;

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

      let invalidated = false;
      let touches = 0;
      let wasInside = false;

      for (let j = i + 2; j < data.length; j++) {
        const candle = data[j];

        if (
          candidate.type === "Demand" &&
          candle.close < candidate.low
        ) {
          invalidated = true;
          break;
        }

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

      const impulseScore = Math.min(
        35,
        Math.max(0, (candidate.impulseRatio - 1) * 20)
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

      zone.status = currentPrice !== null
        ? getZoneStatus(zone, currentPrice)
        : "WAITING";

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
        detectZones(getSeries(tf.id), tf.id)
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
      return { demand: null, supply: null };
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
    const validZones = zones.filter(zone => !zone.invalidated);

    validZones.forEach((zone, index) => {
      const matches = validZones.filter((other, otherIndex) => {
        if (index === otherIndex) return false;
        if (zone.type !== other.type) return false;
        if (zone.timeframe === other.timeframe) return false;

        return (
          zone.low <= other.high &&
          other.low <= zone.high
        );
      });

      if (!matches.length) return;

      const members = [zone, ...matches];

      const uniqueTimeframes = [
        ...new Set(members.map(item => item.timeframe))
      ];

      const commonLow = Math.max(
        ...members.map(item => item.low)
      );

      const commonHigh = Math.min(
        ...members.map(item => item.high)
      );

      if (commonLow > commonHigh) return;

      const key = [
        zone.type,
        uniqueTimeframes.sort().join(","),
        commonLow.toFixed(4),
        commonHigh.toFixed(4)
      ].join("|");

      if (results.some(item => item.key === key)) {
        return;
      }

      results.push({
        key,
        type: zone.type,
        low: commonLow,
        high: commonHigh,
        timeframes: uniqueTimeframes,
        count: uniqueTimeframes.length
      });
    });

    return results.sort((a, b) => b.count - a.count);
  }

  function getZoneConfluenceCount(zone, confluences) {
    let highest = 1;

    confluences.forEach(group => {
      const overlaps =
        zone.low <= group.high &&
        group.low <= zone.high;

      if (
        group.type === zone.type &&
        group.timeframes.includes(zone.timeframe) &&
        overlaps
      ) {
        highest = Math.max(highest, group.count);
      }
    });

    return highest;
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
        " · " + nearest.demand.status +
        " · " + nearest.demand.touches + " touches"
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
        " · " + nearest.supply.status +
        " · " + nearest.supply.touches + " touches"
      );

    } else {
      setText(elements.supply, "No candidate found");
      setText(elements.supplyMeta, "Awaiting a qualifying zone");
    }

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
     ZONE TABLE AND FILTERS
  ========================================== */

  function renderZoneTable(zones) {
    if (!elements.zones) return;

    elements.zones.innerHTML = "";

    const typeFilter = elements.zoneFilter
      ? elements.zoneFilter.value
      : "all";

    const minimumConfluence = elements.confluenceFilter
      ? Number(elements.confluenceFilter.value)
      : 1;

    let sorted = zones
      .filter(zone => currentPrice !== null)
      .map(zone => ({
        ...zone,
        distance: getZoneDistance(zone, currentPrice),
        confluenceCount: getZoneConfluenceCount(
          zone,
          latestConfluences
        )
      }));

    if (typeFilter !== "all") {
      sorted = sorted.filter(zone =>
        zone.type === typeFilter
      );
    }

    if (minimumConfluence > 1) {
      sorted = sorted.filter(zone =>
        zone.confluenceCount >= minimumConfluence
      );
    }

    sorted.sort((a, b) => a.distance - b.distance);

    setText(
      elements.zoneCount,
      zones.length + " candidates · " +
      sorted.length + " shown"
    );

    sorted = sorted.slice(0, 25);

    if (!sorted.length) {
      const row = document.createElement("tr");
      const cell = document.createElement("td");

      cell.colSpan = 6;
      cell.className = "empty-row";
      cell.textContent = currentPrice === null
        ? "Waiting for live market price."
        : "No zones match the selected filters.";

      row.appendChild(cell);
      elements.zones.appendChild(row);
      return;
    }

    sorted.forEach(zone => {
      const row = document.createElement("tr");

      createCell(
        row,
        zone.type,
        zone.type === "Demand"
          ? "type-demand"
          : "type-supply"
      );

      createCell(row, getTimeframeLabel(zone.timeframe));

      createCell(
        row,
        formatPrice(zone.low) + " – " + formatPrice(zone.high)
      );

      createCell(row, formatPrice(zone.distance));

      createCell(row, zone.status);

      createCell(
        row,
        zone.score + "/100 · " +
        zone.confluenceCount + " TF"
      );

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

      item.append(heading, direction, small);

      if (tf.id === selectedTimeframe) {
        item.style.outline = "1px solid #23c58e";
      }

      elements.ladder.appendChild(item);
    });
  }

  /* ==========================================
     CONFIRMED MARKET STRUCTURE
     HH + HL = BULLISH
     LH + LL = BEARISH
  ========================================== */

  function findConfirmedPivots(series, strength = 2) {
    const highs = [];
    const lows = [];

    if (series.length < strength * 2 + 10) {
      return { highs, lows };
    }

    for (
      let i = strength;
      i < series.length - strength;
      i++
    ) {
      const candle = series[i];

      let isHigh = true;
      let isLow = true;

      for (let j = 1; j <= strength; j++) {
        if (
          candle.high <= series[i - j].high ||
          candle.high <= series[i + j].high
        ) {
          isHigh = false;
        }

        if (
          candle.low >= series[i - j].low ||
          candle.low >= series[i + j].low
        ) {
          isLow = false;
        }
      }

      if (isHigh) {
        highs.push({
          price: candle.high,
          epoch: candle.epoch
        });
      }

      if (isLow) {
        lows.push({
          price: candle.low,
          epoch: candle.epoch
        });
      }
    }

    return { highs, lows };
  }

  function analyseStructure(timeframe) {
    const series = getSeries(timeframe);

    if (series.length < 15) {
      return {
        bias: "UNAVAILABLE",
        direction: "AWAITING DATA",
        message: "Waiting for sufficient completed candle history.",
        highs: [],
        lows: []
      };
    }

    const recent = series.slice(-12);
    const first = recent[0];
    const last = recent[recent.length - 1];

    let direction = "SIDEWAYS";

    if (last.close > first.close) {
      direction = "UPWARD";

    } else if (last.close < first.close) {
      direction = "DOWNWARD";
    }

    const pivots = findConfirmedPivots(series, 2);

    if (
      pivots.highs.length < 2 ||
      pivots.lows.length < 2
    ) {
      return {
        bias: "UNCONFIRMED",
        direction,
        message:
          "Price direction is " + direction.toLowerCase() +
          ", but there are not yet enough confirmed swing highs " +
          "and swing lows to classify market structure.",
        highs: pivots.highs,
        lows: pivots.lows
      };
    }

    const previousHigh =
      pivots.highs[pivots.highs.length - 2];

    const latestHigh =
      pivots.highs[pivots.highs.length - 1];

    const previousLow =
      pivots.lows[pivots.lows.length - 2];

    const latestLow =
      pivots.lows[pivots.lows.length - 1];

    const higherHigh =
      latestHigh.price > previousHigh.price;

    const higherLow =
      latestLow.price > previousLow.price;

    const lowerHigh =
      latestHigh.price < previousHigh.price;

    const lowerLow =
      latestLow.price < previousLow.price;

    let bias = "NEUTRAL";
    let message =
      "Structure is mixed or unclear. Wait for a clearer sequence.";

    if (higherHigh && higherLow) {
      bias = "BULLISH";
      message =
        "Confirmed bullish structure: the latest swing high is " +
        "higher and the latest swing low is higher (HH + HL).";

    } else if (lowerHigh && lowerLow) {
      bias = "BEARISH";
      message =
        "Confirmed bearish structure: the latest swing high is " +
        "lower and the latest swing low is lower (LH + LL).";

    } else if (higherHigh || higherLow || lowerHigh || lowerLow) {
      message =
        "Mixed structure: some swings are progressing, but the " +
        "complete HH + HL or LH + LL sequence is not confirmed.";
    }

    return {
      bias,
      direction,
      message,
      highs: pivots.highs,
      lows: pivots.lows,
      latestHigh,
      previousHigh,
      latestLow,
      previousLow
    };
  }

  /* ==========================================
     MARKET CONTEXT PANEL
  ========================================== */

  function renderStructure(zones) {
    const timeframe = selectedStructureTimeframe;
    const result = analyseStructure(timeframe);

    setText(
      elements.marketDirection,
      result.direction
    );

    setText(
      elements.structureState,
      result.bias
    );

    setText(
      elements.structureTimeframe,
      getTimeframeLabel(timeframe)
    );

    setText(
      elements.structure,
      result.message
    );

    if (elements.marketDirection) {
      elements.marketDirection.classList.remove(
        "up",
        "down"
      );

      if (result.direction === "UPWARD") {
        elements.marketDirection.classList.add("up");
      }

      if (result.direction === "DOWNWARD") {
        elements.marketDirection.classList.add("down");
      }
    }

    if (elements.structureState) {
      elements.structureState.classList.remove(
        "up",
        "down"
      );

      if (result.bias === "BULLISH") {
        elements.structureState.classList.add("up");
      }

      if (result.bias === "BEARISH") {
        elements.structureState.classList.add("down");
      }
    }

    const relevant = zones.filter(zone =>
      zone.timeframe === timeframe
    );

    const matchingConfluences = latestConfluences.filter(item =>
      item.timeframes.includes(timeframe)
    );

    if (elements.structure) {
      elements.structure.dataset.zoneCount = String(relevant.length);
      elements.structure.dataset.confluenceCount =
        String(matchingConfluences.length);
    }
  }

  /* ==========================================
     MTZC CONFLUENCE PANEL
  ========================================== */

  function renderConfluence(zones) {
    if (!elements.confluenceRows) return;

    const groups = latestConfluences;

    setText(
      elements.confluenceCount,
      groups.length + " overlap groups"
    );

    setText(
      elements.confluenceSummary,
      groups.length
        ? groups.length + " overlapping zone groups detected across " +
          "multiple timeframes. These are research candidates, " +
          "not trade signals."
        : "No overlapping multi-timeframe zone groups detected yet."
    );

    elements.confluenceRows.innerHTML = "";

    if (!groups.length) {
      showEmptyRow(
        elements.confluenceRows,
        zones.length
          ? "No qualifying overlaps between different timeframes."
          : "Waiting for qualifying zones.",
        1
      );
      return;
    }

    groups.slice(0, 12).forEach(group => {
      const item = document.createElement("div");
      item.className = "confluence-item";

      const main = document.createElement("div");

      const title = document.createElement("strong");
      title.textContent =
        group.type + " · " + group.count + " timeframes";

      const detail = document.createElement("small");
      detail.textContent =
        group.timeframes
          .map(getTimeframeLabel)
          .join(" + ");

      main.append(title, detail);

      const range = document.createElement("span");
      range.textContent =
        formatPrice(group.low) + " – " +
        formatPrice(group.high);

      item.append(main, range);
      elements.confluenceRows.appendChild(item);
    });
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
        data.length >= 2 ? "none" : "grid";
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

    ctx.strokeStyle = "rgba(150,170,190,0.15)";
    ctx.lineWidth = 1;

    for (let i = 1; i <= 4; i++) {
      const gy = height * i / 5;

      ctx.beginPath();
      ctx.moveTo(0, gy);
      ctx.lineTo(width, gy);
      ctx.stroke();
    }

    zones
      .filter(zone => zone.timeframe === selectedTimeframe)
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

    const gap = (width - 20) / data.length;
    const candleWidth = Math.max(2, gap * 0.58);

    data.forEach((candle, index) => {
      const x = 10 + index * gap + gap / 2;

      const bullish = candle.close >= candle.open;

      const candleColor = bullish
        ? "#23c58e"
        : "#ef5965";

      ctx.strokeStyle = candleColor;
      ctx.fillStyle = candleColor;
      ctx.lineWidth = 1.2;

      ctx.beginPath();
      ctx.moveTo(x, y(candle.high));
      ctx.lineTo(x, y(candle.low));
      ctx.stroke();

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

    latestZones = zones;
    latestConfluences = detectConfluence(zones);

    renderChart(zones);
    renderZoneSummary(zones);
    renderZoneTable(zones);
    renderLadder();
    renderStructure(zones);
    renderConfluence(zones);

    if (elements.chartTitle) {
      elements.chartTitle.textContent =
        "Volatility 75 · " +
        getTimeframeLabel(selectedTimeframe);
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

  function changeStructureTimeframe(value) {
    if (!TIMEFRAMES.some(tf => tf.id === value)) {
      return;
    }

    selectedStructureTimeframe = value;

    renderStructure(latestZones);
  }

  function syncStructureToChart() {
    selectedStructureTimeframe = selectedTimeframe;

    if (elements.structureTf) {
      elements.structureTf.value = selectedTimeframe;
    }

    renderStructure(latestZones);
  }

  function refreshZoneFilters() {
    renderZoneTable(latestZones);
  }

  /* ==========================================
     EVENT LISTENERS
  ========================================== */

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

  if (elements.structureTf) {
    elements.structureTf.addEventListener(
      "change",
      event => changeStructureTimeframe(event.target.value)
    );
  }

  if (elements.syncStructureTf) {
    elements.syncStructureTf.addEventListener(
      "click",
      syncStructureToChart
    );
  }

  if (elements.zoneFilter) {
    elements.zoneFilter.addEventListener(
      "change",
      refreshZoneFilters
    );
  }

  if (elements.confluenceFilter) {
    elements.confluenceFilter.addEventListener(
      "change",
      refreshZoneFilters
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

  setText(
    elements.eaConnectionStatus,
    "NOT CONNECTED"
  );

  renderEverything();

  console.log(
    "PFLS Trader v1.40 loaded.",
    "Market:", SYMBOL,
    "| Timeframes:", TIMEFRAMES.length,
    "| Mode: READ ONLY",
    "| EA connection: NOT CONNECTED"
  );

})();
