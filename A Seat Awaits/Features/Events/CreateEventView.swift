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
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var hasDate = false
    @State private var date = Date()
    @State private var location = ""
    @State private var description = ""
    @State private var isSaving = false
    @State private var showingDatePicker = false
    @State private var errorMessage: String?

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
            try await store.create(
                name: name.trimmingCharacters(in: .whitespaces),
                date: hasDate ? Self.isoDate.string(from: date) : nil,
                location: location,
                description: description
            )
            dismiss()
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
    }
}
