import 'package:flutter/material.dart';

enum _AccountAction { select, add }

class _AccountChoice {
  final _AccountAction action;
  final String id;
  const _AccountChoice(this.action, [this.id = '']);
}

/// The sidebar and account menu follow the service's saved Google identities.
class AccountButton extends StatelessWidget {
  final bool connected, busy;
  final String account, displayName, email, photoUrl;
  final List<Map<String, Object?>> accounts;
  final VoidCallback onSignIn, onAddAccount;
  final ValueChanged<String> onSwitchAccount, onSignOutAccount;

  const AccountButton({
    super.key,
    required this.connected,
    required this.busy,
    required this.displayName,
    required this.email,
    required this.photoUrl,
    this.account = '',
    this.accounts = const [],
    required this.onSignIn,
    required this.onAddAccount,
    required this.onSwitchAccount,
    required this.onSignOutAccount,
  });

  Widget avatar({
    required String name,
    required String address,
    required String photo,
    double radius = 16,
    bool signedIn = true,
  }) {
    final label = name.trim().isNotEmpty ? name.trim() : address;
    final fallback = signedIn && label.isNotEmpty
        ? Text(
            label.characters.first.toUpperCase(),
            style: TextStyle(fontSize: radius),
          )
        : const Icon(Icons.person_outline, color: Colors.white, size: 20);
    final uri = Uri.tryParse(photo);
    final hasPhoto = signedIn && uri?.scheme == 'https' && uri!.host.isNotEmpty;
    return CircleAvatar(
      radius: radius,
      backgroundColor: const Color(0xff008577),
      foregroundColor: Colors.white,
      child: hasPhoto
          ? ClipOval(
              child: Image.network(
                photo,
                key: ValueKey(photo),
                width: radius * 2,
                height: radius * 2,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => fallback,
              ),
            )
          : fallback,
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeAvatar = avatar(
      name: displayName,
      address: email,
      photo: photoUrl,
      signedIn: connected,
    );
    if (!connected) {
      return IconButton(
        tooltip: 'Sign in with Google',
        onPressed: busy ? null : onSignIn,
        icon: activeAvatar,
      );
    }
    final saved = accounts.isNotEmpty
        ? accounts
        : <Map<String, Object?>>[
            {
              'id': account,
              'email': email,
              'displayName': displayName,
              'photoUrl': photoUrl,
              'current': true,
            },
          ];
    return PopupMenuButton<_AccountChoice>(
      tooltip: 'Google account: ${email.isEmpty ? displayName : email}',
      enabled: !busy,
      constraints: const BoxConstraints(minWidth: 288, maxWidth: 322),
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      menuPadding: const EdgeInsets.all(10),
      onSelected: (choice) {
        switch (choice.action) {
          case _AccountAction.add:
            onAddAccount();
          case _AccountAction.select:
            onSwitchAccount(choice.id);
        }
      },
      itemBuilder: (_) => [
        for (final savedAccount in saved)
          PopupMenuItem<_AccountChoice>(
            value: _AccountChoice(
              _AccountAction.select,
              savedAccount['id'] as String,
            ),
            padding: EdgeInsets.zero,
            height: 56,
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 2, 8),
              decoration: BoxDecoration(
                color: savedAccount['current'] == true
                    ? const Color(0xffc3e7ff)
                    : null,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                children: [
                  avatar(
                    name: savedAccount['displayName'] as String? ?? '',
                    address: savedAccount['email'] as String? ?? '',
                    photo: savedAccount['photoUrl'] as String? ?? '',
                    radius: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          (savedAccount['displayName'] as String? ?? '').isEmpty
                              ? 'Google account'
                              : savedAccount['displayName'] as String,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: savedAccount['current'] == true
                                ? const Color(0xff004a6f)
                                : null,
                          ),
                        ),
                        Text(
                          savedAccount['email'] as String? ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: savedAccount['current'] == true
                                ? const Color(0xff004a6f)
                                : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Sign out of ${savedAccount['email']}',
                    icon: const Icon(Icons.logout, size: 20),
                    onPressed: () {
                      Navigator.of(context).pop();
                      onSignOutAccount(savedAccount['id'] as String);
                    },
                  ),
                ],
              ),
            ),
          ),
        const PopupMenuItem<_AccountChoice>(
          value: _AccountChoice(_AccountAction.add),
          height: 48,
          child: Row(
            children: [
              Icon(Icons.person_add_alt_1, size: 24),
              SizedBox(width: 18),
              Expanded(child: Text('Add another account')),
            ],
          ),
        ),
      ],
      child: Padding(padding: const EdgeInsets.all(12), child: activeAvatar),
    );
  }
}
