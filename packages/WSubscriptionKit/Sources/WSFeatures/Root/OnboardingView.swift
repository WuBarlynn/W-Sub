#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import WSDesignSystem
import WSCore
import WSVault

public struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel

    @State private var step = 0
    @State private var directory: URL?
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var useBiometry = true
    @State private var recoveryCode: String?
    @State private var acknowledged = false
    @State private var isWorking = false
    @State private var localError: String?
    @State private var showLocationOptions = false

    public init() {}

    public var body: some View {
        Screen {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch step {
                        case 0: welcome
                        case 1: folderStep
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
        .confirmationDialog("数据保存在哪里", isPresented: $showLocationOptions, titleVisibility: .visible) {
            Button("用 App 自己的文件夹") { useAppFolder() }
            Button("存到「文件」…") { saveToFiles() }
            Button("直接选文件夹") { presentPicker() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("App 文件夹最稳，在「文件 > 我的 iPhone > W Sub」里可见；存到「文件」可以选 iCloud 云盘。")
        }
        .task {
            #if DEBUG
            // 调试用：-ws-picker 直接打开文件夹选择器，方便在没有 UI 自动化时验证授权流程
            if ProcessInfo.processInfo.arguments.contains("-ws-picker") {
                step = 1
                try? await Task.sleep(for: .seconds(1))
                presentPicker()
            }
            #endif
        }
    }

    private func presentPicker() {
        FolderPickerPresenter.present { handle($0) }
    }

    /// 走「存储到文件」面板：系统保证目标可写，落盘 URL 的父目录就是用户选的目录。
    private func saveToFiles() {
        FolderPickerPresenter.saveToFiles(fileName: "WSubscription.vault") { handle($0, verify: false) }
    }

    /// 零授权：直接落在 App 自己的 Documents 里，文件 App 里能看到（Info.plist 开了文件共享）。
    private func useAppFolder() {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        accept(folder)
    }

    private func handle(_ outcome: FolderPickerPresenter.Outcome, verify: Bool = true) {
        switch outcome {
        case .picked(let url):
            accept(url, verify: verify)
        case .empty:
            localError = "系统没能读取这个位置，换一种方式试试"
        case .cancelled:
            break
        }
    }

    /// 选完立刻验证一次：目录 + 可写。iCloud 里只读的共享文件夹到这里就会被挡住，
    /// 不会等到「创建」按钮按下去才失败。
    private func accept(_ url: URL, verify: Bool = true) {
        localError = nil
        do {
            if verify {
                let access = FolderAccess(url: url, mode: .securityScoped)
                try access.verifyWritable()
            }
            directory = url
            model.clearMessages()
            withAnimation(.easeInOut(duration: 0.2)) { step = 2 }
        } catch {
            localError = AppModel.describe(error)
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

    private var folderStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择文件夹")
                .font(.system(size: 28, weight: .semibold))

            SurfaceCard {
                HStack(spacing: 12) {
                    Image(systemName: directory == nil ? "folder" : "folder.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(directory == nil ? Color.secondary : WSTheme.accent)
                    Text(directory?.lastPathComponent ?? "未选择")
                        .font(.system(size: 15, weight: .medium))
                    Spacer()
                }
            }

            Text("数据是一个加密文件，放进你选的文件夹。选不了位置时用「App 自己的文件夹」即可，之后在「文件」里能移动它。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                primary(directory == nil ? "选择保存位置" : "下一步", enabled: true) {
                    if directory == nil { showLocationOptions = true } else { advance() }
                }
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

            if step == 1, directory != nil {
                Button("重新选择") { presentPicker() }
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
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
        guard let directory else {
            localError = "请先选择文件夹"
            return
        }
        isWorking = true
        localError = nil
        defer { isWorking = false }
        do {
            recoveryCode = try await model.createVault(directory: directory,
                                                       passphrase: passphrase,
                                                       enableBiometry: useBiometry)
            withAnimation(.easeInOut(duration: 0.2)) { step = 3 }
        } catch {
            localError = AppModel.describe(error)
        }
    }
}
#endif
