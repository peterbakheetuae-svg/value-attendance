import 'dart:convert';

class NotificationModel {
  final String id;
  final String userId;
  final String title;
  final String body;
  final String type;
  bool read;
  final DateTime timestamp;
  final DateTime createdAt;

  NotificationModel({
    required this.id,
    required this.userId,
    required this.title,
    required this.body,
    required this.type,
    required this.read,
    required this.timestamp,
    required this.createdAt,
  });

  factory NotificationModel.fromJson(Map<String, dynamic> json) {
    final ts = json['timestamp'];
    return NotificationModel(
      id: json['id'] ?? '',
      userId: json['userId'] ?? '',
      title: json['title'] ?? '',
      body: json['body'] ?? '',
      type: json['type'] ?? 'general',
      read: json['read'] ?? false,
      timestamp: ts is Map
          ? DateTime.fromMillisecondsSinceEpoch(ts['_seconds'] * 1000)
          : DateTime.now(),
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'])
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'userId': userId,
      'title': title,
      'body': body,
      'type': type,
      'read': read,
      'timestamp': timestamp.toIso8601String(),
      'createdAt': createdAt.toIso8601String(),
    };
  }

  String toJsonString() => json.encode(toJson());
  factory NotificationModel.fromJsonString(String jsonString) =>
      NotificationModel.fromJson(json.decode(jsonString));
}
