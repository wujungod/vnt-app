import Flutter
import UIKit
import NetworkExtension

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    
    // Register VPN Method Channel handler
    let controller = window?.rootViewController as? FlutterViewController
    setupVPNChannel(controller: controller!)
    
    // Load and prepare VPN manager
    VPNManager.shared.startMonitoringStatus()
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  
  private func setupVPNChannel(controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "top.wherewego.vnt/vpn",
      binaryMessenger: controller.binaryMessenger
    )
    
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "startVpn":
        guard let args = call.arguments as? [String: Any] else {
          result(FlutterMethodNotImplemented)
          return
        }
        VPNManager.shared.startVpn(config: args) { fd, error in
          if let error = error {
            result(FlutterError(code: "VPN_START_FAILED",
                               message: error.localizedDescription,
                               details: nil))
          } else {
            result(fd)
          }
        }
      case "stopVpn":
        VPNManager.shared.stopVpn()
        result(nil)
      case "moveTaskToBack":
        // No-op on iOS
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
  
  override func applicationDidEnterBackground(_ application: UIApplication) {
    // VPN continues to run via Network Extension even when app is backgrounded
  }
}
