import Cocoa
import FlutterMacOS
import Darwin

private struct MacYtDlpChannelError: Error {
  let code: String
  let message: String
  let details: Any?

  var flutterError: FlutterError {
    FlutterError(code: code, message: message, details: details)
  }
}

@main
class AppDelegate: FlutterAppDelegate {
  private let resolveTimeoutSeconds: TimeInterval = 90
  private let ytDlpChannelName = "com.example.video_player_app/yt_dlp"
  private let ytDlpEventChannelName = "com.example.video_player_app/yt_dlp_events"
  private let ytDlpQueue = DispatchQueue(label: "com.example.video_player_app.macos.yt_dlp")
  fileprivate var ytDlpEventSink: FlutterEventSink?
  private var ytDlpTasks: [String: MacYtDlpTask] = [:]
  private var configuredYtDlpPath: String?
  private var configuredFfmpegPath: String?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      registerYtDlpChannels(controller: controller)
    }
    super.applicationDidFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  private func registerYtDlpChannels(controller: FlutterViewController) {
    let methodChannel = FlutterMethodChannel(
      name: ytDlpChannelName,
      binaryMessenger: controller.engine.binaryMessenger
    )
    methodChannel.setMethodCallHandler {
      [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "configureYtDlpBinaryPaths":
        let args = call.arguments as? [String: Any]
        self.configuredYtDlpPath = (args?["ytDlpPath"] as? String)?.nilIfEmpty
        self.configuredFfmpegPath = (args?["ffmpegPath"] as? String)?.nilIfEmpty
        result(
          self.configuredYtDlpPath.map {
            FileManager.default.isExecutableFile(atPath: $0)
          } ?? false
        )
      case "getYtDlpBinaryStatus":
        self.ytDlpQueue.async { [weak self] in
          guard let self else { return }
          let status = self.getYtDlpBinaryStatus()
          DispatchQueue.main.async {
            result(status)
          }
        }
      case "importYoutubeCookies":
        let args = call.arguments as? [String: Any]
        result(self.importYoutubeCookies(args?["filePath"] as? String))
      case "saveYoutubeSessionConfig":
        let args = call.arguments as? [String: Any]
        self.saveYoutubeSessionConfig(args?["config"])
        result(true)
      case "loadYoutubeSessionConfig":
        result(self.loadYoutubeSessionConfig())
      case "resolveYoutubeMeta":
        let args = call.arguments as? [String: Any]
        self.ytDlpQueue.async { [weak self] in
          guard let self else { return }
          do {
            let payload = try self.resolveYoutubeMeta(args)
            DispatchQueue.main.async {
              result(payload)
            }
          } catch let error as MacYtDlpChannelError {
            DispatchQueue.main.async {
              result(error.flutterError)
            }
          } catch {
            DispatchQueue.main.async {
              result(
                FlutterError(
                  code: "YT_DLP_RESOLVE_FAILED",
                  message: error.localizedDescription,
                  details: nil
                )
              )
            }
          }
        }
      case "startYoutubeDownload":
        let args = call.arguments as? [String: Any]
        do {
          result(try self.startYoutubeDownload(args))
        } catch let error as MacYtDlpChannelError {
          result(error.flutterError)
        } catch {
          result(
            FlutterError(
              code: "YT_DLP_START_FAILED",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      case "pauseYoutubeDownload":
        let args = call.arguments as? [String: Any]
        let stopped = self.pauseYoutubeDownload(args?["taskId"] as? String)
        let response: [String: Any] = [
          "accepted": stopped,
          "stopped": stopped,
          "reason": stopped ? NSNull() : "running task not found",
        ]
        result(response)
      case "cancelYoutubeDownload":
        let args = call.arguments as? [String: Any]
        result(self.cancelYoutubeDownload(args?["taskId"] as? String))
      case "removeYoutubeTask":
        let args = call.arguments as? [String: Any]
        result(self.removeYoutubeTask(args?["taskId"] as? String))
      case "getYoutubeTaskStatus":
        let args = call.arguments as? [String: Any]
        result(self.getYoutubeTaskStatus(args?["taskId"] as? String))
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let eventChannel = FlutterEventChannel(
      name: ytDlpEventChannelName,
      binaryMessenger: controller.engine.binaryMessenger
    )
    eventChannel.setStreamHandler(_MacYtDlpStreamProxy(owner: self))
  }

  private func getYtDlpBinaryStatus() -> [String: Any?] {
    let ytDlpPath = findExecutable(candidates: ["yt-dlp", "resources/yt-dlp"])
    let ffmpegPath = findExecutable(candidates: ["ffmpeg", "resources/ffmpeg"])
    let diagnosticMessage = """
      macOS search roots:
      - \(Bundle.main.executableURL?.deletingLastPathComponent().path ?? "n/a")
      - \(Bundle.main.resourceURL?.path ?? "n/a")
      - \(appSupportDirectory().appendingPathComponent("yt_dlp", isDirectory: true).path)
      """
    let ytVersion = ytDlpPath.flatMap { path -> String? in
      guard let output = try? runProcess(executable: path, arguments: ["--version"]).stdoutText else {
        return nil
      }
      return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let ffmpegVersion = ffmpegPath.flatMap { path -> String? in
      let output = try? runProcess(executable: path, arguments: ["-version"]).stdoutText
      return output?
        .components(separatedBy: .newlines)
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return [
      "ytDlpReady": ytDlpPath != nil,
      "ffmpegReady": ffmpegPath != nil,
      "ytDlpVersion": ytVersion,
      "ffmpegVersion": ffmpegVersion,
      "ytDlpPath": ytDlpPath,
      "ffmpegPath": ffmpegPath,
      "diagnosticMessage": diagnosticMessage,
    ]
  }

  private func importYoutubeCookies(_ filePath: String?) -> String? {
    guard let filePath, !filePath.isEmpty else { return nil }
    let sourceUrl = URL(fileURLWithPath: filePath)
    let targetDir = appSupportDirectory().appendingPathComponent("yt_dlp/cookies", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
      let targetUrl = targetDir.appendingPathComponent("cookies.txt")
      if FileManager.default.fileExists(atPath: targetUrl.path) {
        try FileManager.default.removeItem(at: targetUrl)
      }
      try FileManager.default.copyItem(at: sourceUrl, to: targetUrl)
      return targetUrl.path
    } catch {
      return nil
    }
  }

  private func saveYoutubeSessionConfig(_ config: Any?) {
    guard let config, JSONSerialization.isValidJSONObject(config) else { return }
    if let data = try? JSONSerialization.data(withJSONObject: config, options: []) {
      UserDefaults.standard.set(data, forKey: "yt_dlp_session_config_raw")
    }
  }

  private func loadYoutubeSessionConfig() -> [String: Any]? {
    guard let data = UserDefaults.standard.data(forKey: "yt_dlp_session_config_raw") else {
      return nil
    }
    return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
  }

  private func resolveYoutubeMeta(_ args: [String: Any]?) throws -> [String: Any] {
    guard let url = args?["url"] as? String, !url.isEmpty else {
      throw MacYtDlpChannelError(code: "INVALID_ARGS", message: "missing url", details: nil)
    }
    guard let ytDlpPath = findExecutable(candidates: ["yt-dlp", "resources/yt-dlp"]) else {
      throw MacYtDlpChannelError(
        code: "YT_DLP_NOT_FOUND",
        message: "yt-dlp executable not found",
        details: nil
      )
    }
    let sessionConfig = args?["sessionConfig"] as? [String: Any]
    var commandArgs = buildSessionArgs(sessionConfig)
    commandArgs.append(contentsOf: ["--dump-single-json", "--no-warnings", url])
    let result = try runProcess(
      executable: ytDlpPath,
      arguments: commandArgs,
      timeout: resolveTimeoutSeconds
    )
    guard result.exitCode == 0 else {
      throw MacYtDlpChannelError(
        code: "YT_DLP_RESOLVE_FAILED",
        message: result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? (result.timedOut ? "yt-dlp resolve timed out" : "yt-dlp resolve failed"),
        details: nil
      )
    }
    return ["rawInfoJson": result.stdoutText]
  }

  private func startYoutubeDownload(_ args: [String: Any]?) throws -> Bool {
    guard
      let args,
      let taskId = args["taskId"] as? String,
      !taskId.isEmpty,
      let outputDir = args["outputDir"] as? String,
      !outputDir.isEmpty,
      let rawArgs = args["args"] as? [String],
      !rawArgs.isEmpty
    else {
      throw MacYtDlpChannelError(
        code: "INVALID_ARGS",
        message: "missing download request",
        details: nil
      )
    }
    guard let ytDlpPath = findExecutable(candidates: ["yt-dlp", "resources/yt-dlp"]) else {
      throw MacYtDlpChannelError(
        code: "YT_DLP_NOT_FOUND",
        message: "yt-dlp executable not found",
        details: nil
      )
    }

    let outputUrl = URL(fileURLWithPath: outputDir, isDirectory: true)
    try FileManager.default.createDirectory(at: outputUrl, withIntermediateDirectories: true)

    var commandArgs: [String] = []
    if let ffmpegPath = findExecutable(candidates: ["ffmpeg", "resources/ffmpeg"]) {
      commandArgs.append(contentsOf: ["--ffmpeg-location", ffmpegPath])
    }
    commandArgs.append(contentsOf: rawArgs)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: ytDlpPath)
    process.arguments = commandArgs
    process.currentDirectoryURL = outputUrl

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    let task = MacYtDlpTask(
      taskId: taskId,
      outputDir: outputUrl,
      outputTemplate: (args["outputTemplate"] as? String) ?? "%(title)s.%(ext)s",
      process: process,
      pipe: pipe
    )

    ytDlpQueue.sync {
      if let existing = ytDlpTasks[taskId] {
        existing.terminationReason = "cancel"
        terminateProcessTree(existing.process)
      }
      ytDlpTasks[taskId] = task
    }

    pipe.fileHandleForReading.readabilityHandler = { [weak self, weak task] handle in
      guard let self, let task else { return }
      let data = handle.availableData
      if data.isEmpty { return }
      let chunk = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
      self.handleYtDlpChunk(task: task, chunk: chunk)
    }

    process.terminationHandler = { [weak self, weak task] process in
      guard let self, let task else { return }
      task.pipe.fileHandleForReading.readabilityHandler = nil
      self.finishYtDlpTask(task: task, exitCode: process.terminationStatus)
    }

    try process.run()

    emitYtDlpEvent([
      "taskId": taskId,
      "type": "task_queued",
      "message": "Queued",
    ])
    ytDlpQueue.sync {
      task.status = "downloading"
      task.message = "Starting"
    }
    emitYtDlpEvent([
      "taskId": taskId,
      "type": "task_started",
      "progress": 0.0,
      "message": "Starting",
    ])
    return true
  }

  private func pauseYoutubeDownload(_ taskId: String?) -> Bool {
    guard let taskId else { return false }
    var process: Process?
    ytDlpQueue.sync {
      if let task = ytDlpTasks[taskId] {
        task.terminationReason = "pause"
        task.status = "paused"
        task.message = "Paused"
        process = task.process
      }
    }
    if let process {
      terminateProcessTree(process)
    }
    return process != nil
  }

  private func cancelYoutubeDownload(_ taskId: String?) -> Bool {
    guard let taskId else { return false }
    var process: Process?
    ytDlpQueue.sync {
      if let task = ytDlpTasks[taskId] {
        task.terminationReason = "cancel"
        task.status = "cancelled"
        task.message = "Cancelled"
        process = task.process
      }
    }
    if let process {
      terminateProcessTree(process)
    }
    return process != nil
  }

  private func removeYoutubeTask(_ taskId: String?) -> Bool {
    guard let taskId else { return false }
    var process: Process?
    ytDlpQueue.sync {
      if let task = ytDlpTasks[taskId] {
        task.terminationReason = "cancel"
        task.status = "cancelled"
        task.message = "Removed"
        process = task.process
      }
    }
    if let process {
      terminateProcessTree(process)
    }
    // Task removal must never unlink final media. The file may already be the
    // source of a media-library card. Flutter cleans task-scoped temp files.
    return true
  }

  private func getYoutubeTaskStatus(_ taskId: String?) -> [String: Any]? {
    guard let taskId else { return nil }
    return ytDlpQueue.sync {
      guard let task = ytDlpTasks[taskId] else { return nil }
      return [
        "taskId": task.taskId,
        "status": task.status,
        "progress": task.progress,
        "speedText": task.speedText,
        "etaText": task.etaText,
        "outputPath": task.outputPath,
        "producedPaths": task.producedPaths,
        "message": task.message,
        "errorCode": task.errorCode,
      ]
    }
  }

  private func handleYtDlpChunk(task: MacYtDlpTask, chunk: String) {
    var lines: [String] = []
    ytDlpQueue.sync {
      task.pendingBuffer.append(chunk)
      let split = task.pendingBuffer.components(separatedBy: .newlines)
      if split.count > 1 {
        lines = Array(split.dropLast())
        task.pendingBuffer = split.last ?? ""
      }
    }
    for line in lines {
      handleYtDlpLine(task: task, line: line)
    }
  }

  private func handleYtDlpLine(task: MacYtDlpTask, line: String) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    var eventPayload: [String: Any]?
    ytDlpQueue.sync {
      if task.logTail.count >= 12 {
        task.logTail.removeFirst()
      }
      task.logTail.append(trimmed)

      func registerOutputPath(_ rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).unquoted.nilIfEmpty
        guard let value else { return }
        task.outputPath = value
        if !task.producedPaths.contains(value) {
          task.producedPaths.append(value)
        }
      }

      for marker in ["Destination:", "Merging formats into", "[ExtractAudio] Destination:"] {
        if let range = trimmed.range(of: marker) {
          registerOutputPath(String(trimmed[range.upperBound...]))
        }
      }

      if let path = markerOutputPath("__YTDLP_BEFORE_DL__:", from: trimmed) {
        registerOutputPath(path)
        eventPayload = [
          "taskId": task.taskId,
          "type": "task_step",
          "progress": task.progress,
          "speedText": task.speedText,
          "etaText": task.etaText,
          "outputPath": task.outputPath,
          "producedPaths": task.producedPaths,
          "message": "Preparing output",
        ]
        task.status = "downloading"
        task.message = "Preparing output"
        return
      }

      if let path = markerOutputPath("__YTDLP_AFTER_MOVE__:", from: trimmed) {
        registerOutputPath(path)
        eventPayload = [
          "taskId": task.taskId,
          "type": "task_step",
          "progress": task.progress,
          "speedText": task.speedText,
          "etaText": task.etaText,
          "outputPath": task.outputPath,
          "producedPaths": task.producedPaths,
          "message": "Finalizing file",
        ]
        task.status = "post_processing"
        task.message = "Finalizing file"
        return
      }

      if trimmed.hasPrefix("ERROR:") {
        task.message = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        task.errorCode = "YT_DLP_ERROR"
        return
      }

      if trimmed.contains("[Merger]") ||
        trimmed.contains("[ExtractAudio]") ||
        trimmed.contains("Merging formats into") ||
        trimmed.contains("Deleting original file") ||
        trimmed.contains("Post-process")
      {
        task.status = "post_processing"
        task.message = trimmed
        eventPayload = [
          "taskId": task.taskId,
          "type": "task_post_processing",
          "progress": task.progress,
          "speedText": task.speedText,
          "etaText": task.etaText,
          "outputPath": task.outputPath,
          "producedPaths": task.producedPaths,
          "message": trimmed,
        ]
        return
      }

      if trimmed.hasPrefix("[download]") {
        if let progressValue = firstRegexMatch(pattern: #"(\d+(?:\.\d+)?)%"#, text: trimmed),
           let progress = Double(progressValue) {
          task.progress = min(1.0, max(0.0, progress / 100.0))
        }
        if let speed = firstRegexMatch(pattern: #"\bat\s+(.+?)\s+ETA\b"#, text: trimmed) {
          task.speedText = speed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let eta = firstRegexMatch(pattern: #"\bETA\s+([0-9:]+)"#, text: trimmed) {
          task.etaText = eta.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        task.status = "downloading"
        task.message = "Downloading"
        eventPayload = [
          "taskId": task.taskId,
          "type": "task_progress",
          "progress": task.progress,
          "speedText": task.speedText,
          "etaText": task.etaText,
          "outputPath": task.outputPath,
          "producedPaths": task.producedPaths,
          "message": task.message,
        ]
      }
    }
    if let eventPayload {
      emitYtDlpEvent(eventPayload)
    }
  }

  private func finishYtDlpTask(task: MacYtDlpTask, exitCode: Int32) {
    var pendingLine: String?
    ytDlpQueue.sync {
      if !task.pendingBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        pendingLine = task.pendingBuffer
        task.pendingBuffer.removeAll()
      }
    }
    if let pendingLine {
      handleYtDlpLine(task: task, line: pendingLine)
    }

    var payload: [String: Any]?
    ytDlpQueue.sync {
      defer {
        ytDlpTasks.removeValue(forKey: task.taskId)
      }
      if task.terminationReason == "pause" {
        task.status = "paused"
        payload = [
          "taskId": task.taskId,
          "type": "task_paused",
          "progress": task.progress,
          "speedText": task.speedText,
          "etaText": task.etaText,
          "outputPath": task.outputPath,
          "producedPaths": task.producedPaths,
          "message": task.message.isEmpty ? "Paused" : task.message,
        ]
        return
      }
      if task.terminationReason == "cancel" {
        task.status = "cancelled"
        payload = [
          "taskId": task.taskId,
          "type": "task_cancelled",
          "progress": task.progress,
          "speedText": task.speedText,
          "etaText": task.etaText,
          "outputPath": task.outputPath,
          "producedPaths": task.producedPaths,
          "errorCode": "USER_CANCELLED",
          "message": task.message.isEmpty ? "Cancelled" : task.message,
        ]
        return
      }
      if exitCode == 0 {
        let resolvedOutputPath = self.resolveFinalOutputPath(task)
        task.outputPath = resolvedOutputPath ?? task.outputPath
        if let resolvedOutputPath {
          task.status = "completed"
          task.progress = 1.0
          payload = [
            "taskId": task.taskId,
            "type": "task_completed",
            "progress": 1.0,
            "speedText": task.speedText,
            "etaText": "00:00",
            "outputPath": resolvedOutputPath,
            "producedPaths": task.producedPaths,
            "message": task.message.isEmpty ? "Completed" : task.message,
          ]
        } else {
          task.status = "failed"
          task.errorCode = "NO_OUTPUT_FILE"
          payload = [
            "taskId": task.taskId,
            "type": "task_failed",
            "progress": task.progress,
            "speedText": task.speedText,
            "etaText": task.etaText,
            "outputPath": task.outputPath,
            "producedPaths": task.producedPaths,
            "errorCode": task.errorCode,
            "message": "yt-dlp exited successfully but no final output file was found",
          ]
        }
        return
      }
      task.status = "failed"
      task.errorCode = "EXIT_\(exitCode)"
      let tail = task.logTail.joined(separator: "\n")
      let message = task.message.isEmpty ? (tail.isEmpty ? "Download failed" : tail) : task.message
      payload = [
        "taskId": task.taskId,
        "type": "task_failed",
        "progress": task.progress,
        "speedText": task.speedText,
        "etaText": task.etaText,
        "outputPath": task.outputPath,
        "producedPaths": task.producedPaths,
        "errorCode": task.errorCode,
        "message": message,
      ]
    }
    if let payload {
      emitYtDlpEvent(payload)
    }
  }

  private func emitYtDlpEvent(_ payload: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.ytDlpEventSink?(payload)
    }
  }

  private func terminateProcessTree(_ process: Process) {
    let pid = process.processIdentifier
    guard pid > 0 else { return }

    // Terminate direct helper processes (notably ffmpeg) before their parent
    // can exit and they are re-parented.
    let childTerminator = Process()
    childTerminator.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    childTerminator.arguments = ["-TERM", "-P", String(pid)]
    try? childTerminator.run()
    process.terminate()

    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(150)) {
      guard process.isRunning else { return }
      let childKiller = Process()
      childKiller.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
      childKiller.arguments = ["-KILL", "-P", String(pid)]
      try? childKiller.run()
      kill(pid, SIGKILL)
    }
  }

  private func findExecutable(candidates: [String]) -> String? {
    let fileManager = FileManager.default
    let configuredPath = candidates.contains(where: { $0.hasPrefix("yt-dlp") })
      ? configuredYtDlpPath
      : configuredFfmpegPath
    if let configuredPath {
      return fileManager.isExecutableFile(atPath: configuredPath) ? configuredPath : nil
    }
    let appSupportYtDir = appSupportDirectory().appendingPathComponent("yt_dlp", isDirectory: true)
    let bundleResourceDir = Bundle.main.resourceURL
    let bundleExecutableDir = Bundle.main.executableURL?.deletingLastPathComponent()

    let searchRoots: [URL?] = [
      appSupportYtDir,
      bundleExecutableDir,
      bundleResourceDir?.appendingPathComponent("yt_dlp", isDirectory: true),
      bundleResourceDir,
    ]
    for root in searchRoots {
      guard let root else { continue }
      for candidate in candidates {
        let path = root.appendingPathComponent(candidate).path
        if fileManager.isExecutableFile(atPath: path) {
          return path
        }
      }
    }

    let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for directory in envPath.split(separator: ":") {
      let base = String(directory)
      for candidate in candidates {
        let path = URL(fileURLWithPath: base).appendingPathComponent(candidate).path
        if fileManager.isExecutableFile(atPath: path) {
          return path
        }
      }
    }
    return nil
  }

  private func runProcess(
    executable: String,
    arguments: [String],
    timeout: TimeInterval? = nil
  ) throws -> (exitCode: Int32, stdoutText: String, stderrText: String, timedOut: Bool) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    try process.run()
    var timedOut = false
    if let timeout {
      let deadline = Date().addingTimeInterval(timeout)
      while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
      }
      if process.isRunning {
        timedOut = true
        process.terminate()
        process.waitUntilExit()
      }
    } else {
      process.waitUntilExit()
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    return (
      process.terminationStatus,
      output,
      process.terminationStatus == 0 && !timedOut ? "" : output,
      timedOut
    )
  }

  private func buildSessionArgs(_ sessionConfig: [String: Any]?) -> [String] {
    guard let sessionConfig else { return [] }
    var args: [String] = []

    func boolValue(_ key: String) -> Bool {
      sessionConfig[key] as? Bool ?? false
    }

    func stringValue(_ key: String) -> String? {
      (sessionConfig[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    func intValue(_ key: String) -> Int? {
      if let value = sessionConfig[key] as? Int {
        return value
      }
      if let value = sessionConfig[key] as? NSNumber {
        return value.intValue
      }
      return nil
    }

    if boolValue("useCookies"), let cookiesPath = stringValue("cookiesFilePath") {
      args.append(contentsOf: ["--cookies", cookiesPath])
    }
    if boolValue("useCustomUserAgent"), let userAgent = stringValue("userAgent") {
      args.append(contentsOf: ["--add-header", "User-Agent:\(userAgent)"])
    }
    if boolValue("useProxy"), let proxy = stringValue("proxy") {
      args.append(contentsOf: ["--proxy", proxy])
    }
    if let timeout = intValue("socketTimeoutSeconds"), timeout > 0 {
      args.append(contentsOf: ["--socket-timeout", "\(timeout)"])
    }
    if let retries = intValue("retries"), retries > 0 {
      args.append(contentsOf: ["--retries", "\(retries)"])
    }
    if let fragmentRetries = intValue("fragmentRetries"), fragmentRetries > 0 {
      args.append(contentsOf: ["--fragment-retries", "\(fragmentRetries)"])
    }
    if let concurrentFragments = intValue("concurrentFragments"), concurrentFragments > 0 {
      args.append(contentsOf: ["-N", "\(concurrentFragments)"])
    }
    if let rateLimit = stringValue("rateLimit") {
      args.append(contentsOf: ["-r", rateLimit])
    }
    if boolValue("forceIpv4") {
      args.append("-4")
    }
    let extractorParts = buildYoutubeExtractorParts(sessionConfig)
    if !extractorParts.isEmpty {
      args.append(contentsOf: ["--extractor-args", "youtube:\(extractorParts.joined(separator: ";"))"])
    }
    return args
  }

  private func buildYoutubeExtractorParts(_ sessionConfig: [String: Any]) -> [String] {
    var parts: [String] = []
    let clients = (sessionConfig["enabledPlayerClients"] as? [Any] ?? [])
      .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    if !clients.isEmpty {
      parts.append("player_client=\(Array(Set(clients)).joined(separator: ","))")
    }
    if let visitorData = (sessionConfig["visitorData"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
      parts.append("visitor_data=\(visitorData)")
    }
    let poTokens = (sessionConfig["poTokens"] as? [[String: Any]] ?? [])
      .filter { ($0["enabled"] as? Bool) != false }
      .compactMap { token -> String? in
        guard
          let client = (token["client"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
          let context = (token["context"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
          let value = (token["token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else {
          return nil
        }
        return "\(client).\(context)+\(value)"
      }
    if !poTokens.isEmpty {
      parts.append("po_token=\(poTokens.joined(separator: ","))")
    }
    return parts
  }

  private func markerOutputPath(_ marker: String, from line: String) -> String? {
    guard let range = line.range(of: marker) else { return nil }
    return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines).unquoted.nilIfEmpty
  }

  private func resolveFinalOutputPath(_ task: MacYtDlpTask) -> String? {
    let candidates = [task.outputPath] + task.producedPaths
    for candidate in candidates {
      guard let candidate = candidate.nilIfEmpty else { continue }
      let url = URL(fileURLWithPath: candidate)
      guard FileManager.default.fileExists(atPath: url.path), !url.isTemporaryYtDlpArtifact else {
        continue
      }
      if !url.isSubtitleSidecar {
        return candidate
      }
    }
    for candidate in candidates {
      guard let candidate = candidate.nilIfEmpty else { continue }
      let url = URL(fileURLWithPath: candidate)
      guard FileManager.default.fileExists(atPath: url.path), !url.isTemporaryYtDlpArtifact else {
        continue
      }
      return candidate
    }
    return nil
  }

  private func firstRegexMatch(pattern: String, text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard
      let match = regex.firstMatch(in: text, options: [], range: range),
      match.numberOfRanges > 1,
      let captureRange = Range(match.range(at: 1), in: text)
    else {
      return nil
    }
    return String(text[captureRange])
  }

  private func appSupportDirectory() -> URL {
    let fileManager = FileManager.default
    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    return base.appendingPathComponent("video_player_app", isDirectory: true)
  }
}

private final class _MacYtDlpStreamProxy: NSObject, FlutterStreamHandler {
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

private final class MacYtDlpTask {
  let taskId: String
  let outputDir: URL
  let outputTemplate: String
  let process: Process
  let pipe: Pipe
  var status = "queued"
  var progress = 0.0
  var speedText = ""
  var etaText = ""
  var outputPath = ""
  var producedPaths: [String] = []
  var errorCode = ""
  var message = ""
  var terminationReason = ""
  var pendingBuffer = ""
  var logTail: [String] = []

  init(taskId: String, outputDir: URL, outputTemplate: String, process: Process, pipe: Pipe) {
    self.taskId = taskId
    self.outputDir = outputDir
    self.outputTemplate = outputTemplate
    self.process = process
    self.pipe = pipe
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }

  var unquoted: String {
    guard count >= 2, hasPrefix("\""), hasSuffix("\"") else { return self }
    return String(dropFirst().dropLast())
  }
}

private extension URL {
  var isTemporaryYtDlpArtifact: Bool {
    let ext = pathExtension.lowercased()
    return ext == "part" || ext == "ytdl" || ext == "tmp"
  }

  var isSubtitleSidecar: Bool {
    let ext = pathExtension.lowercased()
    return ["srt", "ass", "ssa", "vtt", "lrc", "json3", "srv1", "srv2", "srv3", "ttml"]
      .contains(ext)
  }
}
