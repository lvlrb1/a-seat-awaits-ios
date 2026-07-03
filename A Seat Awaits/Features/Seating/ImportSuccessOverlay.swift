//
//  ImportSuccessOverlay.swift
//  A Seat Awaits
//
//  Celebratory confirmation shown the moment a guest import commits, before the
//  sheet dismisses: a checkmark that springs in with an expanding ring and a
//  sparkle burst. Pairs with a success haptic in `ReviewImportView`. Honors
//  Reduce Motion (A11y) — falls back to a calm, static badge.
//

import SwiftUI

struct ImportSuccessOverlay: View {
    let count: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pop = false
    @State private var burst = false

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            Brand.canvas.opacity(0.45).ignoresSafeArea()

            VStack(spacing: 16) {
                emblem

                VStack(spacing: 6) {
                    Text("\(count) \(count == 1 ? "guest" : "guests") added")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                    Text("They're on your guest list.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Brand.textSecondary)
                }
            }
            .padding(.vertical, 34)
            .padding(.horizontal, 34)
            .modifier(BrandCard())
            .padding(.horizontal, 44)
            .scaleEffect(reduceMotion ? 1 : (pop ? 1 : 0.88))
            .opacity(pop ? 1 : 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) \(count == 1 ? "guest" : "guests") added to your guest list")
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { pop = true }
            withAnimation(.easeOut(duration: 0.75)) { burst = true }
        }
    }

    // MARK: - Emblem

    private var emblem: some View {
        ZStack {
            // Expanding ring that radiates out and fades.
            Circle()
                .stroke(Brand.success.opacity(0.45), lineWidth: 3)
                .frame(width: 96, height: 96)
                .scaleEffect(reduceMotion ? 1 : (burst ? 1.55 : 0.55))
                .opacity(reduceMotion ? 0 : (burst ? 0 : 0.9))

            // Sparkle burst flying outward.
            ForEach(0..<8, id: \.self) { i in sparkle(i) }

            // Green disc + checkmark that springs in.
            Circle()
                .fill(Brand.successFill)
                .frame(width: 84, height: 84)
                .shadow(color: Brand.success.opacity(0.35), radius: 12, x: 0, y: 8)

            Image(systemName: "checkmark")
                .font(.system(size: 38, weight: .heavy))
                .foregroundStyle(Brand.successText)
                .scaleEffect(reduceMotion ? 1 : (pop ? 1 : 0.2))
        }
        .frame(width: 124, height: 124)
    }

    private func sparkle(_ i: Int) -> some View {
        let angle = (Double(i) / 8.0) * 2 * .pi
        let radius: CGFloat = reduceMotion ? 0 : (burst ? 64 : 12)
        let palette = [Brand.purple, Brand.lilac, Brand.success]
        return Image(systemName: "sparkle")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(palette[i % palette.count])
            .offset(x: cos(angle) * radius, y: sin(angle) * radius)
            .scaleEffect(reduceMotion ? 0 : (burst ? 0.4 : 1))
            .opacity(reduceMotion ? 0 : (burst ? 0 : 1))
    }
}
