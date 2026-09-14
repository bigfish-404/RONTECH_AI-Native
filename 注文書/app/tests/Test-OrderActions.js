"use strict";

const fs = require("fs");
const vm = require("vm");

const sourcePath = process.argv[2];
if (!sourcePath) throw new Error("order-actions.js path is required.");

let nextId = 1;
const state = { records: [], selectedIds: new Set(), collapsedCompanies: new Set(), dirty: false };
const text = (value) => value == null ? "" : String(value).trim();
const normalizedKey = (...values) => values.map((value) => text(value).toLocaleLowerCase("ja-JP")).join("\u001f");
const allCompanyRecords = (companyName) => state.records.filter((record) => normalizedKey(record.宛先会社名) === normalizedKey(companyName));
const allProjectRecords = (companyName, subject) => allCompanyRecords(companyName).filter((record) => normalizedKey(record.件名) === normalizedKey(subject));
const groupRecords = (records) => {
  const companies = new Map();
  records.forEach((record) => {
    const key = normalizedKey(record.宛先会社名);
    if (!companies.has(key)) companies.set(key, { key, name: text(record.宛先会社名), records: [] });
    companies.get(key).records.push(record);
  });
  return [...companies.values()];
};
const companyFolder = (companyName) => text(allCompanyRecords(companyName).find((record) => text(record.出力フォルダ名))?.出力フォルダ名) || text(companyName);
const assert = (condition, message) => { if (!condition) throw new Error(message); };

const context = {
  state,
  fields: ["宛先会社名", "出力フォルダ名", "件名", "業務内容", "工程範囲", "技術者名", "単価", "固定契約", "下限時間", "上限時間", "弊社責任者", "備考"],
  makeId: () => `row-${nextId++}`,
  text,
  normalizedKey,
  allCompanyRecords,
  allProjectRecords,
  groupRecords,
  companyFolder,
  selectionScope: () => ({ company: "", fullCompany: false }),
  setDirty: () => { state.dirty = true; },
  render: () => {},
  showToast: () => {},
  showResult: () => {},
  setBusy: () => {},
  showValidation: () => true,
  validate: () => ({ errors: [] }),
  api: async () => ({ ok: true }),
  persistOutputPath: async () => true,
  elements: {
    companyList: { querySelector: () => null, querySelectorAll: () => [] },
    targetMonth: { value: "2026-10" },
    outputRootInput: { value: "", dataset: {} }
  },
  window: { confirm: () => true },
  requestAnimationFrame: () => {},
  CSS: { escape: (value) => value },
  console,
  setTimeout,
  clearTimeout
};
vm.createContext(context);
vm.runInContext(fs.readFileSync(sourcePath, "utf8"), context, { filename: sourcePath });

(async () => {
context.addCompany();
assert(state.records.length === 1, "A company row was not added from an empty state.");
assert(Object.hasOwn(state.records[0], "件名") && Object.hasOwn(state.records[0], "業務内容"), "The new company row lacks separated subject/business fields.");

Object.assign(state.records[0], {
  宛先会社名: "追加試験株式会社", 件名: "件名1", 業務内容: "業務1", 工程範囲: "工程1",
  技術者名: "技術者1", 単価: "500000", 固定契約: "N", 下限時間: "140", 上限時間: "180", 弊社責任者: "担当1"
});
context.addProject("追加試験株式会社");
assert(state.records.length === 2 && state.records[1].件名 === "" && state.records[1].業務内容 === "", "A blank project was not added correctly.");

Object.assign(state.records[1], { 件名: "件名2", 業務内容: "業務2", 技術者名: "技術者2" });
context.addEngineer("追加試験株式会社", "件名2");
assert(state.records.length === 3, "An engineer was not added.");
assert(state.records[2].件名 === "件名2" && state.records[2].業務内容 === "業務2", "The engineer did not inherit both subject and business content.");

state.records[2].技術者名 = "技術者3";
context.duplicateRecord(state.records[2]);
assert(state.records.length === 4 && state.records[3].技術者名 === "", "Engineer duplication failed.");
state.selectedIds = new Set([state.records[3]._id]);
context.deleteProjectSelection("追加試験株式会社", "件名2");
assert(state.records.length === 3, "Selected engineer deletion failed.");

const serialized = context.payload(state.records);
assert(serialized.records.every((record) => Object.hasOwn(record, "件名") && Object.hasOwn(record, "業務内容")), "Save/generate payload lacks separated fields.");

state.targetMonth = "2026-10";
context.elements.targetMonth.value = state.targetMonth;
state.outputRoot = "D:\\test-output";
context.elements.outputRootInput.value = state.outputRoot;
const generationCounts = [];
context.api = async (path, options = {}) => {
  if (path === "/api/generate") generationCounts.push(options.body.records.length);
  return { ok: true, outputPath: state.outputRoot };
};
for (const selectedCount of [1, 2, state.records.length]) {
  state.selectedIds = new Set(state.records.slice(0, selectedCount).map((record) => record._id));
  await context.generateOrders();
}
assert(generationCounts.join(",") === `1,2,${state.records.length}`, "Single/multiple/select-all filtering did not reach the generation payload.");

context.deleteProject("追加試験株式会社", "件名1");
assert(state.records.length === 2 && state.records.every((record) => record.件名 === "件名2"), "Project deletion failed.");
context.deleteCompany("追加試験株式会社");
assert(state.records.length === 0, "Deleting the last company did not leave an empty state.");

console.log("Order action tests passed.");
})().catch((error) => { console.error(error); process.exit(1); });
