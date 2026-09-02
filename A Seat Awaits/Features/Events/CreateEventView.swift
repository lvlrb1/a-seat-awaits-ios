//
//  CreateEventView.swift
//  A Seat Awaits
//
//  Bottom-sheet form for creating a new event, styled to the design spec:
//  grabber, sheet header, labeled fields with focus rings, and a pinned CTA.
//

import SwiftUI

struct CreateEventView: View {
    let store: EventStore
    /// The user's unattached, unrefunded passes, oldest first — the first one
    /// is what the DB trigger claims by default. With more than one, a picker
    /// lets the user choose which pass covers this event (mirrors the web's
    /// EventForm pass-first flow).
    var unattachedPasses: [EventPass] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var name = ""
    @State private var hasDate = false
    @State private var date = Date()
    @State private var location = ""
    @State private var description = ""
    @State private var isSaving = false
    @State private var showingDatePicker = false
    @State private var showingPassPaywall = false
    @State private var errorMessage: String?
    /// Nil = the default (oldest) pass, the same one the trigger would claim.
    @State private var selectedPassId: String?

    private enum Field { case name, venue }
    @FocusState private var focused: Field?

    private static let isoDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let dateDisplay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving
    }

    var body: some View {
        VStack(spacing: 0) {
            Grabber()
                .padding(.top, 8)
                .padding(.bottom, 6)

            // Single primary action (the pinned "Create Event" button below) —
            // the header only cancels, removing the duplicate CTA (F14).
            SheetHeader(
                title: "New Event",
                onCancel: { dismiss() }
            )
            .padding(.horizontal, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    passBanner

                    LabeledField(title: "Event name", isFocused: focused == .name) {
                        TextField("Patel–Rossi Wedding", text: $name)
                            .focused($focused, equals: .name)
                            .submitLabel(.next)
                    }

                    LabeledField(title: "Date") {
                        Button { showingDatePicker = true } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "calendar")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Brand.slate400)
                                Text(hasDate ? Self.dateDisplay.string(from: date) : "Pick a date")
                                    .foregroundStyle(hasDate ? Brand.textPrimary : Brand.slate400)
                                Spacer(minLength: 0)
                            }
                            // The field chrome lives in LabeledField, outside this
                            // Button — without a full-size content shape only the
                            // icon+text cluster would be tappable.
                            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    LabeledField(title: "Venue", isFocused: focused == .venue) {
                        HStack(spacing: 8) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Brand.slate400)
                            TextField("Cedar Hall, Portland", text: $location)
                                .focused($focused, equals: .venue)
                        }
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Brand.success)
                        Text("You can import the guest list right after.")
                            .font(.system(size: 14))
                            .foregroundStyle(Brand.slate600)
                    }
                    .padding(.horizontal, 2)
                    .padding(.top, 2)

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(Brand.danger)
                    }
                }
                .padding(.top, 22)
                .padding(.horizontal, 4)
            }
            .scrollDismissesKeyboard(.interactively)

            Button("Create Event") { Task { await create() } }
                .buttonStyle(.primaryBrand)
                .disabled(!canCreate)
                .opacity(canCreate ? 1 : 0.5)
                .padding(.top, 8)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 26)
        .background(Brand.card.ignoresSafeArea())
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(isSaving)
        .sheet(isPresented: $showingDatePicker) {
            datePickerSheet
        }
        .sheet(isPresented: $showingPassPaywall, onDismiss: {
            // The "pass required" error belongs to the state before the
            // paywall; leaving it up after a purchase reads as a failure.
            errorMessage = nil
        }) {
            if let supabase = appState.supabase {
                PaywallView(supabase: supabase, appState: appState)
            }
        }
    }

    // MARK: - Pass banner (pass-first flow)

    /// The pass the user has picked (defaults to the oldest — the trigger's
    /// own choice — so a single-pass user never has to think about it).
    private var selectedPass: EventPass? {
        unattachedPasses.first { $0.id == selectedPassId } ?? unattachedPasses.first
    }

    @ViewBuilder
    private var passBanner: some View {
        if let pass = selectedPass {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "ticket")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Brand.accent)
                    Text(unattachedPasses.count == 1
                         ? "Your \(pass.tierDisplayName) is ready"
                         : "You have \(unattachedPasses.count) unused passes")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                }

                Text(unattachedPasses.count == 1
                     ? "It attaches to this event automatically when you create it, with no extra checkout step. Covers up to \(pass.guestCap.formatted()) guests."
                     : "Choose which pass covers this event. It attaches when you create it, with no extra checkout step.")
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if unattachedPasses.count > 1 {
                    VStack(spacing: 8) {
                        ForEach(unattachedPasses) { option in
                            passOptionRow(option, isSelected: option.id == pass.id)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.accent.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Brand.accent.opacity(0.2), lineWidth: 1))
        }
    }

    /// One selectable pass row — a radio-style card, not a system menu, so
    /// long tier/date strings wrap instead of truncating.
    private func passOptionRow(_ option: EventPass, isSelected: Bool) -> some View {
        Button {
            selectedPassId = option.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? Brand.accent : Brand.slate300)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(option.tierDisplayName) · up to \(option.guestCap.formatted()) guests")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Brand.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let bought = AccountDate.medium(option.purchasedAt) {
                        Text("Bought \(bought)")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Brand.accent.opacity(0.12) : Brand.card,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Brand.accent.opacity(0.5) : Brand.slate300.opacity(0.4),
                            lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.tierDisplayName), up to \(option.guestCap.formatted()) guests")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var datePickerSheet: some View {
        NavigationStack {
            DatePicker("Date", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(Brand.plum)
                .padding()
                .navigationTitle("Pick a date")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            hasDate = true
                            showingDatePicker = false
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    private func create() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            // Only send a pass id when the user picked something other than
            // the default (oldest) pass — that one the trigger claims anyway.
            let chosenPassId = (selectedPass?.id != unattachedPasses.first?.id)
                ? selectedPass?.id : nil
            try await store.create(
                name: name.trimmingCharacters(in: .whitespaces),
                date: hasDate ? Self.isoDate.string(from: date) : nil,
                location: location,
                description: description,
                preferredPassId: chosenPassId
            )
            dismiss()
        } catch {
            // The database's entitlement trigger is the authoritative gate:
            // no unattached pass, entitled subscription, or grandfathered
            // flag → the insert is rejected and we sell a pass instead.
            if Self.isPassRequired(error) {
                errorMessage = "An Event Pass is required to create your event."
                showingPassPaywall = true
            } else {
                errorMessage = FriendlyError.message(for: error)
            }
        }
    }

    /// True when the failure is the DB trigger's EVENT_PASS_REQUIRED rejection.
    private static func isPassRequired(_ error: Error) -> Bool {
        if case SupabaseError.http(_, let message) = error {
            return message.contains("EVENT_PASS_REQUIRED")
        }
        return String(describing: error).contains("EVENT_PASS_REQUIRED")
    }
}
