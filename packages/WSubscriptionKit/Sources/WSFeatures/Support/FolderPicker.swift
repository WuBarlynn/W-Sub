#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 选择保存位置的三条路，都不需要用户理解「security-scoped bookmark」。
///
/// 背景（Apple DTS 在开发者论坛的回复）：iOS 26 的文件选择器**只对可写目录启用「打开」**，
/// 不可写的目录按钮是灰的或点了没反应。再叠加侧载签名带来的沙盒差异，直接用
/// `UIDocumentPickerViewController(forOpeningContentTypes: [.folder])` 选目录在真机上很容易失败。
/// 所以这里除了「选文件夹」，还提供了两条不依赖目录选择的路径：
///
/// - `saveToFiles`：走「存储到文件」导出面板，用户选一个目标文件夹，系统把占位文件写进去，
///   我们拿到落盘 URL 后取它的父目录。这是系统自己保证可写的路径。
/// - `appFolder`：直接用 App 自己的 Documents（Info.plist 里开了 `UIFileSharingEnabled`，
///   在「文件」App 的「我的 iPhone > W Sub」里可见）。永远可写，零授权。
@MainActor
enum FolderPickerPresenter {
    enum Outcome {
        case picked(URL)
        case cancelled
        /// 选择器回调了，但没带回任何 URL。系统「准备项目」失败时就是这样。
        case empty
    }

    private static var picker: UIDocumentPickerViewController?
    private static var coordinator: Coordinator?
    private static var temporaryFile: URL?

    // MARK: - 打开目录（尽力而为）

    static func present(_ onOutcome: @escaping (Outcome) -> Void) {
        guard let host = topViewController() else {
            onOutcome(.cancelled)
            return
        }

        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.folder],
                                                        asCopy: false)
        controller.allowsMultipleSelection = false
        controller.shouldShowFileExtensions = false
        controller.directoryURL = FileManager.default.urls(for: .documentDirectory,
                                                           in: .userDomainMask).first

        attach(controller, to: host, onOutcome: onOutcome)
    }

    // MARK: - 存储到文件（系统保证可写）

    /// 先写一个同名占位文件，用「存储到文件」面板让用户挑目标文件夹；
    /// 系统把文件写进去之后回调落盘 URL，父目录就是用户选的目录。
    static func saveToFiles(fileName: String, onOutcome: @escaping (Outcome) -> Void) {
        guard let host = topViewController() else {
            onOutcome(.cancelled)
            return
        }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName, isDirectory: false)
        // 非空占位，避免个别文件提供者拒绝 0 字节文件
        do {
            try Data([0x0]).write(to: temporary, options: .atomic)
        } catch {
            onOutcome(.empty)
            return
        }
        temporaryFile = temporary

        let controller = UIDocumentPickerViewController(forExporting: [temporary], asCopy: true)
        attach(controller, to: host) { outcome in
            defer { cleanUpTemporary() }
            switch outcome {
            case .picked(let url):
                onOutcome(.picked(url.deletingLastPathComponent()))
            default:
                onOutcome(outcome)
            }
        }
    }

    private static func cleanUpTemporary() {
        if let temporaryFile {
            try? FileManager.default.removeItem(at: temporaryFile)
        }
        temporaryFile = nil
    }

    // MARK: - 公共装配

    private static func attach(_ controller: UIDocumentPickerViewController,
                               to host: UIViewController,
                               onOutcome: @escaping (Outcome) -> Void) {
        controller.allowsMultipleSelection = false

        let coordinator = Coordinator { outcome in
            finish()
            onOutcome(outcome)
        }
        controller.delegate = coordinator

        // 选择器和 delegate 都要有人持有：delegate 是 weak，弹出后没人持有就收不到回调。
        picker = controller
        self.coordinator = coordinator
        host.present(controller, animated: true)
    }

    private static func finish() {
        picker?.presentingViewController?.dismiss(animated: true)
        picker = nil
        coordinator = nil
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first

        var controller = scene?.keyWindow?.rootViewController
            ?? scene?.windows.first?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }

    private final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onOutcome: (Outcome) -> Void

        init(onOutcome: @escaping (Outcome) -> Void) {
            self.onOutcome = onOutcome
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                onOutcome(.empty)
                return
            }
            onOutcome(.picked(url))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onOutcome(.cancelled)
        }
    }
}
#endif
