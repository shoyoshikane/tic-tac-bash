import 'dart:async';
import 'dart:math' as math;

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:share_plus/share_plus.dart';

import 'controller.dart';
import 'game.dart';
import 'room.dart';
import 'transport.dart';

Future<void> main() => startGame();

Future<void> startGame({
  RoomPeer Function()? peerFactory,
  void Function(GameController)? onReady,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  final links = AppLinks(), game = GameController(peerFactory: peerFactory);
  await game.load();
  final initial = kIsWeb ? Uri.base : await links.getInitialLink();
  final invitation = initial == null
      ? null
      : parseInvitation(initial.toString());
  onReady?.call(game);
  runApp(GameApp(game: game, links: kIsWeb ? null : links));
  if (invitation != null) unawaited(game.startOnline(invitation: invitation));
}

class GameApp extends StatelessWidget {
  const GameApp({super.key, required this.game, this.links, this.initial});
  final GameController game;
  final AppLinks? links;
  final Uri? initial;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ハイテンション三目並べ',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff354e3d)),
      scaffoldBackgroundColor: const Color(0xffeff0ed),
    ),
    home: GameScreen(game: game, links: links, initial: initial),
  );
}

class GameScreen extends StatefulWidget {
  const GameScreen({super.key, required this.game, this.links, this.initial});
  final GameController game;
  final AppLinks? links;
  final Uri? initial;
  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  GameController get game => widget.game;
  StreamSubscription<Uri>? _links;

  void _showHistory() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => GameHistory(entries: game.moveHistory),
    );
  }

  @override
  void initState() {
    super.initState();
    _links = widget.links?.uriLinkStream.listen(_incoming);
    if (widget.initial != null)
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _incoming(widget.initial!),
      );
  }

  Future<void> _incoming(Uri uri) async {
    final invitation = parseInvitation(uri.toString());
    if (invitation == null || game.room?.target == invitation.target) return;
    if (await _confirmLeave()) await game.startOnline(invitation: invitation);
  }

  Future<bool> _confirmLeave() async {
    if (game.state.moves == 0 && !game.online) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('対局を終了しますか？'),
            content: const Text('いまの対局を終了して切り替えます。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('続ける'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('切り替える'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _online() async {
    if (game.online) return;
    final input = TextEditingController();
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          28,
          24,
          MediaQuery.viewInsetsOf(context).bottom + 28,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'オンライン対戦',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.pop(context, ''),
              child: const Text('部屋を作る'),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: input,
              decoration: InputDecoration(
                labelText: '部屋コード / 招待リンク',
                hintText: '6桁の英数字、または招待リンク',
                suffixIcon: IconButton(
                  tooltip: '貼り付け',
                  icon: const Icon(Icons.content_paste),
                  onPressed: () async {
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
                    input.text = data?.text ?? '';
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () {
                if (parseInvitation(input.text) == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('部屋コード・招待リンクを確認してください')),
                  );
                  return;
                }
                Navigator.pop(context, input.text);
              },
              child: const Text('参加する'),
            ),
          ],
        ),
      ),
    );
    input.dispose();
    if (result == null || !mounted) return;
    if (await _confirmLeave())
      await game.startOnline(
        invitation: result.isEmpty ? null : parseInvitation(result),
      );
  }

  Future<void> _chooseRole(int role) async {
    if (game.online) {
      game.room?.chooseRole(role);
    } else if (role != game.cpuRole && await _confirmLeave()) {
      await game.startCpu(role: role);
    }
  }

  Future<void> _showRolePicker() async {
    final selected = game.localRole;
    final role = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('手番を選択'),
        children: [
          for (final player in [1, 2])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, player),
              child: Row(
                children: [
                  Icon(selected == player ? Icons.check : null, size: 20),
                  const SizedBox(width: 12),
                  Text(player == 1 ? '先攻' : '後攻'),
                ],
              ),
            ),
        ],
      ),
    );
    if (role != null && mounted) await _chooseRole(role);
  }

  Future<void> _share(BuildContext context) async {
    final invite = game.room?.invite;
    if (invite == null || invite.isEmpty) return;
    final box = context.findRenderObject() as RenderBox?;
    try {
      await SharePlus.instance.share(
        ShareParams(
          uri: Uri.parse(invite),
          mailToFallbackEnabled: false,
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: invite));
      if (mounted)
        ScaffoldMessenger.of(
          this.context,
        ).showSnackBar(const SnackBar(content: Text('招待リンクをコピーしました')));
    }
  }

  void _rules() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('遊び方'),
      content: const SingleChildScrollView(
        child: Text(
          '・黒が先攻、白が後攻。自分の番に「置く」か「弾く」を1回行います。\n\n'
          '・マスをタップしてコマを置きます。持ちコマはそれぞれ5個で、自分のコマの周囲8マスには置けません。\n\n'
          '・自分のコマをドラッグして弾くと、ぶつかったコマも同じ方向に動きます。\n\n'
          '・盤面が変わらない手と、相手が動かす前の盤面に戻す手は打てません。\n\n'
          '・縦・横・斜めに自分のコマを3つ揃えると勝ち。黒と白が同時に揃うか、次の人に打てる手がなくなると引き分けです。',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('閉じる'),
        ),
      ],
    ),
  );
  @override
  void dispose() {
    unawaited(_links?.cancel() ?? Future.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: game,
    builder: (context, _) {
      final watching = game.spectator;
      const ink = Color(0xff262a29);
      return Scaffold(
        backgroundColor: const Color(0xffeff0ed),
        body: SafeArea(
          child: SingleChildScrollView(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(22, 16, 22, 28),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          ExcludeSemantics(
                            child: SizedBox(
                              width: 40,
                              height: 24,
                              child: Stack(
                                children: [
                                  for (var i = 0; i < 3; i++)
                                    Positioned(
                                      left: i * 14.0,
                                      top: i == 2 ? 4 : 10,
                                      child: _miniStone(i == 2 ? 2 : 1, 11),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'ハイテンション三目並べ',
                              style: TextStyle(
                                color: ink,
                                fontWeight: FontWeight.w600,
                                fontSize: 15,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '遊び方',
                            onPressed: _rules,
                            icon: Icon(Icons.help_outline, color: ink),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          border: Border.all(color: ink.withValues(alpha: .15)),
                          borderRadius: BorderRadius.circular(30),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: _mode(
                                'CPU対戦',
                                !game.online,
                                ink,
                                () async {
                                  if (!game.online) return;
                                  if (await _confirmLeave())
                                    await game.startCpu();
                                },
                              ),
                            ),
                            Expanded(
                              child: _mode(
                                'オンライン対戦',
                                game.online,
                                ink,
                                _online,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 26),
                      if (!game.online || game.room?.host == true) ...[
                        OutlinedButton.icon(
                          key: const Key('role-selector'),
                          icon: const Icon(Icons.expand_more, size: 18),
                          label: Text(
                            '${game.online && game.state.result != null ? '次の手番' : '手番'}：${game.localRole == 2 ? '後攻' : '先攻'}',
                          ),
                          onPressed:
                              !game.online || game.room?.canChooseRole == true
                              ? _showRolePicker
                              : null,
                        ),
                        const SizedBox(height: 20),
                      ],
                      if (watching)
                        Container(
                          key: const Key('spectator-badge'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 10,
                          ),
                          margin: const EdgeInsets.only(bottom: 22),
                          decoration: BoxDecoration(
                            color: const Color(0xffd6e0d7),
                            borderRadius: BorderRadius.circular(28),
                            border: Border.all(color: const Color(0xffa5ada4)),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.visibility_outlined,
                                color: Color(0xff262a29),
                                size: 18,
                              ),
                              SizedBox(width: 8),
                              Text(
                                '観戦モード',
                                style: TextStyle(
                                  color: Color(0xff262a29),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (game.online &&
                          (game.room?.ready != true ||
                              game.room!.invite.isNotEmpty ||
                              game.room!.localVote ||
                              game.room!.remoteVote)) ...[
                        if (game.room?.roomCode.isNotEmpty == true)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Text('部屋コード '),
                              Semantics(
                                label: game.room!.roomCode,
                                excludeSemantics: true,
                                child: SelectableText(
                                  game.room!.roomCode,
                                  key: const Key('room-code'),
                                  style: TextStyle(
                                    color: ink,
                                    fontSize: 20,
                                    letterSpacing: 3,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: '部屋コードをコピー',
                                icon: Icon(Icons.copy, size: 18, color: ink),
                                onPressed: () async {
                                  await Clipboard.setData(
                                    ClipboardData(text: game.room!.roomCode),
                                  );
                                  if (context.mounted)
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('部屋コードをコピーしました'),
                                      ),
                                    );
                                },
                              ),
                            ],
                          ),
                        if (game.roomStatus.isNotEmpty &&
                            (game.room?.ready != true ||
                                game.room!.localVote ||
                                game.room!.remoteVote))
                          Text(
                            game.roomStatus,
                            style: TextStyle(color: ink, fontSize: 11),
                            textAlign: TextAlign.center,
                          ),
                        Wrap(
                          alignment: WrapAlignment.center,
                          children: [
                            if (game.room?.invite.isNotEmpty == true)
                              Builder(
                                builder: (context) => TextButton(
                                  onPressed: () => _share(context),
                                  child: Text(
                                    '招待リンクを共有 ↗',
                                    style: TextStyle(color: ink),
                                  ),
                                ),
                              ),
                            if (game.room?.ready != true)
                              TextButton(
                                onPressed: game.retry,
                                child: Text(
                                  '再接続',
                                  style: TextStyle(color: ink),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),
                      ],
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [_player(1, ink), _player(2, ink)],
                      ),
                      const SizedBox(height: 18),
                      if (game.reachPlayers.isNotEmpty) ...[
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          alignment: WrapAlignment.center,
                          children: game.reachPlayers.map(_reach).toList(),
                        ),
                        const SizedBox(height: 14),
                      ],
                      Stack(
                        key: const Key('game-board-stack'),
                        alignment: Alignment.center,
                        children: [
                          GameBoard(key: const Key('game-board'), game: game),
                          if (game.state.result != null && !game.presenting)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: Center(
                                  child: TweenAnimationBuilder<double>(
                                    key: ValueKey(game.state.result),
                                    tween: Tween(begin: 0, end: 1),
                                    duration: const Duration(milliseconds: 200),
                                    builder: (context, opacity, child) =>
                                        Opacity(opacity: opacity, child: child),
                                    child: Container(
                                      key: const Key('result-overlay'),
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 20,
                                      ),
                                      color: ink.withValues(alpha: .85),
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          if (watching &&
                                              game.state.result != 0) ...[
                                            _miniStone(game.state.result!, 24),
                                            const SizedBox(width: 16),
                                          ],
                                          Text(
                                            game.state.result == 0
                                                ? 'DRAW'
                                                : watching ||
                                                      game.state.result ==
                                                          game.localRole
                                                ? 'WIN'
                                                : 'LOSE',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 44,
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: 6,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      if (game.state.result == null && !game.presenting)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _miniStone(game.state.turn, 8),
                            const SizedBox(width: 8),
                            Text(
                              game.turnLabel,
                              key: const Key('turn-label'),
                              style: TextStyle(
                                color: ink,
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      if (game.state.result == null &&
                          game.hint.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          game.hint,
                          style: TextStyle(
                            color: ink.withValues(alpha: .7),
                            fontSize: 11,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: '履歴',
                            onPressed: _showHistory,
                            icon: const Icon(Icons.history),
                          ),
                          if (!game.online)
                            IconButton(
                              tooltip: '一手戻す',
                              onPressed: game.canUndo ? game.undo : null,
                              icon: const Icon(Icons.undo),
                            ),
                          if (!watching)
                            TextButton(
                              onPressed:
                                  game.online &&
                                      (game.room?.ready != true ||
                                          game.room!.localVote)
                                  ? null
                                  : () async {
                                      if (game.online) {
                                        game.rematch();
                                        return;
                                      }
                                      if (await _confirmLeave())
                                        await game.startCpu();
                                    },
                              child: Text(game.online ? 'もう一局' : '新しい対局'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
  Widget _reach(int player) {
    final label = '${player == 1 ? '先攻' : '後攻'} リーチ';
    return Semantics(
      liveRegion: true,
      excludeSemantics: true,
      label: '$label。次の一手で勝てる手があります。',
      child: Container(
        key: Key('reach-$player'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xffffe6a7),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xffd1a04e)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _miniStone(player, 9),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: const Color(0xff775116),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mode(String title, bool active, Color ink, VoidCallback action) =>
      TextButton(
        style: TextButton.styleFrom(
          foregroundColor: active ? Colors.white : ink,
          backgroundColor: active ? ink : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        ),
        onPressed: action,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            title,
            maxLines: 1,
            softWrap: false,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      );
  Widget _player(int p, Color ink) {
    final count = game.state.board.where((v) => v == p).length;
    final tag = game.online
        ? game.spectator
              ? ''
              : game.room?.role == p
              ? 'あなた'
              : '相手'
        : p == game.cpuRole
        ? 'あなた'
        : 'CPU';
    return Opacity(
      opacity: game.state.turn == p && game.state.result == null ? 1 : .55,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            p == 1 ? '先攻' : '後攻',
            style: TextStyle(color: ink, fontSize: 11),
          ),
          const SizedBox(width: 7),
          Text(
            tag,
            style: TextStyle(color: ink.withValues(alpha: .65), fontSize: 9),
          ),
          const SizedBox(width: 12),
          ...List.generate(
            5,
            (i) => Padding(
              padding: const EdgeInsets.only(left: 4),
              child: _miniStone(i < 5 - count ? p : 0, 7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniStone(int p, double size) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: p == 0
          ? Colors.transparent
          : p == 1
          ? const Color(0xff171717)
          : Colors.white,
      border: Border.all(
        color: p == 1 ? const Color(0xff171717) : const Color(0xffa5ada4),
      ),
    ),
  );
}

class GameHistory extends StatefulWidget {
  const GameHistory({super.key, required this.entries});
  final List<TurnPresentation> entries;

  @override
  State<GameHistory> createState() => _GameHistoryState();
}

class _GameHistoryState extends State<GameHistory> {
  final _replay = GameController(readOnly: true);
  late int _index;
  final _timeline = ScrollController();

  GameState _position(int index) =>
      index == 0 ? GameState() : widget.entries[index - 1].after;

  @override
  void initState() {
    super.initState();
    _index = widget.entries.length;
    _replay.state = _position(_index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _index > 0) _select(_index);
    });
  }

  @override
  void dispose() {
    _replay.dispose();
    _timeline.dispose();
    super.dispose();
  }

  void _select(int index) {
    final turn = index == 0 ? null : widget.entries[index - 1];
    setState(() => _index = index);
    _replay.state = _position(index);
    _replay.lastTurn = turn != null
        ? TurnPresentation(turn.before, turn.after, turn.move, turn.steps)
        : null;
    _replay.presenting = turn != null;
    _replay.changed();
    if (_timeline.hasClients) {
      final offset =
          ((index - 1) * 76.0 - _timeline.position.viewportDimension / 2 + 38)
              .clamp(0.0, _timeline.position.maxScrollExtent);
      _timeline.animateTo(
        offset,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      key: const Key('visual-history'),
      height: MediaQuery.sizeOf(context).height * .85,
      child: Column(
        children: [
          const Text(
            '履歴',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            '$_index / ${widget.entries.length} 手',
            key: const Key('history-position'),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: GameBoard(
                    key: const Key('history-board'),
                    game: _replay,
                  ),
                ),
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: '最初へ',
                onPressed: _index > 1 ? () => _select(1) : null,
                icon: const Icon(Icons.first_page),
              ),
              IconButton(
                tooltip: '前の手',
                onPressed: _index > 1 ? () => _select(_index - 1) : null,
                icon: const Icon(Icons.chevron_left),
              ),
              IconButton(
                tooltip: '次の手',
                onPressed: _index < widget.entries.length
                    ? () => _select(_index + 1)
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
              IconButton(
                tooltip: '最新へ',
                onPressed: _index < widget.entries.length
                    ? () => _select(widget.entries.length)
                    : null,
                icon: const Icon(Icons.last_page),
              ),
            ],
          ),
          SizedBox(
            height: 90,
            child: ListView.builder(
              controller: _timeline,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: widget.entries.length,
              itemBuilder: (context, item) {
                final index = item + 1;
                return Semantics(
                  selected: index == _index,
                  child: TextButton(
                    key: Key('history-step-$index'),
                    onPressed: () => _select(index),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.all(6),
                      backgroundColor: index == _index
                          ? const Color(0xffd6e0d7)
                          : null,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: SizedBox(
                      width: 64,
                      child: Column(
                        children: [
                          Expanded(
                            child: _HistoryThumbnail(
                              board: _position(index).board,
                            ),
                          ),
                          Text('$index', style: const TextStyle(fontSize: 11)),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('閉じる'),
          ),
        ],
      ),
    ),
  );
}

class _HistoryThumbnail extends StatelessWidget {
  const _HistoryThumbnail({required this.board});
  final List<int> board;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: AspectRatio(
      aspectRatio: 1,
      child: GridView.count(
        crossAxisCount: 5,
        padding: EdgeInsets.zero,
        mainAxisSpacing: 1,
        crossAxisSpacing: 1,
        physics: const NeverScrollableScrollPhysics(),
        children: board
            .map(
              (player) => Container(
                color: const Color(0xffe8ece5),
                padding: const EdgeInsets.all(1),
                child: player == 0 ? null : _Stone(player: player),
              ),
            )
            .toList(),
      ),
    ),
  );
}

// Claim drags at pointer down only when they begin on a playable own stone.
// Other touches stay available to the surrounding scroll view and tap handler.
class _StoneDragGestureRecognizer extends PanGestureRecognizer {
  bool Function(Offset)? canStart;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      event is PointerDownEvent &&
      canStart?.call(event.localPosition) == true &&
      super.isPointerAllowed(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

class GameBoard extends StatefulWidget {
  const GameBoard({super.key, required this.game});
  final GameController game;
  @override
  State<GameBoard> createState() => _GameBoardState();
}

class _GameBoardState extends State<GameBoard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion;
  TurnPresentation? _shownTurn;
  int? _selected;
  Offset? _origin, _last;
  Preview? _ghost;
  (int, int)? _aim;
  double _size = 0;
  int _revision = -1;
  @override
  void initState() {
    super.initState();
    _motion = AnimationController(vsync: this)
      ..addListener(() {
        if (mounted) setState(() {});
      });
    widget.game.addListener(_cancel);
  }

  @override
  void dispose() {
    widget.game.removeListener(_cancel);
    _motion.dispose();
    super.dispose();
  }

  void _cancel() {
    final turn = widget.game.lastTurn;
    if (!identical(turn, _shownTurn)) {
      _shownTurn = turn;
      _motion.stop();
      if (turn != null &&
          widget.game.presenting &&
          !MediaQuery.disableAnimationsOf(context)) {
        _motion.duration = turn.duration;
        _motion.forward(from: 0);
      } else {
        _motion.value = 1;
      }
    }
    if (mounted)
      setState(() {
        _selected = null;
        _ghost = null;
        _aim = null;
        _origin = null;
        _last = null;
      });
  }

  int? _cell(Offset p) {
    if (p.dx < 0 || p.dy < 0 || p.dx >= _size || p.dy >= _size) return null;
    return (p.dy / (_size / 5)).floor() * 5 + (p.dx / (_size / 5)).floor();
  }

  void _start(DragStartDetails details) {
    if (!widget.game.canInteract) return;
    final p = _origin ?? details.localPosition, i = _cell(p);
    if (i == null || widget.game.state.board[i] != widget.game.state.turn)
      return;
    setState(() {
      _selected = i;
      _origin = p;
      _revision = widget.game.state.moves;
    });
    _update(details.localPosition);
  }

  void _update(Offset p) {
    if (_selected == null || _origin == null) return;
    _last = p;
    final delta = p - _origin!;
    setState(() {
      if (delta.distance < 18) {
        _aim = null;
        _ghost = null;
        return;
      }
      final angle =
          (math.atan2(delta.dy, delta.dx) / (math.pi / 4)).round() *
          math.pi /
          4;
      _aim = (math.sin(angle).round(), math.cos(angle).round());
      _ghost = preview(
        widget.game.state,
        Move.flick(_selected!, _aim!.$1, _aim!.$2),
      );
    });
  }

  void _end() {
    final valid =
        _last != null &&
        _cell(_last!) != null &&
        _ghost != null &&
        _aim != null &&
        _selected != null &&
        _revision == widget.game.state.moves &&
        widget.game.canInteract;
    final move = valid ? Move.flick(_selected!, _aim!.$1, _aim!.$2) : null;
    _cancel();
    if (move != null) widget.game.move(move);
  }

  void _tap(int i) {
    final game = widget.game;
    if (!game.canInteract) return;
    if (game.state.board[i] == game.state.turn) {
      setState(() {
        _selected = i;
        _ghost = null;
        _aim = null;
      });
    } else {
      game.move(Move.place(i));
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _selected == null)
      return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _cancel();
      return KeyEventResult.handled;
    }
    if (!widget.game.canInteract) return KeyEventResult.ignored;
    final vector = {
      LogicalKeyboardKey.arrowUp: (-1, 0),
      LogicalKeyboardKey.arrowDown: (1, 0),
      LogicalKeyboardKey.arrowLeft: (0, -1),
      LogicalKeyboardKey.arrowRight: (0, 1),
      LogicalKeyboardKey.keyQ: (-1, -1),
      LogicalKeyboardKey.keyE: (-1, 1),
      LogicalKeyboardKey.keyZ: (1, -1),
      LogicalKeyboardKey.keyC: (1, 1),
    }[event.logicalKey];
    if (vector != null) {
      setState(() {
        _aim = vector;
        _ghost = preview(
          widget.game.state,
          Move.flick(_selected!, vector.$1, vector.$2),
        );
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter &&
        _ghost != null &&
        _aim != null) {
      final move = Move.flick(_selected!, _aim!.$1, _aim!.$2);
      _cancel();
      widget.game.move(move);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    final turn = game.lastTurn;
    final animating = turn != null && _motion.isAnimating;
    List<int> b = _ghost?.board ?? game.state.board;
    Slide? active;
    double progress = 1;
    int movingPlayer = 0;
    if (animating && turn.steps.isNotEmpty) {
      final phase = _motion.value * turn.steps.length;
      final index = math.min(phase.floor(), turn.steps.length - 1);
      active = turn.steps[index];
      progress = Curves.easeInOut.transform(phase - index);
      b = List.of(index == 0 ? turn.before.board : turn.steps[index - 1].board);
      movingPlayer = b[active.from];
      b[active.from] = 0;
    }
    final winning = game.state.result != null && !animating
        ? lines(game.state.board).expand((c) => c).toSet()
        : <int>{};
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xfffafbf7),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: game.reachPlayers.isNotEmpty
              ? const Color(0xffd1a04e)
              : Colors.white,
          width: game.reachPlayers.isNotEmpty ? 2 : 1,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x2024352b),
            blurRadius: 30,
            offset: Offset(0, 14),
          ),
        ],
      ),
      child: AspectRatio(
        aspectRatio: 1,
        child: LayoutBuilder(
          builder: (context, constraints) {
            _size = constraints.maxWidth;
            return Focus(
              autofocus: true,
              onKeyEvent: _key,
              child: Listener(
                // Accepted Flutter drags also emit onPanEnd on pointer cancel.
                // Clear the preview before the recognizer processes that event.
                onPointerCancel: (_) => _cancel(),
                child: RawGestureDetector(
                  key: const Key('board'),
                  behavior: HitTestBehavior.opaque,
                  gestures: {
                    _StoneDragGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          _StoneDragGestureRecognizer
                        >(
                          _StoneDragGestureRecognizer.new,
                          (recognizer) => recognizer
                            ..canStart = (position) {
                              final i = _cell(position);
                              return game.canInteract &&
                                  i != null &&
                                  game.state.board[i] == game.state.turn;
                            }
                            ..onDown = (d) {
                              _origin = d.localPosition;
                            }
                            ..onStart = _start
                            ..onUpdate = (d) {
                              _update(d.localPosition);
                            }
                            ..onEnd = (_) {
                              _end();
                            }
                            ..onCancel = _cancel,
                        ),
                    TapGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          TapGestureRecognizer
                        >(
                          TapGestureRecognizer.new,
                          (recognizer) => recognizer
                            ..onTapUp = (d) {
                              final i = _cell(d.localPosition);
                              if (i != null) _tap(i);
                            },
                        ),
                  },
                  child: Stack(
                    children: [
                      GridView.count(
                        crossAxisCount: 5,
                        padding: EdgeInsets.zero,
                        mainAxisSpacing: 3,
                        crossAxisSpacing: 3,
                        physics: const NeverScrollableScrollPhysics(),
                        children: List.generate(25, (i) {
                          final changed =
                              _ghost != null && b[i] != game.state.board[i];
                          return Semantics(
                            label:
                                '${'ABCDE'[i % 5]}${i ~/ 5 + 1} ${game.state.board[i] == 0
                                    ? '空きマス'
                                    : game.state.board[i] == 1
                                    ? '黒のコマ'
                                    : '白のコマ'}',
                            button: true,
                            enabled: game.canInteract,
                            onTap:
                                game.canInteract &&
                                    (canPlace(game.state, i) ||
                                        game.state.board[i] == game.state.turn)
                                ? () => _tap(i)
                                : null,
                            child: Container(
                              key: Key('cell-$i'),
                              decoration: BoxDecoration(
                                color: winning.contains(i)
                                    ? const Color(0xffdbd6a8)
                                    : changed
                                    ? const Color(0xffd6e0d7)
                                    : const Color(0xffe8ece5),
                                borderRadius: BorderRadius.circular(7),
                                border: winning.contains(i)
                                    ? Border.all(
                                        color: const Color(0xffb48129),
                                        width: 2.5,
                                      )
                                    : _selected == i
                                    ? Border.all(
                                        color: const Color(0xff7d9284),
                                        width: 1.5,
                                      )
                                    : null,
                              ),
                              child: Center(
                                child: b[i] != 0
                                    ? FractionallySizedBox(
                                        widthFactor: .64,
                                        child: AspectRatio(
                                          aspectRatio: 1,
                                          child: Opacity(
                                            opacity: changed ? .65 : 1,
                                            child:
                                                animating &&
                                                    turn.move.type == 'place' &&
                                                    i == turn.move.i
                                                ? Transform.scale(
                                                    scale: Curves.easeOutBack
                                                        .transform(
                                                          _motion.value,
                                                        ),
                                                    child: _Stone(player: b[i]),
                                                  )
                                                : _Stone(player: b[i]),
                                          ),
                                        ),
                                      )
                                    : canPlace(game.state, i) &&
                                          game.canInteract
                                    ? Container(
                                        width: 4,
                                        height: 4,
                                        decoration: const BoxDecoration(
                                          color: Color(0xffa8b3a9),
                                          shape: BoxShape.circle,
                                        ),
                                      )
                                    : null,
                              ),
                            ),
                          );
                        }),
                      ),
                      if (active != null)
                        Positioned(
                          left:
                              (active.from % 5 +
                                      (active.to % 5 - active.from % 5) *
                                          progress) *
                                  ((_size - 12) / 5 + 3) +
                              ((_size - 12) / 5) * .18,
                          top:
                              (active.from ~/ 5 +
                                      (active.to ~/ 5 - active.from ~/ 5) *
                                          progress) *
                                  ((_size - 12) / 5 + 3) +
                              ((_size - 12) / 5) * .18,
                          width: ((_size - 12) / 5) * .64,
                          height: ((_size - 12) / 5) * .64,
                          child: IgnorePointer(
                            child: ExcludeSemantics(
                              child: _Stone(
                                key: const Key('moving-stone'),
                                player: movingPlayer,
                              ),
                            ),
                          ),
                        ),
                      if (_aim != null && _selected != null)
                        IgnorePointer(
                          child: CustomPaint(
                            size: Size.square(_size),
                            painter: _AimPainter(
                              _selected!,
                              _aim!,
                              _ghost != null,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Stone extends StatelessWidget {
  const _Stone({super.key, required this.player});
  final int player;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(
        color: player == 1 ? const Color(0xff141818) : const Color(0xffd0d7cd),
      ),
      gradient: RadialGradient(
        center: const Alignment(-.45, -.6),
        radius: 1,
        colors: player == 1
            ? const [Color(0xffa5a5a5), Color(0xff626262), Color(0xff171717)]
            : const [Colors.white, Color(0xfffcfdf6), Color(0xffc5cfc1)],
        stops: const [0, .25, 1],
      ),
      boxShadow: const [
        BoxShadow(
          color: Color(0x35354434),
          blurRadius: 9,
          offset: Offset(2, 6),
        ),
      ],
    ),
  );
}

class _AimPainter extends CustomPainter {
  _AimPainter(this.i, this.direction, this.valid);
  final int i;
  final (int, int) direction;
  final bool valid;
  @override
  void paint(Canvas canvas, Size size) {
    final start = Offset(
          (i % 5 + .5) * size.width / 5,
          (i ~/ 5 + .5) * size.height / 5,
        ),
        angle = math.atan2(direction.$1, direction.$2),
        length = size.width * .16;
    final end = start + Offset(math.cos(angle), math.sin(angle)) * length;
    final pen = Paint()
      ..color = valid ? const Color(0xff4c6756) : const Color(0xff9b7164)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(start, end, pen);
    for (final sign in [-1, 1]) {
      canvas.drawLine(
        end,
        end -
            Offset(math.cos(angle + sign * .6), math.sin(angle + sign * .6)) *
                9,
        pen,
      );
    }
  }

  @override
  bool shouldRepaint(_AimPainter old) =>
      old.i != i || old.direction != direction || old.valid != valid;
}
