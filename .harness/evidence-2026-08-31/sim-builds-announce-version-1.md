# 砂場/simulator の app が本番の机へ版 `1` を名乗る(2026-08-31 実測)

## 症状

friday の観測器が **2回**「電話が build=1 を名乗りました」を Tom の Discord へ出した
(02:59:42 / 04:59:45)。`1` は build 番号ではない —— 実際の版は 115 → 116。

## 出所(実測で確定)

- `ios/project.yml` は `CFBundleVersion: "1"` を**静的な既定**として持つ。
  実番号を刻むのは `ios/tools/build.sh`(2026-08-10 以降、commit の通算数)。
- 砂場の UI 対照(`conversation-ui-control.sh` / `long-conversation-diag-control.sh`)は
  `xcodegen generate` + `xcodebuild` を**直に**撃つので **`build.sh` を通らない** →
  焼き上がる app の `CFBundleVersion` は `1` のまま。
- 其の app が本番の机へ要求を出すと、机は `client=app build=1` として記録する。
  2026-08-31 に足した sighting の枝は `client=app` を数えるので、
  **「新しい版が現れた」と読んで通知する**。

実測の証拠: `build=1` の行は `/api/sessions` と `/api/account` の**両方**に出る。
密な名乗り(全部の口で押す)は build 116 の性質なので、其の app は
「116 の source から焼かれたが版は 1」= 砂場のビルドだと確定できる。

## 何が本当の問題か

**開発の走行と Tom の電話が、机の上で同じ `client=app` に見える**事。
`RCRole` という仕組みは既に在り、机の分類器は `x-rc-role: control` を
`client=control` に落とす —— 検査用の殻はそれを使っている。
砂場/simulator のビルドが其れを名乗っていないので、Tom の要求と混ざる。

## 直し方(次の回)

`build.sh` の simulator 経路(`--sim` / `--sim-app`)で焼く app に `RCRole=control` を
刻む。すると机の側は `client=control` として記録し、sighting の枝(`client=app` を見る)は
**構造的に**混ざらなくなる。★版の数字で弾く形(`build=1` を無視する等)は採らない ——
数字は変わるが、役は変わらない。

## 当面の手当て

机の記録(`health-state.json.phone-seen`)から `1` を除去した(2回目。退避あり)。
之は対症であって、上の直し方が入るまで再発しうる。
