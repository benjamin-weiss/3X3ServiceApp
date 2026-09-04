import Foundation

public struct FirmwareRelease: Decodable, Equatable, Sendable {
    public let version: String
    public let url: String
    public let releaseDate: String
}

public struct FirmwareCatalog: Decodable, Sendable {
    private let triggerETO: [FirmwareRelease]
    private let triggerHB: [FirmwareRelease]
    private let actuatorETO: [FirmwareRelease]
    private let actuatorHB: [FirmwareRelease]
    private let triggerSFT: [FirmwareRelease]

    public func latestUpdate(
        for product: ThreeByThreeProduct,
        currentVersion: String
    ) -> FirmwareRelease? {
        guard let currentVersion = FirmwareVersion(currentVersion) else {
            return nil
        }
        return releases(for: product)
            .compactMap { release in
                FirmwareVersion(release.version).map { (release, $0) }
            }
            .filter { _, version in
                version > currentVersion
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    private func releases(for product: ThreeByThreeProduct) -> [FirmwareRelease] {
        switch product {
        case .actuatorETO:
            actuatorETO
        case .actuatorHB:
            actuatorHB
        case .triggerETO:
            triggerETO
        case .triggerHB:
            triggerHB
        case .triggerSFT:
            triggerSFT
        }
    }
}

private struct FirmwareVersion: Comparable {
    private let components: [Int]
    private let prereleaseComponents: [String]?

    init?(_ rawValue: String) {
        let withoutSuffix = rawValue.split(separator: "_", maxSplits: 1).first ?? ""
        let normalized = withoutSuffix.drop { !$0.isNumber }
        let versionParts = normalized.split(separator: "-", maxSplits: 1)
        guard let core = versionParts.first else {
            return nil
        }
        let rawComponents = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !rawComponents.isEmpty,
              rawComponents.allSatisfy({ !$0.isEmpty }),
              rawComponents.allSatisfy({ Int($0) != nil }) else {
            return nil
        }
        components = rawComponents.compactMap { Int($0) }
        prereleaseComponents = versionParts.count == 2
            ? versionParts[1].split(separator: ".").map(String.init)
            : nil
    }

    static func < (lhs: FirmwareVersion, rhs: FirmwareVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        switch (lhs.prereleaseComponents, rhs.prereleaseComponents) {
        case (nil, nil):
            return false
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case let (.some(left), .some(right)):
            for (leftIdentifier, rightIdentifier) in zip(left, right) {
                guard leftIdentifier != rightIdentifier else {
                    continue
                }
                switch (Int(leftIdentifier), Int(rightIdentifier)) {
                case let (.some(leftNumber), .some(rightNumber)):
                    return leftNumber < rightNumber
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                case (nil, nil):
                    return leftIdentifier < rightIdentifier
                }
            }
            return left.count < right.count
        }
    }
}