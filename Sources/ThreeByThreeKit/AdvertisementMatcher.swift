import Foundation

public enum AdvertisementMatcher {
    public static func matches(
        name: String?,
        manufacturerData: Data?
    ) -> Bool {
        if let manufacturerData,
           manufacturerData.count >= 2,
           SupportedAdvertisement.manufacturerIdentifiers.contains(
               UInt16(manufacturerData[manufacturerData.startIndex])
                   | UInt16(manufacturerData[manufacturerData.startIndex + 1]) << 8
           ) {
            return true
        }

        guard let name else {
            return false
        }
        return SupportedAdvertisement.exactNames.contains(name)
            || SupportedAdvertisement.namePrefixes.contains { name.hasPrefix($0) }
    }
}