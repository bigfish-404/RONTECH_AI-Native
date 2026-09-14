"use strict";

function validate(requireRecords = true) {
  const errors = [];
  const invalidIds = new Set();
  const invalidCompanyIds = new Set();
  const invalidProjectIds = new Set();
  const add = (record, message) => { errors.push(message); if (record) invalidIds.add(record._id); };
  if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(text(state.targetMonth))) errors.push("対象年月を選択してください。");
  if (requireRecords && !state.records.length) errors.push("注文データが1件もありません。");
  const duplicates = new Map(), companyFolders = new Map(), projects = new Map();

  state.records.forEach((record, index) => {
    const row = index + 1;
    requiredFields.forEach((field) => {
      if (text(record[field])) return;
      add(record, `${row}行目の「${field}」が未入力です。`);
      if (field === "宛先会社名") invalidCompanyIds.add(record._id);
      if (["業務内容", "工程範囲", "弊社責任者"].includes(field)) invalidProjectIds.add(record._id);
    });
    const price = parseNumber(record.単価), lower = parseHours(record.下限時間), upper = parseHours(record.上限時間);
    if (/\s/.test(text(record.単価)) || price == null || price < 0) add(record, `${row}行目の「単価」が正しくありません。`);
    if (!["Y", "N"].includes(text(record.固定契約).toUpperCase())) add(record, `${row}行目の「固定契約」が正しくありません。`);
    if (lower == null || lower <= 0) add(record, `${row}行目の「下限時間」が正しくありません。`);
    if (upper == null || upper <= 0) add(record, `${row}行目の「上限時間」が正しくありません。`);
    if (lower != null && upper != null && lower >= upper) add(record, `${row}行目は下限時間を上限時間より小さくしてください。`);
    if (text(record.宛先会社名) && text(record.業務内容) && text(record.技術者名)) {
      const duplicateKey = normalizedKey(record.宛先会社名, record.業務内容, record.技術者名);
      if (duplicates.has(duplicateKey)) add(record, `${row}行目は${duplicates.get(duplicateKey)}行目と同じ会社・案件・技術者です。`);
      else duplicates.set(duplicateKey, row);
    }
    const companyKey = normalizedKey(record.宛先会社名);
    if (!companyFolders.has(companyKey)) companyFolders.set(companyKey, { company: text(record.宛先会社名), folders: new Map(), records: [] });
    const company = companyFolders.get(companyKey);
    if (text(record.出力フォルダ名)) company.folders.set(normalizedKey(record.出力フォルダ名), text(record.出力フォルダ名));
    company.records.push(record);
    const projectKey = normalizedKey(record.宛先会社名, record.業務内容);
    if (!projects.has(projectKey)) projects.set(projectKey, { company: text(record.宛先会社名), project: text(record.業務内容), records: [], values: new Map() });
    const project = projects.get(projectKey); project.records.push(record);
    ["工程範囲", "弊社責任者", "備考"].forEach((field) => {
      const value = text(record[field]); if (!value) return;
      if (!project.values.has(field)) project.values.set(field, new Set());
      project.values.get(field).add(normalizedKey(value));
    });
  });

  for (const company of companyFolders.values()) {
    if (company.folders.size > 1) company.records.forEach((record) => {
      add(record, `「${company.company}」の出力フォルダ名を統一してください。`);
      invalidCompanyIds.add(record._id);
    });
  }
  const folderOwners = new Map();
  for (const company of companyFolders.values()) {
    const folder = company.folders.size === 1 ? [...company.folders.values()][0] : company.company;
    const safe = safeFileName(folder);
    if (!safe) company.records.forEach((record) => {
      add(record, `「${company.company}」の出力フォルダ名に使用できる文字がありません。`);
      invalidCompanyIds.add(record._id);
    });
    else if (folderOwners.has(normalizedKey(safe)) && folderOwners.get(normalizedKey(safe)) !== company.company) company.records.forEach((record) => {
      add(record, `異なる会社の出力フォルダ名が同じ名前になります。`);
      invalidCompanyIds.add(record._id);
    });
    else folderOwners.set(normalizedKey(safe), company.company);
  }
  for (const project of projects.values()) {
    for (const [field, values] of project.values) {
      if (values.size > 1) project.records.forEach((record) => {
        add(record, `「${project.company} / ${project.project}」の${field}を統一してください。`);
        invalidProjectIds.add(record._id);
      });
    }
  }
  return { errors: [...new Set(errors)], invalidIds, invalidCompanyIds, invalidProjectIds };
}

function showValidation(result) {
  if (!result.errors.length) return true;
  result.invalidIds.forEach((id) => elements.companyList.querySelector(`[data-row-id="${CSS.escape(id)}"]`)?.classList.add("has-error"));
  elements.companyList.querySelectorAll(".company-cell").forEach((cell) => {
    const ids = (cell.dataset.recordIds || "").split(",").filter(Boolean);
    if (ids.some((id) => result.invalidCompanyIds.has(id))) cell.classList.add("has-error");
  });
  elements.companyList.querySelectorAll(".project-cell").forEach((cell) => {
    const ids = (cell.dataset.recordIds || "").split(",").filter(Boolean);
    if (ids.some((id) => result.invalidProjectIds.has(id))) cell.classList.add("has-error");
  });
  const shown = result.errors.slice(0, 8), rest = result.errors.length - shown.length;
  const log = `${shown.join("\n")}${rest > 0 ? `\nほか${rest}件の入力エラーがあります。` : ""}`;
  showResult("入力内容を確認してください。", log, true);
  const firstError = elements.companyList.querySelector(".has-error");
  firstError?.scrollIntoView({ behavior: "smooth", block: "center" });
  firstError?.querySelector("input,select,textarea")?.focus({ preventScroll: true });
  showToast("赤く表示された技術者と所属情報を確認してください。", true);
  return false;
}
