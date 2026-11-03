#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import WSDesignSystem
import WSCore
import WSCrypto
import WSVault

public struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel

    @State private var step = 0
    @State private var recoveryCode: String?
    @State private var isWorking = false
    @State private var localError: String?
    @State private var showImport = false
    @State private var importPassphrase = ""
    @State private var importError: String?

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
                        default: storageStep
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
                Task { await model.importVault(from: url, passphrase: importPassphrase) }
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

    /// 数据说明 + 建库 + 导入。数据加密存在 App 内部，无需密码即可打开（密钥在钥匙串里）。
    private var storageStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("开始使用")
                .font(.system(size: 28, weight: .semibold))

            SurfaceCard {
                HStack(spacing: 12) {
                    Image(systemName: "lock.square.stack.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(WSTheme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("数据加密保存在 App 内部")
                            .font(.system(size: 15, weight: .medium))
                        Text("无需密码即可打开，随时可导出加密备份")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            // 导入旧库：需要输入那份备份的密码
            VStack(alignment: .leading, spacing: 10) {
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
                            Text("选择 .vault 备份，并输入它的密码")
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

                SecureField("备份的密码", text: $importPassphrase)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(size: 15))
                    .padding(12)
                    .background(Color.wsCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.wsHairline, lineWidth: 0.5)
                    }

                if let importError {
                    InlineNotice(importError)
                }
            }
        }
        .padding(.top, 24)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            switch step {
            case 0:
                primary("开始") { advance() }
            default:
                primary(isWorking ? "创建中…" : "创建并开始使用") {
                    Task { await create() }
                }
            }
        }
        .padding(.horizontal, WSTheme.pagePadding)
        .padding(.bottom, 10)
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

    /// 建库：用随机高熵密码做信封（用户无需知道），主密钥存钥匙串，启动静默解锁。
    private func create() async {
        isWorking = true
        localError = nil
        defer { isWorking = false }
        do {
            // 随机 32 字节口令，转 base64；用户不接触它，信封仍强加密
            let random = try SecureBytes.random(count: 32)
            let passphrase = Data(random.bytes).base64EncodedString()
            recoveryCode = try await model.createVault(passphrase: passphrase, enableBiometry: false)
            // 建库后直接进入主界面（createVault 内部已把 MK 存钥匙串、snapshot 就位）
            model.completeOnboarding()
        } catch {
            localError = AppModel.describe(error)
        }
    }
}
#endif
