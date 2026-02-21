# USBHostKit

USBHostKit is a Swift Concurrency-first macOS package for USB host communication on top of `IOKit` and `IOUSBHost`.

It provides:
- USB device discovery and hot-plug notifications
- Actor-based session management (`USBDeviceClient`) for a single device
- Synchronous and asynchronous endpoint I/O
- Device control transfers
- Descriptor and endpoint introspection utilities

> Important:
> USB notifications and communication callbacks rely on the host process run loop/dispatch loop being alive. Run this package inside an app (or another long-lived process loop). Short-lived CLI execution can exit before notifications and asynchronous I/O are delivered.

## Requirements

- macOS 15.0+
- Swift 6+
- `IOKit` and `IOUSBHost` available at runtime

## Installation

Add `USBHostKit` to your package dependencies, then include it in your target dependencies.

```swift
dependencies: [
    .package(url: "https://github.com/Emerah/USBHostKit.git", branch: "main")
]
```



## Tutorial: First Discovery + Open

This section shows the complete happy path:
1. monitor devices matching VID/PID
2. get a `DeviceReference`
3. open `USBDeviceClient`
4. inspect device metadata
5. close cleanly

```swift
import Foundation
import USBHostKit

let manager = USBDeviceManager()
let criteria = USBDeviceManager.DeviceMatchingCriteria(
    vendorID: 0x1234,
    productID: 0x5678
)

let stream = try await manager.monitorNotifications(matchingCriteria: criteria)
defer { Task { await manager.endMonitoringActivity() } }

var reference: USBDeviceClient.DeviceReference?
for try await event in stream {
    if case let .deviceMatched(ref) = event {
        reference = ref
        break
    }
}

guard let reference else {
    throw CancellationError()
}

guard let client = USBDeviceClient(deviceReference: reference) else {
    throw USBHostError.notOpen
}

let info = await client.deviceInfo
print("VID=\(String(format: "0x%04x", info.vendorID)) PID=\(String(format: "0x%04x", info.productID))")
print("name=\(info.name), manufacturer=\(info.manufacturer), serial=\(info.serialNumber)")

await client.close()
```

Notes:
- `USBDeviceManager` and `USBDeviceClient` are actors, so calls are `await`ed from outside actor isolation.
- `USBDeviceClient(deviceReference:)` is failable and returns `nil` when the device cannot be opened.

## Selecting Endpoints

Most I/O APIs use `USBDeviceClient.InterfaceSelection`:

```swift
let inSelection = USBDeviceClient.InterfaceSelection(
    interfaceNumber: 1,
    alternateSetting: 0,
    endpointAddress: 0x81 // IN endpoint
)

let outSelection = USBDeviceClient.InterfaceSelection(
    interfaceNumber: 1,
    alternateSetting: 0,
    endpointAddress: 0x01 // OUT endpoint
)
```

Use:
- IN endpoints (`0x80` bit set) for receive operations
- OUT endpoints for send operations

If direction/transfer type is invalid for an operation, APIs throw `USBHostError.badArgument` or `USBHostError.unsupported`.

## Endpoint I/O

### Asynchronous Send + Receive

```swift
import Foundation
import USBHostKit

let payload = Data([0x09, 0x90, 0x3C, 0x40])
let sent = try await client.enqueueOut(data: payload, to: outSelection, timeout: 3.0)
print("sent bytes: \(sent)")

let received = try await client.enqueueIn(from: inSelection, length: 64, timeout: 3.0)
print("received bytes: \(received.count)")
```

### Synchronous Send + Receive

```swift
let sentSync = try await client.send(data: payload, to: outSelection, timeout: 3.0)
print("sync sent bytes: \(sentSync)")

let receivedSync = try await client.receive(from: inSelection, length: 64, timeout: 3.0)
print("sync received bytes: \(receivedSync.count)")
```

## Continuous Input Monitoring

`monitorNotifications(targetInterface:)` gives a stream of endpoint input and removal events:

```swift
let inputEvents = try await client.monitorNotifications(targetInterface: inSelection)

Task {
    do {
        for try await event in inputEvents {
            switch event {
            case let .inputReceived(interface, data, timestamp):
                print("interface=\(interface) bytes=\(data.count) ts=\(timestamp)")
            case .deviceRemoved:
                print("device removed")
                return
            }
        }
    } catch {
        print("monitor error: \(error)")
    }
}
```

## Control Transfers

Import `IOUSBHost` to build `IOUSBDeviceRequest` values and USB request constants.

```swift
import IOUSBHost

let request = IOUSBDeviceRequest(
    bmRequestType: 0x80,
    bRequest: UInt8(kUSBRqGetDescriptor),
    wValue: UInt16(kUSBDeviceDesc << 8),
    wIndex: 0,
    wLength: 18
)

let descriptor = try await client.controlTransfer(request, receiveLength: 18, timeout: 3.0)
print("device descriptor bytes: \(descriptor.count)")
```

Other control-transfer variants:
- `controlTransfer(_:timeout:) async throws -> Int`
- `controlTransfer(_:data:timeout:) async throws -> Int`

## Descriptor + Device Introspection

```swift
let address = try await client.deviceAddress()
let productString = try await client.stringDescriptor(index: 2)

let deviceDescriptor = try await client.deviceDescriptor()
let activeConfigDescriptor = try await client.currentConfigurationDescriptor()
let config1Descriptor = try await client.configurationDescriptor(configurationValue: 1)
let bosDescriptor = try await client.capabilityDescriptors()

let activeConfig = try await client.currentConfigurationDescriptorData()
let config1 = try await client.configurationDescriptorData(configurationValue: 1)
let bos = try await client.capabilityDescriptorsData() // Data?

print("address=\(address), product='\(productString)'")
print("deviceDescriptorLength=\(deviceDescriptor.bLength), activeConfigValue=\(activeConfigDescriptor.bConfigurationValue)")
print("config1Interfaces=\(config1Descriptor.bNumInterfaces), bosLength=\(bosDescriptor?.bLength ?? 0)")
print("activeConfigBytes=\(activeConfig.count), config1Bytes=\(config1.count), bosBytes=\(bos?.count ?? 0)")
```

## Endpoint Controls

```swift
try await client.setInterfaceIdleTimeout(5.0, interfaceNumber: 1, alternateSetting: 0)
try await client.setEndpointIdleTimeout(5.0, selection: inSelection)

try await client.clearStall(selection: inSelection)
try await client.abortEndpointIO(selection: inSelection)
try await client.abortDeviceRequests()

let activeEndpointDescriptors = try await client.endpointDescriptors(selection: inSelection)
let originalEndpointDescriptors = try await client.endpointOriginalDescriptors(selection: inSelection)
print("active endpoint descriptors: \(activeEndpointDescriptors)")
print("original endpoint descriptors: \(originalEndpointDescriptors)")
```

## Device Session Controls

```swift
try await client.configure(value: 1, matchInterfaces: true)
try await client.reset()
await client.close()
```

`close()` is idempotent and releases monitoring streams, cached interfaces, and the underlying `IOUSBHostDevice` handle.

## Notifications Reference

### `USBDeviceManager.Notification`
- `.deviceMatched(USBDeviceClient.DeviceReference)`
- `.deviceRemoved(USBDeviceClient.DeviceReference)`

### `USBDeviceClient.Notification`
- `.inputReceived(interface:data:timestamp:)`
- `.deviceRemoved`

## Error Handling

APIs throw `USBHostError` for IOKit/IOUSBHost failures.

Common cases:
- `.notOpen`: client is closed or inactive
- `.badArgument`: invalid interface/endpoint/length/request values
- `.unsupported`: endpoint type or operation unsupported
- `.busy`: duplicate monitoring call on same interface selection
- `.noDevice` / `.notAttached` / `.offline`: physical device removal path

Recommended handling pattern:

```swift
do {
    _ = try await client.enqueueOut(data: payload, to: outSelection)
} catch let error as USBHostError {
    print("USBHostError: \(error) -> \(error.localizedDescription)")
} catch {
    print("Unexpected error: \(error)")
}
```

## Lifecycle Tips

- Keep one `USBDeviceClient` per opened device reference.
- End manager monitoring when no longer needed (`endMonitoringActivity()`).
- If a device is unplugged, `USBDeviceManager` monitoring remains active and emits `.deviceRemoved`; `USBDeviceClient` interface streams emit `.deviceRemoved` and then finish, so recreate only the client after reconnect.

## Testing

`USBHostKitTests` includes hardware smoke tests behind an environment gate:
- set `USBHOSTKIT_HW=1` to run hardware-dependent tests
- without it, hardware smoke tests are skipped
