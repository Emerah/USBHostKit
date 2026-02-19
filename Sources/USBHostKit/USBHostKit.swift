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


// MARK: - Device module
internal typealias USBObject = USBHostKit.Device.USBObject
internal typealias USBDevice = USBHostKit.Device.USBDevice
internal typealias USBInterface = USBHostKit.Device.USBDevice.USBInterface
internal typealias USBEndpoint = USBHostKit.Device.USBDevice.USBInterface.USBEndpoint


// MARK: - Session module
public typealias USBDeviceClient = USBHostKit.Client.USBDeviceClient


public enum USBHostKit {
    public enum Client {}
    internal enum Device {}
    public enum Manager {}
}
