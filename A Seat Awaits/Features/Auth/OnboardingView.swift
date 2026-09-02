//
//  OnboardingView.swift
//  A Seat Awaits
//
//  Splash / welcome → account creation / sign-in, wired to live Supabase auth.
//  Mirrors design Section 01: hero splash with a glass logo tile and
//  "Get Started" / "Sign in", then the email form.
//

import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @State private var model: AuthViewModel?
    @State private var stage: Stage = .welcome
    @State private var showPassword = false
    @State private var showResetSheet = false

    enum Stage { case welcome, form, verify }
    private enum FormField { case fullName, email, password }
    @FocusState private var focusedField: FormField?

    var body: some View {
        Group {
            if let model {
                switch stage {
                case .welcome:
                    welcome(model: model)
                case .form:
                    formScreen(model: model)
                case .verify:
                    EmailVerificationView(model: model) {
                        model.needsEmailVerification = false
                        model.mode = .signIn
                        stage = .form
                    }
                }
            } else {
                ConfigErrorView(message: "Supabase client unavailable.")
            }
        }
        .onAppear {
            if model == nil, let supabase = appState.supabase {
                model = AuthViewModel(supabase: supabase) { user, sampleEventProvisioned in
                    appState.didAuthenticate(user, sampleEventProvisioned: sampleEventProvisioned)
                }
            }
        }
    }

    // MARK: - Splash / welcome

    private func welcome(model: AuthViewModel) -> some View {
        ZStack {
            HeroBackground()

            VStack(spacing: 0) {
                Spacer()

                // 96pt glass logo tile.
                Image("BrandChair")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 54, height: 54)
                    .frame(width: 96, height: 96)
                    .background(.white.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 25, x: 0, y: 20)

                Text("A Seat Awaits")
                    .scaledFont(size: 34, weight: .heavy)
                    .tracking(-0.6)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.top, 30)

                Text("Where every guest matters")
                    .scaledFont(size: 18, weight: .medium)
                    .foregroundStyle(Brand.lilac)
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)

                Text("Seating charts without the chaos. Import guests, build your floor plan, and seat everyone with confidence.")
                    .scaledFont(size: 15)
                    .lineSpacing(3)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                    .padding(.top, 20)

                Spacer()

                VStack(spacing: 0) {
                    Button("Get Started") {
                        model.mode = .signUp
                        stage = .form
                    }
                    .buttonStyle(.whiteHero)

                    Button("Sign in") {
                        model.mode = .signIn
                        stage = .form
                    }
                    .buttonStyle(.heroOutline)
                    .padding(.top, 12)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 44)
                .readableWidth(Layout.formWidth)
            }
        }
    }

    // MARK: - Auth form

    @ViewBuilder
    private func formScreen(model: AuthViewModel) -> some View {
        @Bindable var model = model
        let isSignUp = model.mode == .signUp

        NavigationStack {
            ScrollView {
                VStack(alignment: isSignUp ? .leading : .center, spacing: 0) {
                    // Heading block — left-aligned for sign-up, centered for sign-in.
                    if isSignUp {
                        logoChip(size: 56, radius: 15, icon: 30)
                        Text("Create your account")
                            .scaledFont(size: 30, weight: .bold)
                            .tracking(-0.6)
                            .foregroundStyle(Brand.textPrimary)
                            .padding(.top, 24)
                        Text("Start planning calmer seating in minutes.")
                            .scaledFont(size: 16)
                            .foregroundStyle(Brand.textSecondary)
                            .padding(.top, 8)
                    } else {
                        logoChip(size: 64, radius: 17, icon: 34, shadow: true)
                            .padding(.top, 46)
                        Text("Welcome back")
                            .scaledFont(size: 30, weight: .bold)
                            .tracking(-0.6)
                            .foregroundStyle(Brand.textPrimary)
                            .padding(.top, 24)
                        Text("Pick up right where you left off.")
                            .scaledFont(size: 16)
                            .foregroundStyle(Brand.textSecondary)
                            .padding(.top, 8)
                    }

                    // Fields
                    VStack(alignment: .leading, spacing: 16) {
                        if isSignUp {
                            LabeledField(title: "Full name",
                                         isFocused: focusedField == .fullName) {
                                TextField("", text: $model.fullName, prompt: Text("Brooke Fielding").foregroundStyle(Brand.slate400))
                                    .textContentType(.name)
                                    .focused($focusedField, equals: .fullName)
                                    .submitLabel(.next)
                                    .onSubmit { focusedField = .email }
                            }
                        }

                        LabeledField(title: "Email",
                                     isFocused: focusedField == .email) {
                            TextField("", text: $model.email, prompt: Text("Email").foregroundStyle(Brand.slate400))
                                .accessibilityLabel("Email")
                                .textContentType(.emailAddress)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .email)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .password }
                        }

                        passwordField(model: model, isSignUp: isSignUp)
                    }
                    .padding(.top, isSignUp ? 28 : 34)

                    // Status messages
                    if let info = model.infoMessage {
                        Label(info, systemImage: "checkmark.circle.fill")
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundStyle(Brand.successText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 14)
                    }
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundStyle(Brand.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 14)
                    }

                    // Primary CTA
                    Button {
                        focusedField = nil
                        Task {
                            await model.submit()
                            if model.needsEmailVerification { stage = .verify }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if model.isSubmitting { ProgressView().tint(.white) }
                            Text(isSignUp ? "Create Account" : "Sign In")
                        }
                    }
                    .buttonStyle(.primaryBrand)
                    .disabled(model.isSubmitting)
                    .padding(.top, 26)

                    if isSignUp {
                        legalFooter
                    }

                    // Footer link
                    HStack(spacing: 5) {
                        Text(isSignUp ? "Already have an account?" : "New here?")
                            .foregroundStyle(Brand.textSecondary)
                        Button(isSignUp ? "Sign in" : "Sign up") {
                            focusedField = nil
                            showPassword = false
                            model.toggleMode()
                        }
                        .fontWeight(.bold)
                        .foregroundStyle(Brand.accent)
                    }
                    .scaledFont(size: 15)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                }
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .readableWidth(Layout.formWidth)
            }
            .background(Brand.canvas)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        focusedField = nil
                        stage = .welcome
                    } label: {
                        Image(systemName: "chevron.left")
                            .scaledFont(size: 18, weight: .bold)
                            .foregroundStyle(Brand.accent)
                    }
                    .accessibilityLabel("Back")
                }
            }
            .sheet(isPresented: $showResetSheet) {
                RequestPasswordResetView(model: model) { showResetSheet = false }
            }
        }
    }

    // MARK: - Password field (with Show/Hide and optional "Forgot?")

    @ViewBuilder
    private func passwordField(model: AuthViewModel, isSignUp: Bool) -> some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 7) {
            // Label row — "Forgot?" sits on the right for sign-in.
            HStack {
                Text("Password")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(Brand.slate600)
                Spacer()
                if !isSignUp {
                    Button("Forgot?") {
                        focusedField = nil
                        model.prepareReset()
                        showResetSheet = true
                    }
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(Brand.accent)
                }
            }

            HStack(spacing: 12) {
                Group {
                    if showPassword {
                        TextField("", text: $model.password, prompt: Text("••••••••••").foregroundStyle(Brand.slate400))
                    } else {
                        SecureField("", text: $model.password, prompt: Text("••••••••••").foregroundStyle(Brand.slate400))
                    }
                }
                // The dot prompt is the field's only visible placeholder; give
                // VoiceOver a real name.
                .accessibilityLabel("Password")
                .scaledFont(size: 16)
                .foregroundStyle(Brand.textPrimary)
                .tint(Brand.plum)
                .textContentType(isSignUp ? .newPassword : .password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focusedField, equals: .password)
                .submitLabel(.go)
                .onSubmit {
                    focusedField = nil
                    Task {
                        await model.submit()
                        // Mirror the CTA button: a confirmation-required
                        // sign-up must advance to the verify stage here too,
                        // or keyboard-Go appears to do nothing.
                        if model.needsEmailVerification { stage = .verify }
                    }
                }

                Button(showPassword ? "Hide" : "Show") { showPassword.toggle() }
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(Brand.accent)
                    .accessibilityLabel(showPassword ? "Hide password" : "Show password")
            }
            .frame(height: 54)
            .padding(.horizontal, 16)
            .background(Brand.fieldFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(focusedField == .password ? Brand.plum : Brand.fieldBorder,
                                  lineWidth: 1.5)
            )
            .overlay(
                focusedField == .password
                    ? RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Brand.plum.opacity(0.08), lineWidth: 3)
                        .padding(-1.5)
                    : nil
            )
        }
    }

    // MARK: - Legal footer

    /// "Terms of Service" and "Privacy Policy" are real links (Markdown in
    /// `Text` routes taps through `openURL`), not decorative plain text.
    private var legalFooter: some View {
        let terms = AccountLinks.termsOfService.absoluteString
        let privacy = AccountLinks.privacyPolicy.absoluteString
        return Text(.init("By continuing you agree to our [Terms of Service](\(terms)) and [Privacy Policy](\(privacy))."))
            .scaledFont(size: 12)
            .lineSpacing(2)
            .foregroundStyle(Brand.textSecondary)
            .tint(Brand.accent)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
    }

    // MARK: - Building blocks

    private func logoChip(size: CGFloat, radius: CGFloat, icon: CGFloat, shadow: Bool = false) -> some View {
        Image("BrandChair")
            .resizable()
            .scaledToFit()
            .frame(width: icon, height: icon)
            .frame(width: size, height: size)
            .background(Brand.plum, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: shadow ? Brand.plum.opacity(0.55) : .clear,
                    radius: shadow ? 14 : 0, x: 0, y: shadow ? 12 : 0)
    }

}
