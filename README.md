# ハイテンション三目並べ

タップで置く・ドラッグで弾く三目並べ。CPU対戦、オンライン対戦、観戦に対応しています。

[ブラウザで遊ぶ](https://shoyoshikane.github.io/tic-tac-bash/)

## 遊び方

- 黒が先攻、白が後攻。自分の番に「置く」か「弾く」を1回行います。
- マスをタップしてコマを置きます。持ちコマはそれぞれ5個で、自分のコマの周囲8マスには置けません。
- 自分のコマをドラッグして弾くと、ぶつかったコマも同じ方向に動きます。
- 盤面が変わらない手と、相手が動かす前の盤面に戻す手は打てません。
- 縦・横・斜めに自分のコマを3つ揃えると勝ち。黒と白が同時に揃うか、次の人に打てる手がなくなると引き分けです。

CPU対戦では先攻・後攻を選べます。「履歴」から各手の盤面と動きを見返せます。

## オンライン対戦

1. 部屋を作り、作成者が先攻・後攻を選びます。
2. 6文字の部屋コードか招待リンクを友達に共有します。
3. 友達がコードを入力するかリンクを開くと対戦できます。3人目以降は観戦になります。

「もう一局」はふたりが選ぶと始まります。対戦中は画面を開いたままにしてください。

## 開発

Flutter 3.47.7、Python 3、Node.js 22を使用します。

```sh
cd native
bash tool/bootstrap.sh
cd ..
npm start
```

[localhost:4281](http://localhost:4281/)で起動します。実行中のターミナルで `r` を押すとホットリロードできます。

ゲームのコードは `native/lib/`、WebのHTMLとアイコンは `native/tool/web/` にあります。`web/`・`android/`・`ios/` はbootstrapで生成します。

## テスト

```sh
cd native
flutter analyze
flutter test
flutter build web --no-web-resources-cdn --target test_browser/main.dart --output build/browser-test
cd ..
npm ci
npx playwright install chromium
npm run test:browser
```

ゲームのルールと画面操作に加え、実ブラウザで対戦・部屋コード・観戦・再戦・再接続を検証します。

## 公開

`main` にpushすると、GitHub Actionsで検証後にGitHub Pagesへ公開します。Android・iOSのビルドは `native.yml` の手動実行で行えます。
