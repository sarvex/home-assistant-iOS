import CallbackURLKit
import Foundation
import PromiseKit
import SafariServices
import Shared

class IncomingURLHandler {
    let windowController: WebViewWindowController
    init(windowController: WebViewWindowController) {
        self.windowController = windowController
        registerCallbackURLKitHandlers()
    }

    @discardableResult
    func handle(url: URL) -> Bool {
        Current.Log.verbose("Received URL: \(url)")
        var serviceData: [String: String] = [:]
        if let queryItems = url.queryItems {
            serviceData = queryItems
        }
        guard let host = url.host else { return true }
        switch host.lowercased() {
        case "x-callback-url":
            return Manager.shared.handleOpen(url: url)
        case "call_service":
            callServiceURLHandler(url, serviceData)
        case "fire_event":
            fireEventURLHandler(url, serviceData)
        case "send_location":
            sendLocationURLHandler()
        case "perform_action":
            performActionURLHandler(url, serviceData: serviceData)
        case "navigate": // homeassistant://navigate/lovelace/dashboard
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return false
            }

            components.scheme = nil
            components.host = nil

            let isFromWidget = components.popWidgetAuthenticity()

            guard let rawURL = components.url?.absoluteString else {
                return false
            }

            let wasPresentingSafari: Bool

            if let presenting = windowController.presentedViewController,
               presenting is SFSafariViewController {
                // Dismiss my.* controller if it's on top - we don't get any other indication
                presenting.dismiss(animated: true, completion: nil)

                wasPresentingSafari = true
            } else {
                wasPresentingSafari = false
            }

            windowController.open(
                from: .deeplink,
                urlString: rawURL,
                skipConfirm: wasPresentingSafari || isFromWidget
            )
        default:
            Current.Log.warning("Can't route incoming URL: \(url)")
            showAlert(title: L10n.errorLabel, message: L10n.UrlHandler.NoService.message(url.host!))
        }
        return true
    }

    @discardableResult
    func handle(userActivity: NSUserActivity) -> Bool {
        Current.Log.info(userActivity)

        switch Current.tags.handle(userActivity: userActivity) {
        case let .handled(type):
            let (icon, text) = { () -> (MaterialDesignIcons, String) in
                switch type {
                case .nfc:
                    return (.nfcVariantIcon, L10n.Nfc.tagRead)
                case .generic:
                    return (.qrcodeIcon, L10n.Nfc.genericTagRead)
                }
            }()

            Current.sceneManager.showFullScreenConfirm(
                icon: icon,
                text: text,
                onto: .value(windowController.window)
            )
            return true
        case let .open(url):
            // NFC-based URL
            return handle(url: url)
        case .unhandled:
            // not a tag
            if let url = userActivity.webpageURL, url.host?.lowercased() == "my.home-assistant.io" {
                return showMy(for: url)
            } else if let interaction = userActivity.interaction {
                if #available(iOS 13, *) {
                    if let intent = interaction.intent as? OpenPageIntent,
                       let panel = intent.page, let path = panel.identifier {
                        Current.Log.info("launching from shortcuts with panel \(panel)")

                        windowController.open(from: .deeplink, urlString: "/" + path, skipConfirm: true)
                        return true
                    }
                }

                return false
            } else {
                return false
            }
        }
    }

    func handle(shortcutItem: UIApplicationShortcutItem) -> Promise<Void> {
        Current.backgroundTask(withName: "shortcut-item") { remaining -> Promise<Void> in
            Current.api.then(on: nil) { api -> Promise<Void> in
                if shortcutItem.type == "sendLocation" {
                    return api.GetAndSendLocation(trigger: .AppShortcut, maximumBackgroundTime: remaining)
                } else {
                    return api.HandleAction(actionID: shortcutItem.type, source: .AppShortcut)
                }
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(
            title: title,
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.okLabel, style: .default, handler: nil))
        windowController.webViewControllerPromise.done {
            $0.present(alert, animated: true, completion: nil)
        }
    }

    private func showMy(for url: URL) -> Bool {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            Current.Log.info("couldn't create url components out of \(url)")
            return false
        }

        var queryItems = components.queryItems ?? []
        queryItems.append(.init(name: "mobile", value: "1"))
        components.queryItems = queryItems

        guard let updatedURL = components.url else {
            return false
        }

        // not animated in because it looks weird during the app launch animation
        windowController.present(SFSafariViewController(url: updatedURL), animated: false, completion: nil)

        return true
    }
}

extension IncomingURLHandler {
    enum XCallbackError: FailureCallbackError {
        case generalError
        case eventNameMissing
        case serviceMissing
        case templateMissing

        var code: Int {
            switch self {
            case .generalError:
                return 0
            case .eventNameMissing:
                return 1
            case .serviceMissing:
                return 2
            case .templateMissing:
                return 2
            }
        }

        var message: String {
            switch self {
            case .generalError:
                return L10n.UrlHandler.XCallbackUrl.Error.general
            case .eventNameMissing:
                return L10n.UrlHandler.XCallbackUrl.Error.eventNameMissing
            case .serviceMissing:
                return L10n.UrlHandler.XCallbackUrl.Error.serviceMissing
            case .templateMissing:
                return L10n.UrlHandler.XCallbackUrl.Error.templateMissing
            }
        }
    }

    private func registerCallbackURLKitHandlers() {
        Manager.shared.callbackURLScheme = Manager.urlSchemes?.first

        Manager.shared["fire_event"] = { parameters, success, failure, _ in
            guard let eventName = parameters["eventName"] else {
                failure(XCallbackError.eventNameMissing)
                return
            }

            var cleanParamters = parameters
            cleanParamters.removeValue(forKey: "eventName")
            let eventData = cleanParamters

            Current.api.then(on: nil) { api in
                api.CreateEvent(eventType: eventName, eventData: eventData)
            }.done { _ in
                success(nil)
            }.catch { error -> Void in
                Current.Log.error("Received error from createEvent during X-Callback-URL call: \(error)")
                failure(XCallbackError.generalError)
            }
        }

        Manager.shared["call_service"] = { parameters, success, failure, _ in
            guard let service = parameters["service"] else {
                failure(XCallbackError.serviceMissing)
                return
            }

            let splitService = service.components(separatedBy: ".")
            let serviceDomain = splitService[0]
            let serviceName = splitService[1]

            var cleanParamters = parameters
            cleanParamters.removeValue(forKey: "service")
            let serviceData = cleanParamters

            Current.api.then(on: nil) { api in
                api.CallService(domain: serviceDomain, service: serviceName, serviceData: serviceData)
            }.done { _ in
                success(nil)
            }.catch { error in
                Current.Log.error("Received error from callService during X-Callback-URL call: \(error)")
                failure(XCallbackError.generalError)
            }
        }

        Manager.shared["send_location"] = { _, success, failure, _ in
            Current.api.then(on: nil) { api in
                api.GetAndSendLocation(trigger: .XCallbackURL)
            }.done { _ in
                success(nil)
            }.catch { error in
                Current.Log.error("Received error from getAndSendLocation during X-Callback-URL call: \(error)")
                failure(XCallbackError.generalError)
            }
        }

        Manager.shared["render_template"] = { parameters, success, failure, _ in
            guard let template = parameters["template"] else {
                failure(XCallbackError.templateMissing)
                return
            }

            var cleanParamters = parameters
            cleanParamters.removeValue(forKey: "template")
            let variablesDict = cleanParamters

            Current.apiConnection?.subscribe(
                to: .renderTemplate(template, variables: variablesDict),
                initiated: { result in
                    if case let .failure(error) = result {
                        Current.Log.error("Received error from RenderTemplate during X-Callback-URL call: \(error)")
                        failure(XCallbackError.generalError)
                    }
                }, handler: { token, data in
                    token.cancel()
                    success(["rendered": String(describing: data.result)])
                }
            )
        }
    }

    private func fireEventURLHandler(_ url: URL, _ serviceData: [String: String]) {
        // homeassistant://fire_event/custom_event?entity_id=device_tracker.entity

        Current.api.then(on: nil) { api in
            api.CreateEvent(eventType: url.pathComponents[1], eventData: serviceData)
        }.done { _ in
            self.showAlert(
                title: L10n.UrlHandler.FireEvent.Success.title,
                message: L10n.UrlHandler.FireEvent.Success.message(url.pathComponents[1])
            )
        }.catch { error -> Void in
            self.showAlert(
                title: L10n.errorLabel,
                message: L10n.UrlHandler.FireEvent.Error.message(
                    url.pathComponents[1],
                    error.localizedDescription
                )
            )
        }
    }

    private func callServiceURLHandler(_ url: URL, _ serviceData: [String: String]) {
        // homeassistant://call_service/device_tracker.see?entity_id=device_tracker.entity
        let domain = url.pathComponents[1].components(separatedBy: ".")[0]
        let service = url.pathComponents[1].components(separatedBy: ".")[1]

        Current.api.then(on: nil) { api in
            api.CallService(domain: domain, service: service, serviceData: serviceData)
        }.done { _ in
            self.showAlert(
                title: L10n.UrlHandler.CallService.Success.title,
                message: L10n.UrlHandler.CallService.Success.message(url.pathComponents[1])
            )
        }.catch { error in
            self.showAlert(
                title: L10n.errorLabel,
                message: L10n.UrlHandler.CallService.Error.message(
                    url.pathComponents[1],
                    error.localizedDescription
                )
            )
        }
    }

    private func sendLocationURLHandler() {
        // homeassistant://send_location/
        Current.api.then(on: nil) { api in
            api.GetAndSendLocation(trigger: .URLScheme)
        }.done { _ in
            self.showAlert(
                title: L10n.UrlHandler.SendLocation.Success.title,
                message: L10n.UrlHandler.SendLocation.Success.message
            )
        }.catch { error in
            self.showAlert(
                title: L10n.errorLabel,
                message: L10n.UrlHandler.SendLocation.Error.message(error.localizedDescription)
            )
        }
    }

    private func performActionURLHandler(_ url: URL, serviceData: [String: String]) {
        let pathComponents = url.pathComponents
        guard pathComponents.count > 1 else {
            Current.Log.error("not enough path components for perform action handler")
            return
        }

        let source: HomeAssistantAPI.ActionSource = {
            if let sourceString = serviceData["source"],
               let source = HomeAssistantAPI.ActionSource(rawValue: sourceString) {
                return source
            } else {
                return .URLHandler
            }
        }()

        let actionID = url.pathComponents[1]

        guard let action = Current.realm().object(ofType: Action.self, forPrimaryKey: actionID) else {
            Current.sceneManager.showFullScreenConfirm(
                icon: .alertCircleIcon,
                text: L10n.UrlHandler.Error.actionNotFound,
                onto: .value(windowController.window)
            )
            return
        }

        Current.sceneManager.showFullScreenConfirm(
            icon: MaterialDesignIcons(named: action.IconName),
            text: action.Text,
            onto: .value(windowController.window)
        )

        Current.api.then(on: nil) { api in
            api.HandleAction(actionID: actionID, source: source)
        }.cauterize()
    }
}
