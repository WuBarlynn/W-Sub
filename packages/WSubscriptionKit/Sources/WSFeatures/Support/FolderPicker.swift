#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 系统文件夹选择器。
///
/// 两个必须踩准的点：
///
/// 1. **不能用 SwiftUI 的 `.fileImporter`**：它默认按「导入」语义工作（把选中的项目复制进
///    App 的 Inbox）。文件夹没有「复制一份」这种语义，于是 iCloud 云盘里真实存在的目录会被
///    系统画成不可选。这里显式 `asCopy: false` 走「就地打开」，配合 Info.plist 里的
///    `LSSupportsOpeningDocumentsInPlace = YES`，iCloud 目录才能被选中。
/// 2. **不要塞进 SwiftUI 的 `.sheet`**：那样得到的是一个被包了一层的页面，顶部没有
///    「打开」按钮，用户只能一路往里钻，选不了当前这一层。直接从窗口最上层的控制器弹出，
///    才是系统原生的全屏选择器。
@MainActor
enum FolderPickerPresenter {
    private static var picker: UIDocumentPickerViewController?
    private static var coordinator: Coordinator?

    static func present(onPick: @escaping (URL) -> Void,
                        onCancel: @escaping () -> Void) {
        guard let host = topViewController() else {
            onCancel()
            return
        }

        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.folder],
                                                        asCopy: false)
        controller.allowsMultipleSelection = false

        let coordinator = Coordinator { url in
            finish()
            onPick(url)
        } onCancel: {
            finish()
            onCancel()
        }
        controller.delegate = coordinator

        // 选择器和它的 delegate 都要有人持有，否则弹出后立刻被释放。
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
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        var controller = scene?.keyWindow?.rootViewController
            ?? scene?.windows.first?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }

    private final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                onCancel()
                return
            }
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
#endif
