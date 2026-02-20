import XCTest
@testable import USBHostKit

/// Runs minimal hardware-backed smoke tests for `USBDeviceClient`.
///
/// Set `USBHOSTKIT_HW=1` to enable these tests.
final class USBDeviceClientHardwareSmokeTests: XCTestCase {
    private static let vendorID: UInt16 = 0x17cc
    private static let productID: UInt16 = 0x1610
    private static let midiInterfaceNumber = 0x01
    private static let midiBulkInEndpoint = 0x81
    private static let midiBulkOutEndpoint = 0x01
    private static let timeout: TimeInterval = 3.0

    /// Verifies that the target hardware device can be discovered and opened by `USBDeviceClient`.
    func testOpenAndCloseClient() async throws {
        try requireHardwareEnabled()

        let client = try await makeClient()
        await client.close()
    }

    /// Verifies that control transfer can read the device descriptor from the target hardware.
    func testControlTransferReadsDeviceDescriptor() async throws {
        try requireHardwareEnabled()

        let client = try await makeClient()
        defer {
            Task { await client.close() }
        }

        let request = IOUSBDeviceRequest(
            bmRequestType: 0x80,
            bRequest: UInt8(kUSBRqGetDescriptor),
            wValue: UInt16(kUSBDeviceDesc << 8),
            wIndex: 0,
            wLength: 18
        )

        let descriptor = try await client.controlTransfer(request, receiveLength: 18, timeout: Self.timeout)
        XCTAssertEqual(descriptor.count, 18, "Expected full USB device descriptor length.")

        let vendor = descriptor.withUnsafeBytes { rawBuffer -> UInt16 in
            rawBuffer.load(fromByteOffset: 8, as: UInt16.self)
        }
        let product = descriptor.withUnsafeBytes { rawBuffer -> UInt16 in
            rawBuffer.load(fromByteOffset: 10, as: UInt16.self)
        }

        XCTAssertEqual(vendor.littleEndian, Self.vendorID)
        XCTAssertEqual(product.littleEndian, Self.productID)
    }

    /// Verifies a MIDI endpoint roundtrip using bulk OUT endpoint `0x01` and bulk IN endpoint `0x81`.
    func testMidiBulkEndpointRoundtrip() async throws {
        try requireHardwareEnabled()

        let client = try await makeClient()
        defer {
            Task { await client.close() }
        }

        let inputSelection = USBDeviceClient.InterfaceSelection(
            interfaceNumber: Self.midiInterfaceNumber,
            alternateSetting: 0,
            endpointAddress: Self.midiBulkInEndpoint
        )
        let outputSelection = USBDeviceClient.InterfaceSelection(
            interfaceNumber: Self.midiInterfaceNumber,
            alternateSetting: 0,
            endpointAddress: Self.midiBulkOutEndpoint
        )

        let inputStream = try await client.monitorNotifications(interfaceSelection: inputSelection)

        let midiPacket = Data([0x09, 0x90, 0x3C, 0x40])
        let sentBytes = try await client.enqueueOut(data: midiPacket, to: outputSelection, timeout: Self.timeout)
        XCTAssertEqual(sentBytes, midiPacket.count, "Expected full MIDI payload to be written.")

        let received = try await awaitAnyInput(from: inputStream, timeout: Self.timeout)
        XCTAssertEqual(received.interface, Self.midiInterfaceNumber)
    }
}

// MARK: - Hardware helpers
extension USBDeviceClientHardwareSmokeTests {
    /// Ensures hardware smoke tests only run when explicitly enabled by environment variable.
    ///
    /// - Throws: `XCTSkip` when `USBHOSTKIT_HW` is not set to `1`.
    private func requireHardwareEnabled() throws {
        let value = ProcessInfo.processInfo.environment["USBHOSTKIT_HW"] ?? "0"
        if value != "1" {
            throw XCTSkip("Set USBHOSTKIT_HW=1 to run hardware smoke tests.")
        }
    }

    /// Creates a `USBDeviceClient` for the first discovered device matching the configured VID/PID.
    ///
    /// - Returns: Opened USB device client.
    /// - Throws: Test failure errors when no device is found in the timeout window.
    private func makeClient() async throws -> USBDeviceClient {
        let manager = USBDeviceManager()
        let criteria = USBDeviceManager.DeviceMatchingCriteria(vendorID: Self.vendorID, productID: Self.productID)
        let stream = try await manager.monitorNotifications(matchingCriteria: criteria)
        defer {
            Task { await manager.endMonitoringActivity() }
        }

        guard let reference = try await awaitMatchedReference(from: stream, timeout: Self.timeout) else {
            XCTFail("No matching device was discovered for VID \(String(format: "0x%04x", Self.vendorID)) PID \(String(format: "0x%04x", Self.productID)).")
            throw CancellationError()
        }

        guard let client = USBDeviceClient(deviceReference: reference) else {
            XCTFail("Discovered device could not be opened by USBDeviceClient.")
            throw CancellationError()
        }

        return client
    }

    /// Waits for a matched device notification within a bounded timeout.
    ///
    /// - Parameters:
    ///   - stream: Device-manager notification stream.
    ///   - timeout: Timeout in seconds.
    /// - Returns: Matched device reference if found before timeout, otherwise `nil`.
    /// - Throws: Stream errors from the manager.
    private func awaitMatchedReference(
        from stream: AsyncThrowingStream<USBDeviceManager.Notification, any Error>,
        timeout: TimeInterval
    ) async throws -> USBDeviceClient.DeviceReference? {
        try await withThrowingTaskGroup(of: USBDeviceClient.DeviceReference?.self) { group in
            group.addTask {
                for try await notification in stream {
                    if case let .deviceMatched(reference) = notification {
                        return reference
                    }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }

            let result = try await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// Waits for any input notification from the monitored endpoint stream.
    ///
    /// - Parameters:
    ///   - stream: Endpoint notification stream.
    ///   - timeout: Timeout in seconds.
    /// - Returns: Interface number and received data payload.
    /// - Throws: Test failure errors when no payload is received in time.
    private func awaitAnyInput(
        from stream: AsyncThrowingStream<USBDeviceClient.Notification, any Error>,
        timeout: TimeInterval
    ) async throws -> (interface: Int, data: Data) {
        try await withThrowingTaskGroup(of: (Int, Data)?.self) { group in
            group.addTask {
                for try await notification in stream {
                    if case let .inputReceived(interface, data, _) = notification {
                        return (interface, data)
                    }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }

            let result = try await group.next() ?? nil
            group.cancelAll()

            guard let result else {
                XCTFail("Timed out waiting for endpoint input notification.")
                throw CancellationError()
            }

            return result
        }
    }
}
