#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import WSDesignSystem
import WSCore
import WSVault

public struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel

    @State private var step = 0
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var useBiometry = true
    @State private var recoveryCode: String?
    @State private var acknowledged = false
    @State private var isWorking = false
    @State private var localError: String?
    @State private var showImport = false

    /// .vault 文件类型：动态 UTType，按扩展名匹配
    private static let vaultType: [UTType] = {
        [UTType(filenameExtension: "vault") ?? .data]
    }()

    public init() {}

    public var body: some View {
        Screen {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch step {
                        case 0: welcome
                        case 1: storageStep
                        case 2: passphraseStep
                        default: recoveryStep
                        }
                        if let message = localError ?? model.flowError {
                            InlineNotice(message)
                        }
                    }
                    .padding(.horizontal, WSTheme.pagePadding)
                    .padding(.top, 40)
                }
                footer
            }
        }
        .fileImporter(isPresented: $showImport,
                      allowedContentTypes: Self.vaultType,
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await model.importVault(from: url) }
            case .failure(let error):
                localError = error.localizedDescription
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 26) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(WSTheme.accent)
            Text("W Sub")
                .font(.system(size: 34, weight: .semibold))
            Text("本地加密的订阅台账")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 60)
    }

    /// 数据保存说明。不再选文件夹：主存储固定在 App 内部，随时可导出加密备份。
    private var storageStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("数据保存")
                .font(.system(size: 28, weight: .semibold))

            SurfaceCard {
                HStack(spacing: 12) {
                    Image(systemName: "lock.square.stack.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(WSTheme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("加密后保存在 App 内部")
                            .font(.system(size: 15, weight: .medium))
                        Text("可在设置中随时导出加密备份")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            Button {
                showImport = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 20))
                        .foregroundStyle(WSTheme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("打开之前的库")
                            .font(.system(size: 15, weight: .medium))
                        Text("选择之前导出的 .vault 备份")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .padding(14)
            .background(Color.wsCard, in: RoundedRectangle(cornerRadius: WSTheme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: WSTheme.cardRadius, style: .continuous)
                    .strokeBorder(Color.wsHairline, lineWidth: 0.5)
            }
        }
        .padding(.top, 24)
    }

    private var passphraseStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置密码")
                .font(.system(size: 28, weight: .semibold))

            SurfaceCard(padding: 14) {
                VStack(spacing: 12) {
                    SecureField("至少 8 位", text: $passphrase)
                        .textContentType(.newPassword)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(size: 16))
                    WSRowDivider()
                    SecureField("再输入一次", text: $confirm)
                        .textContentType(.newPassword)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(size: 16))
                }
            }

            if model.biometryKind != .none {
                SurfaceCard(padding: 14) {
                    Toggle("同时启用 \(model.biometryKind.displayName)", isOn: $useBiometry)
                        .font(.system(size: 15))
                }
            }
        }
        .padding(.top, 24)
    }

    private var recoveryStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("保存恢复码")
                .font(.system(size: 28, weight: .semibold))

            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(recoveryCode ?? "—")
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .lineSpacing(7)
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = recoveryCode
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            SurfaceCard(padding: 14) {
                Toggle("我已保存", isOn: $acknowledged)
                    .font(.system(size: 15))
            }
        }
        .padding(.top, 24)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            switch step {
            case 0:
                primary("开始") { advance() }
            case 1:
                primary("下一步") { advance() }
            case 2:
                primary(isWorking ? "创建中…" : "创建", enabled: canCreate) {
                    Task { await create() }
                }
            default:
                primary("完成", enabled: acknowledged) {
                    model.clearMessages()
                    model.completeOnboarding()
                }
            }
        }
        .padding(.horizontal, WSTheme.pagePadding)
        .padding(.bottom, 10)
    }

    private var canCreate: Bool {
        passphrase.count >= 8 && passphrase == confirm && !isWorking
    }

    private func primary(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isWorking || model.isBusy {
                    ProgressView().controlSize(.small).tint(.white)
                }
                Text(title).font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .disabled(!enabled)
    }

    private func advance() {
        localError = nil
        model.clearMessages()
        withAnimation(.easeInOut(duration: 0.2)) { step += 1 }
    }

    private func create() async {
        isWorking = true
        localError = nil
        defer { isWorking = false }
        do {
            recoveryCode = try await model.createVault(passphrase: passphrase,
                                                       enableBiometry: useBiometry)
            withAnimation(.easeInOut(duration: 0.2)) { step = 3 }
        } catch {
            localError = AppModel.describe(error)
        }
    }
}
#endif
