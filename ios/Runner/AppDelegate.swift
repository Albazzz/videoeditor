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
