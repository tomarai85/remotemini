# 履歴の伏字化 計画(CF-5「private GitHub へ出すか」の材料)— 起票 2026-09-01、予行 2026-09-03

**目的**: この repo を GitHub(private)へ出す前に、履歴(push が運ぶのは作業木ではなく履歴)に
残る 3 種の識別子を、**捨てクローンで**書き換えて検出器を通せるかを測る。本物の repo には
書かない。出すか・書き換えるかは Tom の裁定で、此処は其の材料。

## 種類と規則(`.harness/redaction-rules.txt`、検出器 `rc-backend/tools/check-no-pii.sh` と同じ正規表現)

| 種類 | 履歴の箇所数(readiness-check、2026-09-03) | 規則 | 置換後 | 書き換えると何が壊れるか |
|---|---|---|---|---|
| 1 人のメール | 約 10,935 | 検出器の `PAT_MAIL`(example.* / .invalid / .test は触らない) | `mail-redacted@example.invalid` | 転写の fixture・設計文書の本文。意味は残る(誰か、が消えるだけ) |
| 2a tailnet 名 `<host>.tail<id>.ts.net` | 約 45,041(2b と合算) | 検出器の `PAT_MACH` 前半 | `desk.tailnet.example` | **deploy / OTA / 観測の台本が机を指せなくなる**(公開した写しは動かない写し) |
| 2b CGNAT の IP 100.64/10 | (同上) | 検出器の `PAT_MACH` 後半 | `10.0.0.0` | 同上 |
| 3 hostname(短い名) | 65 | 走行時に `hostname -s` から足す(literal を repo に置かない) | `host-redacted` | 錠の札(`deploy-<host>-…`)の実例だけ。動作には効かない |

★生 capture(fixture)の「同じ桁数の伏字」は此の規則では守れない(置換は固定文字列)。罫線・箱の
判定が変わる検査は書き換え後に赤くなる = 下の「一式の集計」が其れを数える。
★規則 file(`.harness/redaction-rules.txt`)には**註釈を書けない**。`git filter-repo --replace-text` は
`==>` の無い行を「其の文字列を `***REMOVED***` へ」の規則として読む。予行 1 回目(2026-09-03)で
単独の `#` の行が全 533 file の `#` を潰し(shebang も)、検出器が動かず・一式が 17 本 赤になった。
台本は `==>` の無い行が在れば走る前に止まる。此処に本物の値を書かないのは、此の file 自身が
検出器の赤になり、道具が検査対象を増やすから(hostname だけは走行時に `hostname -s` から足す)。

## 予行の台本(`.harness/redaction-rehearsal.sh`)

clone(hardlink 無し)→ 規則を当てて `git filter-repo --replace-text` → 書き換え後の clone に
検出器(作業木 + 履歴)→ 書き換え後の `npm test` の集計 → 本物の HEAD と remote 無しを確認 → 捨てる。
出力の最後の 1 行が `REHEARSAL CLEAN` / `REHEARSAL DIRTY`。

## 予行の結果(2026-09-03)

(台本の出力から写した。走らせるたびに更新する)

- 書き換えた commit: **536 / 539**(全 commit を書き換える = 履歴の sha が全部変わる)。HEAD で内容が変わった file: **85**
  (大半は `.harness/evidence-*` と `.harness/feedback/*`、sprint の brief、設計文書)。
- HEAD での置換の内訳: CGNAT の IP **114** / tailnet 名 **82** / メール **47** / hostname **1**。
- 書き換え後の検出器(`check-no-pii.sh`、作業木 + 履歴): **緑(exit 0)**。
- 書き換え後の `npm test`: **1115 / 1116**。赤 1 本 = `★文面に会話の中身が入らない(通知経路に秘密を流さない)`
  —— fixture のメールを伏字に置き換えた事で、検査が「漏れていない」の証拠に使う文字列が変わった。
  書き換える道を選ぶなら、其の検査の検体を伏字前提に直す(1 本、意味は変わらない)。
- 本物の HEAD は不変、remote 無し(台本が自分で確認)。
- 予行 1 回目は規則 file の註釈が `***REMOVED***` 規則として読まれ全 file が壊れた(上の註)。2 回目で通った。

## Tom の裁定の形(はい/いいえ で答えられる 3 つ)

| 選択 | 何が起きるか | 私の推奨 |
|---|---|---|
| A. private のまま**今の履歴で**出す | 露出は 3 種(メール / tailnet 名と IP / hostname)。private なら GitHub と Tom 以外は読めない。台本は動く写しのまま | **推奨**。鍵は 0 件で、tailnet 名と CGNAT の IP は tailnet の外から届かない |
| B. 書き換えてから出す | 検出器は通る(予行で確認)が、写しの deploy 台本は机を指さない。本物の履歴を書き換える場合は全 worktree・機外 mirror(`athenas:~/backup/jervis-mirrors/`)の付け直しが要る | 公開(public)にする日が来たら |
| C. 出さない | 機外の複製は `athenas` の mirror だけ(30 分ごと)。之で足りているなら出す理由は薄い | GitHub に出す価値(Tom が他の機械・人から読む)が無いなら |
