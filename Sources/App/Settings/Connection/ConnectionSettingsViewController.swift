import Alamofire
import Eureka
import HAKit
import MBProgressHUD
import ObjectMapper
import PromiseKit
import Shared
import UIKit

class ConnectionSettingsViewController: HAFormViewController, RowControllerType {
    public var onDismissCallback: ((UIViewController) -> Void)?

    let server: Server

    init(server: Server) {
        self.server = server

        super.init()
    }

    private var tokens: [HACancellable] = []

    deinit {
        tokens.forEach { $0.cancel() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = L10n.Settings.ConnectionSection.header

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(connectionInfoDidChange(_:)),
            name: SettingsStore.connectionInfoDidChange,
            object: nil
        )

        let connection = Current.api(for: server).connection

        form +++ Section { _ in

        } <<< ButtonRow {
            $0.title = NSLocalizedString("Activate", comment: "")
            $0.onCellSelection { [server] _, _ in
                Current.sceneManager.webViewWindowControllerPromise.done {
                    $0.open(server: server)
                }
            }
        }

        form
            +++ Section(header: L10n.Settings.StatusSection.header, footer: "") {
                $0.tag = "status"
            }

            <<< LabelRow("locationName") {
                $0.title = L10n.Settings.StatusSection.LocationNameRow.title
                $0.displayValueFor = { [server] _ in server.info.name }
            }

            <<< LabelRow("version") {
                $0.title = L10n.Settings.StatusSection.VersionRow.title
                $0.displayValueFor = { [server] _ in server.info.version.description }
            }

            <<< with(WebSocketStatusRow()) {
                $0.connection = connection
            }

            <<< LabelRow { row in
                row.title = L10n.SettingsDetails.Notifications.LocalPush.title
                let manager = Current.notificationManager.localPushManager

                let updateValue = { [weak row, server] in
                    guard let row = row else { return }
                    switch manager.status(for: server) {
                    case .disabled:
                        row.value = L10n.SettingsDetails.Notifications.LocalPush.Status.disabled
                    case .unsupported:
                        row.value = L10n.SettingsDetails.Notifications.LocalPush.Status.unsupported
                    case let .allowed(state):
                        switch state {
                        case .unavailable:
                            row.value = L10n.SettingsDetails.Notifications.LocalPush.Status.unavailable
                        case .establishing:
                            row.value = L10n.SettingsDetails.Notifications.LocalPush.Status.establishing
                        case let .available(received: received):
                            let formatted = NumberFormatter.localizedString(
                                from: NSNumber(value: received),
                                number: .decimal
                            )
                            row.value = L10n.SettingsDetails.Notifications.LocalPush.Status.available(formatted)
                        }
                    }

                    row.updateCell()
                }

                let cancel = manager.addObserver(for: server) { _ in
                    updateValue()
                }
                after(life: self).done(cancel.cancel)
                updateValue()
            }

            <<< LabelRow { row in
                row.title = L10n.Settings.ConnectionSection.loggedInAs

                tokens.append(connection.caches.user.subscribe { _, user in
                    row.value = user.name
                    row.updateCell()
                })
            }

            +++ Section(L10n.Settings.ConnectionSection.details)
            <<< TextRow {
                $0.title = L10n.SettingsDetails.General.DeviceName.title
                $0.placeholder = Current.device.deviceName()
                $0.value = server.info.setting(for: .overrideDeviceName)
                $0.onChange { [server] row in
                    server.info.setSetting(value: row.value, for: .overrideDeviceName)
                }
            }

            <<< LabelRow("connectionPath") {
                $0.title = L10n.Settings.ConnectionSection.connectingVia
                $0.displayValueFor = { [server] _ in server.info.connection.activeURLType.description }
            }

            <<< ButtonRowWithPresent<ConnectionURLViewController> { row in
                row.cellStyle = .value1
                row.title = L10n.Settings.ConnectionSection.InternalBaseUrl.title
                row.displayValueFor = { [server] _ in server.info.connection.address(for: .internal)?.absoluteString }
                row.presentationMode = .show(controllerProvider: .callback(builder: { [server] in
                    ConnectionURLViewController(server: server, urlType: .internal, row: row)
                }), onDismiss: { [navigationController] _ in
                    navigationController?.popViewController(animated: true)
                })

                row.evaluateHidden()
            }

            <<< ButtonRowWithPresent<ConnectionURLViewController> { row in
                row.cellStyle = .value1
                row.title = L10n.Settings.ConnectionSection.ExternalBaseUrl.title
                row.displayValueFor = { [server] _ in
                    if server.info.connection.useCloud, server.info.connection.canUseCloud {
                        return L10n.Settings.ConnectionSection.HomeAssistantCloud.title
                    } else {
                        return server.info.connection.address(for: .external)?.absoluteString
                    }
                }
                row.presentationMode = .show(controllerProvider: .callback(builder: { [server] in
                    ConnectionURLViewController(server: server, urlType: .external, row: row)
                }), onDismiss: { [navigationController] _ in
                    navigationController?.popViewController(animated: true)
                })
            }

            +++ Section()

            <<< ButtonRow {
                $0.title = NSLocalizedString("Delete Server", comment: "")
                $0.onCellSelection { [navigationController, server, view] cell, _ in
                    let alert = UIAlertController(
                        title: NSLocalizedString("Are you sure you wish to delete this server?", comment: ""),
                        message: NSLocalizedString("This cannot be undone.", comment: ""),
                        preferredStyle: .actionSheet
                    )

                    with(alert.popoverPresentationController) {
                        $0?.sourceView = cell
                        $0?.sourceRect = cell.bounds
                    }

                    alert
                        .addAction(UIAlertAction(
                            title: NSLocalizedString("Delete Server", comment: ""),
                            style: .destructive,
                            handler: { _ in
                                let hud = MBProgressHUD.showAdded(to: view!, animated: true)
                                hud.label.text = NSLocalizedString("Deleting Server…", comment: "")
                                hud.show(animated: true)

                                let waitAtLeast = after(seconds: 3.0)

                                firstly {
                                    race(
                                        when(resolved: Current.apis.map { $0.tokenManager.revokeToken() }).asVoid(),
                                        after(seconds: 10.0)
                                    )
                                }.then {
                                    waitAtLeast
                                }.get {
                                    Current.api(for: server).connection.disconnect()
                                    Current.servers.remove(identifier: server.identifier)
                                }.ensure {
                                    hud.hide(animated: true)
                                }.done {
                                    navigationController?.popViewController(animated: true)
                                }.cauterize()
                            }
                        ))

                    alert.addAction(UIAlertAction(title: L10n.cancelLabel, style: .cancel, handler: nil))
                    cell.formViewController()?.present(alert, animated: true, completion: nil)
                }
                $0.cellUpdate { cell, _ in
                    if #available(iOS 13, *) {
                        cell.textLabel?.textColor = .systemRed
                    } else {
                        cell.textLabel?.textColor = .red
                    }
                }
            }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        // Detect when your view controller is popped and invoke the callback
        if !isMovingToParent {
            onDismissCallback?(self)
        }
    }

    @objc func connectionInfoDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [self] in
            form.allRows.forEach { $0.updateCell() }
        }
    }
}
