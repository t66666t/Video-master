import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterStreamHandler {
  private let shareChannelName = "com.example.video_player_app/share_intent"
  private let shareEventChannelName = "com.example.video_player_app/share_intent_events"
  private let ytDlpChannelName = "com.example.video_player_app/yt_dlp"
  private let ytDlpEventChannelName = "com.example.video_player_app/yt_dlp_events"
  private var pendingSharedMediaPaths: [String] = []
  private var shareEventSink: FlutterEventSink?
  fileprivate var ytDlpEventSink: FlutterEventSink?
  private let mediaExtensions: Set<String> = [
    ".mp4", ".mov", ".avi", ".mkv", ".flv", ".webm", ".wmv", ".3gp", ".m4v", ".ts",
    ".rmvb", ".mpg", ".mpeg", ".f4v", ".m2ts", ".mts", ".vob", ".ogv", ".divx",
    ".mp3", ".m4a", ".wav", ".flac", ".ogg", ".aac", ".wma", ".opus", ".m4b", ".aiff",
  ]

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      registerShareChannels(controller: controller)
      registerYtDlpChannels(controller: controller)
    }
    application.beginReceivingRemoteControlEvents()
    NSLog("AppDelegate: iOS remote control events enabled for control center")
    if let launchUrl = launchOptions?[.url] as? URL {
      _ = handleIncomingUrls([launchUrl])
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if handleIncomingUrls([url]) {
      return true
    }
    return super.application(app, open: url, options: options)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    shareEventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    shareEventSink = nil
    return nil
  }

  private func registerShareChannels(controller: FlutterViewController) {
    let methodChannel = FlutterMethodChannel(
      name: shareChannelName,
      binaryMessenger: controller.binaryMessenger
    )
    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result([])
        return
      }
      if call.method == "getInitialSharedMedia" {
        result(self.pendingSharedMediaPaths)
        self.pendingSharedMediaPaths.removeAll()
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    let eventChannel = FlutterEventChannel(
      name: shareEventChannelName,
      binaryMessenger: controller.binaryMessenger
    )
    eventChannel.setStreamHandler(self)
  }

  private func registerYtDlpChannels(controller: FlutterViewController) {
    let methodChannel = FlutterMethodChannel(
      name: ytDlpChannelName,
      binaryMessenger: controller.binaryMessenger
    )
    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "getYtDlpBinaryStatus":
        result(self.getYtDlpBinaryStatus())
      case "importYoutubeCookies":
        let args = call.arguments as? [String: Any]
        let filePath = args?["filePath"] as? String
        result(self.importYoutubeCookies(filePath))
      case "saveYoutubeSessionConfig":
        let args = call.arguments as? [String: Any]
        self.saveYoutubeSessionConfig(args?["config"])
        result(true)
      case "loadYoutubeSessionConfig":
        result(self.loadYoutubeSessionConfig())
      case "resolveYoutubeMeta":
        result(
          FlutterError(
            code: "YT_DLP_UNSUPPORTED",
            message: "yt-dlp process execution is not supported on iOS",
            details: nil
          )
        )
      case "startYoutubeDownload":
        result(false)
      case "pauseYoutubeDownload":
        result(false)
      case "cancelYoutubeDownload":
        result(false)
      case "removeYoutubeTask":
        result(false)
      case "getYoutubeTaskStatus":
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let eventChannel = FlutterEventChannel(
      name: ytDlpEventChannelName,
      binaryMessenger: controller.binaryMessenger
    )
    eventChannel.setStreamHandler(_YtDlpStreamProxy(owner: self))
  }

  private func handleIncomingUrls(_ urls: [URL]) -> Bool {
    let paths = urls.compactMap { copyIncomingFileToCache($0) }.filter { isMediaPath($0) }
    if paths.isEmpty {
      return false
    }
    if let sink = shareEventSink {
      sink(paths)
    } else {
      pendingSharedMediaPaths.append(contentsOf: paths)
    }
    return true
  }

  private func isMediaPath(_ path: String) -> Bool {
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    if ext.isEmpty {
      return false
    }
    return mediaExtensions.contains(".\(ext)")
  }

  private func copyIncomingFileToCache(_ url: URL) -> String? {
    guard url.isFileURL else { return nil }
    let accessing = url.startAccessingSecurityScopedResource()
    defer {
      if accessing {
        url.stopAccessingSecurityScopedResource()
      }
    }
    let fileManager = FileManager.default
    let incomingDir = fileManager.temporaryDirectory.appendingPathComponent("incoming_media", isDirectory: true)
    if !fileManager.fileExists(atPath: incomingDir.path) {
      do {
        try fileManager.createDirectory(at: incomingDir, withIntermediateDirectories: true)
      } catch {
        return nil
      }
    }
    let originalName = url.lastPathComponent
    let fallbackName = "incoming_\(Int(Date().timeIntervalSince1970 * 1000))"
    let safeName = originalName.isEmpty ? fallbackName : originalName
    let targetUrl = incomingDir.appendingPathComponent("\(UUID().uuidString)_\(safeName)")
    do {
      if fileManager.fileExists(atPath: targetUrl.path) {
        try fileManager.removeItem(at: targetUrl)
      }
      try fileManager.copyItem(at: url, to: targetUrl)
      return targetUrl.path
    } catch {
      return nil
    }
  }

  private func getYtDlpBinaryStatus() -> [String: Any?] {
    let fileManager = FileManager.default
    let ytDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("yt_dlp", isDirectory: true)
    let ytDlpPath = ytDir?.appendingPathComponent("yt-dlp").path
    let ffmpegPath = ytDir?.appendingPathComponent("ffmpeg").path
    let ytReady = ytDlpPath != nil && fileManager.fileExists(atPath: ytDlpPath!)
    let ffmpegReady = ffmpegPath != nil && fileManager.fileExists(atPath: ffmpegPath!)
    return [
      "ytDlpReady": ytReady,
      "ffmpegReady": ffmpegReady,
      "ytDlpVersion": nil,
      "ffmpegVersion": nil,
      "ytDlpPath": ytReady ? ytDlpPath : nil,
      "ffmpegPath": ffmpegReady ? ffmpegPath : nil,
    ]
  }

  private func importYoutubeCookies(_ filePath: String?) -> String? {
    guard let filePath = filePath, !filePath.isEmpty else { return nil }
    let sourceUrl = URL(fileURLWithPath: filePath)
    let fileManager = FileManager.default
    guard let baseDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return nil
    }
    let targetDir = baseDir.appendingPathComponent("yt_dlp/cookies", isDirectory: true)
    do {
      if !fileManager.fileExists(atPath: targetDir.path) {
        try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
      }
      let targetUrl = targetDir.appendingPathComponent("cookies.txt")
      if fileManager.fileExists(atPath: targetUrl.path) {
        try fileManager.removeItem(at: targetUrl)
      }
      try fileManager.copyItem(at: sourceUrl, to: targetUrl)
      return targetUrl.path
    } catch {
      return nil
    }
  }

  private func saveYoutubeSessionConfig(_ config: Any?) {
    guard let config else { return }
    guard JSONSerialization.isValidJSONObject(config) else { return }
    do {
      let data = try JSONSerialization.data(withJSONObject: config, options: [])
      UserDefaults.standard.set(data, forKey: "yt_dlp_session_config_raw")
    } catch {
    }
  }

  private func loadYoutubeSessionConfig() -> [String: Any]? {
    guard let data = UserDefaults.standard.data(forKey: "yt_dlp_session_config_raw") else {
      return nil
    }
    do {
      return try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    } catch {
      return nil
    }
  }
}

private final class _YtDlpStreamProxy: NSObject, FlutterStreamHandler {
  weak var owner: AppDelegate?

  init(owner: AppDelegate) {
    self.owner = owner
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    owner?.ytDlpEventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    owner?.ytDlpEventSink = nil
    return nil
  }
}
