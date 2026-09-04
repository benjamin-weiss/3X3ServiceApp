public protocol TIFCommand: RawRepresentable, Sendable where RawValue == UInt8 {}

public enum DiagnosticParameterCommand: UInt8, TIFCommand {
    case write = 1
    case read = 2
}

public enum GearCommand: UInt8, TIFCommand {
    case reboot = 0
    case rebootMCU = 1
    case position = 9
    case shift = 13
    case mcuInfo = 14
    case commitHashRead = 31
    case mcuBLEBridgeEnable = 32
}

public enum TriggerCommand: UInt8, TIFCommand {
    case reboot = 0
    case batteryVoltage = 7
    case setMode = 8
    case sendShift = 9
    case commitHashRead = 11
}