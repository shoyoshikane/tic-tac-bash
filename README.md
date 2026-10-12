# ハイテンション三目並べ

ドラッグでコマを弾く三目並べ。FlutterでWeb・iOS・AndroidのUIとゲーム処理を共通化し、Web版はGitHub Pagesで公開します。

公開URL: https://shoyoshikane.github.io/tic-tac-bash/

## 友達とオンライン対戦

1. 「オンライン対戦」を選び、部屋を作ります。6桁の英数字の部屋コードを表示します。
2. 「招待リンクを共有」でスマホの共有メニューを開き、LINEなどで友達にリンクを送ります。共有メニューが使えない場合はリンクをコピーします。
3. 友達がリンクを開くか、「オンライン対戦」の入力欄に部屋コードを入力すると接続します。コードは小文字でも入力できます。先攻・後攻は作成者が選び、友達は反対の手番になります。
4. 「もう一局」はふたりが選ぶと始まります。手番は対局前または終了後に作成者が変更できます。

対戦枠が埋まっている招待リンクを開くと、自動で観戦モードになります。切断中の対戦者の枠も保持され、元の対戦者が再接続すると対局に復帰できます。

ふたりとも対局中は画面を開いたままにしてください。オンラインでは手戻しと対局保存はありません。画面を再読み込みした場合は新しい部屋を作って招待し直してください。一時的な通信切断では「再接続」を使えます。

観戦する友達にも同じ招待リンクを送れます。盤面の上の「観戦モード」表示で、観戦中であることを確認できます。複数人が同時に観戦でき、途中参加でも現在の盤面から表示します。駒の配置・連鎖・勝敗・再戦を同期し、観戦者は駒を操作したり再戦を提案したりできません。対戦相手が切断したら接続待ちを表示します。観戦者の再読み込みや「再接続」では、同じ部屋の現在の盤面を取得できます。作成者が部屋を閉じた場合は観戦も終了します。

通信にはPeerJS互換の接続処理と無料のPeerJS Cloud接続仲介サービスを使用し、盤面はWebRTCデータチャネルで共有します。FlutterのWeb版・ネイティブ版と旧Web版で同じ対戦プロトコルを使用します。サードパーティの仲介サービスとSTUNサーバーへの接続が発生します。サービス障害や一部の企業ネットワーク・NAT環境では接続できないことがあります。この版では専用TURNサーバーを用意していないため、接続できないときはモバイル回線など別の回線をお試しください。

PeerJS: https://peerjs.com/client/faq （MITライセンス。`dist/vendor/peerjs-LICENSE`参照）

## 開発環境と起動

Flutter 3.47.7（Dart同梱）を使用します。macOSでは `brew install --cask flutter` でインストールできます。

```sh
cd native
bash tool/bootstrap.sh
flutter run -d chrome
```

初回のbootstrapでAndroid・iOS・Webの雛形を生成し、表示名、権限、招待リンクの設定を適用して依存パッケージを取得します。雛形は生成物として扱い、ゲームのソースは `native/lib/` に置きます。WebのHTMLは `native/tool/web/index.html` で管理します。

UIにはNoto Sans JP（SIL Open Font License）を同梱します。bootstrapは固定したGoogle Fontsの原本を検証し、FontTools 4.60.1で通常・見出し用のフォントを生成します。ゲーム中の文字とかな・英数字を含め、初回の転送量を抑えます。Python 3と初回ダウンロード用のネットワーク接続が必要です。文字を追加したときはbootstrapを再実行してください。

ネイティブ版はAndroid SDKまたはXcode、iOSの依存関係用にCocoaPodsを用意し、`flutter doctor -v` で確認してください。接続した端末・シミュレーターを `flutter devices` で確認し、`flutter run -d <端末ID>` で起動できます。

共有する招待URLはWeb版を開きます。アプリでは「オンライン対戦」の招待リンク欄へ貼り付けて参加できます。`hightension://join?room=部屋ID` のカスタムURLにも対応します。HTTPSの招待リンクでインストール済みアプリを自動的に開くUniversal Links／Android App Linksは未設定です。

## 遊び方

- モードは「CPU対戦」「オンライン対戦」の2つ。CPU対戦ではあなたの先攻（黒）・後攻（白）を選べます。
- 印のついた空きマスをタップしてコマを置きます。各自5個まで。自分のコマの周囲8マスには置けません。
- 自分のコマをドラッグし、8方向に弾きます。移動後の配置をプレビューし、盤の上で離すと確定します。
- 盤の外で離す、元の位置に戻す、Escを押すとキャンセルします。小さい動きや不可能な方向では手を消費しません。
- 端または他のコマまで滑り、衝突したコマに移動が連鎖します。
- 自分の番に「置く」か「弾く」のどちらかを1回行います。ぶつかった黒・白のコマは同じ方向に動き、自分のコマが動かず隣のコマを押すだけでも打てます。
- 盤面が何も変わらない手と、相手が動かす前の盤面に戻す手は打てません。
- 自分・相手・CPUの弾きは、連鎖も順番にアニメーションで表示します。盤面下の履歴ボタンで、各手の盤面をサムネイルから選んだり前後に切り替えたりできます。表示した手の配置・連鎖は自動で再生します。
- 自分のコマを縦・横・斜めに3つ連続で揃えると勝ちです。
- 打てる手の中に次の一手で勝てる手があると、盤面の近くに「先攻／後攻 リーチ」を表示します。弾いたあとの連鎖まで判定し、同時成立による引き分けはリーチに含めません。
- 黒と白が同時に3つ揃ったとき、または次の番の人に打てる手がなくなったときは引き分けです。
- キーボードではTabとEnterでコマを選択、矢印キーで方向、Enterで確定。斜めはQ/E/Z/C。Escでキャンセルできます。
- CPU対戦はブラウザに自動保存され、手戻しも可能です。再読み込みすると手戻し履歴はリセットされます。

## 検証

```sh
cd native
flutter analyze
flutter test
flutter build web --no-web-resources-cdn --base-href /tic-tac-bash/
```

旧JavaScript版の244局面とDart版の打てる手・盤面・勝敗を比較し、配置、連鎖、反転禁止、CPU、対戦同期、満員時の観戦、再戦、再接続、ドラッグUIを検証します。

実際のブラウザ・WebRTCを使うテスト:

```sh
# native/ でテスト用のFlutterエントリーポイントをビルド
flutter build web --no-web-resources-cdn --target test_browser/main.dart --output build/browser-test
cd ..
npm ci
npx playwright install chromium
npx playwright test --config native/test_browser/playwright.config.js
```

テスト用ビルドだけが状態確認用のブリッジとローカル接続サーバーを使います。公開用 `lib/main.dart` のビルドには含めません。旧版のソース `dist/` とそのテストは移行時のルール・通信互換性の確認用として残しています。

## ビルドと公開

`.github/workflows/pages.yml` は `main` へのpushでFlutter解析・テスト・Webビルド、旧版の検証、Flutterのブラウザテストを実行し、成功後に `native/build/web/` をGitHub Pagesへ公開します。CanvasKitは同じサイトから配信します。

公開用ビルドのパスと招待URLはGitHub Pagesの設定から取得するため、リポジトリ名や独自ドメインの変更にも追従します。手動ビルドでは `--dart-define WEB_GAME_URL=公開URL` で招待URLを指定できます。

`.github/workflows/native.yml` はGitHub Actionsから手動実行したときだけ、AndroidのデバッグAPKとiOSシミュレーター用アプリをビルドします。push時の自動ビルドは行いません。iOSシミュレーターのビルドには開発チームの署名は不要です。実機配布・ストア公開には別途署名と配布設定が必要です。Web公開にAndroid・iOSのビルド成功は必須ではありません。

```sh
cd native
flutter build apk --debug
flutter build ios --simulator
```

以前のSites登録情報はローカルの `.openai/` にありますが、GitHubには含めず、公開先として使用しません。
