#!/usr/bin/env node
/**
 * 実機の Claude Code TUI に対する注入の一巡を、**再現できる形**で回す。
 *
 * これまで(2026-08-01 の MBP 側)この4ケースは手打ちで回した。手打ちは、次の機械
 * (edith)で「同じ物を回した」と言えない。同じ台本を両方で走らせる為の道具。
 *
 * 安全側の約束(崩さない事):
 *   - **使い捨てのセッション名しか受け付けない**(`rc-live-<数字>`)。Tom の実セッション
 *     `work` に触れる余地を構造的に消す。既に同名が在れば作らずに落ちる。
 *   - 送り先ペインは**自分が作ったセッションの中から**取り、`#{session_name}` が一致する
 *     事を確かめてから使う。名前で当てに行かない。
 *   - 選択画面(CHOICE)では**Enter を押さない**。TmuxInjector 側が modal を見たら
 *     打ち切る。この台本も Enter を送る経路を持たない。
 *   - 画面の写しは**この repo の中に置かない**(既定は $TMPDIR)。起動バナーには
 *     アカウントのメールが載るので、repo に置くと履歴に本物の個人情報が入る。
 *     `check-no-pii.sh` が赤にしてくれるが、**入れてから気付くのでは遅い**。
 *
 * 使い方:
 *   node tools/live-inject-check.mjs [--cwd <trusted dir>] [--bin claude] [--keep]
 *   終了コード: 0 = 全ケース delivered=verified / 1 = どれかが未確認・失敗 / 2 = 準備段で中断
 *              **3 = 配達は成立したが、相手が答えられていない**(利用上限)
 *
 * ★2026-08-02 追加(自分の道具に踏まれて): edith で回したら `4/4 delivered=verified` /
 * exit 0 が出た。画面の写しを開くと4件とも
 *   `⎿  You've hit your weekly limit · resets 12am (Asia/Tokyo)`
 * で、**一度も答えが返っていなかった**。この台本の検査対象は配達なので、緑それ自体は
 * 嘘ではない。だが「edith で 4/4 緑」は「注入の鎖が通った」と読まれる。読まれ方まで
 * 含めて計器の責任なので、答えられない機械では**緑を出さない**(exit 3)。
 * 配達の判定は変えない — 上限は「送れない」ではなく「答えが返らない」なので、
 * delivered の列はそのまま真実を出し続ける。
 *
 * 前提: 与える `--cwd` は **claude が既に信頼済みの dir**。未信頼だと起動直後に
 *   「Do you trust the files…」の選択画面が出る。この台本はそこで Enter を押さないので、
 *   composer が出ないまま時間切れになり、その旨を報告して落ちる(それが正しい振る舞い)。
 *
 * ★`--cwd` は **必須**(2026-08-02 に既定を外した)。以前の既定は `$HOME` で、これは
 *   上の前提と真っ向から矛盾していた — `$HOME` は普通 claude の信頼済み dir ではない。
 *   実際 edith(`$HOME=/Users/edith`)で既定のまま撃つと必ず信頼確認で止まる。
 *   「既定値が、その道具自身が禁じている値」という形なので、既定を持たせない方を採った。
 */
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TmuxInjector, makeTmuxRunner, classifyScreen, limitNoticeIn, tmuxChildEnv, PANE_SEP } from "../src/inject.mjs";

const TMUX_BIN =
  process.env.RC_TMUX_BIN ||
  (existsSync("/opt/homebrew/bin/tmux") ? "/opt/homebrew/bin/tmux" : "tmux");

/**
 * 注入層に渡すランナー。**`makeTmuxRunner` を経由する**のが要点で、こうすると
 * `run`(飲む)と `runStrict`(投げる)の両方が揃う。一覧は runStrict を通るので、
 * ここを裸の `{ run: tmux }` に戻すと構築の時点で落ちる(= M84 が塞いだ穴)。
 * `quiet:false` は今までと同じ意味(この道具では tmux の失敗はそのまま失敗)。
 */
const injectorRunner = () => makeTmuxRunner({
  tmuxBin: TMUX_BIN,
  exec: (bin, args, opts) => execFileSync(bin, args, { ...opts, maxBuffer: 8 * 1024 * 1024 }),
  quiet: false,
});

/** 引数を素朴に読む。値を取る物だけ列挙する。 */
function parseArgs(argv) {
  // 既定の桁数は 120。**折り返しの確認が目的なので桁数は結果を変える**。偽の TUI で
  // 配管だけ確かめる時は、写しを撮った時と同じ桁(実機の写しは 80 桁)に合わせる必要がある。
  // cwd に既定は置かない(上の理由)。未指定は下で exit 2。
  const out = { cwd: null, bin: "claude", keep: false, out: null, session: null, cols: "120", rows: "40", cases: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--keep") out.keep = true;
    else if (a === "--cwd") out.cwd = argv[++i];
    else if (a === "--bin") out.bin = argv[++i];
    else if (a === "--out") out.out = argv[++i];
    else if (a === "--cols") out.cols = argv[++i];
    else if (a === "--rows") out.rows = argv[++i];
    else if (a === "--session") out.session = argv[++i];
    else if (a === "--cases") out.cases = argv[++i].split(",").map((x) => x.trim().toUpperCase());
    else throw new Error(`知らない引数: ${a}`);
  }
  // ★引数の妥当性は**ここで**見る。後段(tmux を建てて起動を待った後)に置くと、
  //   打ち間違いに気付くまで起動待ちの上限だけ待たされ、しかもその経路は普段通らない。
  if (out.cases) {
    const known = buildCases().map((c) => c.id);
    const bad = out.cases.filter((x) => !known.includes(x));
    if (bad.length) throw new Error(`--cases に無いケース: ${bad.join(",")}(有効: ${known.join(",")})`);
  }
  return out;
}

/**
 * tmux 実行。**失敗を握り潰さない**。
 * server.mjs 側の runner は失敗を "" にして UNKNOWN へ倒す(送信側は fail-closed が正しい)が、
 * ここは検査の道具なので、失敗を空文字にすると「画面が空だった」と読み違える。
 */
function tmux(args) {
  // ★locale を明示する。UTF-8 でないと tmux は `-F` の中のタブを `_` に潰し、
  //   下の `#{session_name}\t#{pane_id}` が1列に化ける(2026-08-02 edith 実測、tmux 3.7b)。
  //   シェルから走らせている限り LANG が在るので緑のまま = 気付けない側の故障。
  return execFileSync(TMUX_BIN, args, {
    encoding: "utf8", maxBuffer: 8 * 1024 * 1024, env: tmuxChildEnv(),
  });
}
function tmuxOk(args) {
  try {
    tmux(args);
    return true;
  } catch {
    return false;
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** 4ケース。**画面の折り返し方が違う物**を選んである(ここが注入の壊れ所だった)。 */
function buildCases() {
  const a =
    "これは折り返しの確認用の長い一文です。画面の桁数を超えて折り返された時に、" +
    "入力欄の判定と本文の照合が壊れないかを見ています。返答は不要なので、A とだけ返してください。" +
    "以上です。よろしくお願いします。";
  const d0 =
    "これは長文の確認です。画面より遥かに長い本文を一度に送った時、入力欄の枠の判定と" +
    "本文の消費確認が成立するかを見ています。返答は不要です。";
  let d = "";
  while (d.length < 1500) d += d0;
  d = d.slice(0, 1490) + "最後に D とだけ返してください。";
  return [
    { id: "A", why: "折り返す長文(1行)", text: a },
    {
      id: "B",
      why: "番号付きの複数行",
      text: "次の3行はそのまま読み飛ばして、B とだけ返してください。\n1. 一つ目\n2. 二つ目\n3. 三つ目",
    },
    {
      id: "C",
      why: "先頭行が短い複数行",
      text: "短い\nここから先は少し長い行になります。先頭行が短い時に入力欄の枠を取り違えないかを見ています。C とだけ返してください。",
    },
    { id: "D", why: "1500字級の長文", text: d },
  ];
}

/** 画面が SENDABLE になるまで待つ。何が見えているかを返す(時間切れでも黙らない)。 */
async function waitSendable(injector, pane, budgetMs, label) {
  const t0 = Date.now();
  let last = { state: "UNKNOWN" };
  for (;;) {
    const text = injector.capture(pane);
    last = classifyScreen(text);
    if (last.state === "SENDABLE") return { ok: true, waited: Date.now() - t0, text };
    if (Date.now() - t0 >= budgetMs) {
      return { ok: false, waited: Date.now() - t0, state: last.state, text, label };
    }
    await sleep(500);
  }
}

async function main() {
  const opt = parseArgs(process.argv.slice(2));
  const stamp = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 14);
  const session = opt.session || `rc-live-${stamp}`;

  // ★使い捨ての名前しか受け付けない。ここが唯一の入口なので、`work` へ届く道が無い。
  if (!/^rc-live-[0-9]{6,}$/.test(session)) {
    console.error(`使い捨てのセッション名ではない: ${session}(rc-live-<数字6桁以上> のみ)`);
    process.exit(2);
  }
  // ★引数の検査を tmux より**先**に置く(2026-08-02)。逆順だった為、`--cwd` を忘れただけの
  //   使い方エラーでも先に tmux を叩き、`no server running on …` という無関係な赤が
  //   使い方の説明の上に出ていた。証拠を出す為の道具の出力に嘘の赤を混ぜない。
  if (!opt.cwd) {
    console.error("--cwd は必須(既定値は持たない)。**claude が既に信頼済みの dir** を渡す事。");
    console.error("  信頼済みの dir の一覧はこれで出る:");
    console.error("    /usr/bin/jq -r '.projects | keys[]' ~/.claude.json");
    console.error("  例: node tools/live-inject-check.mjs --cwd /Users/edith/Projects");
    process.exit(2);
  }
  if (!existsSync(opt.cwd)) {
    console.error(`--cwd が実在しない: ${opt.cwd}`);
    process.exit(2);
  }
  if (tmuxOk(["has-session", "-t", `=${session}`])) {
    console.error(`同名のセッションが既に在る: ${session}。触らずに止める。`);
    process.exit(2);
  }
  const outDir = opt.out || join(tmpdir(), `rc-live-${stamp}`);
  if (outDir.includes("/mobile-work/")) {
    console.error(`写しの置き場が repo の中を指している: ${outDir}。個人情報が履歴に入る。`);
    process.exit(2);
  }
  mkdirSync(outDir, { recursive: true });

  console.log(`tmux      : ${TMUX_BIN} (${tmux(["-V"]).trim()})`);
  console.log(`セッション: ${session}(使い捨て)`);
  console.log(`起動      : ${opt.bin}  cwd=${opt.cwd}  ${opt.cols}x${opt.rows}`);
  console.log(`写し      : ${outDir}\n`);

  let pane = null;
  const results = [];
  try {
    tmux(["new-session", "-d", "-s", session, "-x", opt.cols, "-y", opt.rows, "-c", opt.cwd]);

    // ★ペインは**自分のセッションから**取る。名前で当てず、セッション名の一致を確かめる。
    // 区切りは本体と同じ物を使う(タブは locale 次第で `_` に潰れる。inject.mjs の PANE_SEP 注記)。
    const listed = tmux(["list-panes", "-t", `=${session}`, "-F", `#{session_name}${PANE_SEP}#{pane_id}`])
      .split("\n")
      .map((l) => l.split(PANE_SEP))
      .filter((p) => p[0] === session && p[1]);
    if (listed.length !== 1) throw new Error(`ペインが1つに定まらない: ${listed.length}`);
    pane = listed[0][1];

    const injector = new TmuxInjector({ tmux: injectorRunner(), echoBudgetMs: 8000 });

    // claude を起動。ここだけは composer がまだ無いので injector を通さない(素の shell 相手)。
    tmux(["send-keys", "-t", pane, "-l", "--", opt.bin]);
    tmux(["send-keys", "-t", pane, "Enter"]);

    const boot = await waitSendable(injector, pane, 90000, "起動");
    writeFileSync(join(outDir, "00-boot.txt"), boot.text);
    if (!boot.ok) {
      console.error(`起動後 90 秒で入力欄が出ない(state=${boot.state})。写し: ${outDir}/00-boot.txt`);
      // ★2026-08-02: ここは「信頼確認か上限の画面」と**2つを束ねて**いた。人が次に取る手が
      //   全く違う(片方は --cwd を変える / 片方は待つ)ので、束ねた助言は助言になっていない。
      //   しかも画面を見れば区別できる: 上限は告知の文字列で名指しできるし、そもそも上限の
      //   画面は入力欄が実在する = ここ(入力欄が出ない)には来ない。名指しできる物を名指しする。
      if (limitNoticeIn(boot.text)) {
        console.error("  → 画面に**利用上限の告知**が出ている。--cwd の問題ではない。解除を待つ事。");
      } else if (boot.state === "CHOICE") {
        console.error(`  → **信頼確認のダイアログ**(Do you trust the files…)が出ている。`);
        console.error(`     この台本は選択画面で Enter を押さない(押せば「信頼する」の選択になる)。`);
        console.error(`     --cwd に **claude が既に信頼済みの dir** を渡す事。今回渡したのは: ${opt.cwd}`);
      } else {
        console.error(`  → 上限の告知は画面に無く、選択画面でもない(state=${boot.state})。`);
        console.error(`     写しを人が読む事: ${outDir}/00-boot.txt`);
      }
      process.exitCode = 1;
      return;
    }

    const cases = buildCases().filter((c) => !opt.cases || opt.cases.includes(c.id));
    for (const c of cases) {
      // ★1ケースの失敗で残りと**表そのもの**を落とさない。例外をそのまま投げると
      //   finally が片付けた後に表を一行も出さずに終わる = 証拠を出す為の台本が
      //   証拠を捨てる形(8/1 に `tail -20` で一度やった型)。行として記録して続ける。
      try {
        const ready = await waitSendable(injector, pane, 120000, `${c.id} 前`);
        if (!ready.ok) {
          results.push({ id: c.id, why: c.why, chars: c.text.length, result: `前段で時間切れ(${ready.state})` });
          writeFileSync(join(outDir, `${c.id}-stuck.txt`), ready.text);
          continue;
        }
        const r = await injector.send(pane, c.text);
        await sleep(1200);
        const after = injector.capture(pane);
        writeFileSync(join(outDir, `${c.id}-after.txt`), after);
        results.push({
          id: c.id,
          why: c.why,
          chars: c.text.length,
          result: r.sent ? `sent delivered=${r.delivered}` : `未送信 reason=${r.reason}`,
          waited: r.waited ? `echo=${r.waited.echo}ms clear=${r.waited.clear}ms` : "-",
          // ★送った後の画面に上限の告知が出ているか。配達の判定には混ぜない(別の列)。
          limited: limitNoticeIn(after),
        });
      } catch (e) {
        // ペインが消えた等で tmux が落ちた時ここに来る(この台本の tmux() は失敗を握り潰さない)。
        results.push({ id: c.id, why: c.why, chars: c.text.length, result: `★落ちた: ${e.message}` });
        // 相手が居ないなら以降のケースも同じ死に方をするので、そこで止める。
        if (!tmuxOk(["has-session", "-t", `=${session}`])) {
          console.error(`セッションが消えたので残りのケースは回さない: ${session}`);
          break;
        }
      }
    }
  } finally {
    if (opt.keep) {
      console.log(`\n--keep 指定。セッション ${session} は残す。**手で消す事**: tmux kill-session -t ${session}`);
    } else {
      tmuxOk(["kill-session", "-t", `=${session}`]);
      const gone = !tmuxOk(["has-session", "-t", `=${session}`]);
      console.log(`\n片付け: ${session} は ${gone ? "不在を確認" : "★残っている"}`);
    }
  }

  console.log("\n| ケース | 何を見ている | 字数 | 結果 | 待ち | 相手 |");
  console.log("|---|---|---|---|---|---|");
  for (const r of results) {
    // ★2026-08-02: `false` を「応答可」と書いていた。観測したのは**告知が画面に見えない**
    //   事だけで、「答えが返る」は観測していない(告知が上へ流れれば false になるし、
    //   そもそも答えが返ったかはこの列では一度も見ていない)。観測より強い語を出さない。
    const peer = r.limited ? "★上限" : r.limited === false ? "上限の告知なし" : "-";
    console.log(`| ${r.id} | ${r.why} | ${r.chars} | ${r.result} | ${r.waited || "-"} | ${peer} |`);
  }
  const bad = results.filter((r) => r.result !== "sent delivered=verified");
  const limited = results.filter((r) => r.limited);
  console.log(`\n合計: ${results.length - bad.length}/${results.length} が delivered=verified`);
  console.log(`画面の写し(repo の外): ${outDir}`);
  if (limited.length) {
    // 緑の隣に小さく書いても読まれない。**結論の位置に**置く。
    console.log(
      `\n★この結果を「注入の鎖が通った」と読んではいけない: ${limited.length}/${results.length} 件が` +
        `利用上限の画面。**配達は成立したが、相手は一度も答えていない**。` +
        `\n  確かめたのは「本文が入力欄に載って消費された」ところまで。会話が進んだ事は確かめていない。` +
        `\n  上限が解けてから同じ台本をもう一度回す事(それまで exit 0 は出ない)。`,
    );
  }
  // 配達の失敗(1)を上限(3)より優先する。壊れている方を先に見せる。
  if (bad.length) process.exitCode = 1;
  else if (limited.length) process.exitCode = 3;
}

main().catch((e) => {
  console.error(`落ちた: ${e.message}`);
  process.exit(2);
});
