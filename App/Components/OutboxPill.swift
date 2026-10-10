import SwiftUI

/// The glass capsule under the thread list that says what hasn't reached Fastmail yet, for example
/// "Offline · 2 changes and 1 message waiting"; a tap opens the Outbox. It replaces the plain offline notice and
/// shows nothing when there is nothing to report.
struct OutboxPill: View {
    private let waiting: Int
    private let failed: Int
    private let pendingChanges: Int
    private let isOffline: Bool
    private let onTap: () -> Void

    init(waiting: Int, failed: Int, pendingChanges: Int, isOffline: Bool, onTap: @escaping () -> Void) {
        self.waiting = waiting
        self.failed = failed
        self.pendingChanges = pendingChanges
        self.isOffline = isOffline
        self.onTap = onTap
    }

    var body: some View {
        let summary = Self.summary(
            waiting: waiting, failed: failed, pendingChanges: pendingChanges, isOffline: isOffline)
        if let summary {
            Button(action: onTap) {
                Label(summary, systemImage: symbolName)
                    .font(.footnote)
                    .foregroundStyle(failed > 0 ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityHint("Opens the Outbox")
            .help("Show the Outbox")
        }
    }

    private var symbolName: String {
        if failed > 0 { return "exclamationmark.circle" }
        return isOffline ? "wifi.slash" : "tray.and.arrow.up"
    }

    /// "Offline · 2 changes and 1 message waiting · 1 not sent"; nil when online with nothing outstanding.
    static func summary(waiting: Int, failed: Int, pendingChanges: Int, isOffline: Bool) -> String? {
        var segments: [String] = []
        if isOffline { segments.append("Offline") }
        let waitingItems = [
            count(pendingChanges, "change", "changes"),
            count(waiting, "message", "messages"),
        ].compactMap { $0 }
        if !waitingItems.isEmpty {
            segments.append(waitingItems.joined(separator: " and ") + " waiting")
        } else if isOffline && failed == 0 {
            segments.append("Showing saved mail")
        }
        if failed > 0 {
            segments.append(failed == 1 ? "1 message not sent" : "\(failed) messages not sent")
        }
        return segments.isEmpty ? nil : segments.joined(separator: " · ")
    }

    private static func count(_ value: Int, _ singular: String, _ plural: String) -> String? {
        switch value {
        case ..<1: nil
        case 1: "1 \(singular)"
        default: "\(value) \(plural)"
        }
    }
}
