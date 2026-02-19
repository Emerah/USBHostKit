// Package: USBDevice
// File: USBDevice.swift
// Path: Sources/USBDevice/USBDevice.swift
// Date: 2025-11-23
// Author: Ahmed Emerah
// Email: ahmed.emerah@icloud.com
// Github: https://github.com/Emerah


import Foundation
import IOUSBHost


extension USBHostKit.Device {
    
    internal final class USBDevice: USBObject {
        
        internal typealias USBHandle = IOUSBHostDevice
        
        internal let handle: IOUSBHostDevice
        private let metadata: MetaData
        
        /// Creates a device wrapper from an existing `IOUSBHostDevice` handle.
        ///
        /// - Parameter handle: Open device handle.
        internal init(handle: IOUSBHostDevice) {
            self.handle = handle
            let metadata = Self.retrieveDeviceMetadata(from: handle)
            self.metadata = metadata
        }
        
        /// Creates and wraps an `IOUSBHostDevice` from an `io_service_t`.
        ///
        /// - Parameters:
        ///   - service: Registry service for the USB device.
        ///   - options: Host object initialization options.
        ///   - queue: Dispatch queue used by the host object.
        ///   - interestHandler: Optional interest callback.
        /// - Throws: ``USBHostError`` when handle creation fails.
        internal convenience init(
            service: io_service_t,
            options: IOUSBHostObjectInitOptions,
            queue: DispatchQueue?,
            interestHandler: IOUSBHostInterestHandler?
        ) throws(USBHostError) {
            do {
                let handle = try IOUSBHostDevice(__ioService: service, options: options, queue: queue, interestHandler: interestHandler)
                self.init(handle: handle)
            } catch {
                throw USBHostError.translated(error)
            }
        }
        
        /// Destroys the underlying host-device handle.
        internal func destroy() {
            handle.destroy()
        }
    }
}




// MARK: - Matching dictionary
extension USBHostKit.Device.USBDevice {
    
    /// Builds an IOService matching dictionary for USB device discovery.
    ///
    /// - Returns: A retained mutable dictionary accepted by IOKit matching APIs.
    internal static func createMatchingDictionary(
        vendorID: Int? = nil,
        productID: Int? = nil,
        bcdDevice: Int? = nil,
        deviceClass: Int? = nil,
        deviceSubclass: Int? = nil,
        deviceProtocol: Int? = nil,
        speed: Int? = nil,
        productIDs: [Int]? = nil
    ) -> CFMutableDictionary {
        let vendorNum   = vendorID.map(NSNumber.init(value:))
        let productNum  = productID.map(NSNumber.init(value:))
        let bcdNum      = bcdDevice.map(NSNumber.init(value:))
        let classNum    = deviceClass.map(NSNumber.init(value:))
        let subclassNum = deviceSubclass.map(NSNumber.init(value:))
        let protoNum    = deviceProtocol.map(NSNumber.init(value:))
        let speedNum    = speed.map(NSNumber.init(value:))
        let productArray: [NSNumber]? = productIDs?.map(NSNumber.init(value:))
        
        let dict = IOUSBHostDevice.__createMatchingDictionary(
            withVendorID: vendorNum,
            productID: productNum,
            bcdDevice: bcdNum,
            deviceClass: classNum,
            deviceSubclass: subclassNum,
            deviceProtocol: protoNum,
            speed: speedNum,
            productIDArray: productArray
        )
        
        return dict.takeRetainedValue()
    }
}


// MARK: - Configuration
extension USBHostKit.Device.USBDevice {
    
    /// Applies a configuration value on the device.
    ///
    /// - Parameters:
    ///   - value: Configuration value to select.
    ///   - matchInterfaces: Whether interfaces should be re-matched by IOUSBHost.
    /// - Throws: ``USBHostError`` when configuration fails.
    internal func configure(value: Int, matchInterfaces: Bool) throws(USBHostError) {
        do {
            try handle.__configure(withValue: value, matchInterfaces: matchInterfaces)
        } catch {
            throw USBHostError.translated(error)
        }
    }
    
    /// Applies a configuration value and requests interface matching.
    ///
    /// - Parameter value: Configuration value to select.
    /// - Throws: ``USBHostError`` when configuration fails.
    internal func configure(value: Int) throws(USBHostError) {
        try configure(value: value, matchInterfaces: true)
    }
}

// MARK: - Device state
extension USBHostKit.Device.USBDevice {
    
    internal var currentConfigurationDescriptor: UnsafePointer<IOUSBConfigurationDescriptor>? {
        handle.configurationDescriptor
    }
    
    /// Resets the device through IOUSBHost.
    ///
    /// - Throws: ``USBHostError`` when reset fails.
    internal func reset() throws(USBHostError) {
        do {
            try handle.reset()
        } catch {
            throw USBHostError.translated(error)
        }
    }
}


// MARK: - Metadata
extension USBHostKit.Device.USBDevice {
    internal var vendorID: UInt16 {
        metadata.vendorID
    }
    
    internal var productID: UInt16 {
        metadata.productID
    }
    
    internal var name: String {
        metadata.name
    }
    
    internal var manufacturer: String {
        metadata.manufacturer
    }
    
    internal var serialNumber: String {
        metadata.serialNumber
    }
    
    internal var interfaceCount: UInt8 {
        metadata.interfaceCount
    }
    
    internal var configurationCount: UInt8 {
        metadata.configurationCount
    }
    
    internal var currentConfigurationValue: UInt8 {
        currentConfigurationDescriptor?.pointee.bConfigurationValue ?? metadata.currentConfigurationValue
    }
}


// MARK: - Metadata support
extension USBHostKit.Device.USBDevice {
    
    fileprivate struct MetaData {
        fileprivate let vendorID: UInt16
        fileprivate let productID: UInt16
        fileprivate let name: String
        fileprivate let manufacturer: String
        fileprivate let serialNumber: String
        fileprivate let configurationCount: UInt8
        fileprivate let interfaceCount: UInt8
        fileprivate let currentConfigurationValue: UInt8
        
        fileprivate static let `default` = MetaData(
            vendorID: 0,
            productID: 0,
            name: "",
            manufacturer: "",
            serialNumber: "",
            configurationCount: 0,
            interfaceCount: 0,
            currentConfigurationValue: 0
        )
    }
    
    /// Reads immutable device metadata from the current descriptors and strings.
    ///
    /// - Parameter handle: Device handle to query.
    /// - Returns: Metadata snapshot with descriptor and string values.
    private static func retrieveDeviceMetadata(from handle: IOUSBHostDevice) -> MetaData {
        guard
            let deviceDescriptor = handle.deviceDescriptor,
            let configurationDescriptor = handle.configurationDescriptor
        else {
            return .default
        }
        
        let vendorID = deviceDescriptor.pointee.idVendor
        let productID = deviceDescriptor.pointee.idProduct
        var name: String
        var manufacturer: String
        var serialNumber: String
        let languageID = Int(kIOUSBLanguageIDEnglishUS.rawValue)
        
        do {
            name = try handle.__string(with: Int(deviceDescriptor.pointee.iProduct), languageID: languageID)
            manufacturer = try handle.__string(with: Int(deviceDescriptor.pointee.iManufacturer), languageID: languageID)
            serialNumber = try handle.__string(with: Int(deviceDescriptor.pointee.iSerialNumber), languageID: languageID)
        } catch {
            name = "Undefined"
            manufacturer = "Undefined"
            serialNumber = "Undefined"
        }
        
        let configurationCount = deviceDescriptor.pointee.bNumConfigurations
        let interfaceCount = configurationDescriptor.pointee.bNumInterfaces
        let currentConfigurationValue = configurationDescriptor.pointee.bConfigurationValue
        
        return MetaData(
            vendorID: vendorID,
            productID: productID,
            name: name,
            manufacturer: manufacturer,
            serialNumber: serialNumber,
            configurationCount: configurationCount,
            interfaceCount: interfaceCount,
            currentConfigurationValue: currentConfigurationValue
        )
    }
}


// MARK: - Request interface
extension USBHostKit.Device.USBDevice {

    private var liveConfigurationValue: UInt8? {
        handle.configurationDescriptor?.pointee.bConfigurationValue
    }

    /// Finds the matching interface service node for a given interface number.
    ///
    /// - Parameter number: Interface number to locate.
    /// - Returns: Matching `io_service_t` interface node.
    /// - Throws: ``USBHostError`` when iterator creation fails or no match is found.
    private func serviceForInterface(number: UInt8) throws -> io_service_t {
        var iterator = io_iterator_t()
        let status = IORegistryEntryGetChildIterator(ioService, kIOServicePlane, &iterator)
        guard status == KERN_SUCCESS, iterator != IO_OBJECT_NULL else {
            throw USBHostError.translated(status: status)
        }
        
        defer { IOObjectRelease(iterator) }
        
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            if IOObjectConformsTo(service, kIOUSBHostInterfaceClassName) != 0,
               isValidInterface(service, interfaceNumber: number) {
                return service
            }
            
            IOObjectRelease(service)
        }
        
        throw USBHostError.invalid
    }
    
    /// Checks whether an interface service belongs to the active configuration and requested number.
    ///
    /// - Parameters:
    ///   - service: Interface service to validate.
    ///   - interfaceNumber: Requested interface number.
    /// - Returns: `true` when the service matches selection criteria.
    private func isValidInterface(_ service: io_service_t, interfaceNumber: UInt8) -> Bool {
        guard
            let number = propertyNumber(IOUSBHostMatchingPropertyKey.interfaceNumber.rawValue, service: service),
            let configuration = propertyNumber(IOUSBHostMatchingPropertyKey.configurationValue.rawValue, service: service),
            let currentConfiguration = liveConfigurationValue
        else {
            return false
        }
        return number == interfaceNumber && configuration == currentConfiguration
    }
    
    /// Opens and wraps a USB interface for the given interface and alternate setting.
    ///
    /// - Parameters:
    ///   - number: Interface number.
    ///   - alternateSetting: Alternate setting to select after opening.
    /// - Returns: Wrapped USB interface object.
    /// - Throws: ``USBHostError`` when lookup/open/select operations fail.
    internal func interface(_ number: UInt8, alternateSetting: UInt8 = 0) throws -> USBInterface {
        let service = try serviceForInterface(number: number)
        defer { IOObjectRelease(service) }
        
        let interfaceHandle = try IOUSBHostInterface(
            __ioService: service,
            options: [],
            queue: queue,
            interestHandler: nil
        )
        
        let usbInterface = USBInterface(handle: interfaceHandle)
        do {
            if alternateSetting != 0 {
                try usbInterface.selectAlternateSetting(Int(alternateSetting))
            }
        } catch {
            usbInterface.destroy()
            throw USBHostError.translated(error)
        }

        return usbInterface
    }
    
    /// Reads an IORegistry numeric property as `UInt8`.
    ///
    /// - Parameters:
    ///   - key: Property key.
    ///   - service: Service that owns the property.
    /// - Returns: Property value when available and numeric.
    private func propertyNumber(_ key: String, service: io_service_t) -> UInt8? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        else { return nil }
        
        guard let number = value as? NSNumber
        else { return nil }
        
        return number.uint8Value
    }
    
}
