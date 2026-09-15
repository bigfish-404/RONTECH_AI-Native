"use strict";

elements.addStaffButton.addEventListener("click", addStaff);
elements.saveStaffButton.addEventListener("click", () => saveStaff(false));
elements.reloadButton.addEventListener("click", () => loadData(true));
elements.runCheckButton.addEventListener("click", runCheck);
elements.targetMonth.addEventListener("change", () => { state.targetMonth = elements.targetMonth.value; });
elements.folderPathInput.addEventListener("change", persistFolderPath);
elements.selectFolderButton.addEventListener("click", selectFolder);
elements.problemOnly.addEventListener("change", () => { state.problemOnly = elements.problemOnly.checked; renderReport(); });
elements.copyMessageButton.addEventListener("click", copyMessage);
elements.closeMessageButton.addEventListener("click", () => elements.messageDialog.close());
elements.dismissMessageButton.addEventListener("click", () => elements.messageDialog.close());
elements.messageDialog.addEventListener("click", (event) => {
  if (event.target === elements.messageDialog) elements.messageDialog.close();
});
elements.shutdownButton.addEventListener("click", async () => {
  const question = state.dirty
    ? "保存していない人員リストの変更があります。\nこのまま終了すると、変更は失われます。\n\n終了しますか？"
    : "月次提出チェックを終了します。\n\n終了しますか？";
  if (!window.confirm(question)) return;
  setBusy(true, "終了中");
  try {
    await api("/api/shutdown", { method: "POST" });
    setDirty(false);
    showToast("月次提出チェックを終了しました。この画面を閉じてください。");
  } catch (error) {
    showToast(error.message, true);
  }
});
window.addEventListener("beforeunload", (event) => {
  if (state.dirty) {
    event.preventDefault();
    event.returnValue = "";
  }
});

loadData();
