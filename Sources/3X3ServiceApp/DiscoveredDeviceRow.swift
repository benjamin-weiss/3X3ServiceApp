import SwiftUI
import ThreeByThreeKit

struct DiscoveredDeviceRow: View {
    let store: DeviceStore
    let device: DiscoveredDevice
    var showsConnectionHint = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: deviceSymbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.displayName(for: device))
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(device.id.uuidString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if showsConnectionHint, !device.isReadyToConnect {
                    Text(connectionHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            SignalStrengthView(rssi: device.rssi)
        }
        .contentShape(Rectangle())
    }

    private var deviceSymbol: String {
        let name = device.name.uppercased()
        if name.hasPrefix("TSW") || name.contains("TRIGGER") {
            return "switch.2"
        }
        if name.contains("GEAR") {
            return "gearshape.2.fill"
        }

        switch device.manufacturerIdentifier {
        case 3_394:
            return "switch.2"
        case 3_222:
            return "gearshape.2.fill"
        default:
            return "antenna.radiowaves.left.and.right"
        }
    }

    private var connectionHint: LocalizedStringKey {
        device.triggerAdvertisingMode == .awake
            ? "Hold function button for 10 seconds to connect"
            : "Not connectable"
    }
}

private struct SignalStrengthView: View {
    let rssi: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "wifi", variableValue: signalLevel)
            #if DEBUG
                Text("\(rssi) dBm")
            #endif
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signal strength")
        .accessibilityValue("\(rssi) dBm")
    }

    private var signalLevel: Double {
        min(max((Double(rssi) + 100) / 60, 0), 1)
    }
}