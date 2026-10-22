import DeviceCheck
import Flutter
import UIKit

/// The `catzconnect/attest` method channel for Catz Connect app keys.
///
/// - `info` → platform, Simulator flag, `DCAppAttestService.shared.isSupported`.
/// - `read` / `write` / `remove` → small non-secret values (device id, App
///   Attest key id) in `UserDefaults.standard` under `com.catzconnect.sdk.attest.`.
/// - `generateKey` → `DCAppAttestService.shared.generateKey` (key id).
/// - `attestKey {keyId, clientDataHash}` → `attestKey(_:clientDataHash:)`.
/// - `generateAssertion {keyId, clientDataHash}` → `generateAssertion(_:clientDataHash:)`.
///
/// The client data hash (SHA-256 of the server's challenge) is computed in
/// Dart. Errors are `FlutterError(code: <reason>)`, reason `app_attest_<DCError>`.
/// Nothing runs until Dart calls the channel, so apps that only use server
/// keys are not affected.
public final class CatzConnectPlugin: NSObject, FlutterPlugin {
  private static let channelName = "catzconnect/attest"
  private static let storePrefix = "com.catzconnect.sdk.attest."

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
    let instance = CatzConnectPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "info":
      let info: [String: Any] = [
        "platform": "ios",
        "emulator": CatzConnectPlugin.isSimulator,
        "appAttestSupported": CatzConnectPlugin.appAttestSupported,
        "osVersion": UIDevice.current.systemVersion,
      ]
      result(info)
    case "read":
      guard let key = args["key"] as? String, !key.isEmpty else {
        result(FlutterError(code: "bad_arguments", message: "Missing key", details: nil))
        return
      }
      result(UserDefaults.standard.string(forKey: CatzConnectPlugin.storePrefix + key))
    case "write":
      guard let key = args["key"] as? String, !key.isEmpty, let value = args["value"] as? String else {
        result(FlutterError(code: "bad_arguments", message: "Missing key or value", details: nil))
        return
      }
      UserDefaults.standard.set(value, forKey: CatzConnectPlugin.storePrefix + key)
      result(nil)
    case "remove":
      guard let key = args["key"] as? String, !key.isEmpty else {
        result(FlutterError(code: "bad_arguments", message: "Missing key", details: nil))
        return
      }
      UserDefaults.standard.removeObject(forKey: CatzConnectPlugin.storePrefix + key)
      result(nil)
    case "generateKey":
      generateKey(result: result)
    case "attestKey":
      attestKey(args: args, result: result)
    case "generateAssertion":
      generateAssertion(args: args, result: result)
    case "requestIntegrityToken":
      result(FlutterError(code: "unsupported_platform", message: "Play Integrity is available on Android only.",
                          details: nil))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Device

  private static var isSimulator: Bool {
    #if targetEnvironment(simulator)
      return true
    #else
      return false
    #endif
  }

  private static var appAttestSupported: Bool {
    if #available(iOS 14.0, *) {
      return DCAppAttestService.shared.isSupported
    }
    return false
  }

  private static func unsupported(_ result: @escaping FlutterResult) {
    result(FlutterError(
      code: "app_attest_unsupported",
      message: "App Attest needs iOS 14 or later on a real device (it is not available in the Simulator "
        + "or in some app extensions).",
      details: nil))
  }

  private static func reply(_ result: @escaping FlutterResult, _ value: Any?) {
    DispatchQueue.main.async { result(value) }
  }

  // MARK: - App Attest

  private func generateKey(result: @escaping FlutterResult) {
    guard #available(iOS 14.0, *), DCAppAttestService.shared.isSupported else {
      CatzConnectPlugin.unsupported(result)
      return
    }
    DCAppAttestService.shared.generateKey { keyId, error in
      if let keyId = keyId, error == nil {
        CatzConnectPlugin.reply(result, keyId)
      } else {
        CatzConnectPlugin.reply(result, CatzConnectPlugin.flutterError(error, operation: "generateKey"))
      }
    }
  }

  private func attestKey(args: [String: Any], result: @escaping FlutterResult) {
    guard #available(iOS 14.0, *), DCAppAttestService.shared.isSupported else {
      CatzConnectPlugin.unsupported(result)
      return
    }
    guard let keyId = args["keyId"] as? String, !keyId.isEmpty,
      let hash = (args["clientDataHash"] as? FlutterStandardTypedData)?.data
    else {
      result(FlutterError(code: "app_attest_invalid_input", message: "Missing keyId or clientDataHash", details: nil))
      return
    }
    DCAppAttestService.shared.attestKey(keyId, clientDataHash: hash) { attestation, error in
      if let attestation = attestation, error == nil {
        CatzConnectPlugin.reply(result, FlutterStandardTypedData(bytes: attestation))
      } else {
        CatzConnectPlugin.reply(result, CatzConnectPlugin.flutterError(error, operation: "attestKey"))
      }
    }
  }

  private func generateAssertion(args: [String: Any], result: @escaping FlutterResult) {
    guard #available(iOS 14.0, *), DCAppAttestService.shared.isSupported else {
      CatzConnectPlugin.unsupported(result)
      return
    }
    guard let keyId = args["keyId"] as? String, !keyId.isEmpty,
      let hash = (args["clientDataHash"] as? FlutterStandardTypedData)?.data
    else {
      result(FlutterError(code: "app_attest_invalid_input", message: "Missing keyId or clientDataHash", details: nil))
      return
    }
    DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: hash) { assertion, error in
      if let assertion = assertion, error == nil {
        CatzConnectPlugin.reply(result, FlutterStandardTypedData(bytes: assertion))
      } else {
        CatzConnectPlugin.reply(result, CatzConnectPlugin.flutterError(error, operation: "generateAssertion"))
      }
    }
  }

  /// DCError → `app_attest_<code>`; `details.errorCode` = `DCError.Code.rawValue`.
  @available(iOS 14.0, *)
  private static func flutterError(_ error: Error?, operation: String) -> FlutterError {
    if let dc = error as? DCError {
      let reason: String
      switch dc.code {
      case .featureUnsupported: reason = "app_attest_feature_unsupported"
      case .invalidInput: reason = "app_attest_invalid_input"
      case .invalidKey: reason = "app_attest_invalid_key"
      case .serverUnavailable: reason = "app_attest_server_unavailable"
      case .unknownSystemFailure: reason = "app_attest_unknown_system_failure"
      @unknown default: reason = "app_attest_failed"
      }
      return FlutterError(
        code: reason,
        message: "App Attest \(operation) failed: \(dc.localizedDescription)",
        details: ["errorCode": dc.code.rawValue])
    }
    let message = error?.localizedDescription ?? "no result"
    return FlutterError(code: "app_attest_failed", message: "App Attest \(operation) failed: \(message)", details: nil)
  }
}
