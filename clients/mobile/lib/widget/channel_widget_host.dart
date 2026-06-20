import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/services.dart';

/// The iOS concrete [WidgetHost] over a plain [MethodChannel] (`capecho/widget`) — NO plugin, so the
/// mobile iOS build stays SwiftPM-pure (this replaces `home_widget`, which lacks SPM). The Runner's
/// `WidgetChannel.swift` handles these calls against the App Group container; the SwiftUI widget reads/
/// writes the same keys. On Android / in tests there's no native handler, so calls no-op gracefully.
class ChannelWidgetHost implements WidgetHost {
  const ChannelWidgetHost();

  static const MethodChannel _channel = MethodChannel('capecho/widget');

  @override
  Future<void> publishSnapshot(String snapshotJson) =>
      _invoke('publishSnapshot', {'snapshot': snapshotJson});

  @override
  Future<String?> readQueueJson() => _invokeString('readQueue');

  @override
  Future<void> writeQueueJson(String queueJson) => _invoke('writeQueue', {'queue': queueJson});

  /// Clear the shared container on sign-out so a different account can't inherit the previous user's
  /// snapshot / un-synced grade queue.
  Future<void> clear() => _invoke('clear');

  Future<void> _invoke(String method, [Map<String, dynamic>? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // No native handler (Android — no widget surface, or a test) → harmless no-op.
    }
  }

  Future<String?> _invokeString(String method) async {
    try {
      return await _channel.invokeMethod<String>(method);
    } on MissingPluginException {
      return null;
    }
  }
}
