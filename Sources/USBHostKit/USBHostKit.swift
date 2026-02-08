// Package: USBHostKit
// File: USBHostKit.swift
// Path: Sources/USBHostKit/USBHostKit.swift
// Date: 2026-01-07
// Author: Ahmed Emerah
// Email: ahmed.emerah@icloud.com
// Github: https://github.com/Emerah








// MARK: - Manager module
public typealias USBDeviceManager = USBHostKit.Manager.USBDeviceManager
internal typealias ConnectionError = USBHostKit.Manager.ConnectionError


// MARK: - Session module
public typealias USBDeviceClient = USBHostKit.Client.USBDeviceClient
internal typealias USBObject = USBHostKit.Client.Device.USBObject
internal typealias USBDevice = USBHostKit.Client.Device.USBDevice
internal typealias USBInterface = USBHostKit.Client.Device.USBDevice.USBInterface
internal typealias USBEndpoint = USBHostKit.Client.Device.USBDevice.USBInterface.USBEndpoint



public enum USBHostKit {
    public enum Manager {}
    public enum Client {
        internal enum Device {}
    }
}
