import Alamofire
import Eureka
import HAKit
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
