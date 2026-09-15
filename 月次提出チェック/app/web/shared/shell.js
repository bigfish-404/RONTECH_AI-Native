"use strict";

(async () => {
  const root = document.getElementById("appRoot");
  try {
    const response = await fetch("/check/check.html", { cache: "no-store" });
    if (!response.ok) throw new Error("チェック画面を読み込めませんでした。");
    root.innerHTML = await response.text();

    const scripts = [
      "/shared/core.js",
      "/check/check-format.js",
      "/check/check-view.js",
      "/check/check-actions.js",
      "/check/check.js"
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
    root.innerHTML = `<main class="startup-error"><h1>月次提出チェックを開けませんでした</h1><p>${String(error.message || error)}</p></main>`;
  }
})();
