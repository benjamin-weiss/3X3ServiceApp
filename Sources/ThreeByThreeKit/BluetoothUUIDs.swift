public enum BluetoothUUIDs {
    public enum Service {
        public static let genericAccess = "1800"
        public static let genericAttribute = "1801"
        public static let deviceInformation = "180A"
        public static let battery = "180F"
        public static let diagnostics = "E892FDCC-79BD-462F-A1D6-9EF13C3D9B92"
        public static let shift = "F12D66E5-4E50-4F2F-901F-A1B1C2A8726B"
        public static let authentication = "7F6D0010-B996-5845-90F3-0796DCD321D8"
        public static let siliconLabsOTA = "1D14D6EE-FD63-4FA1-BFA4-8F47B42119F0"
        public static let nordicOTA = "30EFF7A7-6996-4CAB-B5C9-588ACF554B59"
        public static let nordicSecureDFU = "FE59"
    }

    public enum DiagnosticsCharacteristic {
        public static let parameterData = "E4B00270-86B2-49DE-983F-701E1845470A"
        public static let authentication = "87A8E1A7-AF9D-4A4F-BE5A-213F1603839C"
        public static let gatewayToMCU = "4711"
        public static let log = "D0102CD3-F08E-4381-A82A-D6AC015D4879"
        public static let tif = "80E9B23C-A7FC-46EB-9AA3-7DE13573E534"
    }

    public enum StandardCharacteristic {
        public static let batteryLevel = "2A19"
        public static let modelNumber = "2A24"
        public static let serialNumber = "2A25"
        public static let firmwareRevision = "2A26"
        public static let softwareRevision = "2A28"
    }

    public enum AuthenticationCharacteristic {
        public static let challenge = "7F6D0011-B996-5845-90F3-0796DCD321D8"
        public static let responseFD = "7F6D0012-B996-5845-90F3-0796DCD321D8"
        public static let response = "7F6D0013-B996-5845-90F3-0796DCD321D8"
    }

    public enum NordicDFUCharacteristic {
        public static let buttonless = "8EC90003-F315-4F60-9FB8-838830DAEA50"
    }
}

public enum SupportedAdvertisement {
    public static let manufacturerIdentifiers: Set<UInt16> = [3_394, 3_222]
    public static let exactNames: Set<String> = [
        "Gear-OTA",
        "Trigger-OTA",
        "OTA",
        "OTA_Trigger",
        "Zephyr",
    ]
    public static let namePrefixes = ["TSW"]
}