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
        
        private var state: State = .active
        
        /// Creates a device client bound to a device registry reference.
        ///
        /// - Parameter deviceReference: The target device registry identifier.
        /// - Returns: A configured client, or `nil` if the service cannot be opened.
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
    /// - Throws: ``USBHostError`` when the client is closed, selection is invalid, or monitoring is already active for this selection.
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

    /// Closes the client and releases associated resources.
    ///
    /// > Note: Manual close does not emit `.deviceRemoved`.
    public func close() {
        guard state == .active else { return }
        finishStreams()
        destroyCachedInterfaces()
        device.destroy()
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
            let interface = try acquireInterface(number: interfaceNumber, alternateSetting: alternateSetting)
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
                for continuation in continuations.values {
                    continuation.yield(.deviceRemoved)
                }
                finishStreams()
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
    
    /// Finishes all active streams and monitoring tasks.
    ///
    /// This method only finalizes stream-related resources. Device and interface
    /// teardown is handled by ``close()``.
    private func finishStreams() {
        guard state != .closed else { return }
        state = .closing
        stopMonitoringTasks()

        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
        state = .closed
    }
}

// MARK: - Sending
extension USBHostKit.Client.USBDeviceClient {
    
    /// Applies a USB configuration value on the open device.
    ///
    /// - Parameters:
    ///   - value: Configuration value to select.
    ///   - matchInterfaces: Whether IOUSBHost should rematch interfaces after the change.
    /// - Throws: ``USBHostError`` when the client is inactive or configuration fails.
    public func configure(value: Int, matchInterfaces: Bool = true) throws {
        try ensureActiveSession()
        try device.configure(value: value, matchInterfaces: matchInterfaces)
        destroyCachedInterfaces()
    }
    
    /// Resets the open USB device.
    ///
    /// - Throws: ``USBHostError`` when the client is inactive or reset fails.
    public func reset() throws {
        try ensureActiveSession()
        try device.reset()
        destroyCachedInterfaces()
    }
    
    /// Aborts queued device-level requests.
    ///
    /// - Parameter option: Abort behavior option.
    /// - Throws: ``USBHostError`` when the client is inactive or abort fails.
    public func abortDeviceRequests(option: IOUSBHostAbortOption = .synchronous) throws {
        try ensureActiveSession()
        try device.abortDeviceRequests(option: option)
    }
    
    /// Sets idle timeout for an interface identified by interface number and alternate setting.
    ///
    /// - Parameters:
    ///   - timeout: Idle timeout in seconds.
    ///   - interfaceNumber: USB interface number.
    ///   - alternateSetting: USB alternate setting.
    /// - Throws: ``USBHostError`` when the client is inactive, arguments are invalid, or update fails.
    public func setInterfaceIdleTimeout(
        _ timeout: TimeInterval,
        interfaceNumber: Int,
        alternateSetting: Int = 0
    ) throws {
        try ensureActiveSession()
        guard
            let number = UInt8(exactly: interfaceNumber),
            let setting = UInt8(exactly: alternateSetting)
        else {
            throw USBHostError.badArgument
        }
        
        let interface = try acquireInterface(number: number, alternateSetting: setting)
        try interface.setIdleTimeout(timeout)
    }
    
    /// Sets idle timeout for an endpoint pipe.
    ///
    /// - Parameters:
    ///   - timeout: Idle timeout in seconds.
    ///   - selection: Endpoint selection.
    /// - Throws: ``USBHostError`` when the client is inactive, selection is invalid, or update fails.
    public func setEndpointIdleTimeout(_ timeout: TimeInterval, selection: InterfaceSelection) throws {
        let endpoint = try resolveEndpoint(for: selection)
        try endpoint.setIdleTimeout(timeout)
    }
    
    /// Clears halt/stall state on an endpoint.
    ///
    /// - Parameter selection: Endpoint selection.
    /// - Throws: ``USBHostError`` when the client is inactive, selection is invalid, or clear-stall fails.
    public func clearStall(selection: InterfaceSelection) throws {
        let endpoint = try resolveEndpoint(for: selection)
        try endpoint.clearStall()
    }
    
    /// Aborts queued I/O on an endpoint.
    ///
    /// - Parameters:
    ///   - selection: Endpoint selection.
    ///   - option: Abort behavior option.
    /// - Throws: ``USBHostError`` when the client is inactive, selection is invalid, or abort fails.
    public func abortEndpointIO(selection: InterfaceSelection, option: IOUSBHostAbortOption = .synchronous) throws {
        let endpoint = try resolveEndpoint(for: selection)
        try endpoint.abort(option: option)
    }
    
    /// Sends one synchronous bulk/interrupt transfer to an endpoint.
    ///
    /// - Parameters:
    ///   - data: Payload bytes to write.
    ///   - selection: Target endpoint selection.
    ///   - timeout: Completion timeout in seconds.
    /// - Returns: Number of bytes transferred.
    /// - Throws: ``USBHostError`` when the client is inactive, endpoint is invalid, or transfer fails.
    public func sendSynchronously(
        data: Data,
        to selection: InterfaceSelection,
        timeout: TimeInterval = IOUSBHostDefaultControlCompletionTimeout
    ) throws -> Int {
        let endpoint = try resolveEndpoint(for: selection)
        try validateOutputEndpoint(endpoint)
        let buffer = NSMutableData(data: data)
        return try endpoint.sendIORequest(data: buffer, timeout: timeout)
    }
    
    /// Receives one synchronous bulk/interrupt transfer from an endpoint.
    ///
    /// - Parameters:
    ///   - selection: Target endpoint selection.
    ///   - length: Requested receive buffer size in bytes.
    ///   - timeout: Completion timeout in seconds.
    /// - Returns: Received payload bytes.
    /// - Throws: ``USBHostError`` when the client is inactive, arguments are invalid, endpoint is invalid, or transfer fails.
    public func receiveSynchronously(
        from selection: InterfaceSelection,
        length: Int,
        timeout: TimeInterval = IOUSBHostDefaultControlCompletionTimeout
    ) throws -> Data {
        guard length > 0 else { throw USBHostError.badArgument }
        let endpoint = try resolveEndpoint(for: selection)
        try validateInputEndpoint(endpoint)
        let buffer = try device.makeIOData(capacity: length)
        let bytes = try endpoint.sendIORequest(data: buffer, timeout: timeout)
        return Data(bytes: buffer.bytes, count: bytes)
    }
    
    /// Receives one asynchronous bulk/interrupt transfer from an endpoint.
    ///
    /// - Parameters:
    ///   - selection: Target endpoint selection.
    ///   - length: Requested receive buffer size in bytes.
    ///   - timeout: Completion timeout in seconds.
    /// - Returns: Received payload bytes.
    /// - Throws: ``USBHostError`` when the client is inactive, arguments are invalid, endpoint is invalid, or transfer fails.
    public func receive(
        from selection: InterfaceSelection,
        length: Int,
        timeout: TimeInterval = IOUSBHostDefaultControlCompletionTimeout
    ) async throws -> Data {
        guard length > 0 else { throw USBHostError.badArgument }
        let endpoint = try resolveEndpoint(for: selection)
        try validateInputEndpoint(endpoint)
        return try await readData(from: endpoint, length: length, timeout: timeout)
    }
    
    /// Sends data to an output endpoint identified by an interface selection.
    ///
    /// - Parameters:
    ///   - data: Payload bytes to write.
    ///   - selection: Target interface, alternate setting, and endpoint.
    ///   - timeout: Completion timeout in seconds.
    /// - Returns: Number of bytes transferred.
    /// - Throws: ``USBHostError`` when the client is inactive, endpoint is invalid, or the I/O request fails.
    public func send(data: Data, to selection: InterfaceSelection, timeout: TimeInterval = IOUSBHostDefaultControlCompletionTimeout) async throws -> Int {
        let endpoint = try resolveEndpoint(for: selection)
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
    /// - Throws: ``USBHostError`` when the client is inactive or the request fails.
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
    /// - Throws: ``USBHostError`` when the client is inactive or the request fails.
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
    /// - Throws: ``USBHostError`` when arguments are invalid, the client is inactive, or the request fails.
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

// MARK: - Descriptor & Introspection
extension USBHostKit.Client.USBDeviceClient {
    /// Returns the current USB device address assigned by the host.
    ///
    /// - Returns: Device address value.
    /// - Throws: ``USBHostError/notOpen`` when the client is not active.
    public func deviceAddress() throws -> Int {
        try ensureActiveSession()
        return device.deviceAddress
    }
    
    /// Reads the current host frame number from IOUSBHost.
    ///
    /// - Returns: Current USB frame number.
    /// - Throws: ``USBHostError/notOpen`` when the client is not active.
    public func currentFrameNumber() throws -> UInt64 {
        try ensureActiveSession()
        return device.currentFrameNumber
    }
    
    /// Reads a string descriptor from the device.
    ///
    /// - Parameters:
    ///   - index: String descriptor index.
    ///   - languageID: USB language identifier used for lookup.
    /// - Returns: Localized string descriptor value.
    /// - Throws: ``USBHostError`` when the client is inactive or descriptor retrieval fails.
    public func stringDescriptor(
        index: Int,
        languageID: Int = Int(kIOUSBLanguageIDEnglishUS.rawValue)
    ) throws -> String {
        try ensureActiveSession()
        return try device.stringDescriptor(index: index, languageID: languageID)
    }
    
    /// Reads the active configuration descriptor as raw bytes.
    ///
    /// - Returns: Configuration descriptor bytes including subordinate descriptors.
    /// - Throws: ``USBHostError`` when the client is inactive or descriptor data is unavailable.
    public func currentConfigurationDescriptorData() throws -> Data {
        try ensureActiveSession()
        guard let descriptor = device.currentConfigurationDescriptor else {
            throw USBHostError.invalid
        }
        
        let length = Int(descriptor.pointee.wTotalLength)
        guard length > 0 else { throw USBHostError.invalid }
        return Data(bytes: descriptor, count: length)
    }
    
    /// Reads a configuration descriptor by configuration value as raw bytes.
    ///
    /// - Parameter configurationValue: USB configuration value to query.
    /// - Returns: Configuration descriptor bytes including subordinate descriptors.
    /// - Throws: ``USBHostError`` when the client is inactive or descriptor retrieval fails.
    public func configurationDescriptorData(configurationValue: Int) throws -> Data {
        try ensureActiveSession()
        let descriptor = try device.configurationDescriptor(configurationValue: configurationValue)
        let length = Int(descriptor.pointee.wTotalLength)
        guard length > 0 else { throw USBHostError.invalid }
        return Data(bytes: descriptor, count: length)
    }
    
    /// Reads BOS/capability descriptors as raw bytes when supported by the device.
    ///
    /// - Returns: BOS descriptor bytes, or `nil` when the device has no BOS descriptor.
    /// - Throws: ``USBHostError/notOpen`` when the client is not active.
    public func capabilityDescriptorsData() throws -> Data? {
        try ensureActiveSession()
        guard let descriptors = device.capabilityDescriptors else {
            return nil
        }
        
        let length = Int(descriptors.pointee.wTotalLength)
        guard length > 0 else { return nil }
        return Data(bytes: descriptors, count: length)
    }
    
    /// Reads a descriptor tuple and returns the resulting bytes.
    ///
    /// - Parameters:
    ///   - type: Descriptor type.
    ///   - maxLength: Maximum descriptor length to request.
    ///   - index: Descriptor index.
    ///   - languageID: USB language identifier for string descriptors.
    ///   - requestType: USB request type value.
    ///   - requestRecipient: USB request recipient value.
    /// - Returns: Descriptor bytes.
    /// - Throws: ``USBHostError`` when the client is inactive, arguments are invalid, or retrieval fails.
    public func descriptorData(
        type: tIOUSBDescriptorType,
        maxLength: Int,
        index: Int,
        languageID: Int,
        requestType: tIOUSBDeviceRequestTypeValue,
        requestRecipient: tIOUSBDeviceRequestRecipientValue
    ) throws -> Data {
        try ensureActiveSession()
        guard maxLength > 0 else { throw USBHostError.badArgument }
        
        var requestedLength = maxLength
        guard let descriptor = try device.descriptor(
            type: type,
            maxLength: &requestedLength,
            index: index,
            languageID: languageID,
            requestType: requestType,
            requestRecipient: requestRecipient
        ) else {
            throw USBHostError.invalid
        }
        
        let copiedLength = max(0, min(requestedLength, maxLength))
        guard copiedLength > 0 else { return Data() }
        return Data(bytes: descriptor, count: copiedLength)
    }
}

// MARK: - Advanced Endpoint
extension USBHostKit.Client.USBDeviceClient {
    /// Enables USB streams on the selected endpoint.
    ///
    /// - Parameter selection: Target endpoint selection.
    /// - Throws: ``USBHostError`` when the client is inactive, selection is invalid, or stream enabling fails.
    public func enableStreams(selection: InterfaceSelection) throws {
        let endpoint = try resolveEndpoint(for: selection)
        try endpoint.enableStreams()
    }
    
    /// Disables USB streams on the selected endpoint.
    ///
    /// - Parameter selection: Target endpoint selection.
    /// - Throws: ``USBHostError`` when the client is inactive, selection is invalid, or stream disabling fails.
    public func disableStreams(selection: InterfaceSelection) throws {
        let endpoint = try resolveEndpoint(for: selection)
        try endpoint.disableStreams()
    }
    
    /// Opens a stream handle by stream identifier on the selected endpoint.
    ///
    /// - Parameters:
    ///   - streamID: Stream identifier.
    ///   - selection: Target endpoint selection.
    /// - Returns: Opened IOUSBHost stream handle.
    /// - Throws: ``USBHostError`` when the client is inactive, selection is invalid, or stream lookup fails.
    public func copyStream(streamID: Int, selection: InterfaceSelection) throws -> IOUSBHostStream {
        let endpoint = try resolveEndpoint(for: selection)
        return try endpoint.copyStream(streamID: streamID)
    }
    
    /// Reads the endpoint's active scheduling descriptors.
    ///
    /// - Parameter selection: Target endpoint selection.
    /// - Returns: Current endpoint scheduling descriptor values.
    /// - Throws: ``USBHostError/notOpen`` when the client is not active or endpoint resolution fails.
    public func endpointDescriptors(selection: InterfaceSelection) throws -> IOUSBHostIOSourceDescriptors {
        let endpoint = try resolveEndpoint(for: selection)
        return endpoint.descriptors.pointee
    }
    
    /// Reads the endpoint's original scheduling descriptors.
    ///
    /// - Parameter selection: Target endpoint selection.
    /// - Returns: Original endpoint scheduling descriptor values.
    /// - Throws: ``USBHostError/notOpen`` when the client is not active or endpoint resolution fails.
    public func endpointOriginalDescriptors(selection: InterfaceSelection) throws -> IOUSBHostIOSourceDescriptors {
        let endpoint = try resolveEndpoint(for: selection)
        return endpoint.originalDescriptors.pointee
    }
    
    /// Applies endpoint scheduling descriptor overrides.
    ///
    /// - Parameters:
    ///   - descriptors: Descriptor values to apply.
    ///   - selection: Target endpoint selection.
    /// - Throws: ``USBHostError`` when the client is inactive, selection is invalid, or adjustment fails.
    public func adjustEndpointDescriptors(
        _ descriptors: IOUSBHostIOSourceDescriptors,
        selection: InterfaceSelection
    ) throws {
        let endpoint = try resolveEndpoint(for: selection)
        var mutableDescriptors = descriptors
        try withUnsafePointer(to: &mutableDescriptors) { pointer in
            try endpoint.adjust(descriptors: pointer)
        }
    }
}

// MARK: - Endpoint helpers
extension USBHostKit.Client.USBDeviceClient {
    
    /// Ensures APIs are called while the device client is active.
    ///
    /// - Throws: ``USBHostError/notOpen`` when the client is not active.
    private func ensureActiveSession() throws {
        guard state == .active else { throw USBHostError.notOpen }
    }

    private struct CachedInterfaceKey: Hashable, Sendable {
        let interfaceNumber: UInt8
        let alternateSetting: UInt8
    }
    
    /// Resolves a public endpoint selection into a cached endpoint wrapper.
    ///
    /// - Parameter selection: Public endpoint selection.
    /// - Returns: Endpoint wrapper.
    /// - Throws: ``USBHostError`` when client is inactive, conversion fails, or resolution fails.
    private func resolveEndpoint(for selection: InterfaceSelection) throws -> USBEndpoint {
        try ensureActiveSession()
        let (interfaceNumber, alternateSetting, endpointAddress) = try validatedSelection(selection)
        let interface = try acquireInterface(number: interfaceNumber, alternateSetting: alternateSetting)
        let endpoint = try interface.copyEndpoint(address: endpointAddress)
        return endpoint
    }
    
    /// Returns a cached interface object for a selection, creating it when needed.
    ///
    /// - Parameters:
    ///   - number: USB interface number.
    ///   - alternateSetting: USB alternate setting value.
    /// - Returns: Cached interface object.
    /// - Throws: ``USBHostError`` when interface creation fails.
    private func acquireInterface(number: UInt8, alternateSetting: UInt8) throws -> USBInterface {
        let key = CachedInterfaceKey(interfaceNumber: number, alternateSetting: alternateSetting)

        if let cached = interfaceCache[key] {
            return cached
        }

        let interface = try device.interface(number, alternateSetting: alternateSetting)
        interfaceCache[key] = interface
        return interface
    }

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
        
        /// Creates immutable device information captured at client initialization time.
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


// MARK: - Client State
extension USBHostKit.Client.USBDeviceClient {
    private enum State {
        case active
        case closing
        case closed
    }
}
