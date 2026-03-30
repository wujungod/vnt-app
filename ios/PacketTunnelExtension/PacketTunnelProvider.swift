import NetworkExtension
import os.log
import Foundation

/// VNT Packet Tunnel Extension Provider
/// This extension creates a TUN interface, configures network settings,
/// and passes the file descriptor to the main app via Unix Domain Socket.
///
/// Data Flow:
/// 1. Main App writes tunnel config to shared UserDefaults
/// 2. Main App starts VPN via NETunnelProviderManager
/// 3. System spawns this Extension process
/// 4. Extension reads config, creates TUN, configures network
/// 5. Extension opens a Unix Domain Socket server in App Group container
/// 6. Extension waits for main app to connect
/// 7. Extension sends the utun fd to main app via SCM_RIGHTS (sendmsg)
/// 8. Extension notifies main app that fd is ready (via shared UserDefaults)
/// 9. Main app reads IP packets from the fd (Rust FFI) and writes them to the utun
final class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private static let log = OSLog(subsystem: "top.wherewego.vntApp.PacketTunnel", category: "PacketTunnel")
    
    private static let appGroupIdentifier = "group.top.wherewego.vntApp"
    
    /// Shared UserDefaults via App Group
    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: Self.appGroupIdentifier)
    }
    
    /// The utun file descriptor
    private var tunnelFileDescriptor: Int32 = -1
    
    /// Whether the tunnel is running
    private var isRunning = false
    
    /// Unix Domain Socket server for fd transfer
    private var socketPath: String {
        let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)
        return (containerURL?.appendingPathComponent("vnt_fd.sock").path) ?? "/tmp/vnt_fd.sock"
    }
    
    private var listenSocket: Int32 = -1
    
    // MARK: - NEPacketTunnelProvider Lifecycle
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        os_log("Starting VNT Packet Tunnel", log: Self.log, type: .info)
        
        guard let sharedDefaults = sharedDefaults else {
            let error = NSError(domain: "VNTTunnelError", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to access shared UserDefaults"])
            completionHandler(error)
            return
        }
        
        // Read configuration from shared defaults
        guard let configData = sharedDefaults.data(forKey: "tunnelConfig"),
              let config = try? JSONDecoder().decode(TunnelConfig.self, from: configData) else {
            let error = NSError(domain: "VNTTunnelError", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid tunnel configuration"])
            completionHandler(error)
            return
        }
        
        os_log("Tunnel config: virtualIp=%{public}@, netmask=%{public}@, gateway=%{public}@",
               log: Self.log, type: .info, config.virtualIp, config.virtualNetmask, config.virtualGateway)
        
        // Configure network settings (IP, routes, DNS, MTU)
        configureNetworkSettings(config: config) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                os_log("Failed to configure network settings: %{public}@",
                       log: Self.log, type: .error, error.localizedDescription)
                completionHandler(error)
                return
            }
            
            os_log("Network settings configured successfully", log: Self.log, type: .info)
            
            // Get the utun file descriptor from packetFlow
            let fd = self.getTunnelFileDescriptor()
            if fd < 0 {
                let error = NSError(domain: "VNTTunnelError", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "Failed to get tunnel file descriptor"])
                completionHandler(error)
                return
            }
            
            self.tunnelFileDescriptor = fd
            os_log("TUN file descriptor: %d", log: Self.log, type: .info, fd)
            
            self.isRunning = true
            
            // Notify main app that tunnel is ready (fd available via socket)
            // The main app will connect to our Unix Domain Socket to receive the fd
            sharedDefaults.set(true, forKey: "tunnelReady")
            sharedDefaults.set(Date().timeIntervalSince1970, forKey: "tunnelReadyTime")
            
            // Keep Extension alive and handle fd transfer requests
            self.startFdTransferServer()
            
            // Start reasserting timer
            self.startReasserting()
            
            completionHandler(nil)
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("Stopping VNT Packet Tunnel, reason: %ld", log: Self.log, type: .info, reason.rawValue)
        
        isRunning = false
        cancelReasserting()
        
        // Close socket server
        if listenSocket >= 0 {
            close(listenSocket)
            listenSocket = -1
        }
        
        // Remove socket file
        try? FileManager.default.removeItem(atPath: socketPath)
        
        // Notify main app
        sharedDefaults?.set(false, forKey: "tunnelReady")
        sharedDefaults?.removeObject(forKey: "tunnelReadyTime")
        
        // Stop packet flow
        packetFlow.stop { [weak self] in
            self?.tunnelFileDescriptor = -1
            os_log("Packet flow stopped", log: Self.log, type: .info)
            completionHandler()
        }
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if let message = String(data: messageData, encoding: .utf8) {
            os_log("Received app message: %{public}@", log: Self.log, type: .info, message)
            
            switch message {
            case "getStatus":
                let response = isRunning ? "running" : "stopped"
                completionHandler?(response.data(using: .utf8))
            case "getFd":
                if tunnelFileDescriptor >= 0 {
                    completionHandler?(String(tunnelFileDescriptor).data(using: .utf8))
                } else {
                    completionHandler?("none".data(using: .utf8))
                }
            default:
                completionHandler?(nil)
            }
        } else {
            completionHandler?(nil)
        }
    }
    
    override func sleep(completionHandler: @escaping () -> Void) {
        os_log("Tunnel going to sleep", log: Self.log, type: .info)
        completionHandler()
    }
    
    override func wake() {
        os_log("Tunnel waking up", log: Self.log, type: .info)
    }
    
    // MARK: - File Descriptor Transfer
    
    /// Get the utun file descriptor from the packet flow
    private func getTunnelFileDescriptor() -> Int32 {
        // packetFlow internally wraps a utun socket
        // We can access the fd through KVO on the private API
        // This is a well-known technique used by many iOS VPN apps
        let fd = packetFlow.value(forKeyPath: "socket.fileDescriptor") as! Int32
        return fd
    }
    
    /// Start a Unix Domain Socket server to transfer the fd to the main app
    private func startFdTransferServer() {
        // Remove existing socket file if present
        try? FileManager.default.removeItem(atPath: socketPath)
        
        // Create Unix Domain Socket
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            os_log("Failed to create Unix Domain Socket: %d", log: Self.log, type: .error, errno)
            return
        }
        listenSocket = sock
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathData = socketPath.cString(using: .utf8)!
        // SAFETY: pathData is null-terminated, sun_path has 104 bytes
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            pathData.withUnsafeBufferPointer { src in
                let count = min(src.count, 103) // leave room for null terminator
                ptr.initialize(from: src.baseAddress!, count: count)
                ptr[count] = 0
            }
        }
        
        // Bind
        var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPtr in
                bind(sock, reboundPtr, addrLen)
            }
        }
        
        guard bindResult == 0 else {
            os_log("Failed to bind Unix Domain Socket: %d", log: Self.log, type: .error, errno)
            close(sock)
            listenSocket = -1
            return
        }
        
        // Listen
        guard listen(sock, 5) == 0 else {
            os_log("Failed to listen on Unix Domain Socket: %d", log: Self.log, type: .error, errno)
            close(sock)
            listenSocket = -1
            return
        }
        
        os_log("FD transfer server started at: %{public}@", log: Self.log, type: .info, socketPath)
        
        // Accept connections in a background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptAndSendFd()
        }
    }
    
    /// Accept connection from main app and send the utun fd
    private func acceptAndSendFd() {
        var clientAddr = sockaddr_un()
        var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        
        let clientSock = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPtr in
                accept(listenSocket, reboundPtr, &clientAddrLen)
            }
        }
        
        guard clientSock >= 0 else {
            if listenSocket >= 0 {
                os_log("Accept failed (expected when stopping): %d", log: Self.log, type: .error, errno)
            }
            return
        }
        
        os_log("Main app connected for fd transfer", log: Self.log, type: .info)
        
        // Wait a moment for the client to be ready to receive
        usleep(100_000) // 100ms
        
        // Send the fd using sendmsg with SCM_RIGHTS
        let result = sendFileDescriptor(sock: clientSock, fdToSend: tunnelFileDescriptor)
        
        if result {
            os_log("Successfully sent fd %d to main app", log: Self.log, type: .info, tunnelFileDescriptor)
        } else {
            os_log("Failed to send fd: %d", log: Self.log, type: .error, errno)
        }
        
        close(clientSock)
    }
    
    /// Send a file descriptor to a connected Unix Domain Socket using SCM_RIGHTS
    private func sendFileDescriptor(sock: Int32, fdToSend: Int32) -> Bool {
        var buf = [UInt8](repeating: 0, count: 1) // Dummy data
        var iov = iovec(
            iov_base: &buf,
            iov_len: 1
        )
        
        // Control message buffer: cmsghdr + 1 fd
        let cmsgDataSize = MemoryLayout<Int32>.size
        let cmsgBufferSize = MemoryLayout<cmsghdr>.size + cmsgDataSize
        var cmsgBuffer = [UInt8](repeating: 0, count: cmsgBufferSize)
        
        var msg = msghdr()
        msg.msg_name = nil
        msg.msg_namelen = 0
        msg.msg_iov = &iov
        msg.msg_iovlen = 1
        msg.msg_control = &cmsgBuffer
        msg.msg_controllen = cmsgBufferSize
        
        // Set up the control message header
        let cmsg = UnsafeMutablePointer<cmsghdr>(&cmsgBuffer)
        cmsg.pointee.cmsg_len = socklen_t(MemoryLayout<cmsghdr>.size + cmsgDataSize)
        cmsg.pointee.cmsg_level = SOL_SOCKET
        cmsg.pointee.cmsg_type = SCM_RIGHTS
        
        // Copy the fd into the control message data
        let fdPtr = cmsgBuffer.withUnsafeMutableBytes { ptr -> UnsafeMutablePointer<Int32> in
            let offset = MemoryLayout<cmsghdr>.size
            return ptr.baseAddress!.advanced(by: offset).assumingMemoryBound(to: Int32.self)
        }
        fdPtr.pointee = fdToSend
        
        let sendResult = withUnsafeMutablePointer(to: &msg) { msgPtr in
            sendmsg(sock, msgPtr, 0)
        }
        
        return sendResult >= 0
    }
    
    // MARK: - Network Configuration
    
    private func configureNetworkSettings(config: TunnelConfig, completion: @escaping (Error?) -> Void) {
        let settings = createTunnelNetworkSettings(config: config)
        setTunnelNetworkSettings(settings) { error in
            completion(error)
        }
    }
    
    private func createTunnelNetworkSettings(config: TunnelConfig) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: config.tunnelRemoteAddress)
        
        // Set IPv4 address and subnet
        let ipv4Settings = NEIPv4Settings(addresses: [config.virtualIp], subnetMasks: [config.virtualNetmask])
        
        // Route VPN subnet through the tunnel
        let vpnRoute = NEIPv4Route(destinationAddress: config.virtualNetwork, subnetMask: config.virtualNetmask)
        ipv4Settings.includedRoutes = [vpnRoute]
        
        // Add external routes
        for route in config.externalRoutes {
            let externalRoute = NEIPv4Route(destinationAddress: route.destination, subnetMask: route.netmask)
            ipv4Settings.includedRoutes.append(externalRoute)
        }
        
        // Exclude the tunnel server to avoid routing loop
        if let serverAddress = config.tunnelServerAddress, !serverAddress.isEmpty {
            let serverIP = serverAddress.components(separatedBy: ":").first ?? serverAddress
            let serverRoute = NEIPv4Route(destinationAddress: serverIP, subnetMask: "255.255.255.255")
            ipv4Settings.excludedRoutes = [serverRoute]
        }
        
        settings.ipv4Settings = ipv4Settings
        settings.mtu = config.mtu
        
        // DNS settings
        if !config.dnsServers.isEmpty {
            let dnsSettings = NEDNSSettings(servers: config.dnsServers)
            dnsSettings.matchDomains = [""]  // Match all domains
            settings.dnsSettings = dnsSettings
        }
        
        return settings
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let vntTunnelDidBecomeReady = Notification.Name("vntTunnelDidBecomeReady")
    static let vntTunnelDidStop = Notification.Name("vntTunnelDidStop")
}

// Note: TunnelConfig and ExternalRoute are defined in SharedTunnelConfig.swift
