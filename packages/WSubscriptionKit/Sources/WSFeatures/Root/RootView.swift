#if os(iOS)
import SwiftUI
import WSDesignSystem
import WSCore

public struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        ZStack {
            switch model.phase {
            case .launching:
                SplashView()
            case .onboarding:
                OnboardingView()
            case .locked:
                LockScreenView()
            case .ready:
                MainShellView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.phase)
        .tint(WSTheme.accent)
        .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
        .preferredColorScheme(model.appearance.colorScheme)
        .task { await model.bootstrap() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.handleBackground()
            case .active: model.handleActive()
            default: break
            }
        }
    }
}

struct SplashView: View {
    var body: some View {
        Screen {
            VStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(WSTheme.accent)
                Text("W Sub")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 锁屏

public struct LockScreenView: View {
    @EnvironmentObject private var model: AppModel

    @State private var passphrase = ""
    @State private var showRecovery = false
    @State private var shakeCount: CGFloat = 0
    @State private var didAutoPrompt = false
    @FocusState private var focused: Bool

    public init() {}

    private var biometrySymbol: String {
        switch model.biometryKind {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "faceid"
        }
    }

    private var canSubmit: Bool {
        !passphrase.isEmpty && !model.isBusy && !model.isLockedOut
    }

    public var body: some View {
        Screen {
            VStack(spacing: 0) {
                Spacer(minLength: 24)

                VStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(WSTheme.accent)
                        .frame(width: 72, height: 72)
                        .background(WSTheme.accent.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    Text("W Sub")
                        .font(.system(size: 22, weight: .semibold))
                    Text(model.folderName.isEmpty ? "本地加密的订阅台账" : model.folderName)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                SurfaceCard(padding: 14) {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                            SecureField("密码", text: $passphrase)
                                .textContentType(nil)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .focused($focused)
                                .font(.system(size: 16))
                                .submitLabel(.go)
                                .onSubmit { submit() }
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 46)
                        .background(Color.primary.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Button(action: submit) {
                            HStack(spacing: 6) {
                                if model.isBusy { ProgressView().controlSize(.small).tint(.white) }
                                Text(model.isBusy ? "正在解锁…" : "解锁")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(canSubmit ? Color.white : Color.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(canSubmit ? WSTheme.accent : Color.primary.opacity(0.06))
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSubmit)
                    }
                }
                .modifier(ShakeEffect(animatableData: shakeCount))
                .padding(.top, 22)

                if model.biometryRegistered, model.biometryKind != .none {
                    Button {
                        Task { await model.unlockWithBiometry() }
                    } label: {
                        Label("用 \(model.biometryKind.displayName) 解锁", systemImage: biometrySymbol)
                            .font(.system(size: 15, weight: .medium))
                            .padding(.horizontal, 20)
                            .frame(height: 46)
                    }
                    .buttonStyle(.plain)
                    .wsGlassCapsule(interactive: true)
                    .disabled(model.isBusy)
                    .padding(.top, 12)
                }

                if let error = model.flowError {
                    InlineNotice(error).padding(.top, 12)
                }

                if model.isLockedOut, let until = model.lockoutUntil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, Int(until.timeIntervalSince(context.date).rounded(.up)))
                        Text("尝试次数过多，请等待 \(remaining) 秒")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.top, 10)
                    }
                }

                Spacer(minLength: 16)

                Button("用恢复码解锁") { showRecovery = true }
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 10)
            }
            .padding(.horizontal, 24)
        }
        .onAppear {
            model.clearMessages()
            if model.biometryRegistered, !didAutoPrompt {
                didAutoPrompt = true
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    await model.unlockWithBiometry()
                }
            }
        }
        .onChange(of: model.failedAttempts) { _, _ in
            withAnimation(.easeInOut(duration: 0.45)) { shakeCount += 1 }
            passphrase = ""
            focused = true
        }
        .sheet(isPresented: $showRecovery) {
            RecoveryUnlockSheet().presentationDetents([.medium])
        }
    }

    private func submit() {
        guard canSubmit else { return }
        focused = false
        let value = passphrase
        Task { await model.unlock(passphrase: value) }
    }
}

struct RecoveryUnlockSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("输入建库时保存的 24 位恢复码，分隔符和大小写都不影响。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                TextField("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", text: $code, axis: .vertical)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(size: 15, design: .monospaced))
                    .padding(12)
                    .background(Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                if let error = model.flowError {
                    InlineNotice(error)
                }

                Button {
                    Task {
                        await model.unlockWithRecoveryKey(code)
                        if model.phase == .ready { dismiss() }
                    }
                } label: {
                    Text("解锁").frame(maxWidth: .infinity).frame(height: 46)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 12))
                .disabled(code.count < 20 || model.isBusy)

                Spacer()
            }
            .padding(20)
            .navigationTitle("恢复码解锁")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
#endif
