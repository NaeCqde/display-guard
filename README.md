# display-guard

macOS で、実際には使っていないディスプレイを「生きている」と扱ってしまい、ウィンドウがそこへ移動する問題(ゾンビ画面)を避けるための小さな常駐ツールです。Apple Silicon の Mac 専用です。

## 動作

| 状況 | 動作 |
|---|---|
| MonsGeek のキーボード(有線・ドングル)が Mac から見えなくなった | Dell を DDC で DP1 に切り替えてから、切断する |
| キーボードが戻った | Dell を再接続し、DDC で HDMI1 に切り替える |
| Mac がロックされている | Dell 以外を切断する |
| この Mac の Sunshine がセッション中 | Dell 以外を切断する |
| 通常に戻った | 再接続する |

- 切断は `CGSConfigureDisplayEnabled`(非公開 API)を使います。
- 入力の切り替えは、IOAVService 経由の DDC/CI(VCP 0x60 の書き込み)です。Dell が表示している入力を読み戻すことは、信頼できないため使いません。キーボードの有無を手がかりにしています。
- 有効なディスプレイが0枚にはなりません。
- USB の抜き差しは IOKit の通知で受け取り、ロックと Sunshine は 1.5 秒ごとに確認します。

## 注意

- 非公開 API を使うため、macOS の更新で動かなくなる可能性があります。
- モデルは Dell G2725D、キーボードは MonsGeek(USB vendor `0x3151`)に決め打ちです。他の機種で使う場合は、`Sources/display-guard/main.swift` の先頭の設定を変更してください。
- Sunshine の判定は、この Mac の LAN / Tailscale アドレスの `:47989` だけに問い合わせます(`127.0.0.1` は見ません)。

## 使い方

```bash
swift build -c release
mkdir -p ~/.local/bin
cp .build/release/display-guard ~/.local/bin/
~/.local/bin/display-guard status     # 現在の状態を表示
~/.local/bin/display-guard restore    # 切断したディスプレイを戻す
~/.local/bin/display-guard run        # 常駐して監視する
```

ログイン時に自動で起動するには、`com.local.display-guard.plist.template` の `__HOME__` を自分のホームフォルダに置き換え、`~/Library/LaunchAgents/com.local.display-guard.plist` として置いてから、次を実行します。

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.display-guard.plist
```

外付けボリューム上のバイナリは、launchd から起動すると止まることがあるため、`~/.local/bin` などに置いてください。

## ライセンス

MIT
