import Foundation
import CallKit

/// Detects call state via CallKit and reports a label to show on the dash.
///
/// ⚠️ iOS privacy limit: third-party apps **cannot** read the caller's name or
/// number for ordinary incoming cellular calls. `CXCallObserver` only exposes the
/// call's state (incoming / connected / ended / outgoing) and an opaque UUID — no
/// handle. So the dash can show "Incoming call" / "On call", but not who it is.
/// (This is the one place iOS is strictly more restrictive than the Android app.)
final class CallObserver: NSObject, ObservableObject, CXCallObserverDelegate {
    private let observer = CXCallObserver()

    /// Called with a label to display ("Incoming call", "On call", …) or nil to clear.
    var onCall: ((String?) -> Void)?
    @Published private(set) var status: String = "idle"

    override init() {
        super.init()
        observer.setDelegate(self, queue: .main)
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        let label: String?
        if call.hasEnded {
            label = nil; status = "idle"
        } else if call.hasConnected {
            label = "On call"; status = "connected"
        } else if call.isOutgoing {
            label = "Calling…"; status = "outgoing"
        } else {
            label = "Incoming call"; status = "incoming"
        }
        DiagnosticsLog.shared.log("call", "state=\(status)")
        onCall?(label)
    }
}
