# display-guard

macOS で、実際には使っていないディスプレイを「生きている」と扱ってしまい、ウィンドウがそこへ移動する問題(ゾンビ画面)を避けるための小さな常駐ツールです。Apple Silicon の Mac 専用です。

## 動作

| 状況 | 動作 |
|---|---|
| 設定した USB 機器(キーボードなど)が、すべて Mac から見えなくなった | メインモニターを DDC で別の入力(例: DP1)に切り替えてから、切断する |
| どれかが戻った | メインモニターを再接続し、DDC で Mac の入力(例: HDMI1)に切り替える |
| Mac がロックされている(設定でオフにできる) | メインモニター以外を切断する |
| Sunshine がセッション中(設定でオフにできる) | メインモニター以外を切断する |
| 通常に戻った | 再接続する |
| ロックを解除した(設定したモニターのみ) | 少し待ってから、そのモニターを一度切断してもう一度接続する。再接続しても画面が暗いままになるモニターへの対策 |

- 切断は `CGSConfigureDisplayEnabled`(非公開 API)を使います。
- 入力の切り替えは、IOAVService 経由の DDC/CI(VCP 0x60 の書き込み)です。モニターが表示している入力を読み戻すことは、信頼できないため使いません。USB 機器の有無を手がかりにしています。
- 有効なディスプレイが0枚にはなりません。
- USB の抜き差しは IOKit の通知で受け取り、ロックと Sunshine は 1.5 秒ごとに確認します。

## 注意

- 非公開 API を使うため、macOS の更新で動かなくなる可能性があります。
- DDC は IOAVService を使うので、Apple Silicon の Mac 専用です。入力の値(`mac_input` / `other_input`)はモニターによって違います。HDMI 1 = `0x11`、DP 1 = `0x0F` が多いです。
- Sunshine の判定は、既定ではこの Mac の LAN / Tailscale アドレスの `:47989` だけに問い合わせます(`127.0.0.1` は見ません。ポート転送が別のマシンの応答を返すことがあるため)。アドレスは設定で指定できます。

## 使い方

```bash
swift build -c release
mkdir -p ~/.local/bin
cp .build/release/display-guard ~/.local/bin/
~/.local/bin/display-guard setup      # 質問に答えて設定ファイルを作る
~/.local/bin/display-guard status     # 現在の状態を表示
~/.local/bin/display-guard restore    # 切断したディスプレイを戻す
~/.local/bin/display-guard run        # 常駐して監視する
```

ログイン時に自動で起動するには、`com.local.display-guard.plist.template` の `__HOME__` を自分のホームフォルダに置き換え、`~/Library/LaunchAgents/com.local.display-guard.plist` として置いてから、次を実行します。

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.display-guard.plist
```

外付けボリューム上のバイナリは、launchd から起動すると止まることがあるため、`~/.local/bin` などに置いてください。

## 設定

`display-guard setup` が、次の順に質問して `~/.config/display-guard/config.toml` を作ります(矢印キーで移動、スペースで選択、Enter で次へ)。

1. メインモニターの選択と、入力の値
2. USB 機器の選択(複数可)
3. メインモニター以外も切断するか → 切断する条件(ロック中 / Sunshine のセッション中)→ Sunshine のアドレス(既定は `auto`)
4. ロック解除後に暗いままになるモニターの選択(モニターの一覧から複数選択、なければ何も選ばず Enter)→ 待ち時間
5. タイミング

ファイルは手で編集できます(`DISPLAY_GUARD_CONFIG` で場所を変えられます)。

```toml
[monitor]
vendor      = 0x10AC   # EDID のベンダー ID(Dell)
model       = 0x2014   # EDID の製品コード(G2725D)
mac_input   = 0x11     # この Mac を映す入力(HDMI 1)
other_input = 0x0F     # もう1台を映す入力(DP 1)

[[keyboard]]           # 複数書ける。どれか1つでも見えていれば、モニターを使う
vendor  = 0x3151
product = 0x0006       # 省略すると、そのベンダーの機器すべて

[others]
enabled       = true
when_locked   = true
when_sunshine = true
sunshine_address = "auto"   # または "100.64.0.1"、"host:47989"

[[refresh_on_unlock]]      # ロック解除後に暗いままになるモニター(複数可、なければ書かない)
vendor = 0x25E4
model  = 0x1706

[timing]
poll_interval    = 1.5      # ロックと Sunshine の確認間隔(秒)
recheck_delay_ms = 300      # 切断前の再確認までの待ち(ミリ秒)
refresh_delay_ms = 1000     # ロック解除から再接続までの待ち(ミリ秒)
refresh_off_ms   = 2000     # 再接続の間、切断したままにする時間(ミリ秒)
```

設定ファイルがないと、`run` は起動しません。先に `setup` を実行してください。

## ライセンス

MIT
