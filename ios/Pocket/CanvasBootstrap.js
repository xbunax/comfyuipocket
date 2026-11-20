(() => {
  window.__POCKET_CANVAS__ = true;
  try { localStorage.setItem("comfyui-pocket.auto.v1", "off"); } catch {}

  const bridge = window.webkit?.messageHandlers.pocketNodeDefinitions;
  if (!bridge) return;
  const fetch = window.fetch.bind(window);
  const routes = new Set(["object_info", "api/object_info"].map(path => new URL(path, location.href).pathname));
  window.fetch = async function (input, options) {
    let url;
    try { url = new URL(input instanceof Request ? input.url : input, document.baseURI); }
    catch { return fetch(input, options); }
    if (url.origin !== location.origin || !routes.has(url.pathname) || url.search) return fetch(input, options);

    const request = new Request(input, options);
    const user = request.headers.get("comfy-user");
    if (request.method !== "GET" || request.headers.has("Authorization") ||
        (user && user !== "default") || request.credentials === "omit" || document.cookie) {
      return fetch(input, options);
    }
    const signal = request.signal;
    if (signal.aborted) return fetch(input, options);
    let cancel;
    const text = await new Promise(resolve => {
      cancel = () => resolve(null);
      signal.addEventListener("abort", cancel, { once: true });
      Promise.resolve().then(() => bridge.postMessage(null)).then(resolve, cancel);
    }).finally(() => signal.removeEventListener("abort", cancel));
    if (signal.aborted || typeof text !== "string") return fetch(input, options);
    return new Response(text, { headers: { "Content-Type": "application/json" } });
  };
})();
