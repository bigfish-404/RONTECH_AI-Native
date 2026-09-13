"use strict";

function addCompany() {
  if (state.records.some((record) => !text(record.宛先会社名))) {
    showToast("入力中の会社名を先に完成してください。", true);
    return;
  }
  const first = state.records[0] || {};
  state.records.push({
    _id: makeId(), 宛先会社名: "", 出力フォルダ名: "", 業務内容: "", 工程範囲: first.工程範囲 || "上記業務とそれに伴う附帯作業",
    技術者名: "", 単価: "", 固定契約: "N", 下限時間: first.下限時間 || "", 上限時間: first.上限時間 || "",
    弊社責任者: first.弊社責任者 || "", 備考: ""
  });
  setDirty();
  render();
  requestAnimationFrame(() => [...elements.companyList.querySelectorAll(".company-name-input")].at(-1)?.focus());
}
function addProject(companyName) {
  const companyRecords = allCompanyRecords(companyName);
  if (companyRecords.some((record) => !text(record.業務内容))) {
    showToast("入力中の案件名を先に完成してください。", true);
    return;
  }
  const first = companyRecords[0] || {};
  const record = {
    _id: makeId(), 宛先会社名: companyName, 出力フォルダ名: "", 業務内容: "",
    工程範囲: first.工程範囲 || "上記業務とそれに伴う附帯作業", 弊社責任者: first.弊社責任者 || "", 備考: "",
    技術者名: "", 単価: "", 固定契約: "N", 下限時間: first.下限時間 || "", 上限時間: first.上限時間 || ""
  };
  const lastIndex = Math.max(...companyRecords.map((item) => state.records.indexOf(item)));
  state.records.splice(lastIndex + 1, 0, record);
  state.collapsedCompanies.delete(normalizedKey(companyName));
  setDirty();
  render();
  requestAnimationFrame(() => elements.companyList.querySelector(`[data-project-anchor-id="${CSS.escape(record._id)}"] .project-title-input`)?.focus());
}
function deleteCompanyForSelection() {
  const scope = selectionScope();
  if (!scope.fullCompany) return;
  deleteCompany(scope.company);
}
function deleteSelectedProject(companyName) {
  const selected = allCompanyRecords(companyName).filter((record) => state.selectedIds.has(record._id));
  const projectNames = new Map(selected.map((record) => [normalizedKey(record.業務内容), text(record.業務内容)]));
  if (projectNames.size !== 1) return;
  const projectName = [...projectNames.values()][0];
  if (selected.length !== allProjectRecords(companyName, projectName).length) return;
  deleteProject(companyName, projectName);
}
function addEngineer(companyName, projectName) {
  const projectRecords = allProjectRecords(companyName, projectName);
  if (projectRecords.some((record) => !text(record.技術者名))) {
    showToast("入力中の技術者名を先に完成してください。", true);
    return;
  }
  const first = projectRecords[0] || {};
  const record = {
    _id: makeId(), 宛先会社名: companyName, 出力フォルダ名: "", 業務内容: projectName,
    工程範囲: first.工程範囲 || "", 弊社責任者: first.弊社責任者 || "", 備考: first.備考 || "",
    技術者名: "", 単価: first.単価 || "", 固定契約: first.固定契約 || "N", 下限時間: first.下限時間 || "", 上限時間: first.上限時間 || ""
  };
  const lastIndex = Math.max(...projectRecords.map((item) => state.records.indexOf(item)));
  state.records.splice(lastIndex + 1, 0, record);
  state.selectedIds = new Set([record._id]);
  setDirty();
  render();
  requestAnimationFrame(() => elements.companyList.querySelector(`[data-row-id="${CSS.escape(record._id)}"] .engineer-name-input`)?.focus());
}
function duplicateRecord(source) {
  if (!source) return;
  const copy = { ...source, _id: makeId(), 技術者名: "", 出力フォルダ名: "" };
  state.records.splice(state.records.indexOf(source) + 1, 0, copy);
  state.selectedIds = new Set([copy._id]);
  setDirty();
  render();
  requestAnimationFrame(() => elements.companyList.querySelector(`[data-row-id="${CSS.escape(copy._id)}"] .engineer-name-input`)?.focus());
}

function duplicateProjectSelection(companyName, projectName) {
  const selected = allProjectRecords(companyName, projectName).filter((record) => state.selectedIds.has(record._id));
  if (selected.length !== 1) return;
  duplicateRecord(selected[0]);
}

function deleteProjectSelection(companyName, projectName) {
  const selected = allProjectRecords(companyName, projectName).filter((record) => state.selectedIds.has(record._id));
  const count = selected.length;
  if (!count) return;
  if (count >= state.records.length) {
    showToast("すべての技術者は削除できません。1名以上残してください。", true);
    return;
  }
  if (!window.confirm(`「${companyName} / ${projectName}」で選択中の${count}名を一覧から削除します。\n技術者がいなくなった案件・会社は一覧に表示されなくなります。\n\n削除しますか？`)) return;
  const folders = new Map(groupRecords(state.records).map((company) => [
    company.key,
    text(allCompanyRecords(company.name).find((record) => text(record.出力フォルダ名))?.出力フォルダ名)
  ]));
  const ids = new Set(selected.map((record) => record._id));
  state.records = state.records.filter((record) => !ids.has(record._id));
  for (const company of groupRecords(state.records)) {
    const preservedFolder = folders.get(company.key);
    if (preservedFolder && !company.records.some((record) => text(record.出力フォルダ名))) company.records[0].出力フォルダ名 = preservedFolder;
  }
  ids.forEach((id) => state.selectedIds.delete(id));
  setDirty();
  render();
  showToast(`${count}名を一覧から削除しました。`);
}

function deleteCompany(companyName) {
  const records = allCompanyRecords(companyName);
  if (!records.length) return;
  if (records.length >= state.records.length) {
    showToast("すべての会社は削除できません。1社以上残してください。", true);
    return;
  }
  const projectCount = new Set(records.map((record) => normalizedKey(record.業務内容))).size;
  if (!window.confirm(`「${companyName}」を一覧から削除します。\n削除対象：${projectCount}案件・${records.length}名\n\n削除しますか？`)) return;
  const ids = new Set(records.map((record) => record._id));
  state.records = state.records.filter((record) => !ids.has(record._id));
  ids.forEach((id) => state.selectedIds.delete(id));
  setDirty();
  render();
  showToast(`「${companyName}」を一覧から削除しました。「更新」を押すと確定します。`);
}

function deleteProject(companyName, projectName) {
  const records = allProjectRecords(companyName, projectName);
  if (!records.length) return;
  if (records.length >= state.records.length) {
    showToast("すべての案件は削除できません。1件以上残してください。", true);
    return;
  }
  const removesCompany = records.length === allCompanyRecords(companyName).length;
  const companyNote = removesCompany ? "\nこの会社の最後の案件のため、会社も一覧に表示されなくなります。" : "";
  if (!window.confirm(`「${companyName} / ${projectName}」を一覧から削除します。\n削除対象：技術者${records.length}名${companyNote}\n\n削除しますか？`)) return;
  const folder = text(allCompanyRecords(companyName).find((record) => text(record.出力フォルダ名))?.出力フォルダ名);
  const ids = new Set(records.map((record) => record._id));
  state.records = state.records.filter((record) => !ids.has(record._id));
  ids.forEach((id) => state.selectedIds.delete(id));
  const remainingCompanyRecords = allCompanyRecords(companyName);
  if (folder && remainingCompanyRecords.length && !remainingCompanyRecords.some((record) => text(record.出力フォルダ名))) {
    remainingCompanyRecords[0].出力フォルダ名 = folder;
  }
  setDirty();
  render();
  showToast(`「${projectName}」を一覧から削除しました。「更新」を押すと確定します。`);
}


function payload(records = state.records) {
  const serializedRecords = records.map((record) => Object.fromEntries(fields.map((field) => [field, text(record[field])])));
  const assignedFolders = new Set();
  serializedRecords.forEach((record) => {
    const companyKey = normalizedKey(record.宛先会社名);
    if (assignedFolders.has(companyKey)) {
      record.出力フォルダ名 = "";
      return;
    }
    record.出力フォルダ名 = companyFolder(record.宛先会社名);
    assignedFolders.add(companyKey);
  });
  return { targetMonth: text(state.targetMonth), records: serializedRecords };
}

async function loadData(confirmDiscard = false) {
  if (confirmDiscard && state.dirty && !window.confirm("更新していない変更があります。注文データを再読込してもよろしいですか？")) return;
  setBusy(true, "読込中");
  try {
    const data = await api("/api/data");
    state.targetMonth = text(data.targetMonth);
    state.outputRoot = text(data.outputRoot);
    state.records = (data.records || []).map((record) => ({ _id: makeId(), ...Object.fromEntries(fields.map((field) => [field, record[field] == null ? "" : String(record[field])])) }));
    if (!state.initialized) {
      state.collapsedCompanies = new Set(groupRecords(state.records).map((company) => company.key));
      state.initialized = true;
    }
    state.selectedIds.clear();
    elements.targetMonth.value = state.targetMonth;
    elements.outputRootInput.value = state.outputRoot;
    elements.outputRootInput.dataset.savedValue = state.outputRoot;
    setDirty(false);
    render();
    showResult("注文データを読み込みました。一覧で内容を直接入力・修正できます。");
  } catch (error) {
    showResult("注文データを読み込めませんでした。", error.message, true); showToast(error.message, true);
  } finally { setBusy(false); }
}
async function saveData(silent = false) {
  state.targetMonth = elements.targetMonth.value;
  if (!showValidation(validate())) return false;
  setBusy(true, "更新中");
  try {
    await api("/api/save", { method: "POST", body: payload() });
    setDirty(false);
    if (!silent) { showResult("注文データを更新しました。更新前のデータは backup フォルダに残しています。"); showToast("更新しました。"); }
    return true;
  } catch (error) {
    showResult("注文データを更新できませんでした。", error.message, true); showToast(error.message, true); return false;
  } finally { setBusy(false); }
}
async function generateOrders() {
  state.targetMonth = elements.targetMonth.value;
  state.outputRoot = text(elements.outputRootInput.value);
  const selectedRecords = state.records.filter((record) => state.selectedIds.has(record._id));
  if (!selectedRecords.length) {
    showToast("注文書を作成する技術者を選択してください。", true);
    showResult("技術者が選択されていません。", "一覧のチェックボックスで1名以上選択してください。", true);
    return;
  }
  if (!showValidation(validate())) return;
  if (!state.outputRoot) {
    showToast("先に出力先を選択してください。", true);
    await selectOutputFolder();
    if (!state.outputRoot) return;
  }
  const outputLabel = state.outputRoot;
  if (!window.confirm(`選択した${selectedRecords.length}名の注文書を作成します。\n対象年月: ${state.targetMonth}\n出力先: ${outputLabel}\n\n画面の全データを主データCSVへ保存してから、選択データだけを生成処理へ渡します。よろしいですか？`)) return;
  if (!await saveData(true)) return;
  setBusy(true, "作成中"); showResult("注文書を作成しています。しばらくお待ちください。");
  try {
    const result = await api("/api/generate", { method: "POST", body: { ...payload(selectedRecords), outputRoot: state.outputRoot } });
    const outputPath = text(result.outputPath);
    elements.outputRootInput.dataset.savedValue = state.outputRoot;
    showResult(`注文書を作成しました。\n保存先: ${outputPath || "成果物フォルダ"}`, result.log || "");
    showToast(`ExcelとPDFを作成しました。\n保存先: ${outputPath}`);
  } catch (error) {
    showResult("注文書を作成できませんでした。", error.message, true); showToast(error.message, true);
  } finally { setBusy(false); }
}

async function persistOutputPath() {
  const previous = elements.outputRootInput.dataset.savedValue || "";
  const requested = text(elements.outputRootInput.value);
  elements.outputRootInput.setAttribute("aria-busy", "true");
  try {
    const result = await api("/api/output-path", { method: "POST", body: { path: requested } });
    state.outputRoot = text(result.path);
    elements.outputRootInput.value = state.outputRoot;
    elements.outputRootInput.dataset.savedValue = state.outputRoot;
    showToast(state.outputRoot ? "出力先を更新しました。" : "出力先を未選択に戻しました。");
  } catch (error) {
    state.outputRoot = previous;
    elements.outputRootInput.value = previous;
    showToast(error.message, true);
  } finally {
    elements.outputRootInput.removeAttribute("aria-busy");
  }
}

async function selectOutputFolder() {
  setBusy(true, "選択中");
  try {
    const started = await api("/api/select-output-folder", { method: "POST", body: { currentPath: state.outputRoot } });
    let result = null;
    for (let attempt = 0; attempt < 1200; attempt += 1) {
      await new Promise((resolve) => setTimeout(resolve, 500));
      result = await api("/api/output-folder-selection", { method: "POST", body: { selectionId: started.selectionId } });
      if (!result.pending) break;
    }
    if (!result || result.pending) throw new Error("出力先の選択がタイムアウトしました。");
    if (result.cancelled) return;
    state.outputRoot = text(result.path);
    elements.outputRootInput.value = state.outputRoot;
    elements.outputRootInput.dataset.savedValue = state.outputRoot;
    showToast("出力先を変更しました。");
  } catch (error) {
    showToast(error.message, true);
  } finally { setBusy(false); }
}
