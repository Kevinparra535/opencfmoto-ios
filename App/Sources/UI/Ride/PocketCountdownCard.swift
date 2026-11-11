// SPDX-License-Identifier: AGPL-3.0-or-later
// The «Modo bolsillo» offer (UI/UX P0, UX-01): after Connect or Go, while `RideModel.pocketCountdown`
// runs, a card at the bottom of any screen counts 5 s down — «Modo bolsillo en 5 s · Guarda el
// teléfono: el tablero sigue en vivo» — with one labelled button, «Quedarme aquí», which cancels.
// When the count runs out, RideModel turns pocket mode on (RootView's cover). The rules of the offer
// (only with the own dash UI live, in the foreground, nothing else waiting for the rider; leaving or
// using the phone ends it) live in the model (PocketMode.swift); this view only shows it.

import SwiftUI
import UIKit
import OpenCfMotoAppModel

/// RootView's bottom overlay: the card while a countdown runs (never over the pocket screen).
struct PocketCountdownOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ride = model.ride
        ZStack(alignment: .bottom) {
            if let countdown = ride.pocketCountdown, !ride.isRideModeActive {
                PocketCountdownCard(countdown: countdown)
                    .padding(.horizontal, Theme.padding)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.25), value: ride.pocketCountdown)
    }
}

struct PocketCountdownCard: View {
    @Environment(AppModel.self) private var model
    let countdown: PocketCountdown
    @ScaledMetric(relativeTo: .title3) private var ringSize: CGFloat = 52
    /// VoiceOver / Switch Control land on «Quedarme aquí» when the card shows (review PH-5).
    @AccessibilityFocusState private var stayFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let now = AppPlatform.shared.now()
                let left = countdown.secondsLeft(at: now)
                HStack(alignment: .center, spacing: 14) {
                    ZStack {
                        Circle()
                            .stroke(Theme.outline, lineWidth: 4)
                        Circle()
                            .trim(from: 0, to: max(0, 1 - countdown.progress(at: now)))
                            .stroke(Theme.brand, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text(verbatim: "\(left)")
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(Theme.text)
                    }
                    .frame(width: ringSize, height: ringSize)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pocket mode in \(left) s")
                            .font(.headline)
                            .foregroundStyle(Theme.text)
                        Text("Put the phone away: the dash stays live.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 0)
                }
            }

            Button {
                model.ride.cancelPocketCountdown()
            } label: {
                Label("Stay here", systemImage: "hand.raised")
            }
            .buttonStyle(TonalButtonStyle())
            .accessibilityHint(Text("Keeps this screen; the dash stays live"))
            .accessibilityFocused($stayFocused)
        }
        .padding(Theme.padding)
        .frame(maxWidth: 520)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.outline, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        .onAppear {
            // With VoiceOver or Switch Control the countdown is 3 × longer (RideModel) and the focus moves to
            // «Quedarme aquí», so one activation stays; the announcement is queued after the focus is read.
            if UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning { stayFocused = true }
            let seconds = Int(countdown.duration.rounded())
            let text = String(localized: "Pocket mode in \(seconds) seconds. Put the phone away: the dash stays live.")
            UIAccessibility.post(notification: .announcement,
                                 argument: NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true]))
        }
    }
}
