import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One contact reachable from the Band's speed dial. Only what's needed to
/// show an avatar and place a call — the full contact record stays with the
/// OS's own contacts store, not duplicated here.
class SpeedDialContact {
  const SpeedDialContact({required this.name, required this.phone});

  final String name;
  final String phone;

  String get initial => name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();

  Map<String, dynamic> toJson() => {'name': name, 'phone': phone};

  factory SpeedDialContact.fromJson(Map<String, dynamic> json) =>
      SpeedDialContact(
        name: json['name'] as String? ?? '',
        phone: json['phone'] as String? ?? '',
      );
}

/// Who's on speed dial, persisted locally so the list picked from the
/// system's contact picker survives closing the app rather than needing to
/// be rebuilt every launch.
class SpeedDial extends ChangeNotifier {
  static const _prefsKey = 'speed_dial_contacts_v1';

  final List<SpeedDialContact> _contacts = [];

  List<SpeedDialContact> get contacts => List.unmodifiable(_contacts);

  /// Reads whatever was saved last, if anything. Call once at startup.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    final decoded = jsonDecode(raw) as List<dynamic>;
    _contacts
      ..clear()
      ..addAll(
        decoded
            .map((e) => SpeedDialContact.fromJson(e as Map<String, dynamic>)),
      );
    notifyListeners();
  }

  void add(SpeedDialContact contact) {
    _contacts.add(contact);
    notifyListeners();
    _persist();
  }

  void removeAt(int index) {
    _contacts.removeAt(index);
    notifyListeners();
    _persist();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(_contacts.map((c) => c.toJson()).toList()),
    );
  }
}
