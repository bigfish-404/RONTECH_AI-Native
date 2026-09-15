"use strict";

function staffFromServer(list) {
  return asArray(list).map((person) => ({ _id: makeId(), 氏名: text(person.氏名), 定期券: Boolean(person.定期券) }));
}
function focusStaff(id) {
  elements.staffBody.querySelector(`[data-id="${CSS.escape(id)}"] .staff-name-input`)?.focus();
}
function validateStaff() {
  const seen = new Map();
  for (const [index, person] of state.staff.entries()) {
    const name = text(person.氏名);
    if (!name) return { id: person._id, message: `${index + 1}行目の氏名が空欄です。` };
    const key = normalizeName(name);
    if (seen.has(key)) return { id: person._id, message: `「${name}」が${seen.get(key)}行目と重複しています。` };
    seen.set(key, index + 1);
  }
  return null;
}

function addStaff() {
  const empty = state.staff.find((person) => !text(person.氏名));
  if (empty) {
    showToast("未入力の氏名があります。先に入力してください。", true);
    focusStaff(empty._id);
    return;
  }
  const person = { _id: makeId(), 氏名: "", 定期券: false };
  state.staff.push(person);
  setDirty();
  renderStaff();
  requestAnimationFrame(() => focusStaff(person._id));
}

function removeStaff(id) {
  const person = state.staff.find((item) => item._id === id);
  if (!person) return;
  const name = text(person.氏名);
  if (name && !window.confirm(`「${name}」を人員リストから削除します。\n「リストを保存」を押すと確定します。\n\n削除しますか？`)) return;
  state.staff = state.staff.filter((item) => item._id !== id);
  setDirty();
  renderStaff();
  if (name) showToast(`「${name}」を削除しました。「リストを保存」を押すと確定します。`);
}

async function loadData(confirmDiscard = false) {
  if (confirmDiscard && state.dirty && !window.confirm("保存していない人員リストの変更があります。\n再読込すると、変更は失われます。\n\n再読込しますか？")) return;
  setBusy(true, "読込中");
  try {
    const data = await api("/api/data");
    state.staff = staffFromServer(data.staff);
    state.targetMonth = text(data.targetMonth);
    state.folderPath = text(data.folderPath);
    elements.targetMonth.value = state.targetMonth;
    elements.folderPathInput.value = state.folderPath;
    elements.folderPathInput.dataset.savedValue = state.folderPath;
    setDirty(false);
    showResult("人員リストを読み込みました。");
  } catch (error) {
    showResult("人員リストを読み込めませんでした。", error.message, true);
    showToast(error.message, true);
  } finally {
    setBusy(false);
    renderStaff();
    renderReport();
  }
}

async function saveStaff(silent = false) {
  const problem = validateStaff();
  if (problem) {
    showToast(problem.message, true);
    focusStaff(problem.id);
    return false;
  }
  setBusy(true, "保存中");
  try {
    const body = { staff: state.staff.map((person) => ({ 氏名: text(person.氏名), 定期券: Boolean(person.定期券) })) };
    const data = await api("/api/staff", { method: "POST", body });
    state.staff = staffFromServer(data.staff);
    setDirty(false);
    if (!silent) showToast("人員リストを保存しました。変更前のリストは backup フォルダに残してあります。");
    return true;
  } catch (error) {
    showToast(error.message, true);
    return false;
  } finally {
    setBusy(false);
    renderStaff();
  }
}

async function runCheck() {
  state.targetMonth = elements.targetMonth.value;
  state.folderPath = text(elements.folderPathInput.value);
  if (!state.targetMonth) {
    showToast("対象年月を選択してください。", true);
    elements.targetMonth.focus();
    return;
  }
  if (!state.staff.length) {
    showToast("人員リストに1名以上追加してください。", true);
    return;
  }
  if (!state.folderPath) {
    showToast("先に提出フォルダを選択してください。", true);
    await selectFolder();
    if (!state.folderPath) return;
  }
  if (state.dirty && !await saveStaff(true)) return;

  setBusy(true, "チェック中");
  showResult("提出ファイルをチェックしています。");
  try {
    const data = await api("/api/check", { method: "POST", body: { targetMonth: state.targetMonth, folderPath: state.folderPath } });
    state.report = normalizeReport(data.report);
    state.expanded = new Set();
    state.folderPath = text(state.report.folderPath);
    elements.folderPathInput.value = state.folderPath;
    elements.folderPathInput.dataset.savedValue = state.folderPath;
    const ng = state.report.results.filter((result) => result.overall === "ng").length;
    const warn = state.report.results.filter((result) => result.overall === "warn").length;
    const summary = ng || warn ? `チェックが終わりました。NG ${ng}名、注意 ${warn}名です。` : "チェックが終わりました。全員OKです。";
    showToast(summary);
    showResult(summary);
  } catch (error) {
    showResult("チェックできませんでした。", error.message, true);
    showToast(error.message, true);
  } finally {
    setBusy(false);
    renderStaff();
    renderReport();
  }
}

async function persistFolderPath() {
  const previous = elements.folderPathInput.dataset.savedValue || "";
  const requested = text(elements.folderPathInput.value);
  if (requested === previous) return;
  try {
    const result = await api("/api/folder-path", { method: "POST", body: { path: requested } });
    state.folderPath = text(result.path);
    elements.folderPathInput.value = state.folderPath;
    elements.folderPathInput.dataset.savedValue = state.folderPath;
    showToast(state.folderPath ? "提出フォルダを変更しました。" : "提出フォルダの設定を解除しました。");
  } catch (error) {
    state.folderPath = previous;
    elements.folderPathInput.value = previous;
    showToast(error.message, true);
  }
}

async function selectFolder() {
  if (selectFolder.pending) return selectFolder.pending;
  selectFolder.pending = (async () => {
    setBusy(true, "選択中");
    try {
      const started = await api("/api/select-folder", { method: "POST", body: { currentPath: text(elements.folderPathInput.value) } });
      let result = null;
      for (let attempt = 0; attempt < 1200; attempt += 1) {
        await new Promise((resolve) => setTimeout(resolve, 500));
        result = await api("/api/folder-selection", { method: "POST", body: { selectionId: started.selectionId } });
        if (!result.pending) break;
      }
      if (!result || result.pending) throw new Error("フォルダの選択がタイムアウトしました。");
      if (result.cancelled) return;
      state.folderPath = text(result.path);
      elements.folderPathInput.value = state.folderPath;
      elements.folderPathInput.dataset.savedValue = state.folderPath;
      showToast("提出フォルダを変更しました。");
    } catch (error) {
      showToast(error.message, true);
    } finally {
      setBusy(false);
      selectFolder.pending = null;
    }
  })();
  return selectFolder.pending;
}

async function copyMessage() {
  const value = elements.messageText.value;
  try {
    await navigator.clipboard.writeText(value);
  } catch {
    elements.messageText.select();
    document.execCommand("copy");
  }
  elements.copyMessageButton.textContent = "コピーしました";
  clearTimeout(copyMessage.timer);
  copyMessage.timer = setTimeout(() => { elements.copyMessageButton.textContent = "コピー"; }, 2000);
}
