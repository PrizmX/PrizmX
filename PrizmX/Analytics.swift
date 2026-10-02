import AppKit
import Foundation
import PostHog

/// Anonymous product analytics (PostHog).
///
/// Every event carries the super properties below so community, App Store
/// macOS and iOS data can be told apart. The SDK already sends the bundle id
/// as `$app_namespace`, but iOS and Pro share `app.prizmx`, so `edition` and
/// `platform` are explicit.
///
/// Events on top of the SDK's lifecycle ones, which on macOS follow window
/// focus and never fire for a menu-bar-only app that is not clicked:
/// - `app_launched`: once per process launch.
/// - `app_active`: once per day while the app runs. Count daily actives on it.
/// - `proxy_state_changed`: TUN or System Proxy turned on or off.
@MainActor
enum Analytics {
    private static let projectToken = "phc_zuvMb7UYcUHnXjFMiW72MPCkLVnSPBYYCuCzPC5p8QER"
    private static let host = "https://us.i.posthog.com"
    private static let enabledKey = "analyticsEnabled"
    private static let lastActiveDayKey = "analyticsLastActiveDay"
    /// Day boundary for `app_active`. Keep in line with the PostHog project
    /// time zone so one heartbeat lands in each of its days.
    private static let activeDayTimeZone = TimeZone(identifier: "UTC")!

    private static var isStarted = false

    private static var proxyState = ProxyState()
    private static var reportedProxyState: ProxyState?
    private static var proxyStateTask: Task<Void, Never>?

    /// User consent from Settings. On by default.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func start() {
        let config = PostHogConfig(projectToken: projectToken, host: host)
        // Applies before the first launch's sync below, so an opted-out user
        // never sends the install event.
        config.optOut = !isEnabled
        PostHogSDK.shared.setup(config)
        isStarted = true
        apply(enabled: isEnabled)
        PostHogSDK.shared.capture("app_launched")
        startHeartbeat()
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        apply(enabled: enabled)
        if enabled { sendHeartbeatIfNeeded() }
    }

    /// Called by `AppModel` whenever the TUN session or the applied system
    /// proxy changes, including once at launch.
    static func updateProxyState(tun: Bool, systemProxy: Bool) {
        proxyState = ProxyState(tun: tun, systemProxy: systemProxy)
        guard isStarted else { return }
        proxyStateTask?.cancel()
        proxyStateTask = Task {
            // A takeover re-apply can flip the state for a moment; report
            // only settled values.
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            reportProxyState()
        }
    }

    /// The SDK persists its own opt-out flag, which outranks `config.optOut`
    /// at setup. Keep it in line with the Settings value.
    private static func apply(enabled: Bool) {
        let sdk = PostHogSDK.shared
        if enabled {
            if sdk.isOptOut() { sdk.optIn() }
            // `register` is a no-op while opted out, so run it after opting in.
            sdk.register(superProperties.merging(proxyState.properties) { _, new in new })
            reportedProxyState = proxyState
        } else if !sdk.isOptOut() {
            sdk.optOut()
        }
    }

    private static func reportProxyState() {
        guard proxyState != reportedProxyState else { return }
        reportedProxyState = proxyState
        PostHogSDK.shared.register(proxyState.properties)
        PostHogSDK.shared.capture("proxy_state_changed")
    }

    // MARK: - Daily heartbeat

    /// A menu bar app can run for days without a launch or focus change, so
    /// check the day on a timer and after wake.
    private static func startHeartbeat() {
        Task {
            // Let the launch takeover connect so the first heartbeat carries
            // the real TUN / System Proxy state.
            try? await Task.sleep(for: .seconds(10))
            sendHeartbeatIfNeeded()
        }
        let timer = Timer(timeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { sendHeartbeatIfNeeded() }
        }
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { sendHeartbeatIfNeeded() }
        }
    }

    private static func sendHeartbeatIfNeeded() {
        // Opted-out days must not mark the day as sent.
        guard isEnabled else { return }
        let day = currentDay
        guard UserDefaults.standard.string(forKey: lastActiveDayKey) != day else { return }
        UserDefaults.standard.set(day, forKey: lastActiveDayKey)
        PostHogSDK.shared.capture("app_active")
    }

    private static var currentDay: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = activeDayTimeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: .now)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - Properties

    private struct ProxyState: Equatable {
        var tun = false
        var systemProxy = false

        var properties: [String: Any] {
            ["tun_on": tun, "system_proxy_on": systemProxy]
        }
    }

    private static var superProperties: [String: Any] {
        [
            "edition": "community",
            "platform": "macos",
            "build_config": buildConfig,
        ]
    }

    private static var buildConfig: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }
}
