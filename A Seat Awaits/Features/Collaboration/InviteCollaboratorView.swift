//
//  InviteCollaboratorView.swift
//  A Seat Awaits
//
//  Owner-facing form to invite a collaborator to an event. Sends the invitation
//  email through the authenticated `send-event-invitation` edge function (never
//  Resend, never the Nuxt API). On success it shows the delivery state; if email
//  delivery failed, the owner can copy the invite link or retry — the invitation
//  is never claimed as "emailed" when it wasn't.
//

import SwiftUI

struct InviteCollaboratorView: View {
    @Bindable var store: EventCollaboratorsStore
    var onDismiss: () -> Void

    @State private var name = ""
    @State private var email = ""
    @State private var role: CollaboratorRole = .viewer
    @State private var result: InvitationSummary?
    @FocusState private var focused: Field?

    private enum Field { case name, email }

    private var canSend: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && EmailValidator.isValid(CollaboratorsOverview.normalize(email: email))
            && !store.isInviting
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let result {
                        resultView(result)
                    } else {
                        formView
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .background(Brand.canvas)
            .navigationTitle("Invite collaborator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onDismiss() }.foregroundStyle(Brand.accent)
                }
            }
        }
    }

    // MARK: - Form

    private var formView: some View {
        VStack(alignment: .leading, spacing: 16) {
            LabeledField(title: "Name", isFocused: focused == .name) {
                TextField("Brooke Fielding", text: $name)
                    .textContentType(.name)
                    .focused($focused, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focused = .email }
            }

            LabeledField(title: "Email", isFocused: focused == .email) {
                TextField("brooke@evergreen-events.co", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .email)
            }

            Text("Role")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Brand.slate600)
                .padding(.top, 4)

            Picker("Role", selection: $role) {
                Text("Viewer").tag(CollaboratorRole.viewer)
                Text("Editor").tag(CollaboratorRole.editor)
            }
            .pickerStyle(.segmented)

            Text(role == .editor
                 ? "Editors can manage guests, assign seating, and edit the floor plan."
                 : "Viewers can see the guest list, seating, and floor plan, but can't make changes.")
                .font(.system(size: 13))
                .foregroundStyle(Brand.textSecondary)

            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Brand.danger)
            }

            Button {
                focused = nil
                Task { result = await store.sendEmailInvite(name: name, email: email, role: role) }
            } label: {
                HStack(spacing: 8) {
                    if store.isInviting { ProgressView().tint(.white) }
                    Text("Send invitation")
                }
            }
            .buttonStyle(.primaryBrand)
            .disabled(!canSend)
            .padding(.top, 8)
        }
    }

    // MARK: - Result

    @ViewBuilder
    private func resultView(_ summary: InvitationSummary) -> some View {
        let emailed = !summary.deliveryStatus.isFailure && summary.deliveryStatus != .failed
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: emailed ? "paperplane.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(emailed ? Brand.accent : Brand.warning)
                .padding(.top, 24)

            Text(emailed ? "Invitation sent" : "Invitation saved")
                .font(.system(size: 24, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(Brand.textPrimary)

            Text(emailed
                 ? "We emailed an invitation to \(summary.inviteeEmail). They'll get \(role == .editor ? "edit" : "view") access when they accept."
                 : "We saved the invitation to \(summary.inviteeEmail) but couldn't send the email. You can copy the link below or resend it.")
                .font(.system(size: 15))
                .lineSpacing(3)
                .foregroundStyle(Brand.textSecondary)

            if let urlString = summary.inviteUrl, let url = URL(string: urlString) {
                ShareLink(item: url) {
                    Label("Share invite link", systemImage: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                }
                .padding(.top, 4)
            }

            Button("Done") { onDismiss() }
                .buttonStyle(.primaryBrand)
                .padding(.top, 8)
        }
    }
}
