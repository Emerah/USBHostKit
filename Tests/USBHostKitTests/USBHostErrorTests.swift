import XCTest
@testable import USBHostKit

final class USBHostErrorTests: XCTestCase {
    /// Verifies that canonical common IOKit status values still map to their expected cases.
    func testKnownCommonStatusMapsToExpectedCase() {
        XCTAssertEqual(USBHostError(status: kIOReturnExclusiveAccess), .exclusiveAccess)
        XCTAssertEqual(USBHostError(status: kIOReturnInternalError), .internalError)
    }

    /// Verifies that classification uses the decoded common code even when subsystem bits differ.
    func testDifferentSubsystemWithSameCodeStillMapsToCommonError() {
        let status = iokitStatus(system: 0x38, subsystem: 1, code: 0x2c5)
        XCTAssertEqual(USBHostError(status: status), .exclusiveAccess)
    }

    /// Verifies that unknown statuses preserve the original full status while exposing decoded code.
    func testUnknownStatusPreservesOriginalCode() {
        let status = iokitStatus(system: 0x38, subsystem: 123, code: 0x3abc)
        let error = USBHostError(status: status)

        guard case .unknown(let captured)? = error else {
            XCTFail("Expected unknown status")
            return
        }

        XCTAssertEqual(captured, status)
        XCTAssertEqual(error?.rawValue, 0x3abc)
        XCTAssertEqual(error?.ioReturnValue, status)
    }

    /// Composes an IOKit-style status value using system/subsystem/code fields from `IOReturn.h`.
    private func iokitStatus(system: UInt32, subsystem: UInt32, code: UInt32) -> IOReturn {
        let full = ((system & 0x3f) << 26) | ((subsystem & 0x0fff) << 14) | (code & 0x3fff)
        return IOReturn(Int32(bitPattern: full))
    }
}
