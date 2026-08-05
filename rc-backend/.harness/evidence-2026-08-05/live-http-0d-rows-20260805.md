# §0-d の3行を edith で観測した(2026-08-05 19:3x JST)

走らせた物: `tools/live-http-check.mjs`(edith 上、Node 25.9.0、`rc-claude` ラッパ、
使い捨て tmux セッション `rc-e2e-<数字>`、サーバは 127.0.0.1 の私用ポート)。
結果: **25 OK / 0 NG / 実測メモ 8 件**、exit 0。

この file には**会話 id もアカウントのメールも写さない**。下の json は実測した本文そのままだが、
どちらにも id は入っていない(サーバがその欄を返していない)。

---

## 行1: 400 / 401 / 404 の線の上の形(`code` 欄を含む)→ **閉じた**(先に観測済)

`tools/wire-shape.mjs` を edith と同一(sha256 一致)にして5つの形を観測した:

| 叩いた物 | status | 本文の欄 | `display` |
|---|---|---|---|
| `GET /api/sessions`(鍵無し) | 401 | `error`, `code:"AUTH_REQUIRED"` | **無** |
| `GET /api/nope` | 404 | `error`, `code:"NO_SUCH_ROUTE"` | **無** |
| `GET /api/sessions/<居ない>/history` | 404 | `error`, `code:"SESSION_NOT_FOUND"` | **無** |
| `POST /api/sessions/<実在>/messages` 本文 `{}` | 400 | `error`, `display{kind,text,keepText}` | **有** |
| `POST /api/sessions/<居ない>/messages` 本文 `{"text":"probe"}` | 404 | `error`, `code:"SESSION_NOT_FOUND"` | **無** |

→ 電話の契約(「`display` が無いのは 401 と 404+`SESSION_NOT_FOUND` だけ、それ以外は応答契約違反」)
は**実物と一致している**。source の読みだけで閉じなかったのはこの為。

## 行2: `202 + delivered:"unverified"` の実物 → **閉じた**

起こし方(再現手順): 生成中(`activity === "observed"`)に、**TUI の定型文と同一の本文**
(`COMPOSER_PLACEHOLDER` = `Press up to edit queued messages`)を送る。
`inject.mjs` の `bodyIsPlaceholder` が「入力欄が空 = 取り込まれた」という直接証拠を無効にするので、
判定が構造的に決まらない = コードが `verified` と名乗るのを拒む唯一の道。

実測した本文(`10-unverified.json`、そのまま):

```json
{
  "accepted": true,
  "route": "tmux",
  "pane": "%3",
  "source": "registry",
  "delivered": "unverified",
  "note": "Enter は送りましたが、本文が取り込まれた事を確認できませんでした(入力欄に残っているか、入力欄自体が見えなくなっています)。画面を確認してください。",
  "display": {
    "kind": "warn",
    "text": "Enter は送りましたが、本文が取り込まれた事を確認できませんでした(入力欄に残っているか、入力欄自体が見えなくなっています)。画面を確認してください。本文は残してあります。送り直すと二重に入ることがあります。",
    "keepText": true
  }
}
```

★電話にとっての要点2つ:
1. `display.text` は `note` の**続きを持っている**(「本文は残してあります。送り直すと二重に入ることがあります。」)。
   電話は `note` ではなく `display.text` を出す —— `note` を出すと二重送信の警告が落ちる。
2. `keepText: true` = **202 でも入力欄を消さない**。`ConversationViewModel` は `keepText` を
   欄として読んでいる(`kind` から推さない)ので此処と一致している。

## 行3: ワーカー経路(`route:"worker"`)の送信 → **閉じた**

起こし方: 使い捨てペインを畳んでから(転写は残る)同じ会話へ送る。

実測した本文(`11-worker.json`、そのまま):

```json
{
  "accepted": true,
  "route": "worker",
  "seq": 1,
  "display": {
    "kind": "ok",
    "text": "送った(ワーカー)",
    "keepText": false
  }
}
```

★この形には **`delivered` も `pane` も無い**。`SendClient.Envelope` は `display` と `code` しか
宣言していないので影響を受けない —— 逆に言うと、生の欄から画面を作る実装だったら此処で落ちていた。

後始末も観測した: 割り込み(`status=200 route=worker interrupted=true`)の後、
`pgrep -f <会話 id>` の**一致数 0**。ワーカーの子は残らない。

---

## 台本側に足した物(この観測の為)

- `src/inject.mjs`: `COMPOSER_PLACEHOLDER` を `export` にした。台本へ写しを置くと
  「写しが実物と最初からズレる」型になるので、値の出所は1つに保つ。
- `tools/live-http-check.mjs`: §10(行2)/ §11(行3)/ `procsMatching`(数だけ返す。
  `pgrep -f` の行は argv と環境変数を含むので持ち出さない)/ `finally` での登録簿の掃除
  (`panes/<id>.json` と `heads/<id>.json` を**完全一致でのみ**消し、不在を確認)。
- 掃除を足した理由: 前回の実機走行が `panes/<id>.json` を1本残していた(ペインは既に死んでいた)。
  手で消して終わりにすると同じ物がまた残る。
- `test/live-http-swallow.test.mjs`: `procsMatching` の素の catch を**理由付きで**除外に登録
  (`pgrep` は一致0件で exit 1 = 失敗ではなく「0件」の表現)。除外は 8 → 7 → 8 と動いており、
  最初の 8 と今の 8 は**顔ぶれが違う**。数字の一致を「合っている」と読ませない註釈を両方に置いた。

## 同じ走行で観測した、閉じていない物

- edith の `npm test` は **673 pass / 1 fail**。落ちるのは `no-linerefs.test.mjs` の
  「走査の範囲が木の直下と一致している」で、実測値は `['rc-backend/.git']`。
  これは 2026-08-03 の艦隊の掃除が作った**私の物ではない `.git`**(手元の木には無い)。
  私の変更とは無関係だが、**edith 側の緑は今この1件ぶん赤い**ので、緑と呼ばない。
- 手元(MBP)の `npm test` は **681/681 緑**。件数が edith と違うのは、木の中身を数える検査が
  在るから(edith の木には `ios/` が無い)。
