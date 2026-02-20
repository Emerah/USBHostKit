// Package: USBDevice
// File: USBInterface.swift
// Path: Sources/USBDevice/USBInterface.swift
// Date: 2025-11-23
// Author: Ahmed Emerah
// Email: ahmed.emerah@icloud.com
// Github: https://github.com/Emerah


import Foundation
import IOUSBHost


// MARK: - Interface type
extension USBHostKit.Device.USBDevice {
    internal final class USBInterface: USBObject {
        
        internal typealias USBHandle = IOUSBHostInterface
        
        internal let handle: IOUSBHostInterface
        private let metadata: MetaData

        /// Creates an interface wrapper from an existing `IOUSBHostInterface` handle.
        ///
        /// - Parameter handle: Open interface handle.
        internal init(handle: IOUSBHostInterface) {
            self.handle = handle
            let metadata = Self.retrieveInterfaceMetadata(from: handle)
            self.metadata = metadata
        }
        
        /// Creates and wraps an interface from an `io_service_t`.
        ///
        /// - Parameters:
        ///   - service: Interface service entry.
        ///   - options: Host object initialization options.
        ///   - queue: Dispatch queue used by the host object.
        ///   - interestHandler: Optional host-object interest callback.
        /// - Throws: ``USBHostError`` when handle creation fails.
        internal convenience init(
            service: io_service_t,
            options: IOUSBHostObjectInitOptions,
            queue: DispatchQueue?,
            interestHandler: IOUSBHostInterestHandler?
        ) throws(USBHostError) {
            do {
                let handle = try IOUSBHostInterface(__ioService: service, options: options, queue: queue, interestHandler: interestHandler)
                self.init(handle: handle)
            } catch {
                throw USBHostError.translated(error)
            }
        }
    }
}


// MARK: - Create matching dictionary
extension USBHostKit.Device.USBDevice.USBInterface {
    /// Builds an interface matching dictionary for IOKit matching APIs.
    ///
    /// - Returns: Retained mutable dictionary for interface matching.
    internal static func createMatchingDictionary(
        vendorID: NSNumber? = nil,
        productID: NSNumber? = nil,
        bcdDevice: NSNumber? = nil,
        interfaceNumber: NSNumber? = nil,
        configurationValue: NSNumber? = nil,
        interfaceClass: NSNumber? = nil,
        interfaceSubClass: NSNumber? = nil,
        interfaceProtocol: NSNumber? = nil,
        speed: NSNumber? = nil,
        productIDArray: [NSNumber]? = nil
    ) -> CFMutableDictionary {
        let dict = IOUSBHostInterface.__createMatchingDictionary(
            withVendorID: vendorID,
            productID: productID,
            bcdDevice: bcdDevice,
            interfaceNumber: interfaceNumber,
            configurationValue: configurationValue,
            interfaceClass: interfaceClass,
            interfaceSubclass: interfaceSubClass,
            interfaceProtocol: interfaceProtocol,
            speed: speed,
            productIDArray: productIDArray
        )
        
        return dict.takeRetainedValue()
    }
}


// MARK: - Power management
extension USBHostKit.Device.USBDevice.USBInterface {
    
    internal var idleTimeout: TimeInterval {
        handle.idleTimeout
    }
    
    /// Sets interface idle timeout.
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
}


// MARK: - Descriptors
extension USBHostKit.Device.USBDevice.USBInterface {
    
    internal var configurationDescriptor: UnsafePointer<IOUSBConfigurationDescriptor> {
        handle.configurationDescriptor
    }
    
    internal var interfaceDescriptor: UnsafePointer<IOUSBInterfaceDescriptor> {
        handle.interfaceDescriptor
    }
}


// MARK: - Alternate settings & pipes
extension USBHostKit.Device.USBDevice.USBInterface {
    
    /// Selects an alternate interface setting.
    ///
    /// - Parameter alternateSetting: Alternate setting value.
    /// - Throws: ``USBHostError`` when selection fails.
    internal func selectAlternateSetting(_ alternateSetting: Int) throws(USBHostError) {
        do {
            try handle.selectAlternateSetting(alternateSetting)
        } catch {
            throw USBHostError.translated(error)
        }
    }

    /// Copies a pipe by USB endpoint address and wraps it as ``USBEndpoint``.
    ///
    /// - Parameter address: Endpoint address.
    /// - Returns: Wrapped endpoint object.
    /// - Throws: ``USBHostError`` when the endpoint cannot be opened.
    internal func copyEndpoint(address: UInt8) throws(USBHostError) -> USBEndpoint {
        do {
            let pipe = try handle.copyPipe(withAddress: Int(address))
            return USBEndpoint(handle: pipe)
        } catch {
            throw USBHostError.translated(error)
        }
    }
}


// MARK: - Metadata
extension USBHostKit.Device.USBDevice.USBInterface {
    internal var name: String {
        metadata.name
    }

    internal var endpointCount: UInt8 {
        metadata.endpointCount
    }

    internal var interfaceNumber: UInt8 {
        metadata.interfaceNumber
    }

    internal var alternateSetting: UInt8 {
        metadata.alternateSetting
    }
}
// MARK: - Metadata support
extension USBHostKit.Device.USBDevice.USBInterface {
    fileprivate struct MetaData {
        fileprivate let name: String
        fileprivate let endpointCount: UInt8
        fileprivate let interfaceNumber: UInt8
        fileprivate let alternateSetting: UInt8
    }

    /// Reads interface metadata from descriptors and string tables.
    ///
    /// - Parameter handle: Interface handle to query.
    /// - Returns: Metadata snapshot for name/endpoints/interface IDs.
    private static func retrieveInterfaceMetadata(from handle: IOUSBHostInterface) -> MetaData {
        let descriptor = handle.interfaceDescriptor.pointee
        let endpointCount = descriptor.bNumEndpoints
        let interfaceNumber = descriptor.bInterfaceNumber
        let alternateSetting = descriptor.bAlternateSetting
        let languageID = Int(kIOUSBLanguageIDEnglishUS.rawValue)
        var name: String
        do {
            name = try handle.__string(with: Int(descriptor.iInterface), languageID: languageID)
        } catch {
            name = "Undefined"
        }

        return MetaData(name: name, endpointCount: endpointCount, interfaceNumber: interfaceNumber, alternateSetting: alternateSetting)
    }
}
