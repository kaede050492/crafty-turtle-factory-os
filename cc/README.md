# Crafty Turtle Factory OS

添付の `factory_auto_v2.lua` を基礎に、Recipe API・JEI・専用Recipe Modへ依存せず、実機のCrafty Turtleへ置いたレシピをテストして登録する方式へ改修した `factory.lua` です。材料供給は上側Barrel固定ではなく、CC:T Wired Modemネットワーク上の複数inventoryを統合して扱います。

使用対象は次の構成です。

```text
       Wired Modem Network
       ┌────────┬────────┐
       │Storage │Storage │  role=STORAGE
       └────────┴────────┘
             │ pushItems() to STAGING
             ▼
       ┌──────────────────┐
       │ STAGING Chest    │  role=STAGING, turtle top
       └──────────────────┘
             │ turtle.suckUp()
             ┌──────────────────┐
             │  Crafty Turtle   │  left: workbench/craft
             │  crafting table  │
             │  upgrade         │
             └──────────────────┘
             │ pushItems() when direct turtle inventory exists
             ▼
       Wired OUTPUT inventory

       Direct turtle transferが使えない場合:
             turtle.dropDown()
                       ▼
                 下側 output chest

CC:T Monitor ─ Wired Modem/Cable ─ Turtle
Storage / OUTPUT inventory ─ Wired Modem/Cable ─┘
Inventory Manager ─ Wired Modem/Cable ─（任意）
```

## 重要な実機スロット

Crafty Turtleの3×3 crafting gridは、物理スロットを次のように使います。

```text
1   2   3
5   6   7
9  10  11
```

論理スロット1～9を物理スロット1～9として扱っていません。プログラム内の共通マッピングは次のとおりです。

```text
logical 1 -> physical 1       logical 4 -> physical 5       logical 7 -> physical 9
logical 2 -> physical 2       logical 5 -> physical 6       logical 8 -> physical 10
logical 3 -> physical 3       logical 6 -> physical 7       logical 9 -> physical 11
```

## 配置

1. Storage用のChest、Barrel、Drawer等へWired Modemを接続し、同じCC:T Wired Networkへ参加させる。
2. 専用STAGING Chest/BarrelをCrafty Turtleの上(top)に置き、Wired Modemへ接続する。STAGINGは材料を一種類ずつ短時間だけ保持します。
3. `factory storage list` またはMonitorのSETTINGSで、材料倉庫を `STORAGE`、Turtleの`top`を`STAGING`、さらに同じ容器のWired Network名（例 `minecraft:barrel_13`）も`STAGING`に設定します。Factoryは`top`を吸引専用のlocal side、ネットワーク名を`pushItems()`専用のdestinationとして分離します。完成品倉庫は`OUTPUT`、対象外は`IGNORE`に設定します。
4. `factory scan`で、次のように2つの名前が表示されることを確認します。

   ```text
   staging local: top
   staging network: minecraft:barrel_13
   ```

   `cfg.staging_inventory`をネットワーク名へ固定することもできますが、通常は`AUTO`のまま、STAGING roleから自動解決してください。

   CLIでは次のようにlocal側とnetwork側の両方へ設定します。

   ```text
   factory storage set top STAGING
   factory storage set minecraft:barrel_13 STAGING
   ```
5. Crafty Turtle自身が汎用inventory Peripheralとして検出できる場合は、従来どおり`pushItems()`で正しいcraft slotへ直接転送します。検出できない場合はSTAGINGへ自動fallbackし、`STORAGE → minecraft:barrel_13 → turtle.suckUp() (top) → craft slot` の順で材料を検証します。`top`を`pushItems()`の宛先には使用しません。
6. 下に完成品用Barrelを置く。Wired OUTPUTへ直接返却できない場合は `turtle.dropDown()` へfallbackします。下BarrelがPeripheralとして認識されない場合も排出できますが、満杯の事前容量検査はできないため、排出失敗時に安全停止します。
7. MonitorとTurtleをWired Modem/Cableで同じネットワークへ接続する。
8. Advanced PeripheralsのInventory Managerを使う場合は、Memory Cardへプレイヤーを登録して接続する。無くても登録・クラフト・在庫表示は使えます。

## インストール

GitHubの公開Rawから直接取得できます。Crafty Turtleで次を実行してください。

```text
wget https://raw.githubusercontent.com/kaede050492/crafty-turtle-factory-os/main/cc/factory.lua /factory
wget https://raw.githubusercontent.com/kaede050492/crafty-turtle-factory-os/main/cc/scan.lua /scan
factory scan
factory version
factory dashboard
```

`wget`はCC:Tweakedの標準シェルコマンドです。`factory version`またはHOMEの`BUILD`行で、GitHub `main`のcommit SHAとcommit時刻を確認できます。HTTP APIが使えない場合もFactory自体は起動し、commit表示だけが`unavailable`になります。引数なしで `factory` を起動する場合は、startup.luaから `shell.run("factory")` としてください。更新時は同じ2つの`wget`を再実行します。

`factory scan` では、少なくとも次の検出結果を確認します。

```text
top   type: minecraft:barrel, inventory   methods: ... list ...
left  type: workbench                     methods: ... craft ...
<monitor> type: monitor
staging local: top
staging network: minecraft:barrel_13
```

## Computer #2: Wired Storage Export Controller

`cc/storage.lua` はMonitorやTurtleを使わず、Computer #2のターミナルだけで搬出用Chestを統合倉庫へ収納する専用プログラムです。CC:Tweaked 1.120.0のgeneric inventory APIだけを使用し、`list()`でSOURCEと各STORAGEを読み、SOURCE側の`pushItems()`で同じWired Network上の倉庫へ転送します。

構成は次のとおりです。

```text
[搬出用 Chest + Wired Modem]
            │
       Wired Network
            │
       [Computer #2]
            │
       Wired Network
            │
[Create Item Vault / Chest / Barrel ...]
```

Create Item Vaultを含め、`list()`と`size()`を持つinventoryをSTORAGEに登録できます。SOURCEには`pushItems()`も必要です。Wired Modem経由で表示されたPeripheral名をそのまま使用してください。

インストール:

```text
wget https://raw.githubusercontent.com/kaede050492/crafty-turtle-factory-os/main/cc/storage.lua /storage
storage list
```

設定は追加した順番がSTORAGE #1、#2…の優先順位になります。各倉庫で同じItem ID/NBTのstackを先に探し、その後に空きslotを使います。#1が満杯または部分転送になった場合は残量を#2以降へ送ります。

```text
storage list
storage set-source <搬出用ChestのPeripheral名>
storage add <倉庫1のPeripheral名>
storage add <倉庫2のPeripheral名>
storage add <倉庫3のPeripheral名>
storage status
storage run
```

`storage set-source`を実行したPeripheralは自動的にSTORAGE一覧から除外されます。SOURCE自身を`storage add`することもできません。設定はComputer #2の`storage_controller.db`へ保存され、再起動後も残ります。DB更新は一時ファイルから入れ替えるため、書き込み途中の中断で元DBを壊しにくくしています。

`storage run`は約0.2秒間隔でSOURCEの`list()`だけを監視します。転送が必要になったときだけSTORAGEの`list()`を読み、`pushItems()`の戻り値だけに依存せず、転送前後のSOURCEスロットと転送先スロットを検証します。部分転送、倉庫満杯、Peripheral切断、異物化、数量不一致が起きた場合はそのサイクルを安全停止し、SOURCEに残ったアイテムを次周期へ残します。`peripheral` / `peripheral_detach`イベントを受けると接続先を再検出します。

起動中の画面には、SOURCE名、接続中/登録済みSTORAGE数、SOURCEの残量、累計転送数、直近のエラーを表示します。終了は`Ctrl+T`です。

`startup.lua`から自動起動する場合は、Computer #2の`startup.lua`へ次を追加します。

```lua
shell.run("storage", "run")
```

`pushItems()`は、SOURCEとSTORAGEの両方が同じWired Network上に接続されている場合に使用できます。CC:Tのinventory API仕様は[generic inventory](https://tweaked.cc/generic_peripheral/inventory.html)と[peripheral](https://tweaked.cc/module/peripheral.html)を参照してください。

## 3x3 Advanced Monitor

`factory dashboard` 起動時にMonitorの`getSize()`を読み取り、1.0 / 0.75 / 0.5の順で画面に収まる文字スケールを自動選択します。3x3 Monitorでは小さいレイアウトへ切り替わり、HOMEのAUTO、CRAFT、RECIPES、REGISTER、STOCK、QUEUE、SETTINGSを2列（さらに狭い場合は1列）で表示します。

タッチ判定は描画したボタンの実際のx/y座標から生成するため、文字スケールやMonitorサイズが変わっても`monitor_touch`の位置がずれません。画面が極端に小さい場合は、0.5スケールと1列レイアウトで操作ボタンを優先して表示します。

通常の表示先はCC:TweakedのAdvanced Monitorです。各行はCC:Tの`blit()`でまとめて送信するため、毎回の色変更と文字書き込みを減らしています。タッチイベントを受け取ったフレーム内で操作を処理して即時再描画し、AUTO監視やQueueの無関係なタイマーでは画面を再描画しません。日本語などのUTF-8文字列は安全のため通常の`write()`経路へ戻ります。

## Tom's Peripherals GPU / Keyboard

Tom's PeripheralsのGPUは互換表示用のオプションです。既定では無効で、CC:TのAdvanced Monitorを使用します。GPUを使う場合だけ、`factory.lua`冒頭の`cfg.gpu = ""`を`cfg.gpu = "AUTO"`または実際のPeripheral名へ変更してください。GPU経路は`refreshSize()`後に`setSize(64)`と`createWindow()`を使って描画コンテキストを作り、`getSize()`のピクセルサイズから文字セルを計算してVRAMへ1フレーム分だけ描画します。各行をMonitorへ個別送信せず、`window.sync()`→GPUの`sync()`を最後に行います。

Tom's Keyboardが検出されると`setFireNativeEvents(true)`を設定し、通常のCC:T `key` / `char`イベントとして扱います。複数接続などで自動検出できない場合は、冒頭の`cfg.gpu` / `cfg.keyboard`をPeripheral名に変更してください。

キーボードショートカット:

```text
H / Home    HOMEへ戻る
R           RECIPES
I           REGISTER
S           STOCK
Q           QUEUE
A           HOMEで全体AUTO、詳細でレシピAUTOを切替
1 / 2 / 3   詳細画面でCRAFT 1 / 16 / 64
T           詳細画面のTarget設定
+ / -       Targetを1ずつ増減
Enter       Targetを保存
Esc         前の画面へ戻る
← / →      レシピ・在庫ページ切替、Targetを1ずつ調整
Delete      詳細画面のレシピ削除
```

キーボード未接続でも、従来どおりCC:T Monitorのタッチ操作を利用できます。GPUを有効にした場合はTom's Bitmap Monitorの`tm_monitor_touch` / `tm_monitor_mouse_click`を文字セル座標へ変換して同じボタン判定を行います。GPUが一時切断・同期失敗した場合はそのフレームを停止し、接続されている通常Monitorへフォールバックします。

参照: [Tom's Peripherals](https://modrinth.com/mod/toms-peripherals)、[GPU API](https://github.com/tom5454/Toms-Peripherals/wiki/GPUImpl)、[Keyboard API](https://github.com/tom5454/Toms-Peripherals/wiki/Keyboard)

GPU単体の描画確認は`cfg.gpu`を有効にした場合だけ次で行えます。画面に`GPU TEST`が出れば、Monitor接続とGPU描画は成功しています。通常のCC:T Monitorだけを使う場合は`factory scan`と`factory dashboard`を実行してください。

```text
factory scan
factory gpu
factory dashboard
```

## レシピ登録

最終操作は次の4段階です。

1. Crafty Turtleの物理スロット `1,2,3,5,6,7,9,10,11` に、レシピ1回分の材料を実際に置く。
2. Monitorの `REGISTER` → `CAPTURE` で現在の3×3配置を確認する。
3. `TEST & REGISTER` を押す。
4. `craft(1)` を実行し、出力アイテムID・表示名・数量を検出できた場合だけDBへ保存する。

テスト前に物理スロット4,8,12,13,14,15,16は空にしてください。出力はslot 16を優先して検出します。テスト失敗時は材料を完成品Barrelへ落とさず、可能な限りWired STORAGEへ戻します。

`CAPTURE` はプレビュー更新だけでDBへ保存しません。DBへ入るのはテストクラフトと出力検出が成功した場合だけです。

CLIでも実行できます。

```text
factory recipe capture
factory recipe list
factory recipe show minecraft:piston
factory recipe remove minecraft:piston
```

`factory recipe capture` は現在の3×3を1回クラフトして登録します。レシピ名は出力IDのnamespaceを除いた名前になり、同名出力の別パターンは `_2`, `_3` のように保存します。

DBは `factory_recipes.db`、キューは `factory_queue.db`、AUTO状態は `factory_auto.db`、inventory役割は `factory_storage.db` に保存され、再起動後も残ります。保存は一時ファイルとバックアップを使ってから置換します。材料の詳細情報は可能な範囲でそのまま保存し、空スロットも記録します。

## Monitor GUI

- `HOME`: CRAFT / RECIPES / REGISTER / STOCK / QUEUE / SETTINGS
- `REGISTER`: 現在の3×3配置を定期更新表示。CAPTURE / TEST & REGISTER / CANCEL
- `RECIPES`: 登録済みレシピをページング表示
- レシピ詳細: 3×3配置、Item ID、表示名、1craftあたりの出力数、完成品在庫（STORAGE+OUTPUT）、Target、CRAFT 1 / 16 / 64、レシピごとのAUTO ON/OFF / TARGET / DELETE
- `STOCK`: 数量ページング、名前/数量ソート、検索、表示名/Item ID切替、REFRESH
- `QUEUE`: 実行中ジョブ表示とキュー消去
- `SETTINGS`: 自動検出したinventory一覧、STORAGE/STAGING/CRAFTER/OUTPUT/IGNORE役割、Turtle転送先、DB設定を表示。inventory名の役割ボタンをタッチすると順番に切り替わります。

Monitorの `monitor_touch` とタイマーで再描画します。Peripheralのattach/detachを受けると再検出します。Monitorが切れた場合は、キューを破棄せずエラー表示して再接続を待ちます。

## 自動クラフト

HOMEまたはSETTINGSの `AUTO ON/OFF` で全体の自動クラフトを切り替えます。全体をONにしても、登録直後のレシピは安全のため個別AUTOがOFFです。RECIPESから対象レシピを開き、詳細画面の `AUTO ON/OFF` を押して、そのレシピだけを自動対象にしてください。

AUTOがONでキューが空になると、約0.2秒（数tick）ごとにWired Network上の全 `STORAGE` inventoryの `list()` を読みます。各inventoryのslotをItem ID/countでインデックス化し、同じItem IDが複数倉庫・複数slotに分散していても合計在庫として扱います。登録済みで個別AUTOがONのレシピをラウンドロビン順に比較し、材料が揃ったレシピを1つ選び、材料から計算した最大batch（最大64）だけをキューへ入れます。

材料不足なら何もせず待機します。Turtle自身がgeneric inventoryとして検出できる場合は、各STORAGE inventoryから`pushItems()`で物理slotへ直接転送します。検出できない場合は、各STORAGEから専用STAGINGへ必要な材料だけを`pushItems()`し、STAGINGが一種類の正しいItem ID/countだけであることを確認してから `turtle.suckUp()` で物理slotへ吸引します。転送前後にItem ID/countを再確認し、部分転送・異物・Peripheral切断を検出したらクラフトせず、可能な範囲でSTORAGEへ返却します。完成品は可能ならOUTPUT inventoryへ `pushItems()` で返し、使えない場合はPeripheral未認識の下側Barrel/Chestにも `turtle.dropDown()` でfallbackします。下側容器が満杯の場合は完成品をslot16に残したまま安全停止します。

AUTOは各レシピについて、STORAGEとOUTPUTの完成品在庫を合算し、`missing = Target - current`を計算します。`missing <= 0`ならクラフトせず、必要craft数は`ceil(missing / output.count)`で求めます。レシピ詳細の`TARGET`をタッチするとMonitor上のTarget設定画面になり、`-1/+1`、`-16/+16`、`-64/+64`、`0`、`SAVE`で0以上のTargetを変更できます。0はそのレシピの自動生産を停止する設定です。1craftで複数個出力するレシピは、Targetを満たす最小craft数のため最終在庫がTargetを出力数未満だけ上回る場合があります。

出力排出、残り物返却、クラフト、peripheral接続のいずれかで安全に処理できない場合はAUTOを停止し、材料を別の完成品倉庫へ誤排出しません。停止後は原因を確認してAUTOをOFF→ONにすると再開します。AUTOジョブは手動Queueより優先されず、手動Queueが残っている間は新しいAUTOジョブを追加しません。

AUTOの全体状態・レシピごとの状態・停止状態は `factory_auto.db` に保存され、再起動後も保持されます。AUTO監視周期はプログラム冒頭の `cfg.auto_poll_seconds`（初期値0.2秒）で変更できます。監視周期では重い `getItemDetail()` を全スロットへ実行せず、表示名が必要なSTOCK画面の更新時だけ詳細を補います。

手動の `CRAFT 1`, `CRAFT 16`, `CRAFT 64` と既存のQueueはそのまま使用できます。詳細画面のGUI `AUTO ON/OFF` は、target在庫を埋めるCLI用予約とは別の常時監視設定です。

CLI:

```text
factory craft minecraft:piston 1
factory craft minecraft:piston 16
factory craft minecraft:piston 64
factory craft minecraft:piston auto
factory queue list
factory queue clear
```

1回のbatchは最大64 craftですが、常に64を指定するわけではありません。次を計算して小さい値を使います。

- 全STORAGE inventoryにある材料数
- レシピ1回あたりの各材料数
- Turtleの1スロットに入る安全な数
- 出力数と非グリッドslotの空き容量
- 最大batch設定64

材料探索に `turtle.suckUp()` は使用しません。直接転送が使えない場合だけ、Wired Network上の各inventoryからSTAGINGへ必要なslotを `pushItems()` し、STAGINGの内容を検証してから `turtle.suckUp()` でcraft slotへ移します。転送前に在庫を再確認し、別Item IDがSTAGINGまたはcraft slotへ入った場合はクラフトしません。クラフト失敗時はSTAGING経由でSTORAGEへ可能な限り返却します。

クラフト後は、既知の完成品だけをOUTPUT inventoryへ返し、Wired転送できない場合だけ `turtle.dropDown()` で下へ出します。レシピ残り物や未知のアイテムはSTORAGEへ返し、下側output chestへ落としません。下側output chestが満杯または排出先切断ならその場で停止し、同じジョブを無条件に再実行しません。

## Wired Storageの役割設定

検出されたgeneric inventoryは、初回は原則 `STORAGE` になります。Crafty Turtle、Monitor、Modem等はinventoryとして誤認しないよう除外します。役割は次の5種類です。

- `STORAGE`: 材料在庫の集計・材料取得・残り物返却に使用
- `STAGING`: Turtleの`top`に置く専用中継inventory。local側とWired Network側の両方へ同じroleを設定する。`top`は`turtle.suckUp()`と内容検証にだけ使い、`pushItems()`の宛先はネットワーク名を使う
- `CRAFTER`: 材料倉庫から除外する予備・加工機用inventory
- `OUTPUT`: 完成品の返却先。STOCK集計から除外
- `IGNORE`: Factory OSから完全に除外

CLI:

```text
factory storage list
factory storage set <peripheral> STORAGE
factory storage set <peripheral> STAGING
factory storage set <peripheral> OUTPUT
factory storage set <peripheral> CRAFTER
factory storage set <peripheral> IGNORE
factory storage reset <peripheral>
```

設定は `factory_storage.db` に保存されます。Peripheral attach/detach後はinventory一覧を再検出します。

## CLI一覧

```text
factory scan
factory dashboard
factory gpu
factory recipe list
factory recipe capture
factory recipe show <name>
factory recipe remove <name>
factory stock
factory stock search <text>
factory craft <name> [count|auto]
factory queue list
factory queue clear
```

## 上限

- 1回の安全なbatch上限: 64 craft
- レシピの3×3材料枠: 最大9物理スロット
- 登録レシピ数: プログラム上の固定上限なし。Turtleの保存領域とDB容量に依存
- 1レシピの同一材料: 実際の3×3配置にある物理スロット数だけ記録
- AUTO対象レシピ数: 固定上限なし。AUTO ONのレシピを登録順で比較

Recipe APIから任意Modのレシピを自動取得する機能は意図的に実装していません。未知のレシピは、Turtleへ実際に置いて `TEST & REGISTER` してください。

## 関連API

- [CC:T turtle API / craft](https://tweaked.cc/module/turtle.html)
- [CC:T generic inventory API / list, pushItems, pullItems](https://tweaked.cc/generic_peripheral/inventory.html)
- [CC:T monitor / monitor_touch](https://tweaked.cc/peripheral/monitor.html)
- [CC:T peripheral API](https://tweaked.cc/module/peripheral.html)
- [Advanced Peripherals Inventory Manager](https://docs.advanced-peripherals.de/0.7/peripherals/inventory_manager/)
