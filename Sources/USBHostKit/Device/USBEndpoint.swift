// Package: USBDevice
// File: USBEndpoint.swift
// Path: Sources/USBDevice/USBEndpoint.swift
// Date: 2025-11-23
// Author: Ahmed Emerah
// Email: ahmed.emerah@icloud.com
// Github: https://github.com/Emerah


import Foundation
import IOUSBHost

extension USBHostKit.Device.USBDevice.USBInterface {
    internal final class USBEndpoint {
        
        internal typealias USBHandle = IOUSBHostPipe
        
        internal let handle: IOUSBHostPipe
        private let metadata: MetaData
        
        /// Creates an endpoint wrapper from an existing `IOUSBHostPipe`.
        ///
        /// - Parameter handle: Open pipe handle.
        internal init(handle: IOUSBHostPipe) {
            self.handle = handle
            let metadata = Self.retrieveEndpointMetadata(from: handle)
            self.metadata = metadata
        }
    }
}

// MARK: - Descriptors & policy
extension USBHostKit.Device.USBDevice.USBInterface.USBEndpoint {

    internal var originalDescriptors: UnsafePointer<IOUSBHostIOSourceDescriptors> {
        handle.originalDescriptors
    }

    internal var descriptors: UnsafePointer<IOUSBHostIOSourceDescriptors> {
        handle.descriptors
    }

    internal var hostInterface: IOUSBHostInterface {
        handle.hostInterface
    }

    /// Applies scheduling descriptor adjustments to the pipe.
    ///
    /// - Parameter descriptors: I/O source descriptor settings.
    /// - Throws: ``USBHostError`` when adjustment fails.
    internal func adjust(descriptors: UnsafePointer<IOUSBHostIOSourceDescriptors>) throws(USBHostError) {
        do {
            try handle.adjust(with:descriptors)
        } catch {
            throw USBHostError.translated(error)
        }
    }
}


// MARK: - Idle timeout & halt
extension USBHostKit.Device.USBDevice.USBInterface.USBEndpoint {
    internal var idleTimeout: TimeInterval {
        handle.idleTimeout
    }

    /// Sets endpoint idle timeout.
    ///
    /// - Parameter timeout: Idle timeout in seconds.
    /// - Throws: ``USBHostError`` when the operation fails.
    internal func setIdleTimeout(_ timeout: TimeInterval) throws(USBHostError) {
        do {
            try handle.setIdleTimeout(timeout)
        } catch {
            throw USBHostError.translated(error)
        }
    }

    /// Clears a halted/stalled endpoint.
    ///
    /// - Throws: ``USBHostError`` when clear-stall fails.
    internal func clearStall() throws(USBHostError) {
        do {
            try handle.clearStall()
        } catch {
            throw USBHostError.translated(error)
        }
    }
}

// MARK: - Abort
extension USBHostKit.Device.USBDevice.USBInterface.USBEndpoint {
    /// Aborts queued endpoint operations.
    ///
    /// - Parameter option: Abort behavior option.
    /// - Throws: ``USBHostError`` when abort fails.
    internal func abort(option: IOUSBHostAbortOption = .synchronous) throws(USBHostError) {
        do {
            try handle.__abort(with: option)
        } catch {
            throw USBHostError.translated(error)
        }
    }
}

// MARK: - Control transfers
extension USBHostKit.Device.USBDevice.USBInterface.USBEndpoint {
    /// Sends a synchronous control request on the endpoint.
    ///
    /// - Parameters:
    ///   - request: USB request descriptor.
    ///   - data: Optional payload buffer.
    ///   - timeout: Completion timeout in seconds.
    /// - Returns: Number of transferred bytes.
    /// - Throws: ``USBHostError`` when request execution fails.
    internal func sendControlRequest(
        _ request: IOUSBDeviceRequest,
        data: NSMutableData? = nil,
        timeout: TimeInterval = IOUSBHostDefaultControlCompletionTimeout
    ) throws(USBHostError) -> Int {
        var bytes: Int = 0
        do {
            try handle.__sendControlRequest(
                request,
                data: data,
                bytesTransferred: &bytes,
                completionTimeout: timeout
            )
        } catch {
            throw USBHostError.translated(error)
        }
        return bytes
    }

    /// Enqueues an asynchronous control request using a callback completion.
    ///
    /// - Parameters:
    ///   - request: USB request descriptor.
    ///   - data: Optional payload buffer.
    ///   - timeout: Completion timeout in seconds.
    ///   - completion: Optional completion callback.
    /// - Throws: ``USBHostError`` when enqueue fails.
    internal func enqueueControlRequest(
        _ request: IOUSBDeviceRequest,
        data: NSMutableData? = nil,
        timeout: TimeInterval = IOUSBHostDefaultControlCompletionTimeout,
        completion: (@Sendable (IOReturn, Int) -> Void)? = nil
    ) throws(USBHostError) {
        do {
            try handle.__enqueueControlRequest(
                request,
                data: data,
                completionTimeout: timeout,
                completionHandler: completion
            )
        } catch {
            throw USBHostError.translated(error)
        }
    }

    /// Enqueues an asynchronous control request and awaits completion.
    ///
    /// - Parameters:
    ///   - request: USB request descriptor.
    ///   - data: Optional payload buffer.
    ///   - timeout: Completion timeout in seconds.
    /// - Returns: Number of transferred bytes.
    /// - Throws: ``USBHostError`` when enqueue or completion fails.
    internal func enqueueControlRequest(
        _ request: IOUSBDeviceRequest,
        data: NSMutableData? = nil,
        timeout: TimeInterval = IOUSBHostDefaultControlCompletionTimeout
    ) async throws(USBHostError) -> Int {
        do {
            let (status, bytesTransferred) = try await handle.__enqueueControlRequest(
                request,
                data: data,
                completionTimeout: timeout
            )
            if status == kIOReturnSuccess {
                return bytesTransferred
            } else {
                throw USBHostError.translated(status: status)
            }
        } catch {
            throw USBHostError.translated(error)
        }
    }
}

// MARK: - Bulk / interrupt IO
extension USBHostKit.Device.USBDevice.USBInterface.USBEndpoint {
    /// Sends a synchronous bulk/interrupt I/O request.
    ///
    /// - Parameters:
    ///   - data: Payload buffer.
    ///   - timeout: Completion timeout in seconds.
    /// - Returns: Number of transferred bytes.
    /// - Throws: ``USBHostError`` when send fails.
    internal func sendIORequest(data: NSMutableData?, timeout: TimeInterval) throws(USBHostError) -> Int {
        var bytes: Int = 0
        do {
            try handle.__sendIORequest(with: data, bytesTransferred: &bytes, completionTimeout: timeout)
        } catch {
            throw USBHostError.translated(error)
        }
        return bytes
    }

    /// Enqueues a bulk/interrupt I/O request with optional callback completion.
    ///
    /// - Parameters:
    ///   - data: Payload buffer.
    ///   - timeout: Completion timeout in seconds.
    ///   - completionHandler: Optional completion callback.
    /// - Throws: ``USBHostError`` when enqueue fails.
    internal func enqueueIORequest(
        data: NSMutableData?,
        timeout: TimeInterval,
        completionHandler: (@Sendable (IOReturn, Int) -> Void)? = nil
    ) throws(USBHostError) {
        do {
            try handle.enqueueIORequest(with: data, completionTimeout: timeout, completionHandler: completionHandler)
        } catch {
            throw USBHostError.translated(error)
        }
    }
}


// MARK: - Streams
extension USBHostKit.Device.USBDevice.USBInterface.USBEndpoint {
    /// Enables USB streams for the endpoint.
    ///
    /// - Throws: ``USBHostError`` when enabling streams fails.
    internal func enableStreams() throws(USBHostError) {
        do {
            try handle.enableStreams()
        } catch {
            throw USBHostError.translated(error)
        }
    }

    /// Disables USB streams for the endpoint.
    ///
    /// - Throws: ``USBHostError`` when disabling streams fails.
    internal func disableStreams() throws(USBHostError) {
        do {
            try handle.disableStreams()
        } catch {
            throw USBHostError.translated(error)
        }
    }

    /// Copies a stream object by stream identifier.
    ///
    /// - Parameter streamID: Stream identifier.
    /// - Returns: Open stream object.
    /// - Throws: ``USBHostError`` when stream lookup/open fails.
    internal func copyStream(streamID: Int) throws(USBHostError) -> IOUSBHostStream {
        do {
            let stream = try handle.copyStream(withStreamID: streamID)
            return stream
        } catch {
            throw USBHostError.translated(error)
        }
    }
}


// MARK: - Metadata
extension USBHostKit.Device.USBDevice.USBInterface.USBEndpoint {
    internal var endpointAddress: UInt8 {
        metadata.endpointAddress
    }

    internal var maxPacketSize: UInt16 {
        metadata.maxPacketSize
    }

    internal var direction: USBEndpointDirection {
        metadata.direction
    }

    internal var transferType: USBEndpointTransferType {
        metadata.transferType
    }

    internal var pollInterval: UInt8 {
        metadata.pollInterval
    }
}


// MARK: - Metadata types
extension USBHostKit.Device.USBDevice.USBInterface.USBEndpoint {
    
    internal enum USBEndpointDirection: Sendable {
        case hostToDevice // out
        case deviceToHost // in
        
        /// Creates an endpoint direction from the endpoint address direction bit.
        ///
        /// - Parameter endpointAddress: USB endpoint address.
        internal init(endpointAddress: UInt8) {
            if (endpointAddress & 0x80) != 0 {
                self = .deviceToHost
            } else {
                self = .hostToDevice
            }
        }
    }

    internal enum USBEndpointTransferType: Sendable {
        case control
        case interrupt
        case bulk
        case isochronous
        case unknown

        /// Creates a transfer type from endpoint `bmAttributes`.
        ///
        /// - Parameter bmAtrributes: Endpoint attribute byte from descriptor.
        internal init(bmAtrributes: UInt8) {
            let transferType = (bmAtrributes & 0x03)
            switch transferType {
                case 0x00: self = .control
                case 0x01: self = .interrupt
                case 0x02: self = .bulk
                case 0x03: self = .isochronous
                default: self = .unknown
            }
        }
    }
}


extension USBHostKit.Device.USBDevice.USBInterface.USBEndpoint {

    fileprivate struct MetaData {
        fileprivate let endpointAddress: UInt8
        fileprivate let maxPacketSize: UInt16
        fileprivate let pollInterval: UInt8
        fileprivate let direction: USBEndpointDirection
        fileprivate let transferType: USBEndpointTransferType
    }

    /// Reads endpoint metadata from pipe descriptors.
    ///
    /// - Parameter handle: Endpoint pipe handle.
    /// - Returns: Metadata snapshot used by endpoint accessors.
    private static func retrieveEndpointMetadata(from handle: IOUSBHostPipe) -> MetaData {
        let descriptor = handle.descriptors.pointee.descriptor
        let endpointAddress = descriptor.bEndpointAddress
        let maxPacketSize = descriptor.wMaxPacketSize
        let pollInterval = descriptor.bInterval
        let direction = USBEndpointDirection(endpointAddress: endpointAddress)
        let transferType = USBEndpointTransferType(bmAtrributes: descriptor.bmAttributes)
        return MetaData(endpointAddress: endpointAddress, maxPacketSize: maxPacketSize, pollInterval: pollInterval, direction: direction, transferType: transferType)
    }
}
