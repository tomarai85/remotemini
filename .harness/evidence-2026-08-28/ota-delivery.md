# 同一 WiFi 無しの配布を通した (2026-08-28)

Tom の異議「同じ WIFI じゃないといけないの論外」への実装側の答え。
経路の実測(なぜ Xcode 経路では解けないか)は `install-path-and-cleanup.md`。

## 何を建てたか

```
Jervis(手元)                          friday(机)                        Tom の iPhone
  build.sh --no-install                                                  (tailnet に居れば
    → 版/commit/机の種を焼き込む                                           何処からでも)
  adhoc-ota.sh
    → Apple Distribution + Ad Hoc profile で署名し直す
    → get-task-allow=false          scp   ~/ota/<秘密>/                    Safari で
    → .ipa + manifest + 導線の頁  ────────→  RemoteMini.ipa                <導線の頁>
                                              manifest.plist               を開いて tap
                                              index.html                        │
                                                   ↑                            │
                                        com.fleet.rc-ota                        │
                                        node ota-server.mjs                     │
                                        127.0.0.1:8788                          │
                                                   ↑                            │
                                        tailscale serve 9443 /ota ──────────────┘
                                        (tailnet 限定。Funnel は 443/8443/10000 のみ
                                         なので、うっかり公開できない)
```

会話の面は `tailscale serve 9443 /` → `127.0.0.1:8787`(rc-backend)のまま。
**同じ入口の別の path** に載せたので、証明書も host 名も既存の物をそのまま使える。

## なぜ TestFlight にしなかったか

Codex(2026-08-28)が「TestFlight が唯一の道」という私の断定を訂正した。それが正しかった。

| | Ad Hoc OTA(採った) | TestFlight |
|---|---|---|
| Apple へ binary を送る | **送らない** | 送る(取り消せない外部送信) |
| App Store Connect のアプリ登録 | 要らない | 要る(名前が全世界で予約される) |
| 反映までの時間 | scp が終わった瞬間 | Apple の処理待ち |
| 束の寿命 | 消すまで | **90 日で消える** |
| 取り消し | file を消すだけ | 実質できない |
| Tom の判断が要るか | **要らない**(全部彼の設備の中) | 要る(彼の Apple の身元に紐づく) |

Ad Hoc の制約は「端末が profile に登録済みである事」だけで、Tom の iPhone は
既に登録されていた(`iPhone (387)` / ENABLED / API で実測)。

★私が作った物: bundle id `com.tomarai.remotemini`(id 4B8C47Z52A)と
profile `RemoteMini AdHoc OTA`(uuid 090c8206…、期限 2027-06-07)。
どちらも Xcode の自動署名が日常的に作る種類の物で、Codex も (a) は EXECUTE と裁定した。
**App Store Connect のアプリ登録も binary の送信もしていない**(それらは GATE 裁定だった)。

## 認証が無い道をどう守っているか

iOS の `installd` は manifest と .ipa を取りに来る時、独自の header を送らない。
だから**この道に認証は付けられない**。代わりに:

| 守り | 実測 |
|---|---|
| 127.0.0.1 にしか bind しない | `lsof -nP -iTCP:8788` = `127.0.0.1:8788 (LISTEN)` |
| 外へ出る面は tailnet 限定の 9443 だけ | Funnel が使えるのは 443/8443/10000 のみ = 構造的に公開できない |
| 推測できない path の一段 | 24 桁 hex。**焼き直しても変えない**(変えると Tom の栞が死ぬ) |
| 一覧を返さない | 対照 N1。返した瞬間に秘密が秘密でなくなる |
| ROOT の外へ出られない | 対照 N2/N3/N4(traversal・接頭辞・symlink) |
| 書き込みの口が無い | 対照 N5(POST/PUT/DELETE = 405) |

★**tailnet 限定は「Tom だけ」を意味しない**。実測 2026-08-28、Tom の tailnet には
今も `edith`(2026-08-20 に家族さんへ譲渡した機体)が居る。だから秘密の一段が要る。

### ★同日中に判明: 此の守りは一度**嘘だった**

上の表の「推測できない path の一段」は、書いた当日は**成立していなかった**。
`adhoc-ota.sh` が置いた直後に `chmod -R a+rX ~/ota` を撃っていた ——
「配る物だから読ませる」という反射で書いた1行。

実測(敵対レビューの指摘を受けて確認): friday の実アカウントは `athenas` / `tomtim` /
`udagawa` の3つ。3人とも `staff` に居て、`/Users/athenas` は `drwxr-x---`(group に r-x)。
つまり**秘密の hex は他の2人から `ls` するだけで読め、`.ipa` も読めた**。
唯一の守りだと自分で書いた物が、同じ機体のローカルからは1つも守っていなかった。

直し: `chmod 700 ~/ota && chmod -R go-rwx ~/ota`。配るのは athenas 権限の node なので、
他人に読ませる必要は最初から無い。再発検査 = `ota-verify.sh` の **N4**
(緩めると赤・戻すと緑まで実演済み)。

★**HTTP の側だけ測っていると此処は永久に見えない。** N1〜N3 も、対照 15 本も、
全部 127.0.0.1 の応答しか見ていない。守りが file の権限に載っているなら、
検査も file の権限を見ないといけない。
★守りを1つ足すより先に、**主張していない守りを主張しない**事 ——
之を直すまで、上の表は読む人に嘘を言っていた。


## 検査が本物である事の実証(ここが今日の主な収穫)

`rc-backend/test/ota-server-controls.sh` は最初 **15/15 緑だったが、何も測っていなかった**。

守りを素朴な `startsWith(ROOT)` へ落とす変異を当てても **15 本全部緑のまま**だった。
原因: **curl は既定で URL の `..` を送る前に畳む**。`/../outside.txt` は `/outside.txt`
としてサーバへ届き、ROOT に無いので 404 —— 守りが1行も効いていなくても緑が出る。

`--path-as-is` を足して測り直した:

| 版 | 結果 |
|---|---|
| 本物 | 緑 15 / 赤 0 |
| 封じ込めを**素朴な startsWith** に落とす | 赤 1(N3 だけ = 接頭辞が同じ隣の dir が読める) |
| 封じ込めを**全部外す** | 赤 6(N2 の4本 + N3 + N4) |

★変異の細かさで赤の本数が変わる = **どの守りがどの対照に対応しているかまで測れている**。
「緑だった」ではなく「赤を出せる事を確かめた上での緑」。

## 外から測った実測(`ios/tools/ota-verify.sh`)

```
配る面(desk.tailnet.example:9443、tailnet 限定)
  緑 manifest が返る / 束(.ipa)が返る / 導線の頁が返る
  緑 N1 秘密のひとつ手前が中身を一覧しない
  緑 N2 出鱈目な秘密は通らない(404)
  緑 N3 manifest の行き先が今の机を指している
  緑 配っている版 = 手元で焼いた版(build 88)
  緑 7 / 赤 0 / 未測定 0
```

## まだ測っていない事(正直に)

- **Tom の iPhone が実際に入れられるか**は測っていない。私は彼の電話で Safari を開けない。
  彼が導線の頁を開いて tap するまで「入る」とは言わない。
- 今入っている束は**開発署名**(wildcard profile)。Ad Hoc 署名の束は
  `application-identifier` が `KJ2942P8F8.com.tomarai.remotemini` で同じなので
  上書きで入るはずだが、**はず**であって実測ではない。入らなければ一度消して入れ直す。
- `adhoc-ota.sh` を端から端まで1回で通した実測はまだ(署名と梱包は手で通し、
  配信面は同じ成果物で測った)。道具としての通し走行は account の対照が空くのを待っている。

## 途中で踏んだ物

★`$DESK_PORT、` —— shell の変数の直後に全角の読点を置いて `unbound variable` で落ちた。
**今日この形で落ちるのは3回目**(Swift の識別子で2回、shell で1回)。
`ios/tools/*.sh` と `rc-backend/tools/*.mjs` を機械で走査して `${}` へ直した。

★Mac App Store 版の Tailscale は**ファイルを配れない**
(`Path serving is not supported on macOS due to sandbox restrictions`)。
proxy を的にした `--set-path` は通る。だから静的配信を別プロセスに切った ——
結果的にこれが正しかった(認証の無い口を rc-backend の中に作らずに済んだ)。

★足す前に `tools/serve-decision.sh` の述語を読んだ。各 Web entry の `Handlers["/"]`
しか見ないので、`/ota` を足しても rc-backend の起動時判定は `ok` のまま
(実測で確認済み)。読まずに足していたら、毎回の起動で「他人が居る」の
**偽の警告**が出る所だった —— 今日ちょうど同じ形を1つ作りかけている。
