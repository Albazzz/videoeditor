import Flutter
import UIKit
import BackgroundTasks

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    registerSubtitleProgress()
    installCrashLog()
    installPrivacyCover()
    return launched
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "VsubSubtitleProgress") {
      installSubtitleProgressChannel(registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "VsubNet") {
      installNetChannel(registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "VsubPrivateAudio") {
      installPrivateAudioChannel(registrar.messenger())
    }
  }
}

private var subtitleProgressChannel: FlutterMethodChannel?
#if compiler(>=6.2)
private var subtitleProgressTask: AnyObject?
#endif

private func registerSubtitleProgress() {
  #if compiler(>=6.2)
  if #available(iOS 26.0, *) {
    subtitleProgressTask = ContinuedSubtitleProgress()
  }
  #endif
}

private func installSubtitleProgressChannel(_ messenger: FlutterBinaryMessenger) {
  let channel = FlutterMethodChannel(name: "vsub/subtitle_progress", binaryMessenger: messenger)
  subtitleProgressChannel = channel
  channel.setMethodCallHandler { call, result in
    if call.method == "opened" { result(false); return }
    guard call.method == "update", let counts = call.arguments as? [String: Any] else {
      result(FlutterMethodNotImplemented); return
    }
    #if compiler(>=6.2)
    if #available(iOS 26.0, *), let task = subtitleProgressTask as? ContinuedSubtitleProgress {
      do { try task.update(counts); result(nil) }
      catch { result(FlutterError(code: "subtitle_progress", message: "iOS chưa cho phép hiển thị tiến trình nền", details: nil)) }
      return
    }
    #endif
    // Earlier iOS versions keep the anonymous progress bar inside the app.
    result(nil)
  }
}

#if compiler(>=6.2)
@available(iOS 26.0, *)
private final class ContinuedSubtitleProgress {
  private let identifier = (Bundle.main.bundleIdentifier ?? "com.example.video") + ".subtitles.*"
  private var submitted: String?
  private var task: BGContinuedProcessingTask?
  private var completed = 0, total = 0, progress = 0
  private var active = false
  private var registered = false
  private var label: String { "\(completed)/\(total) hoàn thành" }

  init() {
    registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] received in
      guard let self, let received = received as? BGContinuedProcessingTask else {
        received.setTaskCompleted(success: false); return
      }
      guard self.active, self.submitted == received.identifier else {
        received.setTaskCompleted(success: self.total > 0 && self.completed == self.total); return
      }
      self.task = received
      received.expirationHandler = { [weak self, weak received] in
        DispatchQueue.main.async {
          guard let self, let received, self.task === received else { return }
          received.setTaskCompleted(success: false)
          self.task = nil
          self.submitted = nil
          self.active = false
          subtitleProgressChannel?.invokeMethod("cancel", arguments: nil)
        }
      }
      self.refresh()
    }
  }

  func update(_ counts: [String: Any]) throws {
    total = max(0, counts["total"] as? Int ?? 0)
    completed = min(total, max(0, counts["completed"] as? Int ?? 0))
    progress = min(10000, max(0, counts["progress"] as? Int ?? 0))
    active = counts["active"] as? Bool == true && total > 0
    if !active {
      task?.updateTitle("Sub", subtitle: label)
      if total > 0 && completed == total { task?.progress.completedUnitCount = 10000 }
      task?.setTaskCompleted(success: total > 0 && completed == total)
      task = nil
      if let submitted { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: submitted) }
      submitted = nil
      return
    }
    if task != nil { refresh(); return }
    if submitted != nil || UIApplication.shared.applicationState != .active { return }
    guard registered else { throw NSError(domain: "subtitle_progress", code: 1) }
    let job = String(identifier.dropLast()) + UUID().uuidString
    let request = BGContinuedProcessingTaskRequest(identifier: job, title: "Sub", subtitle: label)
    request.strategy = .fail
    submitted = job
    do { try BGTaskScheduler.shared.submit(request) }
    catch { submitted = nil; throw error }
  }

  private func refresh() {
    task?.progress.totalUnitCount = 10000
    task?.progress.completedUnitCount = Int64(min(progress, 9999))
    task?.updateTitle("Sub", subtitle: label)
  }
}
#endif

private func installPrivateAudioChannel(_ messenger: FlutterBinaryMessenger) {
  let channel = FlutterMethodChannel(name: "vsub/private_audio", binaryMessenger: messenger)
  channel.setMethodCallHandler { call, result in
    guard call.method == "directory" else { result(FlutterMethodNotImplemented); return }
    do {
      let manager = FileManager.default
      let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
      var directory = support.appendingPathComponent("retained_audio", isDirectory: true)
      try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
        .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        .posixPermissions: 0o700
      ])
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try directory.setResourceValues(values)
      result(directory.path)
    } catch {
      result(FlutterError(code: "private_audio", message: "Không mở được kho âm thanh riêng", details: nil))
    }
  }
}

// MARK: - Downloads through iOS's own network stack
//
// Some video servers reset any connection whose TLS handshake does not look
// like Safari's; Dart's HTTP client and ffmpeg both were. URLSession goes
// through the same system stack as the web view. Dart side: lib/services/net.dart.

private final class NetDownload {
  let result: FlutterResult
  let maxBytes: Int
  var data = Data()
  var response: HTTPURLResponse?
  var problem: String?

  init(result: @escaping FlutterResult, maxBytes: Int) {
    self.result = result
    self.maxBytes = maxBytes
  }
}

// Delegate callbacks and channel calls both run on the main queue, so the
// request map has one owner. Check limits before buffering movie data.
private final class NetDelegate: NSObject, URLSessionDataDelegate {
  var downloads: [Int: NetDownload] = [:]

  // Dart resolves redirects and scopes credentials before the next request.
  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let download = downloads[dataTask.taskIdentifier] else {
      completionHandler(.cancel)
      return
    }
    download.response = response as? HTTPURLResponse
    if response.expectedContentLength > Int64(download.maxBytes) {
      download.problem = "Máy chủ bỏ qua giới hạn tải từng phần"
      completionHandler(.cancel)
    } else {
      completionHandler(.allow)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard let download = downloads[dataTask.taskIdentifier] else { return }
    if download.data.count + data.count > download.maxBytes {
      download.problem = "Dữ liệu video vượt giới hạn tải từng phần"
      dataTask.cancel()
    } else {
      download.data.append(data)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let download = downloads.removeValue(forKey: task.taskIdentifier) else { return }
    if let problem = download.problem ?? error?.localizedDescription {
      download.result(FlutterError(code: "net", message: problem, details: nil))
      return
    }
    var headers: [String: String] = [:]
    for (name, value) in download.response?.allHeaderFields ?? [:] {
      headers[String(describing: name).lowercased()] = String(describing: value)
    }
    download.result([
      "status": download.response?.statusCode ?? 0,
      "body": FlutterStandardTypedData(bytes: download.data), "headers": headers,
    ])
  }
}

private let netDelegate = NetDelegate()
private let netSession: URLSession = {
  let config = URLSessionConfiguration.default
  // The page's cookies arrive as a header; the shared store must not
  // replace them.
  config.httpShouldSetCookies = false
  config.httpCookieStorage = nil
  config.urlCache = nil
  config.timeoutIntervalForRequest = 30
  return URLSession(configuration: config, delegate: netDelegate, delegateQueue: .main)
}()

/// Kept for the life of the app.
private var netChannel: FlutterMethodChannel?

private func installNetChannel(_ messenger: FlutterBinaryMessenger) {
  let channel = FlutterMethodChannel(name: "vsub/net", binaryMessenger: messenger)
  netChannel = channel
  channel.setMethodCallHandler { call, result in
    guard call.method == "get",
      let args = call.arguments as? [String: Any],
      let address = args["url"] as? String,
      let url = URL(string: address)
    else {
      result(FlutterMethodNotImplemented)
      return
    }
    var request = URLRequest(url: url)
    if let seconds = args["timeout"] as? Int {
      request.timeoutInterval = TimeInterval(seconds)
    }
    if let headers = args["headers"] as? [String: String] {
      for (name, value) in headers {
        request.setValue(value, forHTTPHeaderField: name)
      }
    }
    let task = netSession.dataTask(with: request)
    netDelegate.downloads[task.taskIdentifier] = NetDownload(
      result: result, maxBytes: (args["maxBytes"] as? Int) ?? 32 * 1024 * 1024)
    task.resume()
  }
}

// MARK: - Native crash log
//
// A crash in native code (ML Kit, onnxruntime, ffmpeg) kills the app before
// Dart can say anything. These handlers write what they can into
// Application Support/native_crash.log; the Dart side (app_log.dart) moves it
// into the app's log at the next launch.

/// The open log file; -1 until installed.
private var crashFd: Int32 = -1
/// Set aside up front: a signal handler must not allocate memory.
private let crashFrames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)
private let previousActions = UnsafeMutablePointer<sigaction>.allocate(capacity: 64)
private var previousExceptionHandler: (@convention(c) (NSException) -> Void)?

private func writeCrash(_ text: String) {
  guard crashFd >= 0 else { return }
  var copy = text
  copy.withUTF8 { buf in _ = write(crashFd, buf.baseAddress, buf.count) }
}

private func onCrashSignal(
  _ sig: Int32, _ info: UnsafeMutablePointer<__siginfo>?, _ context: UnsafeMutableRawPointer?
) {
  if crashFd >= 0 {
    let name: StaticString
    switch sig {
    case SIGABRT: name = "\nSIGNAL SIGABRT (abort)\n"
    case SIGSEGV: name = "\nSIGNAL SIGSEGV (bad memory access)\n"
    case SIGBUS: name = "\nSIGNAL SIGBUS (bad memory access)\n"
    case SIGILL: name = "\nSIGNAL SIGILL (illegal instruction)\n"
    case SIGFPE: name = "\nSIGNAL SIGFPE (arithmetic)\n"
    case SIGTRAP: name = "\nSIGNAL SIGTRAP (Swift error or assertion)\n"
    default: name = "\nSIGNAL\n"
    }
    name.withUTF8Buffer { buf in _ = write(crashFd, buf.baseAddress, buf.count) }
    let count = backtrace(crashFrames, 128)
    backtrace_symbols_fd(crashFrames, count, crashFd)
  }
  // Hand the signal back to whoever had it before (by default: the app
  // dies and iOS writes its own crash report).
  sigaction(sig, previousActions + Int(sig), nil)
}

// MARK: - Privacy cover
//
// iOS photographs the screen for the app switcher as the app leaves the
// foreground; the lock screen (Dart) comes too late for that picture, so
// films, pages and the hidden vault could show there. Cover the window as
// soon as the scene stops being active, uncover when it is active again.

private let privacyCoverTag = 0x5653_5542

private func installPrivacyCover() {
  let center = NotificationCenter.default
  _ = center.addObserver(
    forName: UIScene.willDeactivateNotification, object: nil, queue: .main
  ) { note in
    guard let scene = note.object as? UIWindowScene else { return }
    for window in scene.windows where window.viewWithTag(privacyCoverTag) == nil {
      let cover = UIView(frame: window.bounds)
      cover.tag = privacyCoverTag
      cover.backgroundColor = .black
      cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      window.addSubview(cover)
    }
  }
  _ = center.addObserver(
    forName: UIScene.didActivateNotification, object: nil, queue: .main
  ) { note in
    guard let scene = note.object as? UIWindowScene else { return }
    for window in scene.windows {
      window.viewWithTag(privacyCoverTag)?.removeFromSuperview()
    }
  }
}

private func installCrashLog() {
  guard
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first
  else { return }
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  crashFd = open(
    dir.appendingPathComponent("native_crash.log").path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
  guard crashFd >= 0 else { return }

  previousExceptionHandler = NSGetUncaughtExceptionHandler()
  NSSetUncaughtExceptionHandler { exception in
    // The reason says what broke (the app cleans links and keys out of it
    // when moving it into its log); userInfo can hold request data, so no.
    let reason = String((exception.reason ?? "").prefix(300))
    var text = "\n\(Date()) NSException \(exception.name.rawValue): \(reason)\n"
    text += exception.callStackSymbols.prefix(60).joined(separator: "\n") + "\n"
    writeCrash(text)
    previousExceptionHandler?(exception)
  }

  for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
    var action = sigaction()
    action.__sigaction_u.__sa_sigaction = onCrashSignal
    action.sa_flags = SA_SIGINFO
    action.sa_mask = 0
    sigaction(sig, &action, previousActions + Int(sig))
  }
}
