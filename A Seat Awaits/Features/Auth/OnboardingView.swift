//
//  OnboardingView.swift
//  A Seat Awaits
//
//  Splash / welcome → account creation / sign-in, wired to live Supabase auth.
//  Mirrors design Section 01: hero splash with a glass logo tile and
//  "Start for free" / "Log in", then the email form with "Continue with Apple".
//

import SwiftUI
import AuthenticationServices

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
                model = AuthViewModel(supabase: supabase) { user in
                    appState.didAuthenticate(user)
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
                    .font(.system(size: 34, weight: .heavy))
                    .tracking(-0.6)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.top, 30)

                Text("Where every guest matters")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Brand.lilac)
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)

                Text("Seating charts without the chaos. Import guests, build your floor plan, and seat everyone with confidence.")
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                    .padding(.top, 20)

                Spacer()

                VStack(spacing: 0) {
                    Button("Start for free") {
                        model.mode = .signUp
                        stage = .form
                    }
                    .buttonStyle(.whiteHero)

                    Button("Log in") {
                        model.mode = .signIn
                        stage = .form
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                    )
                    .padding(.top, 12)

                    Text("14-day free trial")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.top, 18)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 44)
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
                    // Heading block — left-aligned for sign-up, centered for log-in.
                    if isSignUp {
                        logoChip(size: 56, radius: 15, icon: 30)
                        Text("Create your account")
                            .font(.system(size: 30, weight: .bold))
                            .tracking(-0.6)
                            .foregroundStyle(Brand.textPrimary)
                            .padding(.top, 24)
                        Text("Start planning calmer seating in minutes.")
                            .font(.system(size: 16))
                            .foregroundStyle(Brand.textSecondary)
                            .padding(.top, 8)
                    } else {
                        logoChip(size: 64, radius: 17, icon: 34, shadow: true)
                            .padding(.top, 46)
                        Text("Welcome back")
                            .font(.system(size: 30, weight: .bold))
                            .tracking(-0.6)
                            .foregroundStyle(Brand.textPrimary)
                            .padding(.top, 24)
                        Text("Pick up right where you left off.")
                            .font(.system(size: 16))
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
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Brand.successText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 14)
                    }
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 13, weight: .medium))
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
                            Text(isSignUp ? "Start for free" : "Log in")
                        }
                    }
                    .buttonStyle(.primaryBrand)
                    .disabled(!model.canSubmit)
                    .padding(.top, 26)

                    if isSignUp {
                        Text("By continuing you agree to our Terms & Privacy Policy.")
                            .font(.system(size: 12))
                            .lineSpacing(2)
                            .foregroundStyle(Brand.slate400)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 14)
                    }

                    // "or" divider
                    dividerOr
                        .padding(.vertical, 22)

                    // Apple — white/outlined per spec.
                    SignInWithAppleButton(.continue) { request in
                        model.configureAppleRequest(request)
                    } onCompletion: { result in
                        Task { await model.handleAppleCompletion(result) }
                    }
                    .signInWithAppleButtonStyle(.whiteOutline)
                    .frame(height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Brand.fieldBorder, lineWidth: 1.5)
                    )

                    // Footer link
                    HStack(spacing: 5) {
                        Text(isSignUp ? "Already have an account?" : "New here?")
                            .foregroundStyle(Brand.textSecondary)
                        Button(isSignUp ? "Log in" : "Start for free") {
                            focusedField = nil
                            showPassword = false
                            model.toggleMode()
                        }
                        .fontWeight(.bold)
                        .foregroundStyle(Brand.accent)
                    }
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                }
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 24)
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
                            .font(.system(size: 18, weight: .bold))
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
            // Label row — "Forgot?" sits on the right for log-in.
            HStack {
                Text("Password")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.slate600)
                Spacer()
                if !isSignUp {
                    Button("Forgot?") {
                        focusedField = nil
                        model.prepareReset()
                        showResetSheet = true
                    }
                    .font(.system(size: 13, weight: .semibold))
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
                .font(.system(size: 16))
                .foregroundStyle(Brand.textPrimary)
                .tint(Brand.plum)
                .textContentType(isSignUp ? .newPassword : .password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focusedField, equals: .password)
                .submitLabel(.go)
                .onSubmit {
                    focusedField = nil
                    Task { await model.submit() }
                }

                Button(showPassword ? "Hide" : "Show") { showPassword.toggle() }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.accent)
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

    private var dividerOr: some View {
        HStack(spacing: 14) {
            Rectangle().fill(Brand.separator).frame(height: 1)
            Text("or")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Brand.slate400)
            Rectangle().fill(Brand.separator).frame(height: 1)
        }
    }
}
