# display-guard の仕様

macOS(Apple Silicon 専用)の常駐ツール。実際には使っていないディスプレイを macOS が「生きている」と扱い、ウィンドウがそこへ移動する問題(ゾンビ画面)を避ける。

## コマンド(`display-guard [run|status|restore|setup]`)

| コマンド | 動作 |
|---|---|
| `run`(既定) | 設定を読み、前回の異常終了で切断したままのディスプレイを戻し、常駐して監視する。SIGINT / SIGTERM / SIGHUP を受けたら、切断したディスプレイを戻してから終了する(終了コード 0) |
| `status` | ディスプレイ・切断中のもの・登録した USB 機器の数・ロック・Sunshine の状態を表示する。設定がなくても動く |
| `restore` | 切断したディスプレイを戻す |
| `setup` | 対話式で設定ファイルを作る(端末が必要。既存なら上書きの確認)。ディスプレイや USB 機器が見つからなければ終了コード 1 |
| それ以外 | 使い方を出して終了コード 2 |

設定が読めない・不正なら、理由を出して終了コード 1(`run`)。

## 設定ファイル

場所: `~/.config/display-guard/config.toml`。環境変数 `DISPLAY_GUARD_CONFIG` があればそのパス(`~` を展開)。

| テーブル | キー | 意味 |
|---|---|---|
| `[monitor]` | `vendor`, `model` | メインモニターの EDID のベンダー ID・製品コード(CoreGraphics が返す値) |
| | `mac_input` | この Mac を映す入力の VCP 0x60 の値(HDMI 1 = 0x11) |
| | `other_input` | もう1台を映す入力の値(DP 1 = 0x0F) |
| `[[keyboard]]` | `vendor`, `product?` | 「机がこの Mac につながっている」合図の USB 機器。`product` を省くとそのベンダーの全機器。**最低1つ必要**(なければ、モニターが常に切断されるので、起動しない) |
| `[others]` | `enabled`(既定 true) | メインモニター以外を切断する機能の全体スイッチ |
| | `when_locked`(true) | Mac がロック中に切断する |
| | `when_sunshine`(true) | Sunshine のセッション中に切断する |
| | `sunshine_address`(`auto`) | `auto` = この Mac の自分のアドレス。または `host` / `host:port`(ポートの既定 47989) |
| `[timing]` | `poll_interval`(1.5 秒) | ロックと Sunshine の確認間隔 |
| | `recheck_delay_ms`(300) | 切断する前の再確認までの待ち |

## 動作

1. **メインモニター**: 登録した USB 機器が1つも見えなくなったら、DDC で `other_input` に切り替えてから(0.5 秒待ってから)切断する。1つでも戻ったら、再接続してから `mac_input` に切り替える(リンクが上がるまで数回の確認ごとに、同じコマンドを送り直す)。切断の前に、300ms 後にもう一度数えて、USB の再列挙で一瞬消えただけなら何もしない。
2. **ほかのディスプレイ**: ロック中、または Sunshine のセッション中は切断し、戻れば再接続する(`[others]` で切れる)。
3. **有効なディスプレイが0枚にならない**: 全部が切断対象になるときは、メインモニター以外を、それもなければ全部を残す。
4. 切断したディスプレイの ID は `~/.local/state/display-guard/disabled.json` に、**切断する前に**記録する(異常終了しても `run` の起動時と `restore` で戻せる)。
5. USB の抜き差しは IOKit の通知ですぐに反映する。ロックと Sunshine は `poll_interval` ごと。

## 外部とのやりとり

- 切断: `CGSConfigureDisplayEnabled`(非公開 API)。macOS の更新で動かなくなることがある。
- 入力の切り替え: IOAVService の I2C で DDC/CI(VCP 0x60 の**書き込みだけ**。モニターが表示中の入力の読み戻しは信頼できないので使わない)。ディスプレイを自分で切断している間は届かないので、切断の前に送る。
- ロック: `CGSSessionCopyCurrentDictionary` の `CGSSessionScreenIsLocked`。
- Sunshine: `http://<アドレス>:47989/serverinfo` に GET(1 秒で時間切れ)し、応答に `<state>` があって `SUNSHINE_SERVER_BUSY` を含めばセッション中。`auto` では**この Mac の `127.*` と `169.254.*` 以外の IPv4 アドレス**だけに聞く: ポート転送(OpenRemoteURLReceiver など)が `127.0.0.1:47989` を占有して別のマシンの Sunshine が答えることがあるため、`127.0.0.1` には聞かない。
- 試験用: 環境変数 `DG_FAKE_FILE`(`keyboards=2`、`locked=1`、`sunshine=1` の行を持つファイル)で、USB・ロック・Sunshine を差し替えられる。`keyboards` を指定すると DDC は送らない。

## 構成(`Sources/display-guard/`)

`main.swift`(判断と実行)、`Config.swift`(設定の読み書き)、`Setup.swift`(`setup`)。

## ビルドと常駐

`swift build -c release`、`~/.local/bin/` に置く(外付けボリューム上のバイナリは launchd から起動すると止まることがある)。ログイン時の起動は `com.local.display-guard.plist.template`(`__HOME__` を置き換えて `~/Library/LaunchAgents/` へ)。

## 脆弱性として扱わないもの・前提

- 設定ファイルと環境変数は、この Mac の利用者本人が書く。信頼する。
- 非公開 API の使用は意図したもの。
- Sunshine への問い合わせは、設定したアドレス(または自分の LAN / Tailscale アドレス)への平文の HTTP。意図したもの(認証も秘密も送らない)。
- 外部への通信は上の Sunshine だけ。ネットワークから受け付けるものはない(待ち受けなし)。
