import SwiftUI
import ThreeByThreeKit

struct SecondGearRotationSection: View {
    let store: DeviceStore

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "Use this during installation when the partially visible second gear prevents the final gear from being inserted. Rotate it until the final gear fits."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                rotationRocker
            }

            if !store.canRotateSecondGear {
                Text("Second-gear rotation is unavailable for this Actuator.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Rotate 2nd gear")
        }
    }

    private var rotationRocker: some View {
        HStack(spacing: 0) {
            rotationButton(
                systemImage: "arrow.counterclockwise",
                accessibilityLabel: "Rotate counterclockwise",
                direction: .counterclockwise
            )

            Divider()
                .frame(height: 44)

            Text("ROTATE")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 96)
                .frame(maxHeight: .infinity)
                .accessibilityAddTraits(.isHeader)

            Divider()
                .frame(height: 44)

            rotationButton(
                systemImage: "arrow.clockwise",
                accessibilityLabel: "Rotate clockwise",
                direction: .clockwise
            )
        }
        .frame(height: 76)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
            dimensions.width
        }
    }

    private func rotationButton(
        systemImage: String,
        accessibilityLabel: LocalizedStringKey,
        direction: SecondGearRotationDirection
    ) -> some View {
        Button {
            Task { await store.rotateSecondGear(direction) }
        } label: {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(RockerButtonStyle())
        .accessibilityLabel(accessibilityLabel)
        .disabled(
            !store.canRotateSecondGear
                || store.isRotatingSecondGear
                || store.isCalibrating
                || store.isShifting
                || store.isUpdatingAutoDownshift
                || store.isUpdatingPairing
        )
    }
}