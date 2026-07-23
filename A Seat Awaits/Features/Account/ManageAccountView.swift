//
//  ManageAccountView.swift
//  A Seat Awaits
//
//  The native Manage Account screen. Organizes the account experience into
//  Profile, Plan & Billing, Event Management, Security, Data & Privacy,
//  Support & Legal, Sign Out and a Danger Zone. Reads everything from
//  `AccountStore` and pushes to focused sub-screens; no data or mutation logic
//  lives in this view's body.
//

import SwiftUI

struct ManageAccountView: View {
    let supabase: SupabaseClient

    @State private var store: AccountStore
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var showingSignOutConfirm = false

    init(supabase: SupabaseClient, appState: AppState) {
        self.supabase = supabase
        _store = State(initialValue: AccountStore(supabase: supabase, appState: appState))
    }

    private var snapshot: AccountSnapshot? { store.snapshot }
    private var policy: PlanPolicy { snapshot?.policy ?? .free }

    private var displayName: String {
        snapshot?.fullName ?? appState.currentUser?.displayName ?? "Planner"
    }
    private var email: String? { snapshot?.email ?? appState.currentUser?.email }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    AccountHeroHeader(name: displayName, email: email)
                    VStack(spacing: 16) {
                        if let message = store.loadErrorMessage, snapshot == nil {
                            FeedbackBanner(kind: .error, message: message)
                        }
                        planCard
                        profileSection
                        eventManagementSection
                        securitySection
                        dataPrivacySection
                        supportSection
                        signOutSection
                        dangerZoneSection
                        footer
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                    .readableWidth(Layout.contentWidth)
                }
            }
            .background(Brand.canvas.ignoresSafeArea())
            .scrollIndicators(.hidden)
            .toolbar(.hidden, for: .navigationBar)
            .ignoresSafeArea(edges: .top)
            .task { if store.snapshot == nil { await store.load() } }
            .refreshable { await store.load() }
            .onChange(of: scenePhase) { _, phase in
                // Refresh billing/profile after a billing action on the web.
                if phase == .active, store.hasLoaded {
                    Task { await store.refreshBillingState() }
                }
            }
            .alert("Sign out?", isPresented: $showingSignOutConfirm) {
                Button("Sign Out", role: .destructive) {
                    Task { await appState.signOut() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You can sign back in anytime.")
            }
        }
    }

    // MARK: - Plan card

    private var planCard: some View {
        NavigationLink {
            SubscriptionSummaryView(store: store)
        } label: {
            HStack(spacing: 13) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(LinearGradient(colors: [Brand.plum, Brand.purple],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 46, height: 46)
                    .overlay(
                        Image(systemName: "crown.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white))

                VStack(alignment: .leading, spacing: 3) {
                    if snapshot == nil && store.isLoading {
                        ProgressView()
                    } else {
                        HStack(spacing: 8) {
                            Text("\(policy.planDisplayName) plan")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(Brand.textPrimary)
                            if snapshot?.subscription != nil || !policy.isFree {
                                StatusBadge(status: policy.status)
                            }
                        }
                        Text(planSubtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(Brand.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Text("Manage")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Brand.accent)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Brand.slate300)
            }
            .padding(16)
            .brandCard(radius: 18)
        }
        .buttonStyle(.plain)
        .offset(y: -36)
        .padding(.bottom, -36)
    }

    private var planSubtitle: String {
        if policy.isAccessReducedByStatus {
            return "Access limited — resolve billing to restore your plan"
        }
        let limits = policy.limits
        return "\(limits.eventsText) · \(limits.guestsText)"
    }

    // MARK: - Profile

    private var profileSection: some View {
        VStack(spacing: 8) {
            AccountSectionHeader(title: "Profile")
            AccountCardGroup {
                NavigationLink {
                    EditProfileView(store: store)
                } label: {
                    AccountRowLabel(icon: "person.crop.circle",
                                    title: "Edit Profile",
                                    subtitle: displayName)
                }
                .buttonStyle(.plain)

                AccountRowDivider()

                AccountRowLabel(icon: "envelope",
                                title: "Email",
                                value: email,
                                showsChevron: false,
                                badge: emailBadge,
                                badgeTint: emailVerified ? .success : .warning)

                AccountRowDivider()

                AccountRowLabel(icon: "checkmark.shield",
                                title: "Sign-in method",
                                value: snapshot?.authUser.providerLabel ?? "—",
                                showsChevron: false)

                if let since = AccountDate.medium(snapshot?.createdDate) {
                    AccountRowDivider()
                    AccountRowLabel(icon: "calendar",
                                    title: "Member since",
                                    value: since,
                                    showsChevron: false)
                }
            }

            if let pending = snapshot?.authUser.pendingEmail {
                FeedbackBanner(kind: .info,
                               message: "Pending email change to \(pending). Check that inbox to confirm it.")
            }
        }
    }

    private var emailVerified: Bool { snapshot?.authUser.isEmailVerified ?? false }
    private var emailBadge: String? {
        guard snapshot != nil else { return nil }
        return emailVerified ? "Verified" : "Unverified"
    }

    // MARK: - Event management

    private var eventManagementSection: some View {
        VStack(spacing: 8) {
            AccountSectionHeader(title: "Event Management")
            AccountCardGroup {
                NavigationLink {
                    CollaboratorsView(supabase: supabase)
                } label: {
                    AccountRowLabel(icon: "person.2",
                                    title: "Collaborators",
                                    subtitle: "Manage who has access to your events.")
                }
                .buttonStyle(.plain)

                AccountRowDivider()

                NavigationLink {
                    GuestListExportView(store: store, policy: policy)
                } label: {
                    AccountRowLabel(icon: "square.and.arrow.up",
                                    title: "Export guest lists",
                                    subtitle: "Download an event's guest list as a spreadsheet.")
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Security

    private var securitySection: some View {
        VStack(spacing: 8) {
            AccountSectionHeader(title: "Security")
            AccountCardGroup {
                NavigationLink {
                    AccountSecurityView(store: store)
                } label: {
                    AccountRowLabel(icon: "lock.shield",
                                    title: "Security",
                                    subtitle: securitySubtitle)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var securitySubtitle: String {
        guard let user = snapshot?.authUser else { return "Password and sessions" }
        return user.isPasswordAccount ? "Change password, sign out everywhere" : "Signed in with \(user.providerLabel)"
    }

    // MARK: - Data & privacy

    private var dataPrivacySection: some View {
        VStack(spacing: 8) {
            AccountSectionHeader(title: "Data & Privacy")
            AccountCardGroup {
                NavigationLink {
                    AccountDataPrivacyView(store: store)
                } label: {
                    AccountRowLabel(icon: "hand.raised",
                                    title: "Data & Privacy",
                                    subtitle: "Export your data, privacy & terms.")
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Support & legal

    private var supportSection: some View {
        VStack(spacing: 8) {
            AccountSectionHeader(title: "Support & Legal")
            AccountCardGroup {
                AccountButtonRow(icon: "questionmark.circle", title: "Help & Support") {
                    openURL(AccountLinks.helpCenter)
                }
                AccountRowDivider()
                AccountButtonRow(icon: "envelope.open", title: "Contact Support") {
                    openURL(AccountLinks.supportEmail)
                }
                AccountRowDivider()
                AccountButtonRow(icon: "hand.raised.circle", title: "Privacy Policy") {
                    openURL(AccountLinks.privacyPolicy)
                }
                AccountRowDivider()
                AccountButtonRow(icon: "doc.text", title: "Terms of Service") {
                    openURL(AccountLinks.termsOfService)
                }
            }
        }
    }

    // MARK: - Sign out

    private var signOutSection: some View {
        AccountCardGroup {
            AccountButtonRow(icon: "rectangle.portrait.and.arrow.right",
                             title: "Log Out",
                             tint: Brand.danger,
                             showsChevron: false) {
                showingSignOutConfirm = true
            }
        }
    }

    // MARK: - Danger zone

    private var dangerZoneSection: some View {
        VStack(spacing: 8) {
            AccountSectionHeader(title: "Danger Zone")
            AccountCardGroup {
                NavigationLink {
                    DeleteAccountView(store: store)
                } label: {
                    AccountRowLabel(icon: "trash",
                                    title: "Delete Account",
                                    subtitle: "Permanently delete your account and data.",
                                    tint: Brand.danger)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Text("A Seat Awaits")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Brand.slate400)
            Text(Self.versionString)
                .font(.system(size: 12))
                .foregroundStyle(Brand.slate400)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(version) (\(build))"
    }
}
