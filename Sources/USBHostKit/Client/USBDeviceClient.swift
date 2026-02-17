// Package: USBHostKit
// File: USBDeviceClient.swift
// Path: Sources/USBHostKit/Client/USBDeviceClient.swift
// Date: 2026-01-12
// Author: Ahmed Emerah
// Email: ahmed.emerah@icloud.com
// Github: https://github.com/Emerah


import IOUSBHost

extension USBHostKit.Client {
    
    public final actor USBDeviceClient {
        
        private let device: USBDevice
        private var interfaceMonitoringTasks: [InterfaceSelection: Task<Void, Never>] = [:]
        private var continuations: [InterfaceSelection: AsyncThrowingStream<USBDeviceClient.Notification, any Error>.Continuation] = [:]
        
        public nonisolated final let deviceReference: DeviceReference
        public nonisolated final let deviceInfo: DeviceInfo
        
        private var isMonitoring = false
        private var state: SessionState = .active
        
        public init?(deviceReference: DeviceReference) {
            guard let service = Self.ioService(for: deviceReference.deviceID) else {
                USBHostKit.Manager.USBLogger.error("USBDeviceClient init failed: ioService not found for deviceID \(deviceReference.deviceID)")
                return nil
            }
            let device: USBDevice
            do {
                device = try USBDevice(service: service, options: [.deviceSeize], queue: nil, interestHandler: nil)
                try device.configure(value: 1, matchInterfaces: true)
            } catch {
                let translated = USBHostError.translated(error)
                USBHostKit.Manager.USBLogger.error(
                    "USBDeviceClient init failed for deviceID \(deviceReference.deviceID): \(translated) (\(translated.localizedDescription))"
                )
                IOObjectRelease(service)
                return nil
            }
            IOObjectRelease(service)
            self.deviceReference = deviceReference
            self.device = device
            self.deviceInfo = DeviceInfo(device: device, deviceReference: deviceReference)
        }
    }
}


extension USBHostKit.Client.USBDeviceClient {
    
    public func monitorNotifications(targetInterface selection: InterfaceSelection) throws -> AsyncThrowingStream<USBDeviceClient.Notification, any Error> {
        guard state == .active else { throw USBHostError.notOpen }
        _ = try validatedSelection(selection)
        
        if continuations[selection] != nil {
            throw USBHostError.busy
        }
        
        var localContinuation: AsyncThrowingStream<USBDeviceClient.Notification, any Error>.Continuation?
        let stream = AsyncThrowingStream<USBDeviceClient.Notification, any Error>(bufferingPolicy: .bufferingOldest(128)) { continuation in
            localContinuation = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                guard let self else { return }
                Task { await self.stopMonitoring(for: selection) }
            }
        }
        
        if let localContinuation {
            continuations[selection] = localContinuation
            startMonitoring(selection: selection)
        }
        
        return stream
    }
    
    
    @available(*, deprecated, message: "Use monitor(interface:) to create a per-interface stream.")
    public func monitorNotifications(interfacesToMonitor: [InterfaceSelection]) throws -> AsyncThrowingStream<USBDeviceClient.Notification, any Error> {
        guard state == .active else { throw USBHostError.notOpen }
        
        let selections = Array(Set(interfacesToMonitor))
        guard !selections.isEmpty else { throw USBHostError.badArgument }
        for selection in selections {
            _ = try validatedSelection(selection)
        }
        
        let streams = try selections.map { try monitorNotifications(targetInterface: $0) }
        return AsyncThrowingStream<USBDeviceClient.Notification, any Error>(bufferingPolicy: .bufferingOldest(128)) { continuation in
            let task = Task {
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for stream in streams {
                            group.addTask {
                                for try await notification in stream {
                                    continuation.yield(notification)
                                }
                            }
                        }
                        try await group.waitForAll()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            
            continuation.onTermination = { @Sendable [weak self] _ in
                task.cancel()
                guard let self else { return }
                Task {
                    for selection in selections {
                        await self.finishMonitoring(for: selection, throwing: nil)
                    }
                }
            }
        }
    }
    
    public func close() {
        guard state == .active else { return }
        finishSession(emitRemoval: true)
    }
    
}



// MARK: - Retrieve io_service_t for deviceID
extension USBHostKit.Client.USBDeviceClient {
    
    private static func ioService(for deviceID: UInt64) -> io_service_t? {
        guard let dictionary = IORegistryEntryIDMatching(deviceID) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, dictionary)
        guard service != IO_OBJECT_NULL else { return nil }
        return service
    }
}


// MARK: - Monitoring
extension USBHostKit.Client.USBDeviceClient {
    
    private func stopMonitoringTasks() {
        interfaceMonitoringTasks.values.forEach { $0.cancel() }
        interfaceMonitoringTasks.removeAll()
        isMonitoring = false
    }
    
    private func startMonitoring(selection: InterfaceSelection) {
        isMonitoring = true
        interfaceMonitoringTasks[selection] = Task { await self.monitorInput(for: selection) }
    }
    
    private func stopMonitoringTask(for selection: InterfaceSelection) {
        interfaceMonitoringTasks[selection]?.cancel()
        interfaceMonitoringTasks.removeValue(forKey: selection)
        if interfaceMonitoringTasks.isEmpty {
            isMonitoring = false
        }
    }
    
    private func stopMonitoring(for selection: InterfaceSelection) {
        stopMonitoringTask(for: selection)
        continuations.removeValue(forKey: selection)
    }
    
    private func monitorInput(for selection: InterfaceSelection) async {
        do {
            let endpoint = try resolveEndpoint(for: selection)
            try validateInputEndpoint(endpoint)
            let readLength = max(1, Int(endpoint.maxPacketSize))
            
            while !Task.isCancelled && state == .active {
                let data = try await readData(from: endpoint, length: readLength)
                if Task.isCancelled || state != .active { break }
                continuations[selection]?.yield(.inputReceived(interface: selection.interfaceNumber, data: data, timestamp: Date().timeIntervalSince1970))
            }
        } catch let error as USBHostError {
            if isDeviceRemoval(error) {
                finishSession(emitRemoval: true)
            } else {
                finishMonitoring(for: selection, throwing: error)
            }
        } catch is CancellationError {
            return
        } catch {
            finishMonitoring(for: selection, throwing: error)
        }
    }
    
    private func finishMonitoring(for selection: InterfaceSelection, throwing error: Error?) {
        if let error {
            continuations[selection]?.finish(throwing: error)
        } else {
            continuations[selection]?.finish()
        }
        continuations.removeValue(forKey: selection)
        stopMonitoringTask(for: selection)
    }
    
    private func finishSession(emitRemoval: Bool) {
        guard state != .closed else { return }
        state = .closing
        stopMonitoringTasks()
        
        if emitRemoval {
            for continuation in continuations.values {
                continuation.yield(.deviceRemoved)
            }
        }
        
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
        device.destroy()
        state = .closed
    }
}

// MARK: - Sending
extension USBHostKit.Client.USBDeviceClient {
    
    public func send(data: Data, to selection: InterfaceSelection, timeout: TimeInterval = IOUSBHostDefaultControlCompletionTimeout) async throws -> Int {
        guard state == .active else { throw USBHostError.notOpen }
        let endpoint = try resolveEndpoint(for: selection)
        try validateOutputEndpoint(endpoint)
        let buffer = NSMutableData(data: data)
        let value = try await enqueueIORequest(on: endpoint, data: buffer, timeout: timeout)
        return value
    }
}

// MARK: - Control Transfers
extension USBHostKit.Client.USBDeviceClient {
    public func controlTransfer(
        _ request: IOUSBDeviceRequest,
        timeout: TimeInterval = IOUSBHostDefaultControlCompletionTimeout
    ) async throws -> Int {
        guard state == .active else { throw USBHostError.notOpen }
        return try await enqueueDeviceRequest(request, timeout: timeout)
    }
    
    public func controlTransfer(
        _ request: IOUSBDeviceRequest,
        data: Data,
        timeout: TimeInterval = IOUSBHostDefaultControlCompletionTimeout
    ) async throws -> Int {
        guard state == .active else { throw USBHostError.notOpen }
        let buffer = NSMutableData(data: data)
        return try await enqueueDeviceRequest(request, data: buffer, timeout: timeout)
    }
    
    public func controlTransfer(
        _ request: IOUSBDeviceRequest,
        receiveLength: Int,
        timeout: TimeInterval = IOUSBHostDefaultControlCompletionTimeout
    ) async throws -> Data {
        guard state == .active else { throw USBHostError.notOpen }
        
        let resolvedLength = receiveLength > 0 ? receiveLength : Int(request.wLength)
        guard resolvedLength >= 0 else { throw USBHostError.badArgument }
        
        if resolvedLength == 0 {
            _ = try await enqueueDeviceRequest(request, timeout: timeout)
            return Data()
        }
        
        let buffer = NSMutableData(length: resolvedLength) ?? NSMutableData()
        let bytesTransferred = try await enqueueDeviceRequest(request, data: buffer, timeout: timeout)
        return Data(bytes: buffer.bytes, count: bytesTransferred)
    }
}

// MARK: - Endpoint helpers
extension USBHostKit.Client.USBDeviceClient {
    
    private func resolveEndpoint(for selection: InterfaceSelection) throws -> USBEndpoint {
        let (interfaceNumber, alternateSetting, endpointAddress) = try validatedSelection(selection)
        let interface = try device.interface(interfaceNumber, alternateSetting: alternateSetting)
        return try interface.copyEndpoint(address: endpointAddress)
    }
    
    private func validatedSelection(_ selection: InterfaceSelection) throws -> (UInt8, UInt8, UInt8) {
        guard
            let interfaceNumber = UInt8(exactly: selection.interfaceNumber),
            let alternateSetting = UInt8(exactly: selection.alternateSetting),
            let endpointAddress = UInt8(exactly: selection.endpointAddress)
        else {
            throw USBHostError.badArgument
        }
        
        return (interfaceNumber, alternateSetting, endpointAddress)
    }
    
    private func validateInputEndpoint(_ endpoint: USBEndpoint) throws {
        guard endpoint.direction == .deviceToHost else {
            throw USBHostError.badArgument
        }
        
        guard endpoint.transferType == .bulk || endpoint.transferType == .interrupt else {
            throw USBHostError.unsupported
        }
    }
    
    private func validateOutputEndpoint(_ endpoint: USBEndpoint) throws {
        guard endpoint.direction == .hostToDevice else {
            throw USBHostError.badArgument
        }
        
        guard endpoint.transferType == .bulk || endpoint.transferType == .interrupt else {
            throw USBHostError.unsupported
        }
    }
    
    private func readData(from endpoint: USBEndpoint, length: Int, timeout: TimeInterval = IOUSBHostDefaultControlCompletionTimeout) async throws -> Data {
        let buffer = try device.makeIOData(capacity: length)
        let bytesTransferred = try await enqueueIORequest(on: endpoint, data: buffer, timeout: timeout)
        return Data(bytes: buffer.bytes, count: bytesTransferred)
    }

    private func enqueueDeviceRequest(
        _ request: IOUSBDeviceRequest,
        data: NSMutableData? = nil,
        timeout: TimeInterval = IOUSBHostDefaultControlCompletionTimeout
    ) async throws -> Int {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            do {
                try device.enqueueDeviceRequest(request, data: data, timeout: timeout) { status, bytesTransferred in
                    if status == kIOReturnSuccess {
                        continuation.resume(returning: bytesTransferred)
                    } else {
                        continuation.resume(throwing: USBHostError.translated(status: status))
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func enqueueIORequest(
        on endpoint: USBEndpoint,
        data: NSMutableData?,
        timeout: TimeInterval = IOUSBHostDefaultControlCompletionTimeout
    ) async throws -> Int {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            do {
                try endpoint.enqueueIORequest(data: data, timeout: timeout) { status, bytesTransferred in
                    if status == kIOReturnSuccess {
                        continuation.resume(returning: bytesTransferred)
                    } else {
                        continuation.resume(throwing: USBHostError.translated(status: status))
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    private func isDeviceRemoval(_ error: USBHostError) -> Bool {
        switch error {
        case .noDevice, .notAttached, .offline:
            return true
        default:
            return false
        }
    }
    
}


extension USBHostKit.Client.USBDeviceClient {
    public struct DeviceReference: Sendable, Hashable {
        public let deviceID: UInt64
        
        internal init(deviceID: UInt64) {
            self.deviceID = deviceID
        }
    }
}


extension USBHostKit.Client.USBDeviceClient {
    public enum Notification: Sendable {
        case inputReceived(interface: Int, data: Data, timestamp: TimeInterval)
        case deviceRemoved
    }
}


extension USBHostKit.Client.USBDeviceClient {
    public struct InterfaceSelection: Hashable, Sendable {
        public let interfaceNumber: Int
        public let alternateSetting: Int
        public let endpointAddress: Int
        public init(interfaceNumber: Int, alternateSetting: Int, endpointAddress: Int) {
            self.interfaceNumber = interfaceNumber
            self.alternateSetting = alternateSetting
            self.endpointAddress = endpointAddress
        }
    }
}

// MARK: - Device info
extension USBHostKit.Client.USBDeviceClient {
    public struct DeviceInfo: Hashable, Sendable {
        public let deviceID: UInt64
        public let vendorID: UInt16
        public let productID: UInt16
        public let name: String
        public let manufacturer: String
        public let serialNumber: String
        public let configurationCount: Int
        public let interfaceCount: Int
        public let currentConfigurationValue: Int
        
        fileprivate init(device: USBDevice, deviceReference: DeviceReference) {
            self.deviceID = deviceReference.deviceID
            self.vendorID = device.vendorID
            self.productID = device.productID
            self.name = device.name
            self.manufacturer = device.manufacturer
            self.serialNumber = device.serialNumber
            self.configurationCount = Int(device.configurationCount)
            self.interfaceCount = Int(device.interfaceCount)
            self.currentConfigurationValue = Int(device.currentConfigurationValue)
        }
    }
}


// MARK: - Session State
extension USBHostKit.Client.USBDeviceClient {
    private enum SessionState {
        case active
        case closing
        case closed
    }
}
