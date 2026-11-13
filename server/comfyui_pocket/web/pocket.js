import { app, sanitizeNodeName } from "../../scripts/app.js";
import { api } from "../../scripts/api.js";

const STATE_KEY = "comfyui-pocket.sync.v1";
const ENABLED_KEY = "comfyui-pocket.auto.v1";
const POLL_MS = 5000;

let state = loadState();
let enabled = localStorage.getItem(ENABLED_KEY) !== "off";
let busy = false;
let statusNode = null;
let listNode = null;
let lastStatus = "等待工作流…";
let services = null;
const attempted = new Set();

function loadState() {
  try {
    const value = JSON.parse(localStorage.getItem(STATE_KEY) || "{}");
    return value && typeof value === "object" ? value : {};
  } catch {
    return {};
  }
}

function saveState() {
  localStorage.setItem(STATE_KEY, JSON.stringify(state));
}

function setStatus(text) {
  lastStatus = text;
  if (statusNode) statusNode.textContent = text;
}

function element(tag, text, parent) {
  const node = document.createElement(tag);
  if (text) node.textContent = text;
  parent?.append(node);
  return node;
}

async function checked(path, options) {
  const response = await api.fetchApi(path, options);
  if (!response.ok) throw new Error((await response.text()) || `HTTP ${response.status}`);
  return response.json();
}

async function deleteWorkflow(id) {
  const response = await api.fetchApi(`/pocket/v1/workflows/${id}`, { method: "DELETE" });
  if (!response.ok && response.status !== 404) {
    throw new Error((await response.text()) || `HTTP ${response.status}`);
  }
}

function stableID(path) {
  // Stable 32-hex identifier without relying on crypto.subtle (unavailable over plain LAN HTTP).
  let h1 = 0x811c9dc5;
  let h2 = 0x01000193;
  let h3 = 0x9e3779b9;
  let h4 = 0x85ebca6b;
  const text = `comfyuipocket:${path}`;
  for (let index = 0; index < text.length; index += 1) {
    const code = text.charCodeAt(index);
    h1 = Math.imul(h1 ^ code, 16777619) >>> 0;
    h2 = Math.imul(h2 + code, 2246822519) >>> 0;
    h3 = Math.imul(h3 ^ ((code << 5) | (code >>> 27)), 3266489917) >>> 0;
    h4 = Math.imul(h4 + code + (h1 >>> 16), 668265263) >>> 0;
  }
  return [h1, h2, h3, h4].map((value) => value.toString(16).padStart(8, "0")).join("");
}

async function discoverServices() {
  if (services) return services;
  const resources = performance.getEntriesByType("resource").map((entry) => entry.name);
  const appURL = resources.find((name) => /\/app-[^/]+\.js$/.test(name))
    || resources.find((name) => /\/assets\/app-[^/]+\.js$/.test(name));
  if (!appURL) throw new Error("无法定位 ComfyUI 前端模块");
  const module = await import(appURL);
  const litegraphService = Object.values(module)
    .find((value) => typeof value === "function" && value.name === "useLitegraphService");
  const parseJson = Object.values(module)
    .find((value) => typeof value === "function" && value.name === "parseJsonWithNonFinite");
  if (!litegraphService) throw new Error("当前 ComfyUI 前端不支持全量自动同步");
  services = {
    litegraph: litegraphService(),
    parseJson: parseJson || ((text) => JSON.parse(text))
  };
  return services;
}

function asApiPrompt(data) {
  if (!data || typeof data !== "object" || Array.isArray(data) || Array.isArray(data.nodes)) return null;
  const values = Object.values(data);
  if (values.length === 0) return null;
  const valid = values.every((node) => node && typeof node === "object"
    && typeof node.class_type === "string" && node.inputs && typeof node.inputs === "object");
  return valid ? data : null;
}

function sanitizeUnknownNodes(graphData) {
  const subgraphIDs = new Set((graphData.definitions?.subgraphs ?? []).map((item) => item.id));
  const registry = window.LiteGraph?.registered_node_types;
  const sanitize = (graph) => {
    for (const node of graph.nodes ?? []) {
      if (typeof node?.type !== "string" || subgraphIDs.has(node.type)) continue;
      if (registry && node.type in registry) continue;
      node.type = sanitizeNodeName(node.type);
    }
  };
  sanitize(graphData);
  for (const subgraph of graphData.definitions?.subgraphs ?? []) sanitize(subgraph);
}

async function convertWorkflow(data) {
  const apiPrompt = asApiPrompt(data);
  if (apiPrompt) return { prompt: apiPrompt, workflow: null };

  const { litegraph } = await discoverServices();
  const Graph = app.rootGraph.constructor;
  const graph = new Graph();
  const restores = [];
  const registry = window.LiteGraph?.registered_node_types;

  // Subgraph node types are global, so register per conversion and restore afterwards.
  graph.events.addEventListener("subgraph-created", (event) => {
    const { subgraph, data: definition } = event.detail;
    const previous = registry?.[definition.id];
    const nodeDef = {
      input: { required: {} }, output: [], output_is_list: [], output_name: [], output_tooltips: [],
      name: definition.id, display_name: definition.name,
      description: definition.description || "", category: "subgraph",
      output_node: false, python_module: "nodes"
    };
    litegraph.registerSubgraphNodeDef(nodeDef, subgraph, {
      id: -1, type: definition.id, pos: [0, 0], size: [100, 100],
      inputs: [], outputs: [], flags: {}, order: 0, mode: 0
    });
    restores.push(() => {
      if (!registry) return;
      if (previous) registry[definition.id] = previous;
      else delete registry[definition.id];
    });
  });

  try {
    const graphData = structuredClone(data);
    sanitizeUnknownNodes(graphData);
    graph.configure(graphData);
    const result = await app.graphToPrompt(graph);
    if (!result.output || Object.keys(result.output).length === 0) {
      throw new Error("工作流没有可执行节点");
    }
    return { prompt: result.output, workflow: result.workflow ?? null };
  } finally {
    for (const restore of restores.reverse()) restore();
  }
}

async function syncAll(force = false) {
  if (!enabled || busy) return;
  busy = true;
  try {
    const { parseJson } = await discoverServices();
    const listing = await checked("/pocket/v1/comfy-workflows");
    const files = listing.workflows ?? [];
    const seen = new Set(files.map((file) => file.path));
    let updated = 0;
    let failed = 0;

    for (const file of files) {
      const cursor = `${file.path}:${file.modified}:${file.size}`;
      if (!force && attempted.has(cursor)) continue;
      const previous = state[file.path];
      if (!force && previous && previous.modified === file.modified && previous.size === file.size) continue;
      try {
        const response = await api.fetchApi(`/pocket/v1/comfy-workflows/file?path=${encodeURIComponent(file.path)}`);
        if (!response.ok) throw new Error((await response.text()) || `HTTP ${response.status}`);
        const data = parseJson(await response.text());
        const converted = await convertWorkflow(data);
        const id = previous?.id || stableID(file.path);
        const body = { id, name: file.name, prompt: converted.prompt };
        if (converted.workflow) body.workflow = converted.workflow;
        await checked("/pocket/v1/workflows", {
          method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body)
        });
        state[file.path] = { id, modified: file.modified, size: file.size };
        updated += 1;
        setStatus(`已同步“${file.name}” · ${new Date().toLocaleTimeString()}`);
      } catch (error) {
        failed += 1;
        attempted.add(cursor);
        setStatus(`“${file.name}”同步失败：${error.message}`);
      }
    }

    for (const path of Object.keys(state)) {
      if (seen.has(path)) continue;
      const entry = state[path];
      try {
        await deleteWorkflow(entry.id);
      } catch {
        continue;
      }
      delete state[path];
    }

    saveState();
    if (failed === 0) {
      setStatus(`已自动同步全部工作流 · ${new Date().toLocaleTimeString()}`);
    } else {
      setStatus(`同步完成，${failed} 个失败 · ${new Date().toLocaleTimeString()}`);
    }
    if (listNode) loadList().catch(() => {});
  } catch (error) {
    setStatus(`自动同步失败：${error.message}`);
  } finally {
    busy = false;
  }
}

async function loadList() {
  if (!listNode) return;
  const result = await checked("/pocket/v1/workflows");
  listNode.replaceChildren();
  if (result.workflows.length === 0) {
    element("p", "还没有同步的工作流。ComfyUI 中保存的工作流会自动出现在这里。", listNode);
    return;
  }
  for (const item of result.workflows) {
    const row = element("div", "", listNode);
    row.style.cssText = "border-top:1px solid #8885;padding:10px 0;display:flex;gap:8px;align-items:center;justify-content:space-between";
    element("span", `${item.name} · ${item.nodes} nodes`, row);
    const stamp = element("span", item.updatedAt ? new Date(item.updatedAt).toLocaleTimeString() : "", row);
    stamp.style.cssText = "opacity:.6;font-size:12px";
  }
}

function panel(container) {
  container.replaceChildren();
  const root = element("div", "", container);
  root.style.cssText = "padding:20px;display:flex;flex-direction:column;gap:14px;overflow:auto;height:100%;box-sizing:border-box";
  element("h2", "ComfyUI Pocket", root);
  element("p", "ComfyUI 中保存的所有工作流都会自动同步到手机，无需逐个选择。手机上的参数修改也会自动同步回来。", root);

  const toggleRow = element("label", "", root);
  toggleRow.style.cssText = "display:flex;gap:8px;align-items:center";
  const toggle = element("input", "", toggleRow);
  toggle.type = "checkbox";
  toggle.checked = enabled;
  toggle.onchange = () => {
    enabled = toggle.checked;
    localStorage.setItem(ENABLED_KEY, enabled ? "on" : "off");
    setStatus(enabled ? "自动同步已开启" : "自动同步已关闭");
    if (enabled) syncAll(true);
  };
  element("span", "自动同步全部工作流", toggleRow);

  const sync = element("button", "立即同步", root);
  sync.onclick = () => syncAll(true);

  statusNode = element("p", lastStatus, root);
  statusNode.setAttribute("role", "status");

  listNode = element("div", "", root);
  loadList().catch((error) => setStatus(`读取同步列表失败：${error.message}`));
}

app.registerExtension({
  name: "ComfyUIPocket.Catalog",
  async setup() {
    app.extensionManager.registerSidebarTab({
      id: "comfyui-pocket", icon: "pi pi-mobile", title: "Pocket",
      tooltip: "ComfyUI Pocket · 全部工作流自动同步", type: "custom", render: panel
    });
    // The embedded editor owns a live unsaved graph. Desktop catalog scanning
    // must not overwrite its snapshots or perform unrelated conversions.
    if (window.__POCKET_CANVAS__ || new URLSearchParams(location.search).get("pocket_canvas") === "1") return;
    setTimeout(() => syncAll(false), 1200);
    setInterval(() => syncAll(false), POLL_MS);
  }
});
