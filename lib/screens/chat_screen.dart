import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/message_mail_provider.dart';
import '../widgets/message_bubble.dart';
import '../widgets/voice_recorder_bar.dart';

/// WhatsApp-style 1-to-1 or Group Chat Screen with Call button,
/// real compressed voice notes, and store-and-forward delivery ticks.
class ChatScreen extends StatefulWidget {
  final String chatId;
  final bool isGroup;

  const ChatScreen({
    super.key,
    required this.chatId,
    this.isGroup = false,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final ScrollController _scrollController = ScrollController();
  MessageMailProvider? _providerRef;
  int _lastMsgCount = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = context.read<MessageMailProvider>();
    if (_providerRef != provider) {
      _providerRef = provider;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          provider.openChat(widget.chatId);
        }
      });
    }
  }

  @override
  void dispose() {
    _providerRef?.closeChat();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MessageMailProvider>();
    final messages = provider.activeChatMessages;

    if (messages.length != _lastMsgCount) {
      _lastMsgCount = messages.length;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }

    final group = widget.isGroup ? provider.getGroup(widget.chatId) : null;
    final peer = widget.isGroup ? null : provider.getPeer(widget.chatId);
    final title = widget.isGroup
        ? (group?.groupName ?? widget.chatId)
        : (peer?.displayName ?? widget.chatId);

    final subtitle = widget.isGroup
        ? (group != null
            ? group.members.map((m) => provider.resolveDisplayName(m)).join(', ')
            : 'Group Chat')
        : (peer?.isOnline == true
            ? 'Online on ESP32 relay'
            : 'Offline • Store-and-forward active');

    return Scaffold(
      backgroundColor: const Color(0xFF0B141A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F2C34),
        iconTheme: const IconThemeData(color: Colors.white),
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor:
                  widget.isGroup ? const Color(0xFF005C4B) : const Color(0xFF23323C),
              child: widget.isGroup
                  ? const Icon(Icons.groups, color: Colors.white, size: 19)
                  : Text(
                      title.isNotEmpty ? title.substring(0, 1).toUpperCase() : '?',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: (!widget.isGroup && peer?.isOnline == true)
                          ? const Color(0xFF25D366)
                          : Colors.white54,
                      fontSize: 11.5,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (!widget.isGroup)
            IconButton(
              icon: const Icon(Icons.call, color: Color(0xFF25D366)),
              tooltip: 'Live Mesh Call',
              onPressed: () => provider.startVoiceCall(widget.chatId),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Text(
                        widget.isGroup
                            ? 'Group "$title" created.\nSend a text or compressed voice message to all members!'
                            : 'Say hello to $title!\nMessages deliver live over ESP32 or wait safely in the relay mailbox if $title is offline.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 13.5,
                          height: 1.45,
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    itemCount: messages.length,
                    itemBuilder: (_, idx) {
                      final msg = messages[idx];
                      final isOutgoing = msg.senderId == provider.localUsername;
                      return MessageBubble(
                        message: msg,
                        isOutgoing: isOutgoing,
                      );
                    },
                  ),
          ),
          VoiceRecorderBar(
            chatId: widget.chatId,
            isGroup: widget.isGroup,
          ),
        ],
      ),
    );
  }
}

