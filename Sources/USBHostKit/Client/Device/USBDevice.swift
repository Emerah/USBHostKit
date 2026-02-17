// Package: USBDevice
// File: USBDevice.swift
// Path: Sources/USBDevice/USBDevice.swift
// Date: 2025-11-23
// Author: Ahmed Emerah
// Email: ahmed.emerah@icloud.com
// Github: https://github.com/Emerah


import Foundation
import IOUSBHost


extension USBHostKit.Client.Device {
    
    internal final class USBDevice: USBObject {
        
        internal typealias USBHandle = IOUSBHostDevice
        
        internal let handle: IOUSBHostDevice
        private let metadata: MetaData
        private let interfaceCacheQueue = DispatchQueue(label: "usbdevice.interfacesCache")
        private var interfaces: [InterfaceSelection: USBInterface] = [:]
        
        internal init(handle: IOUSBHostDevice) {
            self.handle = handle
            let metadata = Self.retrieveDeviceMetadata(from: handle)
            self.metadata = metadata
        }
        
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
        
        internal func destroy() {
            clearInterfaceCache()
            handle.destroy()
        }
    }
}




// MARK: - Matching dictionary
extension USBHostKit.Client.Device.USBDevice {
    
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
extension USBHostKit.Client.Device.USBDevice {
    
    internal func configure(value: Int, matchInterfaces: Bool) throws(USBHostError) {
        do {
            try handle.__configure(withValue: value, matchInterfaces: matchInterfaces)
        } catch {
            throw USBHostError.translated(error)
        }
        
        clearInterfaceCache()
    }
    
    internal func configure(value: Int) throws(USBHostError) {
        try configure(value: value, matchInterfaces: true)
    }
}

// MARK: - Device state
extension USBHostKit.Client.Device.USBDevice {
    
    internal var currentConfigurationDescriptor: UnsafePointer<IOUSBConfigurationDescriptor>? {
        handle.configurationDescriptor
    }
    
    internal func reset() throws(USBHostError) {
        do {
            try handle.reset()
        } catch {
            throw USBHostError.translated(error)
        }
        
        clearInterfaceCache()
    }
}


// MARK: - Metadata
extension USBHostKit.Client.Device.USBDevice {
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
        metadata.currentConfigurationValue
    }
}


// MARK: - Metadata support
extension USBHostKit.Client.Device.USBDevice {
    
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
extension USBHostKit.Client.Device.USBDevice {
    
    private struct InterfaceSelection: Hashable, Sendable {
        private let interfaceNumber: UInt8
        private let alternateSetting: UInt8
        fileprivate init(interfaceNumber: UInt8, alternateSetting: UInt8) {
            self.interfaceNumber = interfaceNumber
            self.alternateSetting = alternateSetting
        }
    }
    
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
    
    private func isValidInterface(_ service: io_service_t, interfaceNumber: UInt8) -> Bool {
        guard
            let number = propertyNumber(IOUSBHostMatchingPropertyKey.interfaceNumber.rawValue, service: service),
            let configuration = propertyNumber(IOUSBHostMatchingPropertyKey.configurationValue.rawValue, service: service)
        else {
            return false
        }
        return number == interfaceNumber && configuration == metadata.currentConfigurationValue
    }
    
    internal func interface(_ number: UInt8, alternateSetting: UInt8 = 0) throws -> USBInterface {
        let selection = InterfaceSelection(interfaceNumber: number, alternateSetting: alternateSetting)
        
        return try interfaceCacheQueue.sync {
            if let cached = interfaces[selection] { return cached }
            
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
            
            interfaces[selection] = usbInterface
            return usbInterface
        }
    }
    
    private func propertyNumber(_ key: String, service: io_service_t) -> UInt8? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        else { return nil }
        
        guard let number = value as? NSNumber
        else { return nil }
        
        return number.uint8Value
    }
    
    private func cachedInterface(for key: InterfaceSelection) -> USBInterface? {
        interfaceCacheQueue.sync {
            interfaces[key]
        }
    }
        
    private func store(interface: USBInterface, for key: InterfaceSelection) {
        interfaceCacheQueue.sync {
            interfaces[key] = interface
        }
    }
    
    private func clearInterfaceCache() {
      interfaceCacheQueue.sync {
          interfaces.values.forEach { $0.destroy() }
          interfaces.removeAll()
      }
  }
    
}
