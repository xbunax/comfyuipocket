import { app } from "../../scripts/app.js";
import { api } from "../../scripts/api.js";

function element(tag, text, parent) {
  const node = document.createElement(tag);
  if (text) node.textContent = text;
  parent?.append(node);
  return node;
}

async function checked(path, options) {
  const response = await api.fetchApi(path, options);
  if (!response.ok) throw new Error(await response.text());
  return response.json();
}

function panel(container) {
  container.replaceChildren();
  const root = element("div", "", container);
  root.style.cssText = "padding:20px;display:flex;flex-direction:column;gap:14px;overflow:auto;height:100%;box-sizing:border-box";
  element("h2", "ComfyUI Pocket", root);
  element("p", "把当前工作流保存到本机目录，再从 iPhone 同步。无需中转服务器。", root);
  const name = element("input", "", root);
  name.placeholder = "工作流名称";
  name.maxLength = 200;
  name.setAttribute("aria-label", "工作流名称");
  const save = element("button", "保存当前工作流到 Pocket", root);
  const download = element("button", "下载当前工作流 API JSON", root);
  const refresh = element("button", "刷新列表", root);
  const status = element("p", "", root);
  status.setAttribute("role", "status");
  const list = element("div", "", root);
  let selectedID = null;

  async function load() {
    const result = await checked("/pocket/v1/workflows");
    list.replaceChildren();
    for (const item of result.workflows) {
      const row = element("div", "", list);
      row.style.cssText = "border-top:1px solid #8885;padding:12px 0;display:flex;flex-wrap:wrap;gap:8px;align-items:center";
      element("span", `${item.name} · ${item.nodes} nodes`, row);
      const overwrite = element("button", "选择覆盖", row);
      overwrite.onclick = () => {
        selectedID = item.id; name.value = item.name;
        status.textContent = `下次保存将覆盖：${item.name}`;
      };
      const remove = element("button", "删除", row);
      remove.onclick = async () => {
        if (!window.confirm(`删除 Pocket 目录中的“${item.name}”？`)) return;
        try {
          await checked(`/pocket/v1/workflows/${item.id}`, { method: "DELETE" });
          if (selectedID === item.id) selectedID = null;
          await load();
        } catch (error) { status.textContent = error.message; }
      };
    }
  }

  async function snapshot() {
    // Use ComfyUI's own serializer so links, custom nodes and subgraphs retain their meaning.
    const { output, workflow } = await app.graphToPrompt();
    if (!output || Object.keys(output).length === 0) throw new Error("当前工作流没有可执行节点。");
    return { name: name.value.trim() || "Untitled", prompt: output, workflow };
  }

  save.onclick = async () => {
    save.disabled = true;
    try {
      const data = await snapshot();
      if (selectedID) data.id = selectedID;
      const result = await checked("/pocket/v1/workflows", {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data),
      });
      selectedID = null;
      status.textContent = `已保存 ${result.name}。在手机工作台选择“从电脑同步”。`;
      await load();
    } catch (error) { status.textContent = error.message; }
    finally { save.disabled = false; }
  };
  download.onclick = async () => {
    try {
      const data = await snapshot();
      const url = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], { type: "application/json" }));
      const link = element("a");
      link.href = url; link.download = `${data.name.replace(/[\\/:*?"<>|]/g, "_")}.pocket.json`;
      link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
      status.textContent = "已导出，可通过文件 App 导入 iPhone。";
    } catch (error) { status.textContent = error.message; }
  };
  refresh.onclick = () => load().catch(error => { status.textContent = error.message; });
  load().catch(error => { status.textContent = error.message; });
}

app.registerExtension({
  name: "ComfyUIPocket.Catalog",
  async setup() {
    app.extensionManager.registerSidebarTab({
      id: "comfyui-pocket", icon: "pi pi-mobile", title: "Pocket",
      tooltip: "ComfyUI Pocket · 本机工作流", type: "custom", render: panel,
    });
  },
});
