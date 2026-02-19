// Package: USBDevice
// File: USBObject.swift
// Path: Sources/USBDevice/USBObject.swift
// Date: 2025-11-23
// Author: Ahmed Emerah
// Email: ahmed.emerah@icloud.com
// Github: https://github.com/Emerah


import Foundation
import IOUSBHost


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
    
    internal func destroy() {
        handle.destroy()
    }
    
    internal func destroy(options: IOUSBHostObjectDestroyOptions) {
        handle.destroy(options: options)
    }
}

// MARK: - Synchronous control requests
extension USBHostKit.Device.USBObject {
    
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
    
    internal func configurationDescriptor(configurationValue: Int) throws(USBHostError) -> UnsafePointer<IOUSBConfigurationDescriptor> {
        do {
            return try handle.configurationDescriptor(withConfigurationValue: configurationValue)
        } catch {
            throw USBHostError.translated(error)
        }
    }
    
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
    
    internal func frameNumber(with time: inout IOUSBHostTime) -> UInt64 {
        withUnsafeMutablePointer(to: &time) { ptr in
            handle.__frameNumber(withTime: ptr)
        }
    }
    
    internal func makeIOData(capacity: Int) throws(USBHostError) -> NSMutableData {
        do {
            return try handle.ioData(withCapacity: capacity)
        } catch {
            throw USBHostError.translated(error)
        }
    }
}
