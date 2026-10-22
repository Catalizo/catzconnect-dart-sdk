// In-call chat for the example app: a log of messages (kept while the
// sheet is closed) and a bottom sheet to read and send them, to everyone or
// to one participant. Messages go peer-to-peer over WebRTC data channels
// when they are open and through the signaling server otherwise
// (`CatzCallClient.sendChat` decides; `via` says which was used).

import 'dart:async';

import 'package:catzconnect/catzconnect.dart';
import 'package:flutter/material.dart';

/// One line in the chat.
class ChatEntry {
  const ChatEntry({
    required this.author,
    required this.text,
    required this.at,
    this.mine = false,
    this.private = false,
    this.via,
  });

  final String author;
  final String text;
  final DateTime at;
  final bool mine;
  final bool private;
  final MessageVia? via;
}

/// The messages of the current call, newest last.
class CallChatLog extends ChangeNotifier {
  final List<ChatEntry> _entries = <ChatEntry>[];
  int _unread = 0;

  List<ChatEntry> get entries => List<ChatEntry>.unmodifiable(_entries);

  /// Messages from others since the sheet was last open.
  int get unread => _unread;

  bool _open = false;

  void add(ChatEntry e) {
    _entries.add(e);
    if (_entries.length > 200) _entries.removeAt(0);
    if (!e.mine && !_open) _unread++;
    notifyListeners();
  }

  void opened(bool open) {
    _open = open;
    if (open) _unread = 0;
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    _unread = 0;
    notifyListeners();
  }
}

/// Opens the chat sheet for [client]'s current call. [peers] maps pid to
/// a display name.
Future<void> showCallChat(
  BuildContext context,
  CatzCallClient client,
  CallChatLog log,
  Map<String, String> Function() peers,
) async {
  log.opened(true);
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: CallChatSheet(client: client, log: log, peers: peers),
        ),
      ),
    );
  } finally {
    log.opened(false);
  }
}

class CallChatSheet extends StatefulWidget {
  const CallChatSheet({super.key, required this.client, required this.log, required this.peers});

  final CatzCallClient client;
  final CallChatLog log;
  final Map<String, String> Function() peers;

  @override
  State<CallChatSheet> createState() => _CallChatSheetState();
}

class _CallChatSheetState extends State<CallChatSheet> {
  final TextEditingController _text = TextEditingController();

  /// Recipient pid; null = everyone.
  String? _to;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final String text = _text.text.trim();
    if (text.isEmpty) return;
    final String? to = widget.peers().containsKey(_to) ? _to : null;
    try {
      final SentCallMessage sent = await widget.client.sendChat(text, to: to);
      if (!mounted) return;
      widget.log.add(ChatEntry(
        author: to == null ? 'You' : 'You → ${widget.peers()[to] ?? to}',
        text: text,
        at: sent.ts,
        mine: true,
        private: to != null,
        via: sent.via,
      ));
      _text.clear();
      setState(() => _error = null);
    } on CallMessageError catch (e) {
      if (!mounted) return;
      setState(() => _error = switch (e.code) {
            'message_too_large' => 'That message is too long (${widget.client.messageLimits.chatMaxChars} characters at most).',
            'rate_limited' => 'You are sending too fast — wait a moment.',
            'not_in_call' => 'You are not in a call.',
            _ => e.message,
          });
    }
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, String> peers = widget.peers();
    if (_to != null && !peers.containsKey(_to)) _to = null;
    return Column(
      children: <Widget>[
        Expanded(
          child: ListenableBuilder(
            listenable: widget.log,
            builder: (BuildContext context, Widget? _) {
              final List<ChatEntry> entries = widget.log.entries;
              if (entries.isEmpty) {
                return const Center(child: Text('No messages yet'));
              }
              return ListView.builder(
                reverse: true,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: entries.length,
                itemBuilder: (BuildContext context, int i) => _bubble(context, entries[entries.length - 1 - i]),
              );
            },
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: Row(
            children: <Widget>[
              DropdownButton<String?>(
                value: _to,
                onChanged: (String? v) => setState(() => _to = v),
                items: <DropdownMenuItem<String?>>[
                  const DropdownMenuItem<String?>(value: null, child: Text('Everyone')),
                  for (final MapEntry<String, String> p in peers.entries)
                    DropdownMenuItem<String?>(value: p.key, child: Text(p.value)),
                ],
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _text,
                  maxLength: widget.client.messageLimits.chatMaxChars,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (String _) => unawaited(_send()),
                  decoration: const InputDecoration(hintText: 'Message', counterText: ''),
                ),
              ),
              IconButton(tooltip: 'Send', icon: const Icon(Icons.send), onPressed: () => unawaited(_send())),
            ],
          ),
        ),
      ],
    );
  }

  Widget _bubble(BuildContext context, ChatEntry e) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String time = TimeOfDay.fromDateTime(e.at).format(context);
    return Align(
      alignment: e.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: e.mine ? cs.primaryContainer : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '${e.author}${e.private ? ' (private)' : ''} · $time${e.via == MessageVia.relay ? ' · via server' : ''}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            Text(e.text),
          ],
        ),
      ),
    );
  }
}
