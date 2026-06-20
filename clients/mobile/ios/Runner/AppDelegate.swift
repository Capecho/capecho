import Flutter
import UIKit
import WidgetKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // The review-widget App-Group bridge over a plain MethodChannel (no plugin → SwiftPM-pure).
    if let messenger = engineBridge.pluginRegistry.registrar(forPlugin: "CapechoWidgetChannel")?
      .messenger()
    {
      WidgetChannel.register(with: messenger)
    }
  }
}

/// The Runner side of the review-widget App-Group bridge — a plain FlutterMethodChannel (NO plugin, so
/// the mobile iOS build stays SwiftPM-pure; replaces home_widget, which lacks SPM). The Dart app
/// (ChannelWidgetHost) calls these; the SwiftUI widget extension reads/writes the SAME App-Group keys.
/// Inlined into AppDelegate so it compiles into the Runner target with no extra Xcode file step.
enum WidgetChannel {
  static let appGroupId = "group.com.capecho.app"
  static let snapshotKey = "widget_review_snapshot"
  static let queueKey = "widget_review_queue"
  static let channelName = "capecho/widget"

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      let defaults = UserDefaults(suiteName: appGroupId)
      switch call.method {
      case "publishSnapshot":
        if let args = call.arguments as? [String: Any], let json = args["snapshot"] as? String {
          defaults?.set(json, forKey: snapshotKey)
        }
        reloadWidgets()
        result(nil)
      case "readQueue":
        result(defaults?.string(forKey: queueKey))
      case "writeQueue":
        if let args = call.arguments as? [String: Any], let json = args["queue"] as? String {
          defaults?.set(json, forKey: queueKey)
        }
        result(nil)
      case "clear":
        defaults?.removeObject(forKey: snapshotKey)
        defaults?.removeObject(forKey: queueKey)
        reloadWidgets()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func reloadWidgets() {
    if #available(iOS 14.0, *) {
      WidgetCenter.shared.reloadAllTimelines()
    }
  }
}
