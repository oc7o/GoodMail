import SwiftUI

/// The banner after Send: a glass capsule at the bottom of the window, "Sending “Subject”… Undo", with a ring that
/// counts down the ten seconds in which Undo is offered (timed from this device's clock, like the Outbox).
/// Offline it says instead that the message goes out once the device is back online, with the Outbox a tap away.
/// VoiceOver announces it when it appears. Whoever shows it removes it when `undoUntil` has passed.
struct UndoSendBanner: View {
    static let undoWindow: TimeInterval = 10

    private let subject: String
    private let undoUntil: Date
    private let isOffline: Bool
    private let onUndo: () -> Void
    private let onOpenOutbox: (() -> Void)?

    init(
        subject: String, undoUntil: Date, isOffline: Bool = false, onUndo: @escaping () -> Void,
        onOpenOutbox: (() -> Void)? = nil
    ) {
        self.subject = subject
        self.undoUntil = undoUntil
        self.isOffline = isOffline
        self.onUndo = onUndo
        self.onOpenOutbox = onOpenOutbox
    }

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 12) {
                if isOffline {
                    Label("Will send when you're back online", systemImage: "wifi.slash")
                    if let onOpenOutbox {
                        Button("Outbox", action: onOpenOutbox)
                            .fontWeight(.semibold)
                    }
                } else {
                    TimelineView(.periodic(from: .now, by: 0.25)) { context in
                        let remaining = max(0, undoUntil.timeIntervalSince(context.date))
                        HStack(spacing: 12) {
                            UndoCountdownRing(fraction: remaining / Self.undoWindow)
                                .accessibilityLabel("Time left to undo")
                                .accessibilityValue("\(Int(remaining.rounded(.up))) seconds")
                            Text("Sending “\(displaySubject)”…")
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Undo", action: onUndo)
                                .fontWeight(.semibold)
                                .disabled(remaining <= 0)
                        }
                    }
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .frame(maxWidth: 520)
        .accessibilityElement(children: .contain)
        .onAppear {
            AccessibilityNotification.Announcement(announcement).post()
        }
    }

    private var displaySubject: String {
        subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No Subject" : subject
    }

    private var announcement: String {
        isOffline
            ? "Your message will be sent when you're back online."
            : "Sending \(displaySubject). Undo is available for \(Int(Self.undoWindow)) seconds."
    }
}

/// The share of the Undo window that is left, as a shrinking ring.
private struct UndoCountdownRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 3)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: fraction)
        }
        .frame(width: 18, height: 18)
    }
}
