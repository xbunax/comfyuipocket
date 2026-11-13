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
        if (JSON.stringify(before?.[id]?.inputs?.[name]) === JSON.stringify(value)) continue;
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
        if (JSON.stringify(after?.[id]?.inputs?.[name]) !== JSON.stringify(value)) {
          if (!unmapped.includes(`${id}.${name}`)) unmapped.push(`${id}.${name}`);
        }
      }
    }
    return unmapped;
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

  // The same graph operations are exercised by Node tests and the actual editor.
  if (typeof module !== "undefined" && module.exports) {
    module.exports = { executionNode, applyPrompt, change, ports, connect, disconnect };
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
        await app.loadGraphData(value.workflow, true, true, value.name);
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
