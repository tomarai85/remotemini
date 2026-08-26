# 公開面と机の同居 — 2026-08-26 実測

## 測った物
{
  "TCP": {
    "443": {
      "HTTPS": true
    },
    "9443": {
      "HTTPS": true
    }
  },
  "Web": {
    "desk.tailnet.example:443": {
      "Handlers": {
        "/": {
          "Proxy": "http://127.0.0.1:8799"
        },
        "/ja": {
          "Proxy": "http://127.0.0.1:8801"
        }
      }
    },
    "desk.tailnet.example:9443": {
      "Handlers": {
        "/": {
          "Proxy": "http://127.0.0.1:8787"
        }
      }
    }
  },
  "AllowFunnel": {
    "desk.tailnet.example:443": true
  }
}

## 持ち主
8787 user=athenas
8799 user=athenas
8801 user=athenas
-rw-------@ 1 athenas  staff  65 Aug 25 15:10 /Users/athenas/.rc-backend/api.key

## 最後の線(盗鍵を模した loopback からの拒否)
  409 / reason=denied-by-desk / rule=no-recursive-delete

## 対照

  赤に倒れた入力: 3 件

全ケース OK
