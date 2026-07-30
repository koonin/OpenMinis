import UIKit

/// The Share Extension's principal view controller.
class ShareViewController: UIViewController {

    /// Set to true once async processing + redirect is done, so viewDidAppear can dismiss.
    private var processingDone = false
    private var pendingFailure: (title: String, message: String)?
    private var failurePresented = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        NSLog("[ShareExt] viewDidLoad — starting processing")

        guard SharedContainerStore.isAppGroupAvailable else {
            NSLog("[ShareExt] App Group unavailable — sharing is disabled for this build")
            showFailure(
                title: "Sharing Unavailable",
                message: "This development build cannot access the shared storage used by Minis and its share extension. Use a build signed with App Group support."
            )
            return
        }

        Task { @MainActor in
            let vm = ShareViewModel()
            let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
            NSLog("[ShareExt] inputItems count: %d", items.count)
            await vm.processExtensionItems(items)
            let saved = vm.save()
            NSLog("[ShareExt] save() returned: %@", saved ? "true" : "false")
            guard saved else {
                showFailure(
                    title: "Couldn’t Share",
                    message: "Minis couldn’t prepare this content. Close the share sheet and try again."
                )
                return
            }

            // Verify what was saved
            if let pending = SharedContainerStore.loadPendingShare() {
                NSLog("[ShareExt] Verified pending share: %d items", pending.items.count)
                for (i, item) in pending.items.enumerated() {
                    NSLog("[ShareExt]   item[%d] kind=%@ value=%@", i, item.kind.rawValue, String(item.value.prefix(100)))
                }
            } else {
                NSLog("[ShareExt] WARNING: loadPendingShare returned nil after save!")
            }

            // Verify shared file directory
            if let dir = SharedContainerStore.sharedFileDirectory {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                NSLog("[ShareExt] Shared file dir: %@ — files: %@", dir.path, files.description)
            } else {
                NSLog("[ShareExt] WARNING: sharedFileDirectory is nil!")
            }

            // Verify sharedDefaults accessible
            if let defaults = SharedContainerStore.sharedDefaults {
                let hasKey = defaults.data(forKey: "pendingShare") != nil
                NSLog("[ShareExt] sharedDefaults accessible, pendingShare key present: %@", hasKey ? "YES" : "NO")
            } else {
                NSLog("[ShareExt] WARNING: sharedDefaults is nil — App Group not configured?")
            }

            redirectToHostApp()

            // Mark done and dismiss — if viewDidAppear already ran, dismiss now
            processingDone = true
            NSLog("[ShareExt] Processing done, completing request")
            extensionContext?.completeRequest(returningItems: [])
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if pendingFailure != nil {
            presentFailureIfNeeded()
            return
        }

        // Only dismiss if async processing is already done.
        // If not done yet, the Task completion above will dismiss.
        if processingDone {
            NSLog("[ShareExt] viewDidAppear — processingDone, completing request")
            extensionContext?.completeRequest(returningItems: [])
        } else {
            NSLog("[ShareExt] viewDidAppear — processing still in progress, deferring dismiss")
        }
    }

    // MARK: - Failure UI

    private func showFailure(title: String, message: String) {
        processingDone = false
        pendingFailure = (title, message)
        view.backgroundColor = .systemBackground
        presentFailureIfNeeded()
    }

    private func presentFailureIfNeeded() {
        guard viewIfLoaded?.window != nil,
              !failurePresented,
              presentedViewController == nil,
              let failure = pendingFailure else { return }

        failurePresented = true
        let alert = UIAlertController(
            title: failure.title,
            message: failure.message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Close", style: .default) { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: [])
        })
        present(alert, animated: true)
    }

    // MARK: - Redirect to main app

    private func redirectToHostApp() {
        guard let url = URL(string: "minis://share") else {
            NSLog("[ShareExt] ERROR: Failed to create minis://share URL")
            return
        }

        let selectorOpenURL = sel_registerName("openURL:")
        var responder: UIResponder? = self
        var found = false
        while responder != nil {
            if let application = responder as? UIApplication {
                NSLog("[ShareExt] Found UIApplication in responder chain, opening URL")
                if #available(iOS 18.0, *) {
                    application.open(url, options: [:], completionHandler: nil)
                } else {
                    application.perform(selectorOpenURL, with: url)
                }
                found = true
                break
            }
            responder = responder?.next
        }
        if !found {
            NSLog("[ShareExt] WARNING: UIApplication not found in responder chain!")
        }
    }
}
