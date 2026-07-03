//
//  StructuringOverlay.swift
//  A Seat Awaits
//
//  Full-screen branded loading state shown while `ai-import-guests` structures a
//  pasted list or uploaded spreadsheet. A glowing, rotating sparkle emblem plus
//  rotating status copy that narrates what the AI is actually doing, so the wait
//  feels intentional rather than idle. Honors Reduce Motion (A11y).
//

import Combine
import SwiftUI

struct StructuringOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var spin = false
    @State private var pulse = false
    @State private var dotPhase = false
    @State private var messageIndex = 0

    /// Status lines that mirror the real extraction steps (adults → partners →
    /// children → cleanup), cycled on a timer.
    private let messages = [
        "Reading your list…",
        "Finding your guests…",
        "Splitting couples…",
        "Seating the little ones…",
        "Tidying up the names…",
    ]
    private let timer = Timer.publish(every: 1.7, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Dim + frost the screen behind the card.
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            Brand.canvas.opacity(0.45).ignoresSafeArea()

            VStack(spacing: 22) {
                emblem

                VStack(spacing: 6) {
                    Text("Structuring your guest list")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                        .multilineTextAlignment(.center)

                    Text(messages[messageIndex])
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Brand.textSecondary)
                        .id(messageIndex)
                        .transition(reduceMotion
                                    ? .opacity
                                    : .opacity.combined(with: .move(edge: .bottom)))
                }

                progressDots
            }
            .padding(.vertical, 34)
            .padding(.horizontal, 30)
            .modifier(BrandCard())
            .padding(.horizontal, 44)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Structuring your guest list")
        .accessibilityValue(messages[messageIndex])
        .accessibilityAddTraits(.updatesFrequently)
        .onAppear {
            spin = true
            pulse = true
            dotPhase = true
        }
        .onReceive(timer) { _ in
            withAnimation(.easeInOut(duration: 0.45)) {
                messageIndex = (messageIndex + 1) % messages.count
            }
        }
    }

    // MARK: - Emblem

    private var emblem: some View {
        ZStack {
            // Soft breathing glow.
            Circle()
                .fill(Brand.purple.opacity(0.20))
                .frame(width: 116, height: 116)
                .blur(radius: 16)
                .scaleEffect(reduceMotion ? 1 : (pulse ? 1.10 : 0.90))
                .animation(reduceMotion ? nil
                           : .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                           value: pulse)

            // Rotating comet-tail ring.
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(
                    AngularGradient(
                        colors: [Brand.purple.opacity(0), Brand.purple, Brand.lilac],
                        center: .center),
                    style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .frame(width: 98, height: 98)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(reduceMotion ? nil
                           : .linear(duration: 1.15).repeatForever(autoreverses: false),
                           value: spin)

            // Brand disc + sparkle (matches the import banner / CTA sparkle).
            Circle()
                .fill(Brand.primaryFill)
                .frame(width: 74, height: 74)
                .shadow(color: Brand.plum.opacity(0.5), radius: 12, x: 0, y: 8)

            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .scaleEffect(reduceMotion ? 1 : (pulse ? 1.06 : 0.94))
                .animation(reduceMotion ? nil
                           : .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                           value: pulse)

            // Twinkling satellites.
            twinkle(dx: -56, dy: -30, size: 16, delay: 0.0)
            twinkle(dx: 54, dy: -18, size: 12, delay: 0.5)
            twinkle(dx: 46, dy: 42, size: 14, delay: 0.9)
        }
        .frame(width: 130, height: 130)
    }

    private func twinkle(dx: CGFloat, dy: CGFloat, size: CGFloat, delay: Double) -> some View {
        Image(systemName: "sparkle")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Brand.lilac)
            .opacity(reduceMotion ? 0.7 : (pulse ? 0.95 : 0.25))
            .scaleEffect(reduceMotion ? 1 : (pulse ? 1.0 : 0.6))
            .offset(x: dx, y: dy)
            .animation(reduceMotion ? nil
                       : .easeInOut(duration: 1.1).repeatForever(autoreverses: true).delay(delay),
                       value: pulse)
    }

    // MARK: - Progress dots

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Brand.accent)
                    .frame(width: 8, height: 8)
                    .opacity(reduceMotion ? 0.55 : (dotPhase ? 1 : 0.3))
                    .scaleEffect(reduceMotion ? 1 : (dotPhase ? 1 : 0.7))
                    .animation(reduceMotion ? nil
                               : .easeInOut(duration: 0.6)
                                   .repeatForever(autoreverses: true)
                                   .delay(Double(i) * 0.18),
                               value: dotPhase)
            }
        }
    }
}
