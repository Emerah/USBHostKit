// Package: USBDevice
// File: USBHostError.swift
// Path: Sources/USBDevice/USBHostError.swift
// Date: 2025-11-23
// Author: Ahmed Emerah
// Email: ahmed.emerah@icloud.com
// Github: https://github.com/Emerah


import IOUSBHost


public enum USBHostError: Error, LocalizedError, Equatable {
    case error
    case noMemory
    case noResources
    case ipcError
    case noDevice
    case notPrivileged
    case badArgument
    case lockedRead // irrelevant??
    case lockedWrite // irrelevant??
    case exclusiveAccess
    case badMessageID
    case unsupported
    case vmError // irrelevant??
    case internalError
    case ioError
    case cannotLock // irrelevant??
    case notOpen
    case notReadable // irrelevant??
    case notWritable // irrelevant??
    case notAligned // irrelevant??
    case badMedia // irrelevant??
    case stillOpen // irrelevant??
    case rldError // irrelevant??
    case dmaError // irrelevant??
    case busy
    case timeout
    case offline
    case notReady
    case notAttached
    case noChannels // irrelevant??
    case noSpace
    case portExists
    case cannotWire // irrelevant??
    case noInterrupt // irrelevant??
    case noFrames // irrelevant??
    case messageTooLarge
    case notPermitted
    case noPower
    case noMedia // irrelevant??
    case unformattedMedia // irrelevant??
    case unsupportedMode // irrelevant??
    case underrun
    case overrun
    case deviceError
    case noCompletion
    case aborted
    case noBandwidth
    case notResponding
    case isoTooOld
    case isoTooNew
    case notFound
    case invalid
    
    case unknown(code: IOReturn)
}



extension USBHostError {

    /// Translates an arbitrary Swift ``Error`` into a ``USBHostError`` when possible.
    ///
    /// The translation first preserves existing ``USBHostError`` values, then attempts domain-aware
    /// conversion for `IOUSBHostErrorDomain`, and finally falls back to decoding the numeric status.
    ///
    /// - Parameter error: The source error to translate.
    /// - Returns: The translated ``USBHostError``.
    public static func translated(_ error: Error) -> USBHostError {
        if let hostError = error as? USBHostError {
            return hostError
        }
        
        if let hostError = USBHostError(error: error) {
            return hostError
        }
        
        let nsError = error as NSError
        return USBHostError(status: IOReturn(nsError.code)) ?? .unknown(code: IOReturn(nsError.code))
    }
    
    /// Translates a raw ``IOReturn`` status into a ``USBHostError``.
    ///
    /// - Parameter status: The status value returned by IOKit/IOUSBHost APIs.
    /// - Returns: The translated ``USBHostError``.
    public static func translated(status: IOReturn) -> USBHostError {
        USBHostError(status: status) ?? .unknown(code: status)
    }
    
    /// Creates a ``USBHostError`` from a Swift ``Error`` when it carries a USBHost status.
    ///
    /// - Parameter error: The source error to inspect.
    /// - Returns: A translated ``USBHostError``, or `nil` when the error is success/not applicable.
    public init?(error: Error) {
        let nsError = error as NSError
        guard nsError.domain == IOUSBHostErrorDomain else { return nil }
        self.init(status: IOReturn(nsError.code))
    }
    
    /// Creates a ``USBHostError`` from a raw ``IOReturn`` status.
    ///
    /// This initializer decodes the status using the Mach/IOKit bitfield layout from `IOReturn.h`
    /// and classifies by the extracted error code. This makes classification resilient when subsystem
    /// bits differ while the underlying error code remains the same.
    ///
    /// - Parameter status: The raw IOKit status.
    /// - Returns: A known ``USBHostError`` case for recognized error codes, `nil` for success, and
    ///   ``USBHostError/unknown(code:)`` for unrecognized values.
    public init?(status: IOReturn) {
        guard status != kIOReturnSuccess else { return nil }

        let decoded = Self.decode(status)
        if decoded.system == Self.iokitSystemID, let known = Self.classify(commonCode: decoded.code) {
            self = known
            return
        }

        self = .unknown(code: status)
    }
    
    /// Returns the raw IOKit common code portion (`err_code`) extracted from this error.
    ///
    /// For known cases, this is the canonical common code from `IOReturn.h`. For
    /// ``USBHostError/unknown(code:)``, this is decoded from the captured status.
    public var rawValue: UInt32 {
        switch self {
        case .error:              return 0x2bc
        case .noMemory:           return 0x2bd
        case .noResources:        return 0x2be
        case .ipcError:           return 0x2bf
        case .noDevice:           return 0x2c0
        case .notPrivileged:      return 0x2c1
        case .badArgument:        return 0x2c2
        case .lockedRead:         return 0x2c3
        case .lockedWrite:        return 0x2c4
        case .exclusiveAccess:    return 0x2c5
        case .badMessageID:       return 0x2c6
        case .unsupported:        return 0x2c7
        case .vmError:            return 0x2c8
        case .internalError:      return 0x2c9
        case .ioError:            return 0x2ca
        case .cannotLock:         return 0x2cc
        case .notOpen:            return 0x2cd
        case .notReadable:        return 0x2ce
        case .notWritable:        return 0x2cf
        case .notAligned:         return 0x2d0
        case .badMedia:           return 0x2d1
        case .stillOpen:          return 0x2d2
        case .rldError:           return 0x2d3
        case .dmaError:           return 0x2d4
        case .busy:               return 0x2d5
        case .timeout:            return 0x2d6
        case .offline:            return 0x2d7
        case .notReady:           return 0x2d8
        case .notAttached:        return 0x2d9
        case .noChannels:         return 0x2da
        case .noSpace:            return 0x2db
        case .portExists:         return 0x2dd
        case .cannotWire:         return 0x2de
        case .noInterrupt:        return 0x2df
        case .noFrames:           return 0x2e0
        case .messageTooLarge:    return 0x2e1
        case .notPermitted:       return 0x2e2
        case .noPower:            return 0x2e3
        case .noMedia:            return 0x2e4
        case .unformattedMedia:   return 0x2e5
        case .unsupportedMode:    return 0x2e6
        case .underrun:           return 0x2e7
        case .overrun:            return 0x2e8
        case .deviceError:        return 0x2e9
        case .noCompletion:       return 0x2ea
        case .aborted:            return 0x2eb
        case .noBandwidth:        return 0x2ec
        case .notResponding:      return 0x2ed
        case .isoTooOld:          return 0x2ee
        case .isoTooNew:          return 0x2ef
        case .notFound:           return 0x2f0
        case .invalid:            return 0x1
        case .unknown(let code):  return Self.decode(code).code
        }
    }

    /// Returns a canonical ``IOReturn`` for this error case.
    ///
    /// > Note: For known cases, this composes `sys_iokit | sub_iokit_common | rawValue`.
    /// > For ``USBHostError/unknown(code:)``, the captured raw status is returned unchanged.
    public var ioReturnValue: IOReturn {
        if case .unknown(let code) = self {
            return code
        }

        return Self.composeIOKitCommonStatus(code: rawValue)
    }

    /// Provides a localized description for this error.
    ///
    /// - Returns: A system-generated localized description string.
    public var errorDescription: String? {
        let nsError = NSError(domain: IOUSBHostErrorDomain, code: Int(ioReturnValue))
        return nsError.localizedDescription
    }
}

// MARK: - IOReturn decoding
extension USBHostError {
    /// Holds decoded Mach error fields extracted from an ``IOReturn`` value.
    private struct DecodedIOReturn: Sendable {
        /// The original 32-bit status bit pattern.
        let full: UInt32
        /// The system identifier (`err_get_system`).
        let system: UInt32
        /// The subsystem identifier (`err_get_sub`).
        let subsystem: UInt32
        /// The error code (`err_get_code`).
        let code: UInt32
    }

    /// `sys_iokit` value from `IOReturn.h` (`err_system(0x38)` decoded by `err_get_system`).
    private static let iokitSystemID: UInt32 = 0x38

    /// Decodes an ``IOReturn`` into Mach error bitfield components.
    ///
    /// - Parameter status: Raw status to decode.
    /// - Returns: Decoded fields for system, subsystem, and code.
    private static func decode(_ status: IOReturn) -> DecodedIOReturn {
        let full = UInt32(bitPattern: Int32(status))
        let system = (full >> 26) & 0x3f
        let subsystem = (full >> 14) & 0x0fff
        let code = full & 0x3fff
        return DecodedIOReturn(full: full, system: system, subsystem: subsystem, code: code)
    }

    /// Classifies an IOKit common error code into a known ``USBHostError`` case.
    ///
    /// - Parameter code: The common code (`err_code`) extracted from an IOKit status.
    /// - Returns: A known error case, or `nil` if the code is not recognized.
    private static func classify(commonCode code: UInt32) -> USBHostError? {
        switch code {
        case 0x2bc: return .error
        case 0x2bd: return .noMemory
        case 0x2be: return .noResources
        case 0x2bf: return .ipcError
        case 0x2c0: return .noDevice
        case 0x2c1: return .notPrivileged
        case 0x2c2: return .badArgument
        case 0x2c3: return .lockedRead
        case 0x2c4: return .lockedWrite
        case 0x2c5: return .exclusiveAccess
        case 0x2c6: return .badMessageID
        case 0x2c7: return .unsupported
        case 0x2c8: return .vmError
        case 0x2c9: return .internalError
        case 0x2ca: return .ioError
        case 0x2cc: return .cannotLock
        case 0x2cd: return .notOpen
        case 0x2ce: return .notReadable
        case 0x2cf: return .notWritable
        case 0x2d0: return .notAligned
        case 0x2d1: return .badMedia
        case 0x2d2: return .stillOpen
        case 0x2d3: return .rldError
        case 0x2d4: return .dmaError
        case 0x2d5: return .busy
        case 0x2d6: return .timeout
        case 0x2d7: return .offline
        case 0x2d8: return .notReady
        case 0x2d9: return .notAttached
        case 0x2da: return .noChannels
        case 0x2db: return .noSpace
        case 0x2dd: return .portExists
        case 0x2de: return .cannotWire
        case 0x2df: return .noInterrupt
        case 0x2e0: return .noFrames
        case 0x2e1: return .messageTooLarge
        case 0x2e2: return .notPermitted
        case 0x2e3: return .noPower
        case 0x2e4: return .noMedia
        case 0x2e5: return .unformattedMedia
        case 0x2e6: return .unsupportedMode
        case 0x2e7: return .underrun
        case 0x2e8: return .overrun
        case 0x2e9: return .deviceError
        case 0x2ea: return .noCompletion
        case 0x2eb: return .aborted
        case 0x2ec: return .noBandwidth
        case 0x2ed: return .notResponding
        case 0x2ee: return .isoTooOld
        case 0x2ef: return .isoTooNew
        case 0x2f0: return .notFound
        case 0x1: return .invalid
        default: return nil
        }
    }

    /// Composes a canonical IOKit common ``IOReturn`` from a common code.
    ///
    /// - Parameter code: The IOKit common `err_code` portion.
    /// - Returns: A full `IOReturn` in the `sys_iokit/sub_iokit_common` namespace.
    private static func composeIOKitCommonStatus(code: UInt32) -> IOReturn {
        let system = (iokitSystemID & 0x3f) << 26
        let commonSubsystem: UInt32 = 0 << 14
        let full = system | commonSubsystem | (code & 0x3fff)
        return IOReturn(Int32(bitPattern: full))
    }
}
