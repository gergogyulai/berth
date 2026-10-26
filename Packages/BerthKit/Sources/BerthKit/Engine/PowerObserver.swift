import Foundation
import IOKit
import IOKit.pwr_mgt

/// System sleep/wake via IOKit, so Berth can hold off sleep briefly while it unmounts.
///
/// `NSWorkspace.willSleepNotification` can't delay sleep; `IORegisterForSystemPower` can (until
/// `IOAllowPowerChange` is called or ~30 seconds pass).
@MainActor
public final class PowerObserver {
    public enum Event { case willSleep, didWake }

    /// For `.willSleep`, call the completion when it's OK to sleep.
    public var handler: ((Event, @escaping @MainActor () -> Void) -> Void)?

    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    // IOKit message constants are function-like macros, so they aren't imported into Swift.
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    public init() {}

    public func start() {
        guard rootPort == 0 else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(context, &notifyPort, { ctx, _, messageType, argument in
            guard let ctx else { return }
            let observer = Unmanaged<PowerObserver>.fromOpaque(ctx).takeUnretainedValue()
            let notificationID = Int(bitPattern: argument)
            MainActor.assumeIsolated {
                observer.received(messageType: messageType, notificationID: notificationID)
            }
        }, &notifier)
        if let notifyPort {
            CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .commonModes)
        }
    }

    private func received(messageType: UInt32, notificationID: Int) {
        switch messageType {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, notificationID)
        case Self.systemWillSleep:
            let port = rootPort
            var allowed = false
            let allow: @MainActor () -> Void = {
                guard !allowed else { return }
                allowed = true
                IOAllowPowerChange(port, notificationID)
            }
            if let handler {
                handler(.willSleep, allow)
                // Never hold sleep for long, whatever happens.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(15))
                    allow()
                }
            } else {
                allow()
            }
        case Self.systemHasPoweredOn:
            handler?(.didWake, {})
        default:
            break
        }
    }
}
