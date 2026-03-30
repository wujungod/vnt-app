import UIKit
import Flutter
import NetworkExtension
import Foundation

// Note: TunnelConfig and ExternalRoute are defined in SharedTunnelConfig.swift
// which is compiled into both the Runner and PacketTunnelExtension targets.

/// VPN Manager for VNT App - handles NEPacketTunnelProviderManager lifecycle
/// Provides a clean API for the Flutter side to start/stop VPN
@objc class VPNManager: NSObject {
    
    static let shared = VPNManager()
    
    private static let appGroupIdentifier = "group.top.wherewego.vntApp"
    private static let bundleIdentifier = "top.wherewego.vntApp"
    private static let tunnelBundleIdentifier = "top.wherewego.vntApp.PacketTunnel"
    
    private var tunnelManager: NETunnelProviderManager?
    private var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: Self.appGroupIdentifier) ?? UserDefaults.standard
    }
    
    /// Unix Domain Socket path for fd transfer (in App Group container)
    private var socketPath: String {
        let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)
        return (containerURL?.appendingPathComponent("vnt_fd.sock").path) ?? "/tmp/vnt_fd.sock"
    }
    
    /// Status callback for Flutter
    var statusHandler: ((String) -> Void)?
    
    // Singleton
    private override init() {
        super.init()
        loadTunnelManager()
    }
    
    // MARK: - Tunnel Manager Management
    
    private func loadTunnelManager() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[VPNManager] Error loading tunnel manager: \(error)")
                return
            }
            
            if let manager = managers?.first {
                self.tunnelManager = manager
            } else {
                self.createTunnelManager()
            }
        }
    }
    
    private func createTunnelManager() {
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = Self.tunnelBundleIdentifier
        tunnelProtocol.providerConfiguration = [:]
        tunnelProtocol.serverAddress = "VNT"
        
        let manager = NETunnelProviderManager()
        manager.protocolConfiguration = tunnelProtocol
        manager.localizedDescription = "VNT VPN"
        manager.isEnabled = true
        
        manager.saveToPreferences { [weak self] error in
            if let error = error {
                NSLog("[VPNManager] Error saving tunnel manager: \(error)")
                return
            }
            
            NETunnelProviderManager.loadAllFromPreferences { managers, _ in
                self?.tunnelManager = managers?.first
                NSLog("[VPNManager] Tunnel manager created and saved")
            }
        }
    }
    
    // MARK: - Public API
    
    /// Start VPN with the given device configuration
    /// - Parameters:
    ///   - config: Dictionary with keys: virtualIp, virtualNetmask, virtualGateway, virtualNetwork, mtu, externalRoute, dnsServers, tunnelServerAddress
    ///   - completion: Called with the TUN file descriptor when ready, or error
    @objc func startVpn(config: [String: Any], completion: @escaping (Int, Error?) -> Void) {
        NSLog("[VPNManager] startVpn called with config: \(config)")
        
        // Build tunnel config
        let tunnelConfig = TunnelConfig(
            virtualIp: config["virtualIp"] as? String ?? "",
            virtualNetmask: config["virtualNetmask"] as? String ?? "255.255.255.0",
            virtualGateway: config["virtualGateway"] as? String ?? "",
            virtualNetwork: config["virtualNetwork"] as? String ?? "",
            mtu: config["mtu"] as? Int ?? 1400,
            tunnelRemoteAddress: "127.0.0.1",  // Dummy, required by iOS
            tunnelServerAddress: config["tunnelServerAddress"] as? String,
            externalRoutes: parseExternalRoutes(config["externalRoute"] as? [[String: String]] ?? []),
            dnsServers: config["dnsServers"] as? [String] ?? []
        )
        
        // Save config to shared defaults for the Extension to read
        if let encoded = try? JSONEncoder().encode(tunnelConfig) {
            sharedDefaults.set(encoded, forKey: "tunnelConfig")
            NSLog("[VPNManager] Tunnel config saved to shared defaults")
        }
        
        // Clear previous tunnel ready state
        sharedDefaults.removeObject(forKey: "tunnelReady")
        sharedDefaults.removeObject(forKey: "tunnelReadyTime")
        
        // Ensure tunnel manager exists
        if tunnelManager == nil {
            createTunnelManagerSync()
        }
        
        guard let manager = tunnelManager else {
            let error = NSError(domain: "VPNManager", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Tunnel manager not available"])
            completion(-1, error)
            return
        }
        
        manager.isEnabled = true
        manager.saveToPreferences { [weak self] error in
            if let error = error {
                NSLog("[VPNManager] Error saving preferences: \(error)")
                completion(-1, error)
                return
            }
            
            // Start the tunnel
            do {
                try manager.connection.startVPNTunnel(options: nil)
                NSLog("[VPNManager] VPN start requested, waiting for tunnel ready...")
                
                // Wait for Extension to signal readiness, then receive fd via Unix socket
                self?.waitForTunnelAndReceiveFd(completion: completion)
                
            } catch let error as NSError {
                NSLog("[VPNManager] Error starting VPN: \(error)")
                completion(-1, error)
            }
        }
    }
    
    /// Stop VPN
    @objc func stopVpn() {
        NSLog("[VPNManager] stopVpn called")
        tunnelManager?.connection.stopVPNTunnel()
        sharedDefaults.set(false, forKey: "tunnelReady")
        statusHandler?("stopped")
    }
    
    /// Check if VPN is currently connected
    @objc func isVpnRunning() -> Bool {
        return tunnelManager?.connection.status == .connected
    }
    
    // MARK: - FD Transfer via Unix Domain Socket
    
    /// Wait for Extension to be ready, then connect to its Unix socket to receive fd
    private func waitForTunnelAndReceiveFd(completion: @escaping (Int, Error?) -> Void) {
        let maxWait: TimeInterval = 20  // seconds
        let pollInterval: TimeInterval = 0.3
        let startTime = Date()
        
        Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            // Check if Extension has signaled ready
            let tunnelReady = self.sharedDefaults.bool(forKey: "tunnelReady")
            let status = self.tunnelManager?.connection.status
            
            if tunnelReady {
                timer.invalidate()
                NSLog("[VPNManager] Extension signaled tunnelReady, connecting to receive fd...")
                
                // Connect to Extension's Unix Domain Socket and receive the fd
                self.receiveFdFromExtension { fd, error in
                    if let error = error {
                        completion(-1, error)
                    } else {
                        self.statusHandler?("connected")
                        completion(fd, nil)
                    }
                }
                return
            }
            
            // Check for errors
            if status == .disconnected || status == .invalid {
                // Only report error if we've been waiting a while (avoid false alarms during startup)
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed > 3 {
                    timer.invalidate()
                    NSLog("[VPNManager] VPN tunnel disconnected (status: \(String(describing: status)))")
                    let error = NSError(domain: "VPNManager", code: 3,
                                      userInfo: [NSLocalizedDescriptionKey: "VPN tunnel disconnected: \(String(describing: status))"])
                    completion(-1, error)
                    return
                }
            }
            
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > maxWait {
                timer.invalidate()
                NSLog("[VPNManager] Timeout waiting for tunnel ready")
                let error = NSError(domain: "VPNManager", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Timeout waiting for VPN tunnel to start (20s)"])
                completion(-1, error)
                return
            }
        }
    }
    
    /// Connect to Extension's Unix Domain Socket and receive the utun fd via SCM_RIGHTS
    private func receiveFdFromExtension(completion: @escaping (Int, Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let sock = socket(AF_UNIX, SOCK_STREAM, 0)
            guard sock >= 0 else {
                let error = NSError(domain: "VPNManager", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "Failed to create Unix Domain Socket: errno=\(errno)"])
                DispatchQueue.main.async { completion(-1, error) }
                return
            }
            defer { close(sock) }
            
            // Connect to Extension's socket
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathData = self.socketPath.cString(using: .utf8)!
            withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
                let dst = ptr.baseAddress!.assumingMemoryBound(to: CChar.self)
                let count = min(pathData.count, 103)
                for i in 0..<count {
                    dst[i] = pathData[i]
                }
                dst[count] = 0
            }
            
            var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let connectResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPtr in
                    connect(sock, reboundPtr, addrLen)
                }
            }
            
            guard connectResult == 0 else {
                let error = NSError(domain: "VPNManager", code: 5,
                                  userInfo: [NSLocalizedDescriptionKey: "Failed to connect to Extension socket: errno=\(errno)"])
                NSLog("[VPNManager] Failed to connect to Extension: %d", errno)
                DispatchQueue.main.async { completion(-1, error) }
                return
            }
            
            NSLog("[VPNManager] Connected to Extension socket, receiving fd...")
            
            // Receive the fd using recvmsg with SCM_RIGHTS
            let receivedFd = self.receiveFileDescriptor(sock: sock)
            
            if receivedFd >= 0 {
                NSLog("[VPNManager] Successfully received fd=%d from Extension", receivedFd)
                DispatchQueue.main.async { completion(Int(receivedFd), nil) }
            } else {
                let error = NSError(domain: "VPNManager", code: 6,
                                  userInfo: [NSLocalizedDescriptionKey: "Failed to receive fd from Extension: errno=\(errno)"])
                DispatchQueue.main.async { completion(-1, error) }
            }
        }
    }
    
    /// Receive a file descriptor from a connected Unix Domain Socket using SCM_RIGHTS
    private func receiveFileDescriptor(sock: Int32) -> Int32 {
        var buf = [UInt8](repeating: 0, count: 1)
        
        // Control message buffer
        let cmsgDataSize = MemoryLayout<Int32>.size
        let cmsgBufferSize = MemoryLayout<cmsghdr>.size + cmsgDataSize
        var cmsgBuffer = [UInt8](repeating: 0, count: cmsgBufferSize)
        
        var msg = msghdr()
        msg.msg_name = nil
        msg.msg_namelen = 0
        msg.msg_controllen = socklen_t(cmsgBufferSize)
        
        let receivedFd: Int32 = cmsgBuffer.withUnsafeMutableBytes { cmsgRaw in
            buf.withUnsafeMutableBufferPointer { bufPtr in
                var iov = iovec(
                    iov_base: bufPtr.baseAddress,
                    iov_len: 1
                )
                
                msg.msg_iov = withUnsafeMutablePointer(to: &iov) { $0 }
                msg.msg_iovlen = 1
                msg.msg_control = cmsgRaw.baseAddress
                
                let recvResult = withUnsafeMutablePointer(to: &msg) { msgPtr in
                    recvmsg(sock, msgPtr, 0)
                }
                
                guard recvResult > 0 else {
                    NSLog("[VPNManager] recvmsg failed: %d", errno)
                    return Int32(-1)
                }
                
                // Parse the control message to extract the fd
                var fd: Int32 = -1
                let bufferBase = cmsgRaw.baseAddress!
                var offset = 0
                
                while offset + MemoryLayout<cmsghdr>.size <= Int(msg.msg_controllen) {
                    let cmsg = bufferBase.advanced(by: offset).assumingMemoryBound(to: cmsghdr.self)
                    
                    if cmsg.pointee.cmsg_level == SOL_SOCKET && cmsg.pointee.cmsg_type == SCM_RIGHTS {
                        let fdPtr = UnsafeRawPointer(cmsg).advanced(by: MemoryLayout<cmsghdr>.size)
                            .assumingMemoryBound(to: Int32.self)
                        fd = fdPtr.pointee
                        break
                    }
                    
                    let cmsgLen = Int(cmsg.pointee.cmsg_len)
                    let alignedLen = (cmsgLen + MemoryLayout<Int>.alignment - 1) & ~(MemoryLayout<Int>.alignment - 1)
                    offset += alignedLen
                    if offset == 0 { break }
                }
                return fd
            }
        }
        
        return receivedFd
    }
    
    // MARK: - Private Helpers
    
    private func parseExternalRoutes(_ routes: [[String: String]]) -> [ExternalRoute] {
        return routes.compactMap { route in
            guard let destination = route["destination"],
                  let netmask = route["netmask"] else { return nil }
            return ExternalRoute(destination: destination, netmask: netmask)
        }
    }
    
    private func createTunnelManagerSync() {
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = Self.tunnelBundleIdentifier
        tunnelProtocol.providerConfiguration = [:]
        tunnelProtocol.serverAddress = "VNT"
        
        let manager = NETunnelProviderManager()
        manager.protocolConfiguration = tunnelProtocol
        manager.localizedDescription = "VNT VPN"
        manager.isEnabled = true
        
        let semaphore = DispatchSemaphore(value: 0)
        manager.saveToPreferences { [weak self] error in
            if let error = error {
                NSLog("[VPNManager] Error saving tunnel manager (sync): \(error)")
            } else {
                NETunnelProviderManager.loadAllFromPreferences { managers, _ in
                    self?.tunnelManager = managers?.first
                    semaphore.signal()
                }
                return
            }
            semaphore.signal()
        }
        semaphore.wait()
    }
    
    // MARK: - Connection Status Monitoring
    
    @objc func startMonitoringStatus() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vpnStatusDidChange(_:)),
            name: .NEVPNStatusDidChange,
            object: nil
        )
    }
    
    @objc func vpnStatusDidChange(_ notification: Notification) {
        guard let connection = notification.object as? NEVPNConnection else { return }
        let status: String
        switch connection.status {
        case .invalid: status = "invalid"
        case .disconnected: status = "disconnected"
        case .connecting: status = "connecting"
        case .connected: status = "connected"
        case .reasserting: status = "reasserting"
        case .disconnecting: status = "disconnecting"
        @unknown default: status = "unknown"
        }
        NSLog("[VPNManager] VPN status changed: %@", status)
        statusHandler?(status)
    }
    
    @objc func stopMonitoringStatus() {
        NotificationCenter.default.removeObserver(self, name: .NEVPNStatusDidChange, object: nil)
    }
    
    deinit {
        stopMonitoringStatus()
    }
}
