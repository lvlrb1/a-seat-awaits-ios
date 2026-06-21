//
//  EventCollaboratorsView.swift
//  A Seat Awaits
//
//  The per-event Collaborators screen, presented from an event's More tab. Lets
//  the owner invite people by email + role, copy the resulting invite link, and
//  manage existing access (change role, remove, revoke pending), resend a pending
//  invite, and see delivery status. Invitations are sent via the authenticated
//  `send-event-invitation` edge function (never Resend, never the Nuxt API);
//  delivery status comes from the owner-scoped `invitation_delivery_status` RPC.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct EventCollaboratorsView: View {
    let ownerName: String
    let ownerEmail: String

    @State private var store: EventCollaboratorsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    // Invite sheet
    @State private var showInvite = false

    @State private var pendingRemoval: EventCollaborator?

    private static let subscriptionURL = URL(string: "https://aseatawaits.com/subscription")!

    init(event: Event, supabase: SupabaseClient, siteURL: URL,
         ownerName: String, ownerEmail: String) {
        self.ownerName = ownerName
        self.ownerEmail = ownerEmail
        _store = State(initialValue: EventCollaboratorsStore(event: event, supabase: supabase, siteURL: siteURL))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    limitsCard
                    if store.policy.isCollaborationEnabled {
                        inviteSection
                    } else {
                        upgradeCard
                    }
                    teamSection
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .background(Brand.canvas.ignoresSafeArea())
            .scrollIndicators(.hidden)
            .navigationTitle("Collaborators")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if !store.hasLoaded { await store.load() }
                await store.loadDeliveryStatuses()
            }
            .refreshable {
                await store.load()
                await store.loadDeliveryStatuses()
            }
            .sheet(isPresented: $showInvite) {
                InviteCollaboratorView(store: store) {
                    showInvite = false
                    Task { await store.load(); await store.loadDeliveryStatuses() }
                }
            }
            .alert("Something went wrong",
                   isPresented: Binding(get: { store.errorMessage != nil },
                                        set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK", role: .cancel) { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "")
            }
            .confirmationDialog(
                "Remove collaborator",
                isPresented: Binding(get: { pendingRemoval != nil },
                                     set: { if !$0 { pendingRemoval = nil } }),
                titleVisibility: .visible,
                presenting: pendingRemoval) { person in
                Button(person.isActive ? "Remove" : "Revoke", role: .destructive) {
                    let target = person
                    pendingRemoval = nil
                    Task {
                        if target.isActive { await store.remove(target) }
                        else { await store.revoke(target) }
                    }
                }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: { person in
                Text(person.isActive
                     ? "\(person.displayName) will lose access to this event."
                     : "The pending invitation to \(person.displayName) will be revoked.")
            }
        }
    }

    // MARK: - Limits / usage

    private var limitsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "person.2.badge.gearshape")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                Text("Event Collaborators")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
                Spacer()
                if store.policy.isCollaborationEnabled {
                    usageBadge
                }
            }
            Text(store.policy.isCollaborationEnabled
                 ? "Invite people to view or edit this event's guest list and floor plan."
                 : store.policy.availabilityMessage)
                .font(.system(size: 13))
                .foregroundStyle(Brand.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .brandCard(radius: 18)
    }

    private var usageBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(usageColor).frame(width: 7, height: 7)
            Text("\(store.currentCount)/\(store.maxCount)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(usageColor)
        }
        .accessibilityLabel("\(store.currentCount) of \(store.maxCount) collaborators used")
    }

    private var usageColor: Color {
        switch store.usageLevel {
        case .normal: return Brand.success
        case .warning: return Brand.warning
        case .limitReached: return Brand.danger
        }
    }

    // MARK: - Upgrade (collaboration disabled on plan)

    private var upgradeCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 26))
                .foregroundStyle(Brand.slate400)
            Text("Collaboration isn't on your plan")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.textPrimary)
            Text("Upgrade to invite people to help manage this event.")
                .font(.system(size: 13))
                .foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center)
            Button("Upgrade Plan") { openURL(Self.subscriptionURL) }
                .buttonStyle(.secondaryOutline)
                .frame(maxWidth: 220)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .brandCard(radius: 18)
    }

    // MARK: - Invite form

    @ViewBuilder
    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Invite Someone")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Brand.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)

            if store.isAtLimit {
                Label("This event has reached its collaborator limit. Remove someone to invite a new person.",
                      systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.warningText)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.warningFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Button {
                    store.errorMessage = nil
                    showInvite = true
                } label: {
                    Label("Invite collaborator", systemImage: "person.crop.circle.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.primaryBrand)
            }
        }
        .padding(16)
        .brandCard(radius: 18)
    }

    // MARK: - Team list

    private var teamSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("On This Event")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Brand.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ownerRow
                ForEach(Array(store.collaborators.enumerated()), id: \.element.id) { index, person in
                    Divider().overlay(Brand.hairline).padding(.leading, 64)
                    collaboratorRow(person)
                }
                if store.collaborators.isEmpty && store.hasLoaded {
                    Divider().overlay(Brand.hairline).padding(.leading, 64)
                    Text("No collaborators yet. Invite someone above.")
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
            .brandCard(radius: 16)
        }
    }

    private var ownerRow: some View {
        HStack(spacing: 12) {
            InitialsAvatar(name: ownerName.isEmpty ? "You" : ownerName, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(ownerName.isEmpty ? "You" : ownerName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)
                    .lineLimit(1)
                if !ownerEmail.isEmpty {
                    Text(ownerEmail)
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            TagPill.assigned("Owner")
        }
        .padding(16)
    }

    private func collaboratorRow(_ person: EventCollaborator) -> some View {
        HStack(spacing: 12) {
            InitialsAvatar(name: person.displayName, size: 40)
                .opacity(person.isPending ? 0.6 : 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(person.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)
                    .lineLimit(1)
                if !person.email.isEmpty {
                    Text(person.email)
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if person.isPending {
                    HStack(spacing: 6) {
                        Text("Pending • \(person.role.label)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Brand.warningText)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Brand.warningFill, in: Capsule())
                        if let status = store.deliveryStatus(for: person), status != .pending {
                            Text(status.label)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(status.isFailure ? Brand.danger : Brand.textSecondary)
                        }
                    }
                }
            }

            Spacer(minLength: 8)
            trailing(for: person)
        }
        .padding(16)
        .opacity(store.isDeleting(person) ? 0.5 : 1)
    }

    @ViewBuilder
    private func trailing(for person: EventCollaborator) -> some View {
        if store.isDeleting(person) {
            ProgressView()
        } else if person.isActive {
            HStack(spacing: 8) {
                RolePicker(
                    role: Binding(get: { person.role },
                                  set: { newRole in Task { await store.changeRole(person, to: newRole) } }),
                    isBusy: store.isUpdatingRole(person))
                Menu {
                    Button(role: .destructive) { pendingRemoval = person } label: {
                        Label("Remove from event", systemImage: "person.badge.minus")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(Brand.slate400)
                }
                .accessibilityLabel("More actions for \(person.displayName)")
            }
        } else if store.isResending(person) {
            ProgressView()
        } else {
            Menu {
                let status = store.deliveryStatus(for: person)
                if status?.canResend ?? true {
                    Button { Task { await store.resendInvite(person) } } label: {
                        Label("Resend invitation", systemImage: "paperplane")
                    }
                }
                if let link = store.inviteLink(for: person) {
                    Button { copyLink(link) } label: {
                        Label("Copy invite link", systemImage: "doc.on.doc")
                    }
                }
                Button(role: .destructive) { pendingRemoval = person } label: {
                    Label("Revoke invitation", systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(Brand.slate400)
            }
            .accessibilityLabel("More actions for \(person.displayName)")
        }
    }

    // MARK: - Actions

    private func copyLink(_ url: URL) {
        #if canImport(UIKit)
        UIPasteboard.general.string = url.absoluteString
        #endif
    }
}

// MARK: - Viewer / Editor picker

private struct RolePicker: View {
    @Binding var role: CollaboratorRole
    var isBusy: Bool = false

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                segment(.viewer)
                segment(.editor)
            }
            .padding(2)
            .background(Brand.control, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(isBusy ? 0 : 1)
            if isBusy { ProgressView() }
        }
        .disabled(isBusy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Role")
        .accessibilityValue(role.label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: role == .viewer ? "Make Editor" : "Make Viewer") {
            role = role == .viewer ? .editor : .viewer
        }
    }

    private func segment(_ option: CollaboratorRole) -> some View {
        let selected = role == option
        return Button {
            if !selected { role = option }
        } label: {
            Text(option.label)
                .font(.system(size: 12, weight: selected ? .bold : .semibold))
                .foregroundStyle(selected ? Brand.textPrimary : Brand.textSecondary)
                .frame(width: 52, height: 26)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Brand.card)
                            .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }
}
