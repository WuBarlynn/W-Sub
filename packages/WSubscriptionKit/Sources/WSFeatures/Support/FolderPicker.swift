#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 系统文件夹选择器。
///
/// 三个必须踩准的点，缺一个「打开」按钮就会点了没反应：
///
/// 1. Info.plist 里要同时有 `LSSupportsOpeningDocumentsInPlace` **和** `UIFileSharingEnabled`。
///    只有前者时选择器仍可能按「导入」语义工作 —— 而文件夹无法被复制进沙盒，系统就只回一个
///    空数组，甚至不回调。这两项光靠 `INFOPLIST_KEY_*` 构建设置写不进 plist，所以用了真实
///    的 `Config/Info.plist`。
/// 2. 必须 `asCopy: false`，否则同样是「复制」语义。
/// 3. 要给一个具体的 `directoryURL`。从默认的「最近项目」根进去时，部分 iOS 版本不会启用
///    「打开」按钮；落在真实目录上才稳定。
@MainActor
enum FolderPickerPresenter {
    enum Outcome {
        case picked(URL)
        case cancelled
        /// 选择器回调了，但没带回任何 URL。系统「准备项目」失败时就是这样。
        /// 不能当取消处理，否则用户点「打开」只会看到界面关掉、什么都没发生。
        case empty
    }

    private static var picker: UIDocumentPickerViewController?
    private static var coordinator: Coordinator?

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
