import init, { WasmTokenizer } from "./pkg/delarocha.js";

const SAMPLE = "本とカレー 本X🍛カレー";

const state = {
  tokenizer: null,
  activeView: "tokens",
  tokens: [],
  wakati: "",
  json: "[]",
  dictionaryName: "ipadic",
};

const els = {
  statusDot: document.querySelector("#status-dot"),
  statusText: document.querySelector("#status-text"),
  input: document.querySelector("#input"),
  ignoreSpace: document.querySelector("#ignore-space"),
  maxGrouping: document.querySelector("#max-grouping"),
  sampleButton: document.querySelector("#sample-button"),
  tokenCount: document.querySelector("#token-count"),
  byteCount: document.querySelector("#byte-count"),
  elapsed: document.querySelector("#elapsed"),
  tokenStrip: document.querySelector("#token-strip"),
  tokenRows: document.querySelector("#token-rows"),
  wakatiOutput: document.querySelector("#wakati-output"),
  jsonOutput: document.querySelector("#json-output"),
  tabs: [...document.querySelectorAll(".tab")],
  views: {
    tokens: document.querySelector("#tokens-view"),
    wakati: document.querySelector("#wakati-view"),
    json: document.querySelector("#json-view"),
  },
};

boot();

async function boot() {
  try {
    await init();
    state.tokenizer = new WasmTokenizer();
    setStatus("loading", "Loading ipadic");
    await loadDictionary();
    bindEvents();
    render();
  } catch (error) {
    setStatus("error", error instanceof Error ? error.message : String(error));
  }
}

async function loadDictionary() {
  const [lexicon, matrix, charDef, unkDef] = await Promise.all([
    fetchDictionaryText("./dic/lex.csv.gz"),
    fetchDictionaryText("./dic/matrix.def.gz"),
    fetchDictionaryText("./dic/char.def.gz"),
    fetchDictionaryText("./dic/unk.def.gz"),
  ]);
  state.tokenizer.resetDictionary(lexicon, matrix, charDef, unkDef);
  setStatus("ready", "ipadic ready");
}

async function fetchDictionaryText(path) {
  const response = await fetch(path);
  if (!response.ok) {
    throw new Error(`Failed to load ${path}: ${response.status}`);
  }
  if (!("DecompressionStream" in window)) {
    throw new Error("This browser does not support gzip dictionary streaming.");
  }
  const stream = response.body.pipeThrough(new DecompressionStream("gzip"));
  return new Response(stream).text();
}

function bindEvents() {
  els.input.addEventListener("input", render);
  els.ignoreSpace.addEventListener("change", render);
  els.maxGrouping.addEventListener("input", render);
  els.sampleButton.addEventListener("click", () => {
    els.input.value = SAMPLE;
    render();
  });
  for (const tab of els.tabs) {
    tab.addEventListener("click", () => {
      state.activeView = tab.dataset.view;
      updateTabs();
    });
  }
}

function render() {
  if (!state.tokenizer) {
    return;
  }

  const input = els.input.value;
  const maxGrouping = Number.parseInt(els.maxGrouping.value, 10) || 0;
  const start = performance.now();

  try {
    state.tokenizer.setOptions(els.ignoreSpace.checked, maxGrouping);
    state.json = state.tokenizer.tokenizeJson(input);
    state.tokens = JSON.parse(state.json);
    state.wakati = state.tokenizer.tokenizeWakati(input);
    els.elapsed.textContent = (performance.now() - start).toFixed(2);
    setStatus("ready", "WebAssembly ready");
  } catch (error) {
    state.tokens = [];
    state.wakati = "";
    state.json = JSON.stringify({ error: String(error) }, null, 2);
    setStatus("error", String(error));
  }

  els.tokenCount.textContent = String(state.tokens.length);
  els.byteCount.textContent = String(new TextEncoder().encode(input).length);
  renderStrip();
  renderTable();
  els.wakatiOutput.textContent = state.wakati;
  els.jsonOutput.textContent = JSON.stringify(JSON.parse(state.json), null, 2);
  updateTabs();
}

function renderStrip() {
  els.tokenStrip.replaceChildren(
    ...state.tokens.map((token) => {
      const chip = document.createElement("span");
      chip.className = `token-chip${token.unknown ? " unknown" : ""}`;
      chip.textContent = token.surface || "∅";
      chip.title = token.feature;
      return chip;
    }),
  );
}

function renderTable() {
  els.tokenRows.replaceChildren(
    ...state.tokens.map((token) => {
      const feature = parseFeature(token.feature);
      const row = document.createElement("tr");
      row.append(
        cell(token.surface),
        cell(feature.pos),
        cell(feature.reading),
        cell(`${token.start}-${token.end}`, "mono"),
        cell(String(token.totalCost), "mono"),
      );
      return row;
    }),
  );
}

function parseFeature(feature) {
  const parts = feature.split(",");
  const pos = parts.slice(0, 4).filter((part) => part && part !== "*").join("-");
  const reading = parts[7] && parts[7] !== "*" ? parts[7] : "";
  return {
    pos: pos || feature,
    reading,
  };
}

function cell(text, className = "") {
  const td = document.createElement("td");
  td.textContent = text;
  if (className) {
    td.className = className;
  }
  return td;
}

function updateTabs() {
  for (const tab of els.tabs) {
    tab.classList.toggle("active", tab.dataset.view === state.activeView);
  }
  for (const [name, view] of Object.entries(els.views)) {
    view.classList.toggle("active", name === state.activeView);
  }
}

function setStatus(kind, text) {
  els.statusDot.className = `status-dot ${kind}`;
  els.statusText.textContent = text;
}
