import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    installCrashLog()
    return launched
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "VsubNet") {
      installNetChannel(registrar.messenger())
    }
  }
}

// MARK: - Downloads through iOS's own network stack
//
// Some video servers reset any connection whose TLS handshake does not look
// like Safari's; Dart's HTTP client and ffmpeg both were. URLSession goes
// through the same system stack as the web view. Dart side: lib/services/net.dart.

private let netSession: URLSession = {
  let config = URLSessionConfiguration.default
  // The page's cookies arrive as a header; the shared store must not
  // replace them.
  config.httpShouldSetCookies = false
  config.httpCookieStorage = nil
  config.urlCache = nil
  config.timeoutIntervalForRequest = 30
  return URLSession(configuration: config)
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
    netSession.dataTask(with: request) { data, response, error in
      DispatchQueue.main.async {
        if let error = error {
          result(FlutterError(code: "net", message: error.localizedDescription, details: nil))
          return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        result(["status": status, "body": FlutterStandardTypedData(bytes: data ?? Data())])
      }
    }.resume()
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
    var text = "\n\(Date()) NSException \(exception.name.rawValue): \(exception.reason ?? "")\n"
    if let info = exception.userInfo, !info.isEmpty {
      text += "userInfo: \(info)\n"
    }
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
