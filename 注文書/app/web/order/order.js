"use strict";
elements.addCompanyButton.addEventListener("click", addCompany);
elements.deleteCompanyButton.addEventListener("click", deleteCompanyForSelection);
elements.targetMonth.addEventListener("change", () => { state.targetMonth = elements.targetMonth.value; setDirty(); });
elements.selectAll.addEventListener("change", () => {
  visibleRecords().forEach((record) => elements.selectAll.checked ? state.selectedIds.add(record._id) : state.selectedIds.delete(record._id));
  render();
});
elements.clearSelectionButton.addEventListener("click", () => { state.selectedIds.clear(); render(); });
elements.collapseAllButton.addEventListener("click", collapseAll);
elements.expandAllButton.addEventListener("click", expandAll);
elements.outputRootInput.addEventListener("input", () => { state.outputRoot = text(elements.outputRootInput.value); });
elements.outputRootInput.addEventListener("change", persistOutputPath);
elements.selectOutputButton.addEventListener("click", selectOutputFolder);
elements.reloadButton.addEventListener("click", () => loadData(true));
elements.saveButton.addEventListener("click", () => saveData(false));
elements.generateButton.addEventListener("click", generateOrders);
elements.shutdownButton.addEventListener("click", async () => {
  const question = state.dirty
    ? "保存していない変更があります。\nこのまま終了すると、変更は失われます。\n\n終了しますか？"
    : "注文書作成ツールを終了します。\n\n終了しますか？";
  if (!window.confirm(question)) return;
  setBusy(true, "終了中");
  try { await api("/api/shutdown", { method: "POST" }); setDirty(false); showResult("注文書作成ツールを終了しました。この画面を閉じてください。"); }
  catch (error) { showResult("終了処理でエラーが発生しました。", error.message, true); }
});
window.addEventListener("beforeunload", (event) => { if (state.dirty) { event.preventDefault(); event.returnValue = ""; } });

loadData();
