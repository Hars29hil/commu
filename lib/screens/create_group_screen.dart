import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/message_mail_provider.dart';
import 'chat_screen.dart';

/// WhatsApp-style Create Group screen: pick group name & select discovered people.
class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final TextEditingController _groupNameCtrl = TextEditingController();
  final TextEditingController _searchCtrl = TextEditingController();
  final Set<String> _selectedUsers = {};
  String _query = '';
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      setState(() => _query = _searchCtrl.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _groupNameCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _createGroup() async {
    final name = _groupNameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a group name.')),
      );
      return;
    }
    if (_selectedUsers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least 1 person for the group.')),
      );
      return;
    }

    setState(() => _creating = true);
    final provider = context.read<MessageMailProvider>();
    final group = await provider.createGroup(
      groupName: name,
      memberUsernames: _selectedUsers.toList(),
    );

    if (group != null && mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ChatScreen(chatId: group.groupId, isGroup: true),
        ),
      );
    } else if (mounted) {
      setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MessageMailProvider>();
    final peers = provider.peers.where((p) {
      if (_query.isEmpty) return true;
      return p.displayName.toLowerCase().contains(_query) ||
          p.username.toLowerCase().contains(_query);
    }).toList();

    return Scaffold(
      backgroundColor: const Color(0xFF0B141A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F2C34),
        title: const Text('New Group', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFF00A884),
        foregroundColor: Colors.white,
        onPressed: _creating ? null : _createGroup,
        child: _creating
            ? const CircularProgressIndicator(color: Colors.white)
            : const Icon(Icons.check),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _groupNameCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: InputDecoration(
                labelText: 'Group Name',
                labelStyle: const TextStyle(color: Color(0xFF25D366)),
                hintText: 'e.g. Trek Crew',
                hintStyle: const TextStyle(color: Colors.white30),
                prefixIcon: const Icon(Icons.groups, color: Color(0xFF00A884)),
                filled: true,
                fillColor: const Color(0xFF1F2C34),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          if (_selectedUsers.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                children: _selectedUsers.map((u) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Chip(
                      backgroundColor: const Color(0xFF005C4B),
                      label: Text(
                        provider.resolveDisplayName(u),
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                      deleteIcon: const Icon(Icons.close, size: 15, color: Colors.white70),
                      onDeleted: () => setState(() => _selectedUsers.remove(u)),
                    ),
                  );
                }).toList(),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
            child: TextField(
              controller: _searchCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Search members by name...',
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon: const Icon(Icons.search, color: Colors.white54, size: 19),
                filled: true,
                fillColor: const Color(0xFF1F2C34),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'SELECT PARTICIPANTS',
              style: TextStyle(
                color: Color(0xFF8696A0),
                fontSize: 11.5,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: peers.isEmpty
                ? const Center(
                    child: Text(
                      'No discovered users available yet.\nHave users connect near the ESP32 relay first.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54),
                    ),
                  )
                : ListView.builder(
                    itemCount: peers.length,
                    itemBuilder: (_, idx) {
                      final p = peers[idx];
                      final selected = _selectedUsers.contains(p.username);
                      return CheckboxListTile(
                        value: selected,
                        activeColor: const Color(0xFF00A884),
                        checkColor: Colors.white,
                        secondary: CircleAvatar(
                          backgroundColor: const Color(0xFF23323C),
                          child: Text(
                            p.displayName.substring(0, 1).toUpperCase(),
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                        title: Text(p.displayName,
                            style: const TextStyle(color: Colors.white)),
                        subtitle: Text(
                          p.isOnline ? 'Online' : 'Offline',
                          style: TextStyle(
                            color: p.isOnline
                                ? const Color(0xFF25D366)
                                : Colors.white38,
                            fontSize: 12,
                          ),
                        ),
                        onChanged: (val) {
                          setState(() {
                            if (val == true) {
                              _selectedUsers.add(p.username);
                            } else {
                              _selectedUsers.remove(p.username);
                            }
                          });
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

