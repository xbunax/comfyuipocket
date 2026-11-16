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

  async function applyPrompt(app, prompt) {
    const before = (await app.graphToPrompt(app.rootGraph)).output;
    const unmapped = [];
    for (const [id, spec] of Object.entries(prompt)) {
      for (const [name, value] of Object.entries(spec.inputs)) {
        if (equivalentInput(spec, before?.[id], name)) continue;
        const node = executionNode(app.rootGraph, id);
        // Only actual widgets are assigned. Connections, dynamic structures and
        // custom serializers are never inferred from widget position.
        const widget = node?.widgets?.find(item => item.name === name);
        if (!widget || (value !== null && typeof value === "object")) {
          unmapped.push(`${id}.${name}`); continue;
        }
        widget.value = value;
        await widget.callback?.(value, app.canvas, node, undefined, undefined);
      }
    }
    const after = (await app.graphToPrompt(app.rootGraph)).output;
    for (const [id, spec] of Object.entries(prompt)) {
      for (const [name, value] of Object.entries(spec.inputs)) {
        if (!equivalentInput(spec, after?.[id], name)) {
          if (!unmapped.includes(`${id}.${name}`)) unmapped.push(`${id}.${name}`);
        }
      }
    }
    return unmapped;
  }

  function equivalentInput(expected, actual, name) {
    const a = expected.inputs[name], b = actual?.inputs?.[name];
    if (JSON.stringify(a) === JSON.stringify(b)) return true;
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
    return { nodes, groups, links, nested: graph !== app.rootGraph };
  }

  async function setMobileWidget(app, id, index, value) {
    const node = nodeAt(app.canvas.graph ?? app.rootGraph, id);
    const widget = node?.widgets?.[Number(index)];
    if (!widget || !["string", "number", "boolean"].includes(typeof value) || typeof widget.value !== typeof value) throw new Error("控件类型已改变，请重新打开节点。");
    if (node.inputs?.some(i => i.link != null && i.widget?.name === widget.name)) throw new Error("此参数已连接输入，请编辑上游节点。");
    if (typeof value === "number" && (!Number.isFinite(value) || value < (widget.options?.min ?? -Infinity) || value > (widget.options?.max ?? Infinity))) throw new Error("数值超出节点范围。");
    let choices = widget.options?.values;
    if (typeof choices === "function") choices = choices(widget, node);
    if (Array.isArray(choices) && !choices.includes(value)) throw new Error("此选项已不可用，请刷新节点。");
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

  function moveMobileNode(app, id, x, y) {
    const node = nodeAt(app.canvas.graph ?? app.rootGraph, id);
    if (!node || !Number.isFinite(x) || !Number.isFinite(y)) throw new Error("节点位置无效。");
    return change(app, () => { node.pos[0] = x; node.pos[1] = y; return true; });
  }

  // The same graph operations are exercised by Node tests and the actual editor.
  if (typeof module !== "undefined" && module.exports) {
    module.exports = { executionNode, applyPrompt, change, ports, connect, disconnect, mobileScene, setMobileWidget, moveMobileNode };
    return;
  }

  const send = (type, extra = {}) => window.webkit?.messageHandlers.pocketCanvas.postMessage({ type, ...extra });
  let app;
  let loaded = false;
  let mismatch = false;
  let initialPrompt = null;
  const ready = (async () => {
    for (let attempt = 0; attempt < 300; attempt++) {
      app = window.comfyAPI?.app?.app;
      if (app?.canvas && app?.rootGraph && app?.vueAppReady && typeof app.loadGraphData === "function") return app;
      await new Promise(resolve => setTimeout(resolve, 200));
    }
    throw new Error("ComfyUI 编辑器启动超时，请检查服务器连接并重试。");
  })();
  ready.then(() => send("ready")).catch(error => send("error", { message: error.message }));

  const commands = {
    undo: "Comfy.Undo", redo: "Comfy.Redo", copy: "Comfy.Canvas.CopySelected",
    paste: "Comfy.Canvas.PasteFromClipboard", selectAll: "Comfy.Canvas.SelectAll",
    delete: "Comfy.Canvas.DeleteSelectedItems"
  };
  window.PocketCanvas = {
    async load(text) {
      await ready;
      const value = JSON.parse(text);
      loaded = false;
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
        await app.loadGraphData(value.workflow, true, true, value.name);
        await new Promise(resolve => setTimeout(resolve, 0));
        const unmapped = await applyPrompt(app, value.prompt);
        if (unmapped.length) {
          mismatch = true;
          // Keep the existing graph available for inspection; do not silently
          // replace newer phone parameters with stale canvas widget values.
          send("mismatch", { message: `画布与参数面板有 ${unmapped.length} 项无法自动对应。可重新从当前参数创建可编辑画布，原副本会保留。` });
          return false;
        }
      } else {
        await app.loadApiJson(value.prompt, value.name);
      }
      mismatch = false; loaded = true;
      this.fit();
      send("loaded");
      return true;
    },
    async rebuild(name) {
      if (!initialPrompt) throw new Error("工作流尚未载入。");
      await app.loadApiJson(initialPrompt, name);
      mismatch = false; loaded = true;
      this.fit(); send("loaded"); return true;
    },
    async snapshot() {
      if (!loaded || mismatch) throw new Error("画布尚未准备好保存。");
      const { output, workflow } = await app.graphToPrompt(app.rootGraph);
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
      const canvas = app.canvas, nodes = canvas.graph?._nodes ?? [];
      if (!nodes.length) return true;
      const minX = Math.min(...nodes.map(node => node.pos[0])) - 40;
      const minY = Math.min(...nodes.map(node => node.pos[1])) - 60;
      const maxX = Math.max(...nodes.map(node => node.pos[0] + node.size[0])) + 40;
      const maxY = Math.max(...nodes.map(node => node.pos[1] + node.size[1])) + 40;
      const rect = canvas.canvas.getBoundingClientRect();
      canvas.ds.scale = Math.min(1, Math.max(0.02, Math.min(rect.width / Math.max(1, maxX - minX), rect.height / Math.max(1, maxY - minY))));
      canvas.ds.offset[0] = -minX + (rect.width / canvas.ds.scale - (maxX - minX)) / 2;
      canvas.ds.offset[1] = -minY + (rect.height / canvas.ds.scale - (maxY - minY)) / 2;
      canvas.setDirty(true, true); return true;
    },
    zoom(factor) {
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
    scene() { return JSON.stringify(mobileScene(app)); },
    async widget(id, index, value) { return await setMobileWidget(app, id, index, value); },
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
      const node = nodeAt(app.canvas.graph, id);
      if (!node) throw new Error("节点不存在。");
      app.canvas.selectNode(node);
      const rect = app.canvas.canvas.getBoundingClientRect();
      app.canvas.ds.scale = Math.min(1, rect.width / Math.max(280, node.size[0] + 40));
      app.canvas.ds.offset[0] = -node.pos[0] + 20;
      app.canvas.ds.offset[1] = -node.pos[1] + 70;
      app.canvas.setDirty(true, true); return true;
    },
    subgraph(id) {
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
  style.textContent = `canvas { touch-action: none; } input, textarea, select { font-size: max(16px, 1em); }
    .litecontextmenu { max-height: 70dvh; overflow-y: auto; } .litecontextmenu .litemenu-entry { min-height: 36px; }
    html, body { overscroll-behavior: none; }`;
  document.head.append(style);
})();
