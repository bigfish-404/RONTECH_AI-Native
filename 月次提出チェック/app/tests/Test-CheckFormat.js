"use strict";

// Usage: node Test-CheckFormat.js <check-format.js> <report.json written by Run-SmokeTests.ps1>
const fs = require("fs");
const format = require(process.argv[2]);
const raw = fs.readFileSync(process.argv[3], "utf8").replace(/^﻿/, "");
const report = format.normalizeReport(JSON.parse(raw));

function assert(condition, message) {
  if (!condition) {
    console.error(`check-format test failed: ${message}`);
    process.exit(1);
  }
}
function find(name) {
  const result = report.results.find((item) => item.name === name);
  assert(result, `result for ${name} is missing`);
  return result;
}

const sato = format.buildMessage(find("佐藤花子"), report.targetMonth);
assert(sato.startsWith("佐藤花子さん\n"), "message does not start with the name");
assert(sato.includes("2026年9月分の勤務表・交通費申請書を確認しました。"), "month label is missing");
assert(sato.includes("【勤務表】") && sato.includes("【交通費申請書】"), "sections are missing");
const kobayashi = format.buildMessage(find("小林優"), report.targetMonth);
assert(kobayashi.includes("勤務表の年月が「2026年8月」になっています。「2026年9月」に修正してください。"), "勤務表 month advice is wrong");
assert(!kobayashi.includes("交通費が申請されていません") && !kobayashi.includes("交通費が申請されています"), "dates must not be compared against a 勤務表 of another month");
assert(sato.includes("申請年月が「2026年8月」になっています。「2026年9月」に修正してください。"), "申請年月 advice is wrong");
assert(sato.includes("勤務場所が空欄です。リストから選んでください：9/4(金)"), "place-empty advice is wrong");
assert(sato.includes("リストにない値になっています。リスト（客先出勤・田町本社・大阪支店・在宅）から選んでください：9/10(木)「本社」"), "invalid-place advice is wrong");
assert(sato.includes("交通費が申請されています：9/5(土)（休み）、9/9(水)（在宅）"), "extra-claim advice is wrong");
assert(sato.includes("交通費が申請されていません：9/7(月)"), "missing-claim advice is wrong");
assert(sato.includes("出社日数と交通費の申請日数が一致していません（出社 3日 / 申請 4日）。"), "day count line is wrong");

const sameCount = format.buildMessage({
  name: "テスト",
  issues: [
    { code: "CLAIM_EXTRA", target: "kotsu", days: [{ day: 4, category: "remote" }] },
    { code: "CLAIM_MISSING", target: "kotsu", days: [3] }
  ],
  cells: { dates: { text: "出社 1日 / 申請 1日" } },
  dayCounts: { office: 1, claim: 1 }
}, report.targetMonth);
assert(sameCount.includes("9/4(金)（在宅）") && !sameCount.includes("一致していません（"), "equal day counts must not produce the count line");
assert(sato.trimEnd().endsWith("よろしくお願いいたします。"), "closing line is missing");

assert(format.buildMessage(find("山田太郎"), report.targetMonth) === "", "an OK person must not get a message");
const takahashi = format.buildMessage(find("高橋誠"), report.targetMonth);
assert(takahashi.includes("勤務表がまだ提出されていません。") && takahashi.includes("交通費申請書がまだ提出されていません。"), "missing-file advice is wrong");

for (const result of report.results) {
  for (const issue of result.issues) {
    assert(format.issueSummary(issue, report.targetMonth) !== issue.code, `no summary text for ${issue.code}`);
  }
}
console.log("  check-format tests passed.");
