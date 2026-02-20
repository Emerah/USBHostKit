// Package: USBDevice
// File: USBObject.swift
// Path: Sources/USBDevice/USBObject.swift
// Date: 2025-11-23
// Author: Ahmed Emerah
// Email: ahmed.emerah@icloud.com
// Github: https://github.com/Emerah


import Foundation
import IOUSBHost


// MARK: - Protocol
extension USBHostKit.Device {
    internal protocol USBObject {
        associatedtype USBHandle: IOUSBHostObject
        var handle: USBHandle { get }
    }
}



// MARK: - Session management / creation
extension USBHostKit.Device.USBObject {
    internal var ioService: io_service_t {
        handle.ioService
    }
    
    internal var queue: DispatchQueue {
        handle.queue
    }
    
    /// Destroys the wrapped IOUSBHost object.
    internal func destroy() {
        handle.destroy()
    }
    
    /// Destroys the wrapped IOUSBHost object with explicit destroy options.
    ///
    /// - Parameter options: Host-object destroy options.
    internal func destroy(options: IOUSBHostObjectDestroyOptions) {
        handle.destroy(options: options)
    }
}

// MARK: - Synchronous control requests
extension USBHostKit.Device.USBObject {
    
    /// Sends a synchronous device request and returns the transfer count.
    ///
    /// - Parameters:
    ///   - request: USB device request descriptor.
    ///   - data: Optional payload buffer.
    ///   - timeout: Completion timeout in seconds.
    /// - Returns: Number of bytes transferred.
    /// - Throws: ``USBHostError`` when request execution fails.
    internal func sendDeviceRequest(
        _ request: IOUSBDeviceRequest,
        data: NSMutableData? = nil,
        timeout: TimeInterval = IOUSBHostDefaultControlCompletionTimeout
    ) throws(USBHostError) -> Int {
        var bytesTransferred: Int = 0
        do {
            try handle.__send(request, data: data, bytesTransferred: &bytesTransferred, completionTimeout: timeout)
        } catch {
            throw USBHostError.translated(error)
        }
        return bytesTransferred
    }
    
    /// Sends a synchronous device request without a payload buffer.
    ///
    /// - Parameters:
    ///   - request: USB device request descriptor.
    ///   - timeout: Completion timeout in seconds.
    /// - Throws: ``USBHostError`` when request execution fails.
    internal func sendDeviceRequest(_ request: IOUSBDeviceRequest, timeout: TimeInterval = IOUSBHostDefaultControlCompletionTimeout) throws(USBHostError) {
        do {
            try handle.__send(request, data: nil, bytesTransferred: nil, completionTimeout: timeout)
        } catch {
            throw USBHostError.translated(error)
        }
    }
}

// MARK: - Asynchronous control requests
extension USBHostKit.Device.USBObject {
    
    /// Enqueues an asynchronous device request.
    ///
    /// - Parameters:
    ///   - request: USB device request descriptor.
    ///   - data: Optional payload buffer.
    ///   - timeout: Completion timeout in seconds.
    ///   - completion: Completion callback with status and bytes transferred.
    /// - Throws: ``USBHostError`` when enqueue fails.
    internal func enqueueDeviceRequest(
        _ request: IOUSBDeviceRequest,
        data: NSMutableData? = nil,
        timeout: TimeInterval = IOUSBHostDefaultControlCompletionTimeout,
        completion: @Sendable @escaping (IOReturn, Int) -> Void
    ) throws(USBHostError) {
        do {
            try handle.__enqueue(request, data: data, completionTimeout: timeout, completionHandler: completion)
        } catch {
            throw USBHostError.translated(error)
        }
    }
    
    /// Aborts pending device requests.
    ///
    /// - Parameter option: Abort behavior option.
    /// - Throws: ``USBHostError`` when abort fails.
    internal func abortDeviceRequests(option: IOUSBHostAbortOption = .synchronous) throws(USBHostError) {
        do {
            try handle.__abortDeviceRequests(with: option)
        } catch {
            throw USBHostError.translated(error)
        }
    }
}

// MARK: - Descriptor helpers
extension USBHostKit.Device.USBObject {
    
    /// Reads a descriptor pointer from the device for the requested descriptor tuple.
    ///
    /// - Parameters:
    ///   - type: Descriptor type.
    ///   - maxLength: In/out maximum descriptor length.
    ///   - index: Descriptor index.
    ///   - languageID: String language ID when applicable.
    ///   - requestType: USB request type field.
    ///   - requestRecipient: USB request recipient field.
    /// - Returns: Descriptor pointer when available.
    /// - Throws: ``USBHostError`` when retrieval fails.
    internal func descriptor(
        type: tIOUSBDescriptorType,
        maxLength: inout Int,
        index: Int,
        languageID: Int,
        requestType: tIOUSBDeviceRequestTypeValue,
        requestRecipient: tIOUSBDeviceRequestRecipientValue
    ) throws(USBHostError) -> UnsafePointer<IOUSBDescriptor>? {
        var lengthStorage = maxLength
        let ptr: UnsafePointer<IOUSBDescriptor>?
        do {
            ptr = try handle.__descriptor(
                with: type,
                length: &lengthStorage,
                index: index,
                languageID: languageID,
                requestType: requestType,
                requestRecipient: requestRecipient
            )
        } catch {
            throw USBHostError.translated(error)
        }
        
        maxLength = lengthStorage
        return ptr
    }
    
    internal var deviceDescriptor: UnsafePointer<IOUSBDeviceDescriptor>? {
        handle.deviceDescriptor
    }
    
    internal var capabilityDescriptors: UnsafePointer<IOUSBBOSDescriptor>? {
        handle.capabilityDescriptors
    }
    
    /// Returns a configuration descriptor for a specific configuration value.
    ///
    /// - Parameter configurationValue: Configuration value to query.
    /// - Returns: Pointer to configuration descriptor.
    /// - Throws: ``USBHostError`` when retrieval fails.
    internal func configurationDescriptor(configurationValue: Int) throws(USBHostError) -> UnsafePointer<IOUSBConfigurationDescriptor> {
        do {
            return try handle.configurationDescriptor(withConfigurationValue: configurationValue)
        } catch {
            throw USBHostError.translated(error)
        }
    }
    
    /// Reads a UTF string descriptor from the device.
    ///
    /// - Parameters:
    ///   - index: String descriptor index.
    ///   - languageID: Language ID used for descriptor lookup.
    /// - Returns: Localized descriptor string.
    /// - Throws: ``USBHostError`` when retrieval fails.
    internal func stringDescriptor(index: Int, languageID: Int = Int(kIOUSBLanguageIDEnglishUS.rawValue)) throws(USBHostError) -> String {
        do {
            return try handle.__string(with: Int(index), languageID: languageID)
        } catch {
            throw USBHostError.translated(error)
        }
    }
}

// MARK: - Misc
extension USBHostKit.Device.USBObject {
    internal var deviceAddress: Int {
        handle.deviceAddress
    }
    
    internal var currentFrameNumber: UInt64 {
        handle.__frameNumber(withTime: nil)
    }
    
    /// Retrieves the current frame number and updates the provided time stamp.
    ///
    /// - Parameter time: In/out USB host time structure.
    /// - Returns: Current frame number.
    internal func frameNumber(with time: inout IOUSBHostTime) -> UInt64 {
        withUnsafeMutablePointer(to: &time) { ptr in
            handle.__frameNumber(withTime: ptr)
        }
    }
    
    /// Allocates I/O data storage using the host object allocator.
    ///
    /// - Parameter capacity: Requested buffer capacity in bytes.
    /// - Returns: Mutable data object suitable for USB I/O APIs.
    /// - Throws: ``USBHostError`` when allocation fails.
    internal func makeIOData(capacity: Int) throws(USBHostError) -> NSMutableData {
        do {
            return try handle.ioData(withCapacity: capacity)
        } catch {
            throw USBHostError.translated(error)
        }
    }
}
