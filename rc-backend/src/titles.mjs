// titles.mjs — 明示名(rename)の台帳。
//
// ★何を直しに来たか(2026-08-16、.harness/spec-audit-2026-08-16.md A1)。
// 本家 RC のタイトル優先順は「明示名 → ai-title → 最後の意味あるメッセージ → 自動スラッグ」
// (research/remote-control-teardown.md §2)で、DESIGN §1 はこれを「そのまま採る」と
// 掲げていたのに、明示名の機構が製品のどこにも無かった。sessions.mjs の註が
// 「Phase I-1 に無いので実質 ai-title から始まる」と自認したまま1ヶ月放置されていた形。
//
// ★置き場所は ~/.rc-backend/titles.json(鍵と同じ dir)。transcript(jsonl)には
//   書かない — あれは Claude Code の持ち物で、形式を私達が拡張すると本体の更新で割れる。
//   横に台帳を持つのは heads.mjs(fork の頭)と同じ判断。
//
// ★書きは tmp → rename。読み手(一覧の組み立て)は毎要求で読むので、
//   途中まで書けた JSON を読ませない。

import { readFileSync, writeFileSync, renameSync, mkdirSync } from "node:fs";
import { join } from "node:path";

const FILE = "titles.json";
const ARCHIVE_FILE = "archived.json";

/** {} を返す小さな台帳読み。無い/壊れている = 空(fail-open が正しい: 此処に載る物は装飾と絞り込みで、権限ではない)。 */
function loadLedger(dir, file) {
  try {
    const raw = readFileSync(join(dir, file), "utf8");
    const obj = JSON.parse(raw);
    if (obj && typeof obj === "object" && !Array.isArray(obj)) return obj;
  } catch {
    /* 無い・読めない・壊れている、いずれも空で開く */
  }
  return {};
}

/** tmp -> rename の原子書き。読み手は毎要求で読むので、途中まで書けた JSON を読ませない。 */
function saveLedger(dir, file, obj) {
  mkdirSync(dir, { recursive: true });
  const tmp = join(dir, `${file}.tmp-${process.pid}`);
  writeFileSync(tmp, JSON.stringify(obj, null, 2) + "\n", { mode: 0o600 });
  renameSync(tmp, join(dir, file));
  return obj;
}

/** 明示名の台帳 {sid: title}。 */
export function loadTitles(dir) {
  return loadLedger(dir, FILE);
}

/**
 * 名前の検証。通れば整えた文字列、通らなければ null。
 * 上限 60 は resolveTitle の lastPrompt 切詰めと同じ値 — 一覧の1行に収まる長さの正本。
 * 改行は落とす(一覧は1行で描く。複数行の名前は行の高さを黙って壊す)。
 */
export function normalizeTitle(raw) {
  if (typeof raw !== "string") return null;
  const t = raw.replace(/[\r\n]+/g, " ").trim().replace(/\s+/g, " ");
  if (t.length === 0 || t.length > 60) return null;
  return t;
}

/**
 * 名前を付ける(title=null で外す)。戻り値 = 保存後の台帳。
 * ★外した後の鍵は残さない — 「空文字の名前」と「名前なし」の2状態を作らない。
 */
export function setTitle(dir, sessionId, title) {
  const titles = loadTitles(dir);
  if (title === null) delete titles[sessionId];
  else titles[sessionId] = title;
  return saveLedger(dir, FILE, titles);
}

// ── 保管(archive)の台帳 ────────────────────────────────────────────────────
// REQUIREMENTS §9-1: 「一覧から外すが file は残す。人が選ぶ。自動判定に寄せない」。
// 台帳が持つのは {sid: ISO時刻}(いつ外したか)。**transcript には一切触れない** —
// 消す機構をそもそも持たない事が「file は残る」の実装(約束ではなく形)。

/** 保管の台帳 {sid: 外した時刻(ISO)}。 */
export function loadArchived(dir) {
  return loadLedger(dir, ARCHIVE_FILE);
}

/** 外す(archived=true)/ 一覧へ戻す(false)。戻り値 = 保存後の台帳。 */
export function setArchived(dir, sessionId, archived, now = new Date()) {
  const led = loadArchived(dir);
  if (archived) led[sessionId] = now.toISOString();
  else delete led[sessionId];
  return saveLedger(dir, ARCHIVE_FILE, led);
}
