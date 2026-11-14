import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/message_mail.dart';
import '../providers/message_mail_provider.dart';
import '../widgets/connection_status_pill.dart';
import '../widgets/outbox_diagnostic_drawer.dart';
import 'chat_screen.dart';
import 'create_group_screen.dart';

/// WhatsApp-style home screen showing active 1-to-1 and group chats,
/// real-time search across chats and discovered peers, and New Chat / New Group controls.
class ChatsHomeScreen extends StatefulWidget {
  const ChatsHomeScreen({super.key});

  @override
  State<ChatsHomeScreen> createState() => _ChatsHomeScreenState();
}

class _ChatsHomeScreenState extends State<ChatsHomeScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.trim().toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _openChatScreen(BuildContext context, String chatId, bool isGroup) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(chatId: chatId, isGroup: isGroup),
      ),
    );
  }

  void _showRenameDialog(BuildContext context, MessageMailProvider provider) {
    final ctrl = TextEditingController(text: provider.localDisplayName);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1F2C34),
        title: const Text('Change Your Unique Name',
            style: TextStyle(color: Colors.white, fontSize: 17)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Enter unique name...',
            hintStyle: TextStyle(color: Colors.white38),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A884)),
            onPressed: () async {
              final ok = await provider.registerUsername(ctrl.text);
              if (ok && ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showPeopleSheet(BuildContext context, MessageMailProvider provider) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF111B21),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.65,
          maxChildSize: 0.9,
          builder: (_, scrollCtrl) {
            final peers = provider.peers;
            return Column(
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Select Contact',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '${peers.length} discovered',
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFF00A884),
                    child: Icon(Icons.group_add, color: Colors.white),
                  ),
                  title: const Text('New Group',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600)),
                  subtitle: const Text('Create an off-grid group chat',
                      style: TextStyle(color: Colors.white54, fontSize: 12)),
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const CreateGroupScreen()),
                    );
                  },
                ),
                const Divider(color: Colors.white10),
                Expanded(
                  child: peers.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'No other users discovered yet.\nAs soon as others open the app near the ESP32 relay, their names appear here automatically.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.white54, height: 1.4),
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: scrollCtrl,
                          itemCount: peers.length,
                          itemBuilder: (_, idx) {
                            final p = peers[idx];
                            return ListTile(
                              leading: Stack(
                                children: [
                                  CircleAvatar(
                                    backgroundColor: const Color(0xFF23323C),
                                    child: Text(
                                      p.displayName.substring(0, 1).toUpperCase(),
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                  if (p.isOnline)
                                    Positioned(
                                      right: 0,
                                      bottom: 0,
                                      child: Container(
                                        width: 11,
                                        height: 11,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF25D366),
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                              color: const Color(0xFF111B21),
                                              width: 2),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              title: Text(p.displayName,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600)),
                              subtitle: Text(
                                p.isOnline ? 'Online on relay' : 'Offline • Reachable via relay mail',
                                style: TextStyle(
                                  color: p.isOnline
                                      ? const Color(0xFF25D366)
                                      : Colors.white54,
                                  fontSize: 12,
                                ),
                              ),
                              onTap: () {
                                Navigator.pop(ctx);
                                _openChatScreen(context, p.username, false);
                              },
                            );
                          },
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MessageMailProvider>();
    final allChats = provider.chatSummaries;
    final existingChatIds = allChats.map((c) => c.chatId).toSet();

    final filteredChats = allChats.where((c) {
      if (_searchQuery.isEmpty) return true;
      return c.title.toLowerCase().contains(_searchQuery) ||
          c.chatId.toLowerCase().contains(_searchQuery);
    }).toList();

    // Also include discovered peers that don't have a chat thread yet (great for search & quick chat)
    final discoverablePeers = provider.peers.where((p) {
      if (existingChatIds.contains(p.username)) return false;
      if (_searchQuery.isEmpty) return true;
      return p.displayName.toLowerCase().contains(_searchQuery) ||
          p.username.toLowerCase().contains(_searchQuery);
    }).toList();

    return Scaffold(
      backgroundColor: const Color(0xFF0B141A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F2C34),
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Message Mail',
              style: TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.bold,
              ),
            ),
            GestureDetector(
              onTap: () => _showRenameDialog(context, provider),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Logged in as ${provider.localDisplayName}',
                    style: const TextStyle(
                      color: Color(0xFF25D366),
                      fontSize: 11.5,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.edit, size: 11, color: Color(0xFF25D366)),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.group_add_outlined, color: Colors.white),
            tooltip: 'New Group',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CreateGroupScreen()),
              );
            },
          ),
          Builder(
            builder: (ctx) => IconButton(
              icon: const Icon(Icons.tune, color: Colors.white70),
              tooltip: 'Relay Diagnostics',
              onPressed: () => Scaffold.of(ctx).openEndDrawer(),
            ),
          ),
        ],
      ),
      endDrawer: const OutboxDiagnosticDrawer(),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFF00A884),
        foregroundColor: Colors.white,
        onPressed: () => _showPeopleSheet(context, provider),
        child: const Icon(Icons.chat),
      ),
      body: Column(
        children: [
          const ConnectionStatusPill(compact: true),
          if (provider.nameConflictMessage != null)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF78350F),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFF59E0B)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber, color: Color(0xFFFBBF24), size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      provider.nameConflictMessage!,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _showRenameDialog(context, provider),
                    child: const Text('RENAME',
                        style: TextStyle(
                            color: Color(0xFFFBBF24),
                            fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white, fontSize: 14.5),
              decoration: InputDecoration(
                hintText: 'Search people or groups by name...',
                hintStyle: const TextStyle(color: Colors.white38, fontSize: 14),
                prefixIcon: const Icon(Icons.search, color: Colors.white54, size: 20),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close, color: Colors.white54, size: 18),
                        onPressed: () => _searchController.clear(),
                      )
                    : null,
                filled: true,
                fillColor: const Color(0xFF1F2C34),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: (filteredChats.isEmpty && discoverablePeers.isEmpty)
                ? _buildEmptyState(provider)
                : ListView(
                    children: [
                      ...filteredChats.map((chat) => _buildChatTile(context, provider, chat)),
                      if (discoverablePeers.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
                          child: Text(
                            'PEOPLE ON MESH',
                            style: TextStyle(
                              color: Color(0xFF8696A0),
                              fontSize: 11.5,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.7,
                            ),
                          ),
                        ),
                        ...discoverablePeers.map((p) => _buildPeerQuickTile(context, p)),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatTile(
    BuildContext context,
    MessageMailProvider provider,
    ChatSummary chat,
  ) {
    final last = chat.lastMessage;
    String preview = chat.isGroup
        ? '${chat.memberCount} members'
        : 'Tap to start messaging';
    if (last != null) {
      final prefix = (chat.isGroup && last.senderId != provider.localUsername)
          ? '${provider.resolveDisplayName(last.senderId)}: '
          : '';
      if (last.payloadType == PayloadType.voiceMail) {
        preview = '$prefix🎤 Voice message';
      } else if (last.payloadType == PayloadType.callLog) {
        preview = '📞 ${last.textContent ?? "Call"}';
      } else {
        preview = '$prefix${last.textContent ?? ""}';
      }
    }

    return ListTile(
      onTap: () => _openChatScreen(context, chat.chatId, chat.isGroup),
      leading: Stack(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor:
                chat.isGroup ? const Color(0xFF005C4B) : const Color(0xFF23323C),
            child: chat.isGroup
                ? const Icon(Icons.groups, color: Colors.white)
                : Text(
                    chat.title.isNotEmpty
                        ? chat.title.substring(0, 1).toUpperCase()
                        : '?',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
          ),
          if (!chat.isGroup && chat.isOnline)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 13,
                height: 13,
                decoration: BoxDecoration(
                  color: const Color(0xFF25D366),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF0B141A), width: 2),
                ),
              ),
            ),
        ],
      ),
      title: Text(
        chat.title,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: 16,
        ),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Row(
        children: [
          if (last != null &&
              last.senderId == provider.localUsername &&
              last.payloadType != PayloadType.callLog) ...[
            _buildMiniTick(last.status),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              preview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFF8696A0), fontSize: 13.5),
            ),
          ),
        ],
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (chat.lastActivityMs > 0)
            Text(
              _formatTime(chat.lastActivityMs),
              style: TextStyle(
                color: chat.unreadCount > 0
                    ? const Color(0xFF25D366)
                    : const Color(0xFF8696A0),
                fontSize: 11.5,
              ),
            ),
          if (chat.unreadCount > 0) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: const BoxDecoration(
                color: Color(0xFF25D366),
                shape: BoxShape.circle,
              ),
              child: Text(
                '${chat.unreadCount}',
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPeerQuickTile(BuildContext context, PeerUser peer) {
    return ListTile(
      onTap: () => _openChatScreen(context, peer.username, false),
      leading: Stack(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: const Color(0xFF23323C),
            child: Text(
              peer.displayName.substring(0, 1).toUpperCase(),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (peer.isOnline)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: const Color(0xFF25D366),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF0B141A), width: 2),
                ),
              ),
            ),
        ],
      ),
      title: Text(
        peer.displayName,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        peer.isOnline ? 'Online now on ESP32 relay' : 'Discovered on mesh',
        style: TextStyle(
          color: peer.isOnline ? const Color(0xFF25D366) : const Color(0xFF8696A0),
          fontSize: 12.5,
        ),
      ),
      trailing: const Icon(Icons.chevron_right, color: Colors.white30),
    );
  }

  Widget _buildMiniTick(MessageStatus status) {
    switch (status) {
      case MessageStatus.pendingLocal:
        return const Icon(Icons.access_time, size: 14, color: Colors.white54);
      case MessageStatus.inTransit:
        return const Icon(Icons.done, size: 15, color: Colors.white60);
      case MessageStatus.delivered:
        return const Icon(Icons.done_all, size: 15, color: Color(0xFF53BDEB));
      case MessageStatus.failed:
        return const Icon(Icons.error_outline, size: 14, color: Color(0xFFF87171));
    }
  }

  Widget _buildEmptyState(MessageMailProvider provider) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.radar, color: Color(0xFF00A884), size: 52),
            const SizedBox(height: 16),
            Text(
              _searchQuery.isNotEmpty
                  ? 'No matching people or groups for "$_searchQuery"'
                  : 'Waiting for people on the Off-Grid Relay',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Once another user opens the app near the ESP32 relay and enters their name, they will appear here automatically.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 13, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(int epochMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
