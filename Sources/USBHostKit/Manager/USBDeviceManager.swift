// Package: USBConnection
// File: USBConnection.swift
// Path: Sources/USBConnection/USBConnection.swift
// Date: 2025-11-23
// Author: Ahmed Emerah
// Email: ahmed.emerah@icloud.com
// Github: https://github.com/Emerah



import Foundation
import IOKit
import IOKit.usb


fileprivate typealias USBLogger = USBHostKit.Manager.USBLogger

// MARK: - DECLARE USB DEVICE MANAGER
extension USBHostKit.Manager {
    
    public final actor USBDeviceManager {
        
        private let notificationQueue = DispatchQueue(label: "com.USBHostKit.Manager.notifications", qos: .default)
        private var notificationPort: IONotificationPortRef? = nil
        private var continuation: AsyncThrowingStream<USBDeviceManager.Notification, Error>.Continuation?
        private var connectionContext: UnsafeMutableRawPointer?
        private var iteratorRegistry: IteratorRegistry?
        private var deviceMatchingCriteria: DeviceMatchingCriteria?
        private var isMonitoring = false

        /// Creates an idle USB device manager actor.
        public init() {}
        
    }
}


// MARK: - MONITORING PUBLIC API
extension USBHostKit.Manager.USBDeviceManager {

    /// Starts device monitoring and returns an async stream of match/removal notifications.
    ///
    /// - Parameter matchingCriteria: Criteria applied to IOKit matching dictionaries.
    /// - Returns: Async stream that yields device notifications.
    /// - Throws: ``ConnectionError`` when monitoring setup fails.
    public func monitorNotifications(matchingCriteria: DeviceMatchingCriteria) throws -> AsyncThrowingStream<Notification, any Error> {
        self.deviceMatchingCriteria = matchingCriteria
        var tempContinuation: AsyncThrowingStream<USBDeviceManager.Notification, Error>.Continuation?
        let stream = AsyncThrowingStream<USBDeviceManager.Notification, Error>(bufferingPolicy: .bufferingOldest(64)) { tempContinuation = $0 }

        guard let continuation = tempContinuation else {
            let error = ConnectionError.invalidContinuation
            USBLogger.error("\(#function) failed: \(error.errorDescriptor)")
            throw error
        }

        try startMonitoringDevices(continuation: continuation)
        return stream
    }

    /// Stops monitoring activity and releases all monitoring resources.
    public func endMonitoringActivity() {
        guard isMonitoring else { return }
        continuation?.finish()
        continuation = nil
        cleanupIOKitResources()
        USBLogger.info("\(#function) succeeded")
    }
}


// MARK: - MONITORING ENGINE
extension USBHostKit.Manager.USBDeviceManager {
    /// Sets up notification port, iterators, callbacks, and stream termination handling.
    ///
    /// - Parameter continuation: Stream continuation used to emit notifications.
    /// - Throws: ``ConnectionError`` when setup fails.
    private func startMonitoringDevices(continuation: AsyncThrowingStream<USBDeviceManager.Notification, Error>.Continuation) throws {
        
        guard !isMonitoring else {
            let error = ConnectionError.monitoringAlreadyStarted
            USBLogger.error("\(#function) failed: \(error.errorDescriptor)")
            throw error
        }

        do {
            let port = try createNotificationPort()
            setDispatchQueue(notificationQueue, for: port)
            self.notificationPort = port
                
            self.continuation = continuation
            isMonitoring = true

            let context = Unmanaged.passRetained(self).toOpaque()
            self.connectionContext = context

            let iteratorRegistry = try registerNotificationIterators(context)
            self.iteratorRegistry = iteratorRegistry

            drain(iterator: iteratorRegistry.matchingIterator, event: .connected)
            drain(iterator: iteratorRegistry.terminatingIterator, event: .disconnected)

            continuation.onTermination = { @Sendable [weak self] termination in
                guard let self else { return }
                Task { await self.handleStreamTermination(reason: termination) }
            }
            USBLogger.info("\(#function) succeeded")
        } catch let error as ConnectionError {
            self.continuation = nil
            cleanupIOKitResources()
            throw error
        }
    }

    /// Registers first-match and termination iterators for the configured criteria.
    ///
    /// - Parameter context: Retained actor pointer passed to C callbacks.
    /// - Returns: Registered iterator handles.
    /// - Throws: ``ConnectionError`` when registration fails.
    private func registerNotificationIterators(_ context: UnsafeMutableRawPointer) throws -> IteratorRegistry {
        guard let port = notificationPort else {
            let error = ConnectionError.notificationPortUnavailable
            USBLogger.error("\(#function) failed: \(error.errorDescriptor)")
            throw error
        }
        
        guard
            let matchingDictionary = buildMatchingDictionary(className: kIOUSBHostDeviceClassName, criteria: deviceMatchingCriteria),
            let terminationDictionary = buildMatchingDictionary(className: kIOUSBHostDeviceClassName, criteria: deviceMatchingCriteria)
        else {
            let error = ConnectionError.matchingDictionaryUnavailable
            USBLogger.error("\(#function) failed: \(error.errorDescriptor)")
            throw error
        }
        
        let matchingIterator: io_iterator_t
        
        do {
            matchingIterator = try addMatchingNotification(
                port: port,
                notification: kIOFirstMatchNotification,
                matchingDictionary: matchingDictionary,
                callback: Self.deviceMatchedCallback,
                context: context
            )
        } catch let error as ConnectionError {
            throw error
        }
        
        let terminationIterator: io_iterator_t
        
        do {
            terminationIterator = try addMatchingNotification(
                port: port,
                notification: kIOTerminatedNotification,
                matchingDictionary: terminationDictionary,
                callback: Self.deviceTerminatedCallback,
                context: context
            )
        } catch let error as ConnectionError {
            releaseIOObject(matchingIterator)
            throw error
        }

        USBLogger.info("\(#function) succeeded")
        return IteratorRegistry(matchingIterator: matchingIterator, terminationIterator: terminationIterator)
    }
}

// MARK: - IOKit HELPERS
extension USBHostKit.Manager.USBDeviceManager {
    /// Adds one IOKit matching notification and returns its iterator.
    ///
    /// - Returns: Registered iterator handle.
    /// - Throws: ``ConnectionError`` when registration fails.
    private func addMatchingNotification(
        port: IONotificationPortRef,
        notification: UnsafePointer<CChar>?,
        matchingDictionary: CFMutableDictionary,
        callback: @escaping IOServiceMatchingCallback,
        context: UnsafeMutableRawPointer?
    ) throws -> io_iterator_t {
        guard let notification else {
            let error = ConnectionError.invalidNotificationName
            USBLogger.error("\(#function) failed: \(error.errorDescriptor)")
            throw error
        }

        var iterator: io_iterator_t = IO_OBJECT_NULL
        let status = IOServiceAddMatchingNotification(port, notification, matchingDictionary, callback, context, &iterator)
        
        guard status == KERN_SUCCESS else {
            let error = ConnectionError.addingNotificationFailed(status)
            USBLogger.error("\(#function) failed: \(error.errorDescriptor)")
            throw error
        }
        USBLogger.info("\(#function) succeeded")
        return iterator
    }

    /// Creates an IOKit matching dictionary and applies optional filtering criteria.
    ///
    /// - Parameters:
    ///   - className: IOKit class name to match.
    ///   - criteria: Optional criteria values for filtering.
    /// - Returns: Mutable matching dictionary or `nil` if base dictionary creation fails.
    private func buildMatchingDictionary(className: UnsafePointer<CChar>, criteria: USBHostKit.Manager.USBDeviceManager.DeviceMatchingCriteria? = nil) -> CFMutableDictionary? {
        guard let dictionary = IOServiceMatching(className) else {
            return nil
        }

        if let criteria {
            let vendorID = criteria.vendorID
            let productID = criteria.productID
            let mDict = dictionary as NSMutableDictionary
            mDict[kUSBVendorID] = vendorID
            mDict[kUSBProductID] = productID
            if let productName = criteria.name { mDict[kUSBProductString] = productName as CFString }
            if let manufacturerName = criteria.manufacturer { mDict[kUSBVendorString] = manufacturerName as CFString }
            if let serialNumber = criteria.serialNumber { mDict[kUSBSerialNumberString] = serialNumber as CFString }
            return mDict as CFMutableDictionary
        }

        return dictionary
    }

    /// Creates an IOKit notification port.
    ///
    /// - Returns: Notification port handle.
    /// - Throws: ``ConnectionError`` when port allocation fails.
    private func createNotificationPort() throws -> IONotificationPortRef {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            let error = ConnectionError.notificationPortUnavailable
            USBLogger.error("\(#function) failed: \(error.errorDescriptor)")
            throw error
        }
        USBLogger.info("\(#function) succeeded")
        return port
    }

    /// Assigns a dispatch queue to an IOKit notification port.
    ///
    /// - Parameters:
    ///   - queue: Queue to assign, or `nil` to detach.
    ///   - port: Notification port to configure.
    private func setDispatchQueue(_ queue: DispatchQueue?, for port: IONotificationPortRef) {
        IONotificationPortSetDispatchQueue(port, queue)
    }

    /// Destroys an IOKit notification port.
    ///
    /// - Parameter port: Port to destroy.
    private func destroyNotificationPort(_ port: IONotificationPortRef) {
        IONotificationPortDestroy(port)
    }

    /// Releases an IOKit object handle.
    ///
    /// - Parameter object: Object to release.
    private func releaseIOObject(_ object: io_object_t) {
        IOObjectRelease(object)
    }
}

// MARK: - IOKit C-STYLE CALLBACKS
extension USBHostKit.Manager.USBDeviceManager {

    private static let deviceMatchedCallback: IOServiceMatchingCallback = { refcon, iterator in
        guard let refcon else { return }
        let manager = Unmanaged<USBDeviceManager>.fromOpaque(refcon).takeUnretainedValue()
        Task { await manager.handleConnectionEvent(iterator: iterator, event: .connected) }
    }

    private static let deviceTerminatedCallback: IOServiceMatchingCallback = { refcon, iterator in
        guard let refcon else { return }
        let manager = Unmanaged<USBDeviceManager>.fromOpaque(refcon).takeUnretainedValue()
        Task { await manager.handleConnectionEvent(iterator: iterator, event: .disconnected) }
    }
}


// MARK: - HANDLE CONNECTION
extension USBHostKit.Manager.USBDeviceManager {

    /// Handles stream termination by clearing continuation state and releasing resources.
    ///
    /// - Parameter reason: Stream termination reason.
    private func handleStreamTermination(reason: AsyncThrowingStream<USBDeviceManager.Notification, Error>.Continuation.Termination) {
        guard isMonitoring else { return }
        self.continuation = nil
        cleanupIOKitResources()
    }

    /// Processes one callback event by draining its iterator.
    ///
    /// - Parameters:
    ///   - iterator: Event iterator received from callback.
    ///   - event: Event kind to emit.
    private func handleConnectionEvent(iterator: io_iterator_t, event: ConnectionEvent) {
        drain(iterator: iterator, event: event)
    }

    /// Drains all services from an iterator and emits match/removal notifications.
    ///
    /// - Parameters:
    ///   - iterator: Iterator to drain.
    ///   - event: Event type for emitted notifications.
    private func drain(iterator: io_iterator_t, event: ConnectionEvent) {
        guard iterator != IO_OBJECT_NULL else { return }
        
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            guard let continuation else {
                releaseIOObject(service)
                continue
            }

            switch event {
                case .connected:
                    USBLogger.info("\(#function) device connected: service \(service)")
                    if let registryID = registryID(for: service) {
                        let deviceReference = USBDeviceClient.DeviceReference(deviceID: registryID)
                        continuation.yield(.deviceMatched(deviceReference))
                    }
                case .disconnected:
                    USBLogger.info("\(#function) device disconnected: service \(service)")
                    if let registryID = registryID(for: service) {
                        let deviceReference = USBDeviceClient.DeviceReference(deviceID: registryID)
                        continuation.yield(.deviceRemoved(deviceReference))
                    }
            }
            
            releaseIOObject(service)
        }

    }
}

// MARK: - Registry ID
extension USBHostKit.Manager.USBDeviceManager {
    
    /// Reads IORegistry entry ID for a service.
    ///
    /// - Parameter service: Service whose registry ID is requested.
    /// - Returns: Registry ID on success, otherwise `nil`.
    private func registryID(for service: io_service_t) -> UInt64? {
        var entryID: UInt64 = 0
        let status = IORegistryEntryGetRegistryEntryID(service, &entryID)
        guard status == KERN_SUCCESS else { return nil }
        return entryID
    }
}

// MARK: - CLEANUP IOKit RESOURCES
extension USBHostKit.Manager.USBDeviceManager {

    /// Releases iterators, notification port, and retained callback context.
    private func cleanupIOKitResources() {
        if let registry = iteratorRegistry {
            releaseIOObject(registry.matchingIterator)
            releaseIOObject(registry.terminatingIterator)
            self.iteratorRegistry = nil
        }

        if let port = notificationPort {
            setDispatchQueue(nil, for: port)
            destroyNotificationPort(port)
            self.notificationPort = nil
        }

        if let context = connectionContext {
            Unmanaged<USBDeviceManager>.fromOpaque(context).release()
            self.connectionContext = nil
        }

        isMonitoring = false
        USBLogger.info("\(#function) successful")
    }
}


// MARK: - CONNECTION EVENT
extension USBHostKit.Manager.USBDeviceManager {
    private enum ConnectionEvent {
        case connected
        case disconnected
    }
}

// MARK: - ITERATORS REGISTRY
extension USBHostKit.Manager.USBDeviceManager {
    private struct IteratorRegistry {
        
        fileprivate let matchingIterator: io_iterator_t
        
        fileprivate let terminatingIterator: io_iterator_t

        /// Creates an iterator registry with match and termination iterators.
        ///
        /// - Parameters:
        ///   - matchingIterator: First-match iterator.
        ///   - terminationIterator: Termination iterator.
        fileprivate init(matchingIterator: io_iterator_t, terminationIterator: io_iterator_t) {
            self.matchingIterator = matchingIterator
            self.terminatingIterator = terminationIterator
        }
    }
}


extension USBHostKit.Manager.USBDeviceManager {
    public struct DeviceMatchingCriteria: Sendable {
        public let vendorID: UInt16
        public let productID: UInt16
        public let name: String?
        public let manufacturer: String?
        public let serialNumber: String?

        /// Creates immutable matching criteria for device monitoring.
        ///
        /// - Parameters:
        ///   - vendorID: USB vendor identifier.
        ///   - productID: USB product identifier.
        ///   - productName: Optional product string filter.
        ///   - manufacturerName: Optional manufacturer string filter.
        ///   - serialNumber: Optional serial string filter.
        public init(vendorID: UInt16, productID: UInt16, productName: String? = nil, manufacturerName: String? = nil, serialNumber: String? = nil) {
            self.vendorID = vendorID
            self.productID = productID
            self.name = productName
            self.manufacturer = manufacturerName
            self.serialNumber = serialNumber
        }
    }
}


// MARK: - CONNECTION NOTIFICATAION
extension USBHostKit.Manager.USBDeviceManager {
    public enum Notification: Sendable {
        case deviceMatched(_ reference: USBDeviceClient.DeviceReference)
        case deviceRemoved(_ reference: USBDeviceClient.DeviceReference)
    }
}


// MARK: - CONNECTION ERROR
extension USBHostKit.Manager {
    internal enum ConnectionError: Error, LocalizedError {
        case monitoringAlreadyStarted
        case invalidContinuation
        case invalidNotificationName
        case notificationPortUnavailable
        case matchingDictionaryUnavailable
        case addingNotificationFailed(_ status: kern_return_t)
        
        internal var errorDescription: String? {
            switch self {
                case .monitoringAlreadyStarted:
                    return "Monitoring is already active."
                case .invalidContinuation:
                    return "Unable to start monitoring because the stream continuation is invalid."
                case .invalidNotificationName:
                    return "The provided notification name is invalid."
                case .notificationPortUnavailable:
                    return "Unable to create a notification port for USB events."
                case .matchingDictionaryUnavailable:
                    return "Unable to create a matching dictionary for USB device notifications."
                case .addingNotificationFailed(let status):
                    return "Failed to add a USB notification with kernel status \(status)."
            }
        }
        
        internal var errorDescriptor: String {
            errorDescription ?? "Unknown USB connection error."
        }
    }
}




extension USBHostKit.Manager {

    internal struct USBLogger {

        internal enum LogLevel: String {
            case debug = "DEBUG"
            case info = "INFO"
            case warning = "WARNING"
            case error = "ERROR"
        }

        // Core logging function
//        #if USBCONNECTION_LOGGING
        /// Writes one log message in debug builds.
        ///
        /// - Parameters:
        ///   - level: Log level.
        ///   - message: Log message.
        ///   - file: Source file identifier.
        ///   - line: Source line.
        #if DEBUG
        private static func log(_ level: LogLevel, _ message: String, file: StaticString = #fileID, line: UInt = #line) {
            print("\(timestamp()): [\(level.rawValue)] - \(file):\(line):- \(message)")
        }
        #else
        /// No-op logger used in non-debug builds.
        @inline(__always) private static func log(_ level: LogLevel, _ message: String, file: StaticString = #fileID, line: UInt = #line) { }
        #endif

        // MARK: - Convenience methods
        /// Logs an informational message.
        internal static func info(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
            log(.info, message, file: file, line: line)
        }

        /// Logs a warning message.
        internal static func warning(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
            log(.warning, message, file: file, line: line)
        }

        /// Logs an error message.
        internal static func error(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
            log(.error, message, file: file, line: line)
        }

        /// Logs a debug message.
        internal static func debug(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
            log(.debug, message, file: file, line: line)
        }

        // MARK: - Helper
        /// Creates an HH:mm:ss timestamp string for log prefixes.
        ///
        /// - Returns: Formatted local timestamp string.
        private static func timestamp() -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter.string(from: Date())
        }
    }
}
