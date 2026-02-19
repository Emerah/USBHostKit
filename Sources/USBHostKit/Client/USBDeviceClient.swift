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
        private var interfaceCache: [CachedInterfaceKey: USBInterface] = [:]
        private var interfaceMonitoringTasks: [InterfaceSelection: Task<Void, Never>] = [:]
        private var continuations: [InterfaceSelection: AsyncThrowingStream<USBDeviceClient.Notification, any Error>.Continuation] = [:]
        
        public nonisolated final let deviceReference: DeviceReference
        public nonisolated final let deviceInfo: DeviceInfo
        
        private var state: SessionState = .active
        
        /// Creates a client session bound to a device registry reference.
        ///
        /// - Parameter deviceReference: The target device registry identifier.
        /// - Returns: A configured session, or `nil` if the service cannot be opened.
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
    
    /// Starts monitoring notifications for one interface selection.
    ///
    /// - Parameter selection: Interface, alternate setting, and endpoint to monitor.
    /// - Returns: A stream of notifications for the selected interface.
    /// - Throws: ``USBHostError`` when the session is closed, selection is invalid, or monitoring is already active for this selection.
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

    /// Closes the session and releases associated resources.
    ///
    /// > Note: This currently emits `.deviceRemoved` for all subscribers.
    public func close() {
        guard state == .active else { return }
        // TODO: Distinguish manual close from physical removal notifications.
        finishSession(emitRemoval: true)
    }
    
}



// MARK: - Retrieve io_service_t for deviceID
extension USBHostKit.Client.USBDeviceClient {
    
    /// Resolves an `io_service_t` from a registry entry ID.
    ///
    /// - Parameter deviceID: IORegistry entry identifier.
    /// - Returns: The matching service handle, or `nil` when unavailable.
    private static func ioService(for deviceID: UInt64) -> io_service_t? {
        guard let dictionary = IORegistryEntryIDMatching(deviceID) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, dictionary)
        guard service != IO_OBJECT_NULL else { return nil }
        return service
    }
}


// MARK: - Monitoring
extension USBHostKit.Client.USBDeviceClient {
    
    /// Cancels all active interface-monitoring tasks.
    private func stopMonitoringTasks() {
        interfaceMonitoringTasks.values.forEach { $0.cancel() }
        interfaceMonitoringTasks.removeAll()
    }
    
    /// Starts a monitoring task for a single interface selection.
    ///
    /// - Parameter selection: Interface selection to monitor.
    private func startMonitoring(selection: InterfaceSelection) {
        interfaceMonitoringTasks[selection] = Task { await self.monitorInput(for: selection) }
    }
    
    /// Stops and removes the monitoring task for one selection.
    ///
    /// - Parameter selection: Interface selection whose task should be stopped.
    private func stopMonitoringTask(for selection: InterfaceSelection) {
        interfaceMonitoringTasks[selection]?.cancel()
        interfaceMonitoringTasks.removeValue(forKey: selection)
    }
    
    /// Stops monitoring and detaches the stream continuation for one selection.
    ///
    /// - Parameter selection: Interface selection to remove.
    private func stopMonitoring(for selection: InterfaceSelection) {
        stopMonitoringTask(for: selection)
        continuations.removeValue(forKey: selection)
    }
    
    /// Runs the read loop for one monitored interface endpoint.
    ///
    /// - Parameter selection: Interface selection to read from.
    private func monitorInput(for selection: InterfaceSelection) async {
        do {
            let (interfaceNumber, alternateSetting, endpointAddress) = try validatedSelection(selection)
            let (cacheKey, interface) = try acquireInterface(number: interfaceNumber, alternateSetting: alternateSetting)
            defer { releaseInterface(for: cacheKey) }
            let endpoint = try interface.copyEndpoint(address: endpointAddress)
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
    
    /// Finishes a monitoring stream and removes its bookkeeping state.
    ///
    /// - Parameters:
    ///   - selection: Interface selection to finish.
    ///   - error: Optional error used to finish the stream.
    private func finishMonitoring(for selection: InterfaceSelection, throwing error: Error?) {
        if let error {
            continuations[selection]?.finish(throwing: error)
        } else {
            continuations[selection]?.finish()
        }
        continuations.removeValue(forKey: selection)
        stopMonitoringTask(for: selection)
    }
    
    /// Finalizes the session by cancelling tasks, finishing streams, and destroying handles.
    ///
    /// - Parameter emitRemoval: Whether `.deviceRemoved` should be emitted before stream completion.
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
        destroyCachedInterfaces()
        device.destroy()
        state = .closed
    }
}

// MARK: - Sending
extension USBHostKit.Client.USBDeviceClient {
    
    /// Sends data to an output endpoint identified by an interface selection.
    ///
    /// - Parameters:
    ///   - data: Payload bytes to write.
    ///   - selection: Target interface, alternate setting, and endpoint.
    ///   - timeout: Completion timeout in seconds.
    /// - Returns: Number of bytes transferred.
    /// - Throws: ``USBHostError`` when the session is inactive, endpoint is invalid, or the I/O request fails.
    public func send(data: Data, to selection: InterfaceSelection, timeout: TimeInterval = IOUSBHostDefaultControlCompletionTimeout) async throws -> Int {
        guard state == .active else { throw USBHostError.notOpen }
        let (interfaceNumber, alternateSetting, endpointAddress) = try validatedSelection(selection)
        let (cacheKey, interface) = try acquireInterface(number: interfaceNumber, alternateSetting: alternateSetting)
        defer { releaseInterface(for: cacheKey) }
        let endpoint = try interface.copyEndpoint(address: endpointAddress)
        try validateOutputEndpoint(endpoint)
        let buffer = NSMutableData(data: data)
        let value = try await enqueueIORequest(on: endpoint, data: buffer, timeout: timeout)
        return value
    }
}

// MARK: - Control Transfers
extension USBHostKit.Client.USBDeviceClient {
    /// Performs a control transfer with no external payload buffer.
    ///
    /// - Parameters:
    ///   - request: USB device request descriptor.
    ///   - timeout: Completion timeout in seconds.
    /// - Returns: Number of bytes transferred.
    /// - Throws: ``USBHostError`` when the session is inactive or the request fails.
    public func controlTransfer(
        _ request: IOUSBDeviceRequest,
        timeout: TimeInterval = IOUSBHostDefaultControlCompletionTimeout
    ) async throws -> Int {
        guard state == .active else { throw USBHostError.notOpen }
        return try await enqueueDeviceRequest(request, timeout: timeout)
    }
    
    /// Performs a control transfer with an outbound data buffer.
    ///
    /// - Parameters:
    ///   - request: USB device request descriptor.
    ///   - data: Data to attach to the request.
    ///   - timeout: Completion timeout in seconds.
    /// - Returns: Number of bytes transferred.
    /// - Throws: ``USBHostError`` when the session is inactive or the request fails.
    public func controlTransfer(
        _ request: IOUSBDeviceRequest,
        data: Data,
        timeout: TimeInterval = IOUSBHostDefaultControlCompletionTimeout
    ) async throws -> Int {
        guard state == .active else { throw USBHostError.notOpen }
        let buffer = NSMutableData(data: data)
        return try await enqueueDeviceRequest(request, data: buffer, timeout: timeout)
    }
    
    /// Performs a control transfer and returns inbound data.
    ///
    /// - Parameters:
    ///   - request: USB device request descriptor.
    ///   - receiveLength: Preferred receive length; falls back to `wLength` when non-positive.
    ///   - timeout: Completion timeout in seconds.
    /// - Returns: Received data buffer.
    /// - Throws: ``USBHostError`` when arguments are invalid, the session is inactive, or the request fails.
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

    private struct CachedInterfaceKey: Hashable, Sendable {
        let interfaceNumber: UInt8
        let alternateSetting: UInt8
    }
    
    /// Returns a cached interface object for a selection, creating it when needed.
    ///
    /// - Parameters:
    ///   - number: USB interface number.
    ///   - alternateSetting: USB alternate setting value.
    /// - Returns: Cache key and interface object pair.
    /// - Throws: ``USBHostError`` when interface creation fails.
    private func acquireInterface(number: UInt8, alternateSetting: UInt8) throws -> (CachedInterfaceKey, USBInterface) {
        let key = CachedInterfaceKey(interfaceNumber: number, alternateSetting: alternateSetting)

        if let cached = interfaceCache[key] {
            return (key, cached)
        }

        let interface = try device.interface(number, alternateSetting: alternateSetting)
        interfaceCache[key] = interface
        return (key, interface)
    }

    /// Placeholder release hook for future interface lifetime tuning.
    ///
    /// - Parameter _: Interface cache key.
    private func releaseInterface(for _: CachedInterfaceKey) { }

    /// Destroys all cached interfaces and clears cache storage.
    private func destroyCachedInterfaces() {
        interfaceCache.values.forEach { $0.destroy() }
        interfaceCache.removeAll()
    }
    
    /// Validates and converts public `InterfaceSelection` values to USB byte fields.
    ///
    /// - Parameter selection: Public interface selection.
    /// - Returns: `(interfaceNumber, alternateSetting, endpointAddress)` as `UInt8`.
    /// - Throws: ``USBHostError/badArgument`` when conversion fails.
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
    
    /// Validates that an endpoint can be used for inbound stream reads.
    ///
    /// - Parameter endpoint: Endpoint to validate.
    /// - Throws: ``USBHostError`` when direction or transfer type is unsupported.
    private func validateInputEndpoint(_ endpoint: USBEndpoint) throws {
        guard endpoint.direction == .deviceToHost else {
            throw USBHostError.badArgument
        }
        
        guard endpoint.transferType == .bulk || endpoint.transferType == .interrupt else {
            throw USBHostError.unsupported
        }
    }
    
    /// Validates that an endpoint can be used for outbound writes.
    ///
    /// - Parameter endpoint: Endpoint to validate.
    /// - Throws: ``USBHostError`` when direction or transfer type is unsupported.
    private func validateOutputEndpoint(_ endpoint: USBEndpoint) throws {
        guard endpoint.direction == .hostToDevice else {
            throw USBHostError.badArgument
        }
        
        guard endpoint.transferType == .bulk || endpoint.transferType == .interrupt else {
            throw USBHostError.unsupported
        }
    }
    
    /// Reads a buffer from an endpoint using asynchronous enqueue APIs.
    ///
    /// - Parameters:
    ///   - endpoint: Endpoint to read from.
    ///   - length: Requested buffer size.
    ///   - timeout: Completion timeout in seconds.
    /// - Returns: Data read from the endpoint.
    /// - Throws: ``USBHostError`` when allocation or I/O fails.
    private func readData(from endpoint: USBEndpoint, length: Int, timeout: TimeInterval = IOUSBHostDefaultControlCompletionTimeout) async throws -> Data {
        let buffer = try device.makeIOData(capacity: length)
        let bytesTransferred = try await enqueueIORequest(on: endpoint, data: buffer, timeout: timeout)
        return Data(bytes: buffer.bytes, count: bytesTransferred)
    }

    /// Enqueues a device control request and bridges callback completion to async/await.
    ///
    /// - Parameters:
    ///   - request: USB device request descriptor.
    ///   - data: Optional payload buffer.
    ///   - timeout: Completion timeout in seconds.
    /// - Returns: Number of bytes transferred.
    /// - Throws: ``USBHostError`` when enqueue fails or completion reports an error status.
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

    /// Enqueues endpoint I/O and bridges callback completion to async/await.
    ///
    /// - Parameters:
    ///   - endpoint: Endpoint to enqueue on.
    ///   - data: Payload buffer for the operation.
    ///   - timeout: Completion timeout in seconds.
    /// - Returns: Number of bytes transferred.
    /// - Throws: ``USBHostError`` when enqueue fails or completion reports an error status.
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
    
    /// Identifies errors that represent physical device removal.
    ///
    /// - Parameter error: Error to inspect.
    /// - Returns: `true` when the error indicates device removal.
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
        
        /// Creates a strongly-typed reference from a registry entry ID.
        ///
        /// - Parameter deviceID: IORegistry entry identifier.
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
        /// Creates a public interface selection tuple used by I/O APIs.
        ///
        /// - Parameters:
        ///   - interfaceNumber: USB interface number.
        ///   - alternateSetting: USB alternate setting number.
        ///   - endpointAddress: USB endpoint address.
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
        
        /// Creates immutable device information captured at session creation time.
        ///
        /// - Parameters:
        ///   - device: Internal USB device object.
        ///   - deviceReference: Public device reference.
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
