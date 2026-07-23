//
//  EditProfileView.swift
//  A Seat Awaits
//
//  Edit the user's full name and (for password accounts) request an email
//  change. Both flow through `AccountStore` → the authenticated Supabase client;
//  no profile data or updates touch a web API. Validation, rollback and pending
//  states are handled by the store.
//

import SwiftUI

struct EditProfileView: View {
    @Bindable var store: AccountStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var nameLoaded = false
    @State private var nameFeedback: Feedback?

    @State private var newEmail = ""
    @State private var emailFeedback: Feedback?
    @FocusState private var focus: Field?

    private enum Field { case name, email }

    private struct Feedback: Equatable {
        let kind: FeedbackBanner.Kind
        let message: String
    }

    private var snapshot: AccountSnapshot? { store.snapshot }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canSaveName: Bool {
        !store.isSavingName && !trimmedName.isEmpty && trimmedName != (snapshot?.fullName ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                nameCard
                emailCard
            }
            .padding(18)
            .readableWidth(Layout.contentWidth)
        }
        .background(Brand.canvas.ignoresSafeArea())
        .scrollIndicators(.hidden)
        .navigationTitle("Edit Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !nameLoaded {
                name = snapshot?.fullName ?? ""
                nameLoaded = true
            }
        }
        .onTapGesture { focus = nil }
    }

    // MARK: - Name

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your name")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.textPrimary)

            LabeledField(title: "Full name", isFocused: focus == .name) {
                TextField("Full name", text: $name)
                    .textContentType(.name)
                    .submitLabel(.done)
                    .focused($focus, equals: .name)
                    .onSubmit { Task { await saveName() } }
            }

            if let nameFeedback {
                FeedbackBanner(kind: nameFeedback.kind, message: nameFeedback.message)
            }

            Button {
                Task { await saveName() }
            } label: {
                if store.isSavingName {
                    HStack(spacing: 8) { ProgressView().tint(.white); Text("Saving…") }
                } else {
                    Text("Save Name")
                }
            }
            .buttonStyle(.primaryBrand)
            .disabled(!canSaveName)
            .opacity(canSaveName ? 1 : 0.5)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }

    private func saveName() async {
        focus = nil
        nameFeedback = nil
        switch await store.updateFullName(name) {
        case .success:
            nameFeedback = Feedback(kind: .success, message: "Your name has been updated.")
        case .failure(let error):
            nameFeedback = Feedback(kind: .error, message: AccountStore.message(for: error))
        }
    }

    // MARK: - Email

    @ViewBuilder
    private var emailCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Email")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.textPrimary)

            HStack(spacing: 8) {
                Text(snapshot?.email ?? "—")
                    .font(.system(size: 15))
                    .foregroundStyle(Brand.textSecondary)
                Spacer()
                if let verified = snapshot?.authUser.isEmailVerified {
                    Text(verified ? "Verified" : "Unverified")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(verified ? Brand.successText : Brand.warningText)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(verified ? Brand.successFill : Brand.warningFill, in: Capsule())
                }
            }

            if let pending = snapshot?.authUser.pendingEmail {
                FeedbackBanner(kind: .info,
                               message: "Change to \(pending) is pending. Confirm it from the link sent to that address.")
            }

            if snapshot?.authUser.isPasswordAccount == true {
                Divider().overlay(Brand.hairline)

                LabeledField(title: "New email address", isFocused: focus == .email) {
                    TextField("you@example.com", text: $newEmail)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($focus, equals: .email)
                        .onSubmit { Task { await submitEmail() } }
                }

                Text("We'll send a confirmation link to the new address. Your current email stays active until you confirm.")
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let emailFeedback {
                    FeedbackBanner(kind: emailFeedback.kind, message: emailFeedback.message)
                }

                Button {
                    Task { await submitEmail() }
                } label: {
                    if store.isChangingEmail {
                        HStack(spacing: 8) { ProgressView(); Text("Sending…") }
                    } else {
                        Text("Change Email")
                    }
                }
                .buttonStyle(.secondaryOutline)
                .disabled(store.isChangingEmail || newEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Text("Your email is managed by \(snapshot?.authUser.providerLabel ?? "your sign-in provider"). To change it, update your provider account.")
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }

    private func submitEmail() async {
        focus = nil
        emailFeedback = nil
        switch await store.changeEmail(newEmail) {
        case .success(let outcome):
            switch outcome {
            case .changed:
                emailFeedback = Feedback(kind: .success, message: "Your email has been updated.")
                newEmail = ""
            case .confirmationRequired(let address):
                emailFeedback = Feedback(kind: .info,
                                         message: "Confirmation sent to \(address). Your email updates once you confirm it.")
                newEmail = ""
            }
        case .failure(let error):
            emailFeedback = Feedback(kind: .error, message: AccountStore.message(for: error))
        }
    }
}
