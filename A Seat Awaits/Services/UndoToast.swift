//
//  UndoToast.swift
//  A Seat Awaits
//
//  One shared "undo snackbar" used across the app so destructive and other
//  hard-to-reconstruct actions (delete event, delete guest, assign/unseat,
//  apply template) are reversible for a short window. Backed by an explicit,
//  VoiceOver-announced Undo control — the single pattern the design audit's
//  P0 recovery findings (F1–F3) call for.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Transient "Deleted X. Undo" banner state, owned by a store and presented by
/// its hosting screen via `.undoSnackbar(_:)`. At most one toast is visible at a
/// time — a new action replaces (and silently lets the prior one stand).
@MainActor
@Observable
final class UndoToast {
    /// How long an undo affordance stays actionable. The audit requires ≥5s.
    static let defaultDuration: TimeInterval = 5

    private(set) var message: String?
    private(set) var actionTitle: String = "Undo"

    private var onUndo: (() -> Void)?
    private var dismissTask: Task<Void, Never>?

    /// Shows a toast with an Undo button. `undo` runs on the main actor when the
    /// user taps Undo (and never after the window lapses).
    func show(_ message: String,
              actionTitle: String = "Undo",
              duration: TimeInterval = UndoToast.defaultDuration,
              undo: @escaping () -> Void) {
        self.message = message
        self.actionTitle = actionTitle
        self.onUndo = undo

        #if canImport(UIKit)
        // Announce so VoiceOver users learn the action happened and is reversible.
        UIAccessibility.post(notification: .announcement,
                             argument: "\(message) Double-tap \(actionTitle) to reverse.")
        #endif

        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.clear()
        }
    }

    /// Invokes the stored undo action and dismisses the toast.
    func undo() {
        let action = onUndo
        clear()
        action?()
    }

    /// Dismisses the toast without undoing (lets the action stand).
    func clear() {
        dismissTask?.cancel()
        dismissTask = nil
        message = nil
        onUndo = nil
    }
}

// MARK: - Snackbar view

/// The floating snackbar. Renders nothing when no toast is active.
struct UndoSnackbarView: View {
    @Bindable var toast: UndoToast

    var body: some View {
        if let message = toast.message {
            HStack(spacing: 12) {
                Text(message)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Button {
                    toast.undo()
                } label: {
                    Text(toast.actionTitle)
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(Brand.lilac)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Reverses the last action")
            }
            .padding(.leading, 16)
            .padding(.trailing, 4)
            .padding(.vertical, 6)
            .frame(minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.hex("#1E1124"))
                    .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isModal)
        }
    }
}

extension View {
    /// Overlays the shared undo snackbar at the bottom of the screen, animating
    /// in/out as `toast.message` changes.
    func undoSnackbar(_ toast: UndoToast) -> some View {
        self.overlay(alignment: .bottom) {
            UndoSnackbarView(toast: toast)
                .animation(.snappy(duration: 0.25), value: toast.message)
        }
    }
}
