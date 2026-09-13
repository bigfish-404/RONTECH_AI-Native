"use strict";

(async () => {
  const root = document.getElementById("appRoot");
  try {
    const response = await fetch("/order/order.html", { cache: "no-store" });
    if (!response.ok) throw new Error("注文書画面を読み込めませんでした。");
    root.innerHTML = await response.text();

    const scripts = [
      "/shared/core.js",
      "/order/order-view.js",
      "/order/order-validation.js",
      "/order/order-actions.js",
      "/order/order.js"
    ];
    for (const source of scripts) {
      await new Promise((resolve, reject) => {
        const script = document.createElement("script");
        script.src = source;
        script.onload = resolve;
        script.onerror = () => reject(new Error(`${source} を読み込めませんでした。`));
        document.body.append(script);
      });
    }
  } catch (error) {
    root.innerHTML = `<main class="startup-error"><h1>注文書作成ツールを開けませんでした</h1><p>${String(error.message || error)}</p></main>`;
  }
})();
