(() => {
  "use strict";

  function nodeAt(graph, id) {
    return graph?.getNodeById?.(id) ?? graph?._nodes?.find(node => String(node.id) === String(id));
  }

  function executionNode(graph, id) {
    const parts = String(id).split(":");
    let current = graph;
    let node;
    for (let index = 0; index < parts.length; index++) {
      node = nodeAt(current, parts[index]);
      if (!node) return null;
      if (index < parts.length - 1) current = node.subgraph;
    }
    return node;
  }

  function showSamplingPreview(graph, payload) {
    const node = executionNode(graph, payload?.node_id);
    if (node?.type !== "ModelPreviewOverrideKJ" || typeof node._kjPreviewHandler !== "function") return false;
    node._kjPreviewHandler(payload);
    return true;
  }

  function workspaceRestored(app) {
    // setup() finishes before GraphCanvas restores persisted workflow tabs.
    // These public stores cover both current and older frontend versions.
    return app?.extensionManager?.workflow?.tabsRestored !== false && app?.extensionManager?.spinner !== true;
  }

  function graphMatchesWorkflow(graph, workflow) {
    if (!graph || !Array.isArray(workflow?.nodes)) return false;
    if (workflow.id && String(graph.id) !== String(workflow.id)) return false;
    const ids = new Set((graph._nodes ?? []).map(n => String(n.id)));
    return workflow.nodes.every(n => ids.has(String(n.id)));
  }

  function requireWorkflow(app, workflow) {
    if (workflow && !graphMatchesWorkflow(app.rootGraph, workflow)) {
      throw new Error("ComfyUI 恢复标签时切换了当前画布，已停止套用参数。请重新载入；原工作流未被覆盖。");
    }
  }

  async function loadWorkflowGraph(app, workflow, name) {
    for (let attempt = 0; attempt < 2; attempt++) {
      await app.loadGraphData(structuredClone(workflow), true, true, name);
      if (graphMatchesWorkflow(app.rootGraph, workflow)) return;
    }
    requireWorkflow(app, workflow);
  }

  async function applyPrompt(app, prompt, workflow) {
    requireWorkflow(app, workflow);
    const before = await executablePrompt(app, prompt);
    requireWorkflow(app, workflow);
    for (const [id, spec] of Object.entries(prompt)) {
      for (const [name, value] of Object.entries(spec.inputs)) {
        if (equivalentInput(spec, before?.[id], name)) continue;
        const node = executionNode(app.rootGraph, id);
        if (node?.type && node.type !== spec.class_type) continue;
        // Only actual widgets are assigned. Connections, dynamic structures and
        // custom serializers are never inferred from widget position.
        const widget = node?.widgets?.find(item => item.name === name);
        if (!widget || (value !== null && typeof value === "object")) continue;
        // Never replace a connected input through a stale widget.
        if (node.inputs?.some(input => input.link != null && (input.name === name || input.widget?.name === name))) continue;
        widget.value = value;
        node.onWidgetChanged?.(name, value, before?.[id]?.inputs?.[name], widget);
        await widget.callback?.(value, app.canvas, node, undefined, undefined);
        requireWorkflow(app, workflow);
      }
    }
    const after = await executablePrompt(app, prompt);
    requireWorkflow(app, workflow);
    const unmapped = [];
    for (const [id, spec] of Object.entries(prompt)) {
      if (after[id]?.class_type !== spec.class_type) { unmapped.push(`${id}.class_type`); continue; }
      for (const [name, value] of Object.entries(spec.inputs)) {
        if (!equivalentInput(spec, after?.[id], name)) {
          if (!unmapped.includes(`${id}.${name}`)) unmapped.push(`${id}.${name}`);
        }
      }
    }
    return unmapped;
  }

  async function executablePrompt(app, reference) {
    const { output } = await app.graphToPrompt(app.rootGraph);
    for (const [id, spec] of Object.entries(reference ?? {})) {
      const actual = output[id], node = executionNode(app.rootGraph, id);
      if (!actual || actual.class_type !== spec.class_type || !node) continue;
      for (const name of Object.keys(spec.inputs)) {
        if (Object.hasOwn(actual.inputs, name)) continue;
        const widget = node.widgets?.find(w => w.name === name);
        // Some frontend versions omit hidden widgets from the API prompt. A real,
        // named scalar widget remains authoritative even when the plugin folds it.
        if (!widget || !(widget.hidden || widget.type === "hidden") || widget.options?.serialize === false) continue;
        if (!["string", "number", "boolean"].includes(typeof widget.value)) continue;
        if (node.inputs?.some(i => i.link != null && (i.name === name || i.widget?.name === name))) continue;
        actual.inputs[name] = widget.value;
      }
    }
    return output;
  }

  function sameValue(a, b) {
    if (a === b) return true;
    if (!a || !b || typeof a !== "object" || typeof b !== "object" || Array.isArray(a) !== Array.isArray(b)) return false;
    const keys = Object.keys(a);
    return keys.length === Object.keys(b).length && keys.every(k => Object.hasOwn(b, k) && sameValue(a[k], b[k]));
  }

  function equivalentInput(expected, actual, name) {
    const a = expected.inputs[name], b = actual?.inputs?.[name];
    if (sameValue(a, b)) return true;
    if (expected.class_type?.startsWith("Lazy") && ["timeline_data", "图片数据"].includes(name) && typeof a === "string" && typeof b === "string") {
      try { if (sameValue(JSON.parse(a), JSON.parse(b))) return true; } catch {}
    }
    // H3 versions display seconds at two or three decimal places. Frames remain authoritative.
    const frameKey = { start_second: "start_frame", end_second: "end_frame", duration_seconds: "duration_frames" }[name];
    if (expected.class_type === "LazyH3Director" && frameKey && typeof a === "number" && typeof b === "number") {
      const fps = expected.inputs.frame_rate;
      return fps > 0 && fps === actual?.inputs?.frame_rate && expected.inputs[frameKey] === actual?.inputs?.[frameKey]
        && Math.abs(a - expected.inputs[frameKey] / fps) <= 0.0051 && Math.abs(b - a) <= 0.0051;
    }
    return false;
  }

  function change(app, edit) {
    const graph = app.canvas.graph ?? app.rootGraph;
    const tracker = app.extensionManager?.workflow?.activeWorkflow?.changeTracker;
    tracker?.captureCanvasState?.();
    graph.beforeChange?.();
    try { return edit(graph); }
    finally {
      graph.afterChange?.();
      tracker?.captureCanvasState?.();
      app.canvas.setDirty(true, true);
    }
  }

  function ports(app) {
    return (app.canvas.graph?._nodes ?? []).map(node => ({
      id: String(node.id), title: node.title ?? node.type,
      inputs: (node.inputs ?? []).map((port, slot) => ({ slot, name: port.name, type: String(port.type), linked: port.link != null })),
      outputs: (node.outputs ?? []).map((port, slot) => ({ slot, name: port.name, type: String(port.type) }))
    }));
  }

  function connect(app, from, output, to, input) {
    const graph = app.canvas.graph;
    const source = nodeAt(graph, from), target = nodeAt(graph, to);
    if (!source?.outputs?.[output] || !target?.inputs?.[input]) throw new Error("请选择有效的输入与输出端口。");
    return change(app, () => {
      const link = source.connect(output, target, input);
      if (!link) throw new Error("端口类型不兼容，无法连接。");
      return true;
    });
  }

  function disconnect(app, id, slot) {
    const node = nodeAt(app.canvas.graph, id);
    if (!node?.inputs?.[slot]) throw new Error("输入端口不存在。");
    return change(app, () => { node.disconnectInput(slot); return true; });
  }

  function bookmarkLocations(app) {
    const locations = [];
    let graphPath = null;
    function visit(graph, path, ancestors) {
      if (!graph || ancestors.has(graph)) return;
      if (graph === (app.canvas.graph ?? app.rootGraph) && graphPath === null) graphPath = path;
      const seen = new Set(ancestors); seen.add(graph);
      for (const node of graph._nodes ?? []) {
        locations.push({ path, nodeID: String(node.id), type: node.type || "", title: node.title || node.type || String(node.id) });
        if (node.subgraph) visit(node.subgraph, [...path, String(node.id)], seen);
      }
    }
    visit(app.rootGraph, [], new Set());
    return { graphPath, bookmarkNodes: locations };
  }

  function focusBookmark(app, path, id, type) {
    if (!Array.isArray(path) || !path.every(part => typeof part === "string")) throw new Error("收藏位置无效。");
    let graph = app.rootGraph;
    const graphs = [];
    for (const part of path) {
      graph = nodeAt(graph, part)?.subgraph;
      if (!graph) throw new Error("收藏的子图已移除，可在收藏列表中取消收藏。");
      graphs.push(graph);
    }
    const node = nodeAt(graph, id);
    if (!node || node.type !== type) throw new Error("收藏的节点已移除或类型已改变。");
    // Resolve the complete target before moving the camera; missing bookmarks
    // must not navigate to an unrelated node with the same local ID.
    if (app.canvas.graph !== graph) {
      app.canvas.setGraph(app.rootGraph);
      for (const child of graphs) app.canvas.openSubgraph(child);
    }
    return focusNode(app, id);
  }

  function mobileScene(app) {
    const graph = app.canvas.graph ?? app.rootGraph;
    const groups = (graph._groups ?? []).map((g, index) => ({
      id: String(index), title: g.title || `分组 ${index + 1}`,
      x: Number(g.pos?.[0] ?? g._pos?.[0] ?? 0), y: Number(g.pos?.[1] ?? g._pos?.[1] ?? 0),
      width: Number(g.size?.[0] ?? g._size?.[0] ?? 0), height: Number(g.size?.[1] ?? g._size?.[1] ?? 0)
    }));
    const nodes = (graph._nodes ?? []).map(n => {
      const group = groups.filter(g => n.pos[0] >= g.x && n.pos[1] >= g.y && n.pos[0] < g.x + g.width && n.pos[1] < g.y + g.height)
        .sort((a, b) => a.width * a.height - b.width * b.height)[0];
      return { id: String(n.id), title: n.title || n.type, type: n.type || "", x: n.pos[0], y: n.pos[1],
        width: n.size?.[0] ?? 260, height: n.size?.[1] ?? 100, mode: n.mode ?? 0, group: group?.id ?? "",
        subgraph: !!n.subgraph, widgets: (n.widgets ?? []).flatMap((w, index) => {
          if (!w.name || w.type === "button" || w.type?.startsWith("converted-widget") || w.type === "hidden" || w.hidden) return [];
          if (!["string", "number", "boolean"].includes(typeof w.value)) return [];
          // A widget converted to an input belongs to the connection, not a text field.
          if (n.inputs?.some(i => i.link != null && i.widget?.name === w.name)) return [];
          if (["timeline_data", "timeline_ui", "local_prompts", "segment_lengths", "guide_strength", "history_json", "图片数据"].includes(w.name)) return [];
          let choices = w.options?.values;
          try { if (typeof choices === "function") choices = choices(w, n); } catch { choices = []; }
          return [{ id: String(index), name: w.name, value: w.value,
            choices: Array.isArray(choices) ? choices.filter(x => typeof x === "string" || typeof x === "number") : [],
            min: Number.isFinite(w.options?.min) ? w.options.min : null,
            max: Number.isFinite(w.options?.max) ? w.options.max : null }];
        }) };
    });
    const links = [];
    for (const n of graph._nodes ?? []) {
      for (const input of n.inputs ?? []) {
        if (input.link == null) continue;
        const link = graph.links?.get?.(input.link) ?? graph.links?.[input.link];
        if (link) links.push({ id: String(input.link), from: String(link.origin_id), to: String(link.target_id), type: String(link.type ?? input.type) });
      }
    }
    return { nodes, groups, links, nested: graph !== app.rootGraph, ...bookmarkLocations(app) };
  }

  async function setMobileWidget(app, id, index, value, name, importingFile = false) {
    const node = nodeAt(app.canvas.graph ?? app.rootGraph, id);
    const widget = name ? node?.widgets?.find(w => w.name === name) : node?.widgets?.[Number(index)];
    if (!widget || !["string", "number", "boolean"].includes(typeof value) || typeof widget.value !== typeof value) throw new Error("控件类型已改变，请重新打开节点。");
    if (node.inputs?.some(i => i.link != null && i.widget?.name === widget.name)) throw new Error("此参数已连接输入，请编辑上游节点。");
    if (typeof value === "number" && (!Number.isFinite(value) || value < (widget.options?.min ?? -Infinity) || value > (widget.options?.max ?? Infinity))) throw new Error("数值超出节点范围。");
    let choices = widget.options?.values;
    if (typeof choices === "function") choices = choices(widget, node);
    if (Array.isArray(choices) && !choices.includes(value)) {
      if (!importingFile) throw new Error("此选项已不可用，请刷新节点。");
      if (typeof widget.options.values === "function") {
        const original = widget.options.values;
        widget.options.values = (...args) => [...new Set([...original.apply(widget.options, args), value])];
      } else {
        widget.options.values = [...choices, value];
      }
    }
    const graph = app.canvas.graph ?? app.rootGraph;
    const tracker = app.extensionManager?.workflow?.activeWorkflow?.changeTracker;
    tracker?.captureCanvasState?.(); graph.beforeChange?.();
    const old = widget.value;
    try {
      widget.value = value;
      node.onWidgetChanged?.(widget.name, value, old, widget);
      await widget.callback?.(value, app.canvas, node, undefined, undefined);
    } catch (error) { widget.value = old; throw error; }
    finally { graph.afterChange?.(); tracker?.captureCanvasState?.(); app.canvas.setDirty(true, true); }
    return true;
  }

  function assetInputWidget(node, kind, preferred) {
    if (!node || !["image", "video"].includes(kind)) return null;
    const native = {
      LoadImage: ["image", "image"], LoadImageMask: ["image", "image"], LoadImageGoohai: ["image", "image"],
      LoadVideo: ["video", "file"], VHS_LoadVideo: ["video", "video"],
      VHS_LoadVideoFFmpeg: ["video", "video"]
    }[node.comfyClass ?? node.type];
    const inputs = node.constructor?.nodeData?.input;
    const fields = (node.widgets ?? []).filter(widget =>
      typeof widget.value === "string" && widget.type !== "button" && widget.options?.serialize !== false &&
      !widget.hidden && !widget.disabled && !node.inputs?.some(i => i.link != null && i.widget?.name === widget.name)
    );
    // ComfyUI can mark its upload button as a file widget too. For loaders
    // with a known execution field, target that field from anywhere on the node.
    if (native) return native[0] === kind ? (fields.find(widget => widget.name === native[1]) ?? null) : null;
    const eligible = fields.filter(widget => {
      const definition = inputs?.required?.[widget.name] ?? inputs?.optional?.[widget.name];
      return definition?.[1]?.[kind + "_upload"] === true;
    });
    return eligible.includes(preferred) ? preferred : eligible.length === 1 ? eligible[0] : null;
  }

  function dropReferenceAsset(app, node, hit, asset, clientX, clientY) {
    if (!hit || !app.canvasContainer?.contains(hit)) return null;
    const nodeType = node?.comfyClass ?? node?.type;
    const timeline = nodeType === "LazyH3Director" ? hit.closest(".pr-canvas") : null;
    let zone = timeline ?? hit.closest(".bp-dropzone, .h3-refs-drop");
    const domName = {
      LazyMergeWorkbench: "lazy_merge_wb", LazyQwenWorkbench: "lazy_qwen_wb",
      LazyKreaWorkbench: "lazy_krea_wb"
    }[nodeType];
    let media;
    if (!zone && domName) {
      const root = node.widgets?.find(widget => widget.name === domName)?.element;
      if (root) {
        // Lazy workbenches have an unclassed drop area. Its persistent hint
        // remains the first child after thumbnails have been added.
        for (let element = root.contains(hit) ? hit : null; element && element !== root; element = element.parentElement) {
          if (element.firstElementChild?.textContent === "点击添加，或拖入本地/资产图片") {
            zone = element;
            break;
          }
        }
        // A drop on the workbench body also targets its own reference region.
        zone ??= Array.from(root.querySelectorAll("div")).find(element =>
          element.firstElementChild?.textContent === "点击添加，或拖入本地/资产图片");
        if (zone) media = node.widgets.find(widget => widget.name === "图片数据");
      }
      if (!zone || !media) throw new Error("这个工作台的参考图区尚未就绪，请聚焦节点后重试。");
    }
    if (!zone) return null;
    if (!timeline && asset.media_kind !== "image") throw new Error("这个参考图区只接收图片。");
    const transfer = new DataTransfer();
    transfer.setData("application/x-comfy-asset-info", JSON.stringify(asset));
    if (media || timeline) {
      // Older Qwen and Krea workbenches read a view URL and decode its
      // filename twice. Preserve literal percent signs for those parsers.
      const legacy = domName === "lazy_qwen_wb" || domName === "lazy_krea_wb";
      const path = value => legacy ? value.replaceAll("%", "%25") : value;
      transfer.setData("text/uri-list", "/view?" + new URLSearchParams({
        filename: path(asset.filename), subfolder: path(asset.subfolder), type: asset.type
      }));
    }
    const event = type => new DragEvent(type, {
      dataTransfer: transfer, bubbles: true, cancelable: true, clientX, clientY
    });
    if (timeline) {
      // The director uses the /view URI to recover the original asset and
      // the native dragover handler to select its timeline position.
      zone.dispatchEvent(event("dragover"));
    }
    const drop = () => zone.dispatchEvent(event("drop"));
    if (!media) {
      if (drop()) throw new Error("此参考图区未接受拖放。");
      return "reference";
    }
    const before = media.value;
    change(app, () => { drop(); });
    if (media.value === before) throw new Error("未添加图片。请检查参考图是否已达到张数上限，或更换图片格式。");
    return "reference-added";
  }

  function moveMobileNode(app, id, x, y) {
    const node = nodeAt(app.canvas.graph ?? app.rootGraph, id);
    if (!node || !Number.isFinite(x) || !Number.isFinite(y)) throw new Error("节点位置无效。");
    return change(app, () => { node.pos[0] = x; node.pos[1] = y; return true; });
  }

  function focusNode(app, id) {
    const node = nodeAt(app.canvas.graph, id);
    if (!node) throw new Error("节点不存在。");
    const canvas = app.canvas, rect = canvas.canvas.getBoundingClientRect();
    const title = 32, padding = 20;
    const width = Math.max(1, node.size?.[0] ?? 280), height = Math.max(1, (node.size?.[1] ?? 100) + title);
    canvas.selectNode(node);
    canvas.ds.scale = Math.max(0.02, Math.min(4, (rect.width - padding * 2) / width, (rect.height - padding * 2) / height));
    canvas.ds.offset[0] = -node.pos[0] + (rect.width / canvas.ds.scale - width) / 2;
    canvas.ds.offset[1] = -node.pos[1] + title + (rect.height / canvas.ds.scale - height) / 2;
    canvas.setDirty(true, true); return true;
  }

  // Observe native gestures without taking pointer capture or cancelling events.
  function installOverviewTap(app, enabled, focus, surface = window) {
    let press, serial = 0;
    const reset = () => { press = null; serial++; };
    function hit(e) {
      const canvas = app.canvas, element = e.target;
      if (element?.closest?.('button,input,textarea,select,a,[contenteditable]:not([contenteditable=false]),[role=button],[role=slider],[role=combobox],[role=menu],.dom-widget')) return;
      const domNode = element?.closest?.('[data-node-id]');
      if (element !== canvas.canvas && !(domNode && app.canvasContainer?.contains(domNode))) return;
      const rect = canvas.canvas.getBoundingClientRect?.();
      const point = canvas.convertEventToCanvasOffset?.(e) ?? (rect && canvas.ds && [
        (e.clientX - rect.left) / canvas.ds.scale - canvas.ds.offset[0],
        (e.clientY - rect.top) / canvas.ds.scale - canvas.ds.offset[1]]);
      if (!point) return;
      const node = domNode ? nodeAt(canvas.graph, domNode.dataset.nodeId) : canvas.graph.getNodeOnPos?.(...point);
      if (!node || node.getSlotInPosition?.(...point) || node.getWidgetOnPos?.(...point)) return;
      return node;
    }
    function down(e) {
      reset();
      if (!enabled() || e.isPrimary === false || e.button !== 0 || e.shiftKey || e.altKey || e.ctrlKey || e.metaKey) return;
      const node = hit(e);
      if (node) press = { node, graph: app.canvas.graph, id: e.pointerId, x: e.clientX, y: e.clientY, at: e.timeStamp };
    }
    function move(e) {
      if (press && (e.pointerId !== press.id || Math.hypot(e.clientX - press.x, e.clientY - press.y) > 7)) reset();
    }
    function up(e) {
      move(e);
      const tap = press, ticket = serial;
      press = null;
      if (!tap || !enabled() || e.timeStamp - tap.at > 400 || tap.graph !== app.canvas.graph || hit(e) !== tap.node) return;
      surface.requestAnimationFrame(() => {
        if (serial === ticket && enabled() && app.canvas.graph === tap.graph && nodeAt(tap.graph, tap.node.id) === tap.node)
          focus(String(tap.node.id));
      });
    }
    for (const [name, handler] of Object.entries({pointerdown: down, pointermove: move, pointerup: up, pointercancel: reset, wheel: reset, blur: reset}))
      surface.addEventListener(name, handler, {capture: true, passive: true});
  }

  function restoreExecutionModes(app, prompt, currentOutput = {}) {
    for (const [id, spec] of Object.entries(prompt)) {
      const node = executionNode(app.rootGraph, id);
      // Custom serializers can deliberately emit bypassed nodes (e.g. Goohai's
      // string-only bypass). Their existing execution output preserves that
      // behavior; activating the graph node would silently enable model inference.
      if (currentOutput[id]?.class_type === spec.class_type) continue;
      // The saved API prompt is authoritative about which concrete nodes execute.
      // Never activate annotations, virtual nodes, or a different node class.
      if (node?.type === spec.class_type && (node.mode === 2 || node.mode === 4)) node.mode = 0;
    }
  }

  function textInputCamera(bounds, viewport) {
    const padding = 16;
    const width = Math.max(1, viewport.width - padding * 2);
    const height = Math.max(1, viewport.height - padding * 2);
    const scale = Math.max(0.02, Math.min(4, width / Math.max(1, bounds.width)));
    return {
      scale, maxHeight: height / scale, fontSize: Math.max(16, 16 / scale),
      offset: [-bounds.x + (viewport.x + padding + (width - bounds.width * scale) / 2) / scale,
        -bounds.y + (viewport.y + padding) / scale]
    };
  }

  // Theme only the renderer's background argument. Never change node.color,
  // bgcolor, widgets, geometry or serialization, even during a draw callback.
  const appearanceRenderers = new WeakMap();
  function setNodeAppearance(canvas, enabled, palette = {}) {
    if (!canvas || typeof canvas.drawNodeShape !== "function") return false;
    let state = appearanceRenderers.get(canvas);
    if (!enabled) {
      if (state) {
        state.enabled = false;
        if (canvas.drawNodeShape === state.wrapper) {
          if (state.descriptor) Object.defineProperty(canvas, "drawNodeShape", state.descriptor);
          else delete canvas.drawNodeShape;
          appearanceRenderers.delete(canvas);
        }
      }
      canvas.setDirty?.(true, true); return true;
    }
    if (!/^#[0-9a-f]{6}$/i.test(palette.surface || "")) return false;
    if (!state || canvas.drawNodeShape !== state.wrapper) {
      if (state) state.enabled = false;
      const original = canvas.drawNodeShape;
      state = { enabled: true, surface: palette.surface,
        descriptor: Object.getOwnPropertyDescriptor(canvas, "drawNodeShape") };
      const current = state;
      current.wrapper = function(node, ctx, size, foreground, background, ...rest) {
        return original.call(this, node, ctx, size, foreground,
          current.enabled ? current.surface : background, ...rest);
      };
      canvas.drawNodeShape = current.wrapper;
      appearanceRenderers.set(canvas, current);
    }
    state.enabled = true; state.surface = palette.surface;
    canvas.setDirty?.(true, true); return true;
  }

  // The same graph operations are exercised by Node tests and the actual editor.
  if (typeof module !== "undefined" && module.exports) {
    module.exports = { installOverviewTap, executionNode, showSamplingPreview, applyPrompt, executablePrompt, equivalentInput, change, ports, connect, disconnect, mobileScene, setMobileWidget, assetInputWidget, dropReferenceAsset, moveMobileNode, focusNode, focusBookmark, bookmarkLocations, restoreExecutionModes, textInputCamera, setNodeAppearance, workspaceRestored, graphMatchesWorkflow, loadWorkflowGraph };
    return;
  }

  const send = (type, extra = {}) => window.webkit?.messageHandlers.pocketCanvas.postMessage({ type, ...extra });
  let app;
  let loaded = false;
  let mismatch = false;
  let initialPrompt = null;
  let textEditor;
  let ownedGraphID, overviewGraph, overviewScale;
  let pendingAsset;
  let tapToFocus = false;
  let updateMap = () => {};
  function installMiniMap() {
    if (!app.canvas.canvas || !document.body) return () => {};
    const map = document.createElement("div");
    map.id = "pocket-overview-map"; map.setAttribute("aria-hidden", "true");
    const bitmap = document.createElement("canvas"), label = document.createElement("span");
    bitmap.width = 176; bitmap.height = 84; map.append(bitmap, label); document.body.append(map);
    const ctx = bitmap.getContext("2d");
    const background = document.createElement("canvas");
    background.width = bitmap.width; background.height = bitmap.height;
    const backgroundContext = background.getContext("2d");
    let geometry = [], left, top, k, x, y;
    let scheduled = false;
    function refreshBackground(nodes) {
      if (geometry.length === nodes.length && nodes.every((node, index) => {
        const [px, py, width, height] = geometry[index];
        return node.pos[0] === px && node.pos[1] === py && node.size[0] === width && node.size[1] === height;
      })) return;
      geometry = nodes.map(node => [node.pos[0], node.pos[1], node.size[0], node.size[1]]);
      left = Infinity; top = Infinity;
      let right = -Infinity, bottom = -Infinity;
      for (const [px, py, width, height] of geometry) {
        left = Math.min(left, px); top = Math.min(top, py - 32);
        right = Math.max(right, px + width); bottom = Math.max(bottom, py + height);
      }
      k = Math.min(168 / Math.max(1, right-left), 76 / Math.max(1, bottom-top));
      x = (176 - (right-left)*k)/2; y = (84 - (bottom-top)*k)/2;
      backgroundContext.clearRect(0, 0, 176, 84);
      backgroundContext.fillStyle = "#b8b6c4";
      for (const [px, py, width, height] of geometry) {
        backgroundContext.fillRect(x+(px-left)*k, y+(py-32-top)*k, Math.max(2,width*k), Math.max(2,(height+32)*k));
      }
    }
    function draw() {
      scheduled = false;
      const c = app.canvas, nodes = c.graph?._nodes ?? [];
      map.hidden = !loaded || ownedGraphID !== app.rootGraph.id || !nodes.length || textEditor?.busy || document.hidden;
      if (map.hidden || !ctx || !backgroundContext) return;
      refreshBackground(nodes);
      ctx.clearRect(0, 0, 176, 84);
      ctx.drawImage(background, 0, 0);
      const rect = c.canvas.getBoundingClientRect(), scale = c.ds.scale;
      const x0 = Math.max(1,x+(-c.ds.offset[0]-left)*k), y0 = Math.max(1,y+(-c.ds.offset[1]-top)*k);
      const x1 = Math.min(175,x+(-c.ds.offset[0]+rect.width/scale-left)*k), y1 = Math.min(83,y+(-c.ds.offset[1]+rect.height/scale-top)*k);
      if (x1>x0 && y1>y0) {
        ctx.strokeStyle = "#faf8ff"; ctx.fillStyle = "#b7a3f238"; ctx.lineWidth = 2;
        ctx.fillRect(x0,y0,x1-x0,y1-y0); ctx.strokeRect(x0,y0,x1-x0,y1-y0);
      }
      label.textContent = Math.round(scale*100) + "%";
    }
    function schedule() {
      if (!scheduled) { scheduled = true; requestAnimationFrame(draw); }
    }
    for (const name of ["wheel","pointerup","focusin","focusout","resize"]) window.addEventListener(name, schedule, {passive:true,capture:true});
    window.addEventListener("pointermove", e => { if (e.buttons) schedule(); }, {passive:true,capture:true});
    return schedule;
  }
  const startup = { app: null, registered: false, complete: false, failure: null };
  function followStartup(candidate) {
    if (!candidate || startup.app === candidate) return;
    startup.app = candidate;
    for (const [method, flag] of [["registerNodes", "registered"], ["setup", "complete"]]) {
      const original = candidate[method];
      if (typeof original !== "function") continue;
      candidate[method] = async function(...args) {
        try { const result = await original.apply(this, args); startup[flag] = true; return result; }
        catch (error) { startup.failure = error.message || String(error); throw error; }
      };
    }
  }
  function coordinatesReady(candidate) {
    if (candidate?.positionConversion) return true;
    if (typeof candidate?.clientPosToCanvasPos !== "function") return false;
    try { return candidate.clientPosToCanvasPos([0, 0]).every(Number.isFinite); }
    catch { return false; }
  }
  function layoutSettled() {
    return new Promise(resolve => {
      const timer = setTimeout(resolve, 180);
      requestAnimationFrame(() => requestAnimationFrame(() => { clearTimeout(timer); resolve(); }));
    });
  }
  function markWorkspace() {
    let workspace = app.canvasContainer?.querySelector(".side-toolbar-container");
    while (workspace?.parentElement && workspace.parentElement !== app.canvasContainer) workspace = workspace.parentElement;
    if (workspace && workspace.parentElement === app.canvasContainer) workspace.dataset.pocketWorkspace = "true";
  }
  const ready = (async () => {
    const started = Date.now();
    let previousMessage = "";
    while (Date.now() - started < 180000) {
      app = window.comfyAPI?.app?.app;
      followStartup(app);
      if (startup.failure) throw new Error(`ComfyUI 节点初始化失败：${startup.failure}`);
      // A graph object alone is too early. Follow actual setup completion, with
      // the public coordinate API for a bridge attached after setup has started.
      if (app?.canvas && app?.rootGraph && app?.vueAppReady && (startup.complete || coordinatesReady(app)) && workspaceRestored(app) && typeof app.loadGraphData === "function") {
        // Keep the real graph and plugin DOM widgets mounted. Pocket supplies
        // navigation and the node wheel; desktop chrome must not consume its viewport.
        if (app.extensionManager?.focusMode === false) app.extensionManager.toggleFocusMode?.();
        await layoutSettled();
        markWorkspace();
        app.canvas.resize?.();
        textEditor = installTextEditing(app);
        updateMap = installMiniMap(); updateMap();
        installOverviewTap(app, () => tapToFocus && overviewGraph === app.canvas.graph && overviewScale === app.canvas.ds.scale && loaded &&
          ownedGraphID === app.rootGraph.id && !textEditor.busy, id => {
            if (focusNode(app, id)) { overviewGraph = null; updateMap(); send("overviewFocus", {nodeID: id}); }
          });
        return app;
      }
      const message = (startup.complete || coordinatesReady(app)) && !workspaceRestored(app)
        ? "正在等待 ComfyUI 恢复工作流标签…"
        : startup.registered ? "节点已加载，正在初始化扩展控件…" : "正在加载 ComfyUI 节点与扩展…";
      if (message !== previousMessage) { send("loading", { message }); previousMessage = message; }
      await new Promise(resolve => setTimeout(resolve, 200));
    }
    throw new Error(startup.registered ? "节点已加载，但扩展控件初始化未完成。可重新加载画布，并检查 ComfyUI 前端扩展错误。" : "ComfyUI 节点加载超时。请检查服务器的节点定义与扩展资源是否能正常读取。");
  })();
  ready.then(() => send("ready")).catch(error => send("error", { message: error.message }));

  function installTextEditing(app) {
    let current = null, savedCamera = null, restoring = false;
    let blurTimer, restoreTimer, resizeFrame;
    const editable = target => {
      if (!(target instanceof HTMLElement)) return null;
      const field = target.closest('textarea, input, [contenteditable="true"]');
      if (!field || field.disabled || field.readOnly || !app.canvasContainer.contains(field)) return null;
      if (field.tagName === "INPUT" && !["text", "search", "url", "email", "tel", "password", "number"].includes(field.type)) return null;
      return field;
    };
    function restoreField() {
      if (!current) return;
      current.field.classList.remove("pocket-canvas-text-edit");
      for (const name of ["--pocket-input-height", "--pocket-input-font", "--pocket-input-padding"]) current.field.style.removeProperty(name);
      for (const wrapper of current.wrappers) wrapper.classList.remove("pocket-canvas-edit-wrapper");
      if (current.widget) {
        if (current.hadHideOnZoom) current.widget.options.hideOnZoom = current.hideOnZoom;
        else delete current.widget.options.hideOnZoom;
      }
      current = null;
    }
    function restoreSoon() {
      clearTimeout(restoreTimer);
      restoreTimer = setTimeout(() => {
        if (current || !savedCamera) return;
        const canvas = app.canvas;
        canvas.ds.scale = savedCamera.scale;
        canvas.ds.offset[0] = savedCamera.x; canvas.ds.offset[1] = savedCamera.y;
        savedCamera = null; restoring = false;
        canvas.setDirty(true, true);
      }, 350);
    }
    function fitField() {
      if (!current?.field.isConnected) return;
      const canvas = app.canvas, rect = canvas.canvas.getBoundingClientRect();
      const visual = window.visualViewport;
      const left = Math.max(rect.left, visual?.offsetLeft ?? 0), top = Math.max(rect.top, visual?.offsetTop ?? 0);
      const right = Math.min(rect.right, (visual?.offsetLeft ?? 0) + (visual?.width ?? window.innerWidth));
      const bottom = Math.min(rect.bottom, (visual?.offsetTop ?? 0) + (visual?.height ?? window.innerHeight));
      if (right - left < 32 || bottom - top < 48) return;
      const camera = textInputCamera(current.bounds, { x: left - rect.left, y: top - rect.top, width: right - left, height: bottom - top });
      const visibleHeight = current.field.tagName === "INPUT" ? Math.min(camera.maxHeight, 40 / camera.scale) : camera.maxHeight;
      current.field.style.setProperty("--pocket-input-height", `${visibleHeight}px`);
      current.field.style.setProperty("--pocket-input-font", `${camera.fontSize}px`);
      current.field.style.setProperty("--pocket-input-padding", `${8 / camera.scale}px`);
      canvas.ds.scale = camera.scale;
      canvas.ds.offset[0] = camera.offset[0]; canvas.ds.offset[1] = camera.offset[1];
      canvas.setDirty(true, true);
    }
    function begin(field) {
      clearTimeout(blurTimer); clearTimeout(restoreTimer);
      if (current?.field === field) return;
      const canvas = app.canvas, rect = field.getBoundingClientRect(), area = canvas.canvas.getBoundingClientRect();
      if (!savedCamera) savedCamera = { scale: canvas.ds.scale, x: canvas.ds.offset[0], y: canvas.ds.offset[1] };
      const bounds = { x: (rect.left - area.left) / canvas.ds.scale - canvas.ds.offset[0],
        y: (rect.top - area.top) / canvas.ds.scale - canvas.ds.offset[1], width: rect.width / canvas.ds.scale };
      restoreField(); restoring = false;
      let owner, widget;
      for (const node of canvas.graph?._nodes ?? []) {
        const found = node.widgets?.find(w => w.element === field || w.element?.contains?.(field));
        if (found) { owner = node; widget = found; break; }
      }
      const wrappers = [];
      const mount = field.closest(".dom-widget");
      if (mount && field !== mount) {
        for (let parent = field.parentElement; parent; parent = parent.parentElement) {
          wrappers.push(parent);
          parent.classList.add("pocket-canvas-edit-wrapper");
          if (parent === mount) break;
        }
      }
      current = { field, bounds, widget, wrappers, hadHideOnZoom: widget ? Object.hasOwn(widget.options, "hideOnZoom") : false, hideOnZoom: widget?.options.hideOnZoom };
      if (widget) widget.options.hideOnZoom = false;
      field.classList.add("pocket-canvas-text-edit");
      send("textEditing", { active: true, nodeID: owner ? String(owner.id) : "" });
      fitField();
    }
    function end() {
      if (!current) return;
      restoreField(); restoring = true;
      send("textEditing", { active: false });
      restoreSoon();
    }
    function resized() {
      if (current) {
        fitField(); cancelAnimationFrame(resizeFrame);
        resizeFrame = requestAnimationFrame(fitField);
      } else if (restoring) restoreSoon();
      return !!current || restoring;
    }
    document.addEventListener("focusin", event => { const field = editable(event.target); if (field) begin(field); }, true);
    document.addEventListener("focusout", event => {
      if (event.target !== current?.field) return;
      clearTimeout(blurTimer);
      blurTimer = setTimeout(() => {
        const next = editable(document.activeElement);
        if (next) begin(next); else end();
      }, 60);
    }, true);
    window.addEventListener("resize", resized);
    window.visualViewport?.addEventListener("resize", resized);
    window.visualViewport?.addEventListener("scroll", resized);
    return {
      get editing() { return !!current; },
      get busy() { return !!current || restoring; },
      resized,
      finish() { current?.field.blur(); end(); return true; },
      reset() {
        const field = current?.field;
        restoreField(); savedCamera = null; restoring = false;
        clearTimeout(blurTimer); clearTimeout(restoreTimer); cancelAnimationFrame(resizeFrame);
        field?.blur();
        if (field) send("textEditing", { active: false });
      }
    };
  }

  const commands = {
    undo: "Comfy.Undo", redo: "Comfy.Redo", copy: "Comfy.Canvas.CopySelected",
    paste: "Comfy.Canvas.PasteFromClipboard", selectAll: "Comfy.Canvas.SelectAll",
    delete: "Comfy.Canvas.DeleteSelectedItems"
  };
  window.PocketCanvas = {
    samplingPreview(payload) {
      if (!loaded || app.rootGraph.id !== ownedGraphID) return false;
      return showSamplingPreview(app.rootGraph, JSON.parse(payload));
    },
    prepareAsset(x, y, asset, token) {
      pendingAsset = undefined;
      if (!loaded || app.rootGraph.id !== ownedGraphID || textEditor?.busy) throw new Error("请先完成当前编辑。");
      const canvas = app.canvas, visual = window.visualViewport;
      const clientX = (visual?.offsetLeft ?? 0) + x * (visual?.width ?? window.innerWidth);
      const clientY = (visual?.offsetTop ?? 0) + y * (visual?.height ?? window.innerHeight);
      const graph = canvas.graph;
      const bounds = canvas.canvas.getBoundingClientRect();
      if (clientX < bounds.left || clientX > bounds.right || clientY < bounds.top || clientY > bounds.bottom)
        throw new Error("请把资产拖到画布中的文件节点。");
      const hit = document.elementFromPoint(clientX, clientY);
      const point = canvas.convertEventToCanvasOffset({ clientX, clientY });
      const domNodeID = hit?.closest("[data-node-id]")?.getAttribute("data-node-id");
      const node = (domNodeID && nodeAt(graph, domNodeID)) || graph.getNodeOnPos(...point);
      const reference = dropReferenceAsset(app, node, hit, asset, clientX, clientY);
      if (reference) return reference;
      const widget = assetInputWidget(node, asset.media_kind, node?.getWidgetOnPos?.(...point));
      if (!widget) throw new Error("请选择支持此文件的加载节点或参考图区。");
      pendingAsset = { token, graph, node, widget, kind: asset.media_kind };
      return "input";
    },
    async importAsset(token, value) {
      const target = pendingAsset;
      if (target?.token !== token) throw new Error("导入目标已改变。");
      pendingAsset = undefined;
      if (!loaded || app.rootGraph.id !== ownedGraphID || app.canvas.graph !== target.graph ||
          nodeAt(target.graph, target.node.id) !== target.node || textEditor?.busy ||
          assetInputWidget(target.node, target.kind, target.widget) !== target.widget) {
        throw new Error("节点或文件控件已改变，请重新拖放。");
      }
      return await setMobileWidget(app, target.node.id, 0, value, target.widget.name, true);
    },
    overviewPreference(enabled) { tapToFocus = !!enabled; return true; },
    nodeAppearance(enabled, palette) { return setNodeAppearance(app?.canvas, enabled, palette); },
    async load(text) {
      await ready;
      textEditor?.reset();
      const value = JSON.parse(text);
      loaded = false; overviewGraph = null;
      initialPrompt = value.prompt;
      if (value.workflow?.nodes) {
        // Lazy's director restores its DOM timeline from named serialized properties.
        // Populate those before configuration so its cached editor and execution widgets agree.
        for (const node of value.workflow.nodes) {
          const spec = value.prompt[String(node.id)];
          if (node.type !== "LazyH3Director" || spec?.class_type !== "LazyH3Director") continue;
          node.properties = { ...node.properties, has_serialized_properties: true };
          for (const [key, field] of Object.entries(spec.inputs)) {
            if (["string", "number", "boolean"].includes(typeof field)) node.properties[key] = field;
          }
        }
        await loadWorkflowGraph(app, value.workflow, value.name);
        await new Promise(resolve => setTimeout(resolve, 0));
        requireWorkflow(app, value.workflow);
        const currentOutput = await executablePrompt(app, value.prompt);
        requireWorkflow(app, value.workflow);
        restoreExecutionModes(app, value.prompt, currentOutput);
        let unmapped = await applyPrompt(app, value.prompt, value.workflow);
        // Third-party widgets may finish configuration on animation frames.
        for (const delay of [100, 300]) {
          if (!unmapped.length) break;
          await new Promise(resolve => setTimeout(resolve, delay));
          unmapped = await applyPrompt(app, value.prompt, value.workflow);
        }
        if (unmapped.length) {
          mismatch = true;
          // Keep the existing graph available for inspection; do not silently
          // replace newer phone parameters with stale canvas widget values.
          send("mismatch", { fields: unmapped, message: `有 ${unmapped.length} 项参数需要核对，当前以只读方式显示节点。原工作流和手机参数已保留。` });
          return false;
        }
      } else {
        await app.loadApiJson(value.prompt, value.name);
      }
      mismatch = false; loaded = true;
      ownedGraphID = app.rootGraph.id;
      this.fit();
      send("loaded");
      return true;
    },
    async rebuild(name) {
      if (!initialPrompt) throw new Error("工作流尚未载入。");
      textEditor?.reset();
      await app.loadApiJson(initialPrompt, name);
      mismatch = false; loaded = true;
      ownedGraphID = app.rootGraph.id;
      this.fit(); send("loaded"); return true;
    },
    async snapshot() {
      // Serializers and virtual/custom widgets may update DOM. Leave them alone
      // while an input or IME composition is active; the next autosave commits it.
      if (textEditor?.editing) return null;
      if (!loaded || mismatch) throw new Error("画布尚未准备好保存。");
      if (ownedGraphID && app.rootGraph.id !== ownedGraphID) {
        send("foreignGraph");
        throw new Error("ComfyUI 面板已切换到其他工作流。请使用手机画布菜单中的“切换工作流”，或重新加载当前画布，避免覆盖原工作流。");
      }
      const { workflow } = await app.graphToPrompt(app.rootGraph);
      if (textEditor?.editing) return null;
      const output = await executablePrompt(app, initialPrompt);
      if (textEditor?.editing) return null;
      if (ownedGraphID && app.rootGraph.id !== ownedGraphID) {
        send("foreignGraph");
        throw new Error("导出期间画布切换到了其他工作流，已停止保存。请重新载入当前工作流。");
      }
      return JSON.stringify({ prompt: output, workflow });
    },
    async command(name) {
      if (!loaded) throw new Error("画布尚未准备好。");
      if (!commands[name]) throw new Error("不支持的画布操作。");
      document.activeElement?.blur?.();
      const tracker = app.extensionManager.workflow.activeWorkflow?.changeTracker;
      tracker?.captureCanvasState?.();
      await app.extensionManager.command.execute(commands[name]);
      if (name !== "undo" && name !== "redo") tracker?.captureCanvasState?.();
      app.canvas.setDirty(true, true);
      return true;
    },
    fit() {
      if (textEditor?.busy) return true;
      const canvas = app.canvas, nodes = canvas.graph?._nodes ?? [];
      overviewGraph = canvas.graph; updateMap();
      if (!nodes.length) return true;
      const minX = Math.min(...nodes.map(node => node.pos[0])) - 40;
      const minY = Math.min(...nodes.map(node => node.pos[1])) - 60;
      const maxX = Math.max(...nodes.map(node => node.pos[0] + node.size[0])) + 40;
      const maxY = Math.max(...nodes.map(node => node.pos[1] + node.size[1])) + 40;
      const rect = canvas.canvas.getBoundingClientRect();
      canvas.ds.scale = Math.min(1, Math.max(0.02, Math.min(rect.width / Math.max(1, maxX - minX), rect.height / Math.max(1, maxY - minY))));
      overviewScale = canvas.ds.scale;
      canvas.ds.offset[0] = -minX + (rect.width / canvas.ds.scale - (maxX - minX)) / 2;
      canvas.ds.offset[1] = -minY + (rect.height / canvas.ds.scale - (maxY - minY)) / 2;
      canvas.setDirty(true, true); return true;
    },
    zoom(factor) {
      overviewGraph = null;
      const canvas = app.canvas;
      const rect = canvas.canvas.getBoundingClientRect();
      canvas.ds.changeScale(canvas.ds.scale * factor, [rect.width / 2, rect.height / 2]);
      canvas.setDirty(true, true); return true;
    },
    addNode(type) {
      if (!loaded) throw new Error("画布尚未准备好。");
      const node = window.LiteGraph.createNode(type);
      if (!node) throw new Error("服务器未安装此节点。");
      return change(app, graph => {
        const rect = app.canvas.canvas.getBoundingClientRect();
        node.pos = [rect.width / 2 / app.canvas.ds.scale - app.canvas.ds.offset[0], rect.height / 2 / app.canvas.ds.scale - app.canvas.ds.offset[1]];
        graph.add(node); app.canvas.selectNode(node); return String(node.id);
      });
    },
    library() {
      return JSON.stringify(Object.entries(window.LiteGraph.registered_node_types).map(([type, node]) => ({
        type, title: node.title || type, category: node.category || "其他"
      })).sort((a, b) => a.title.localeCompare(b.title)));
    },
    scene() { updateMap(); return JSON.stringify(mobileScene(app)); },
    async stepParameter(id, type, name, direction, path) {
      if (!loaded || app.rootGraph.id !== ownedGraphID || ![-1, 1].includes(direction) ||
          JSON.stringify(bookmarkLocations(app).graphPath) !== JSON.stringify(path)) throw new Error("画布已切换，请重新选择节点。");
      const node = nodeAt(app.canvas.graph, id);
      const widget = node?.widgets?.find(w => w.name === name);
      if (node?.type !== type || !["steps", "cfg"].includes(name) || !Number.isFinite(widget?.value)) throw new Error("节点参数已变化。");
      const customStep = widget.options?.step2;
      const step = Number.isFinite(customStep) && customStep > 0 ? customStep : (name === "steps" ? 1 : 0.1);
      const value = Math.max(widget.options?.min ?? -Infinity, Math.min(widget.options?.max ?? Infinity, Number((widget.value + direction * step).toFixed(8))));
      if (value !== widget.value) await setMobileWidget(app, id, 0, value, name);
      return true;
    },
    async widget(id, index, value, name) { return await setMobileWidget(app, id, index, value, name); },
    moveNode(id, x, y) { return moveMobileNode(app, id, x, y); },
    nodeMode(id, mode) {
      if (![0, 2, 4].includes(mode)) throw new Error("无效的节点执行模式。");
      const node = nodeAt(app.canvas.graph, id);
      if (!node) throw new Error("节点不存在。");
      return change(app, () => { node.mode = mode; return true; });
    },
    groupMode(id, mode) {
      if (![0, 2, 4].includes(mode)) throw new Error("无效的节点执行模式。");
      const scene = mobileScene(app);
      if (!scene.groups.some(g => g.id === id)) throw new Error("分组已改变，请重新选择。");
      const members = scene.nodes.filter(n => n.group === id);
      return change(app, graph => {
        for (const member of members) {
          // UI controllers and annotations do not represent an execution stage.
          if (/^(Note|MarkdownNote|Reroute)$/.test(member.type) || member.type.startsWith("Fast Groups")) continue;
          const node = nodeAt(graph, member.id); if (node) node.mode = mode;
        }
        return true;
      });
    },
    removeNode(id) {
      const node = nodeAt(app.canvas.graph, id);
      if (!node) throw new Error("节点不存在。");
      return change(app, graph => { graph.remove(node); return true; });
    },
    focus(id) {
      if (textEditor?.busy) return true;
      overviewGraph = null; updateMap();
      return focusNode(app, id);
    },
    focusBookmark(path, id, type) {
      if (textEditor?.busy) return false;
      const focused = focusBookmark(app, path, id, type);
      if (focused) overviewGraph = null;
      return focused;
    },
    viewport() { return textEditor?.resized() ?? false; },
    finishText() { return textEditor?.finish() ?? true; },
    tools(enabled) {
      document.documentElement.classList.toggle("pocket-canvas-compact", !enabled);
      return true;
    },
    async chrome(enabled) {
      document.documentElement.classList.toggle("pocket-canvas-isolated", !enabled);
      if (app.extensionManager?.focusMode === enabled) app.extensionManager.toggleFocusMode?.();
      await layoutSettled(); markWorkspace(); app.canvas.resize?.();
      return true;
    },
    subgraph(id) {
      textEditor?.reset();
      if (!id) { app.canvas.setGraph(app.rootGraph); return true; }
      const node = nodeAt(app.canvas.graph, id);
      if (!node?.subgraph) throw new Error("此节点没有子图。");
      app.canvas.openSubgraph(node.subgraph); return true;
    },
    ports() { return JSON.stringify(ports(app)); },
    connect(from, output, to, input) { return connect(app, from, output, to, input); },
    disconnect(id, slot) { return disconnect(app, id, slot); }
  };

  const style = document.createElement("style");
  document.documentElement?.classList?.add("pocket-canvas-compact");
  document.documentElement?.classList?.add("pocket-canvas-isolated");
  style.textContent = `.pocket-canvas-isolated #graph-canvas-container { position: fixed !important; inset: 0 !important; width: 100vw !important; height: 100dvh !important; z-index: 2; }
    .pocket-canvas-isolated [data-pocket-workspace], .pocket-canvas-isolated .workflow-tabs-container,
    .pocket-canvas-isolated .side-toolbar-container, .pocket-canvas-isolated .comfy-menu,
    .pocket-canvas-isolated #comfyui-body-top, .pocket-canvas-isolated #comfyui-body-bottom,
    .pocket-canvas-isolated #comfyui-body-left, .pocket-canvas-isolated #comfyui-body-right { display: none !important; }
    #lazy-res-monitor, rgthree-progress-bar { display: none !important; }
    .pocket-canvas-compact #graph-canvas-container .selection-toolbox,
    .pocket-canvas-compact #graph-canvas-container [role="toolbar"]:has([data-testid="zoom-controls-button"]) { display: none !important; }
    #pocket-overview-map { position:fixed; z-index:5; bottom:8px; left:10px; pointer-events:none; background:#222329de; border:1px solid #a5a7bb70; border-radius:8px; color:white; padding:4px 5px; display:none; font:10px system-ui; text-align:right; }
    .pocket-canvas-isolated #pocket-overview-map:not([hidden]) { display:block; }
    #pocket-overview-map canvas { width:88px; height:42px; display:block; }
    @media (max-height:340px) { #pocket-overview-map { visibility:hidden; } }
    canvas { touch-action: none; } input, textarea, select { font-size: max(16px, 1em); }
    .pocket-canvas-edit-wrapper { clip-path: none !important; overflow: visible !important; }
    .dom-widget.pocket-canvas-edit-wrapper { z-index: 2147483000 !important; }
    .pocket-canvas-text-edit {
      font-size: var(--pocket-input-font) !important; line-height: 1.45 !important;
      height: var(--pocket-input-height) !important; min-height: var(--pocket-input-height) !important;
      max-height: var(--pocket-input-height) !important; padding: var(--pocket-input-padding) !important;
      resize: none !important; box-sizing: border-box !important; overflow: auto !important;
      overscroll-behavior: contain; touch-action: auto;
      background: var(--comfy-input-bg, #202124) !important;
    }
    .litecontextmenu { max-height: 70dvh; overflow-y: auto; } .litecontextmenu .litemenu-entry { min-height: 36px; }
    html, body { overscroll-behavior: none; }`;
  document.head.append(style);
})();
