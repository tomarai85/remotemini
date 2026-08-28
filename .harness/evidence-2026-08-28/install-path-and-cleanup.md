# 配布経路の実測 と 検査残骸の後始末 (2026-08-28)

## 1. 「同じ WiFi じゃないといけないの論外」への実測回答

Tom の指摘(2026-08-27):「同じ WIFI じゃないといけないの論外だけど」

### 測った物

| 測定 | 結果 |
|---|---|
| 電話は tailnet に居るか | **居る** — `10.0.0.0 iphone-13 iOS` (tailscale status) |
| devicectl から見えるか | 見えるが **`unavailable`** (`xcrun devicectl list devices`) |
| tailnet の IP を直に指せるか | **拒否** — `ERROR: The specified device was not found. (Name: 10.0.0.0) CoreDeviceError 1000` |
| 端末 UUID 指定での状態 | **`tunnelState: unavailable`** |
| USB に居るか | 居ない (`system_profiler SPUSBDataType` に iPhone 無し) |

### 結論(反証条件つき)

**tailnet に居る事と、Xcode / devicectl が入れられる事は別**。devicectl の coredevice tunnel は
USB か **同一 LAN の探索(Bonjour/mDNS)** の上に建つ。Tailscale は L3 の VPN なので mDNS を運ばない。
`--device <IP>` を受け付けない事がそれを直接示している —— 対応していれば IP で引けるはずで、
実際には「そんな端末は無い」と名前解決の段で落ちる。

つまり **Tom の異議は正しく、かつ Xcode 経路では解けない**。ケーブルか同一 LAN を要求するのは
Apple の配布経路の性質であって、私の手抜きではない。回避策は経路を変える事しかない:

| 経路 | 同一 WiFi 要るか | 状態 |
|---|---|---|
| Xcode / devicectl | **要る**(ケーブル or 同一 LAN) | 今使っている物。上記の通り tailnet では無理 |
| **TestFlight** | **要らない**(インターネット越し) | 素材は揃っている。`com.tomarai.remotemini` の**アプリ登録だけが未了** |
| MDM / 社内配布 | 要らない | 設定されていない。個人には過剰 |

★**反証条件**: Apple が devicectl に任意 IP のペアリングを足したら、または Tailscale 側で
mDNS 中継を建てたら、上の結論は崩れる。今日の実測では両方とも無い。

★これで TestFlight の位置付けが変わる。「あると便利」ではなく **Tom が既に出した指示に
答える唯一の道**。判断待ちは 1 点(Tom の開発者アカウントに `com.tomarai.remotemini` を登録して良いか)。

## 2. 検査残骸の後始末(Tom「あとは残骸処理忘れないでね」)

### friday(athenas)側

| 物 | 処理 |
|---|---|
| tmux `rc-e2e-202608282106417241955328597376294` (16:06 建立) | **kill**。Tom の `work` セッション(pane %1 / pid 6306)には触れていない |
| 検査用 transcript 9本 + pane 記録 3本 | **隔離**(削除でない) → `~/.rc-backend/quarantine-2026-08-28-jarvis-e2e/` (12 ファイル) |

**効果の実測**: `GET /api/sessions` の一覧が **4 件 → 3 件**。
消えた 1 件は私の検査セッション(題「1から400までの数字リスト」= live-send-check の投入文)。
残る 3 件は全部 Tom の実物(`New session` = 今生きている `work` / `UNO ハンドオフの確認` / 8/26 の物)。

★**電話の一覧に私の検査が混ざっていた**。これは「残骸」ではなく Tom の画面の汚染で、
彼が言うまで私は数えていなかった。

### 併せて分かった良い事: 死んだ登録は既に濾されている

`~/.rc-backend/panes/` に **pid が死んだ登録が 9 件**在ったが、一覧には 1 件も出ていなかった。
Codex が挙げた「crash-orphan」は **今日の Tom の画面には影響していない**(掃除の価値は在るが緊急ではない)。
実測: 登録 11 件 / 生存 pid 2 件 / 一覧 4 件。

### Jervis 側

`iPhone-dogfood` シミュレータから **`RemoteMiniUITests-Runner.app` を外した**
(bundle id = `com.tomarai.RemoteMiniUITests.xctrunner`)。`xcodebuild test` が置いていく物で、
Tom がドッグフードに使う画面にアイコンが 1 個増えていた。私が出した瑕なので私が消した。
手順: headless `simctl boot` → `uninstall` → `shutdown`(状態は元の Shutdown に戻した。画面は奪っていない)。

**本体は無事**: `RemoteMini.app` = `RCBaseURL: https://desk.tailnet.example:9443` /
`RCBuildRev: 6d34f7c-dirty` / build 82 —— 8/27 12:04 に私が復元した物のまま。

★ランナーの bundle id を1回目に間違えた(`com.tomarai.remotemini.RemoteMiniUITests.xctrunner`)。
`simctl uninstall` は**存在しない id でも黙って成功する**ので、`&&` の後の「外した」は嘘だった。
disk 上に bundle が残っている事で気付いた。**uninstall の成否は exit code でなく、消えた事で確かめる。**
