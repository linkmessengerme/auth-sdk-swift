import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Routes the verified authorization URL through iOS Universal Links. V1's
/// browser fallback opens Link's existing install/open interstitial, not WebView.
public struct SystemLinkOpener: LinkAuthorizationOpener {
    public let allowBrowserFallback: Bool
    public init(allowBrowserFallback: Bool = true) { self.allowBrowserFallback = allowBrowserFallback }

    @MainActor public func open(_ url: URL) async -> Bool {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return false }
        #if canImport(UIKit)
        let opened = await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { continuation.resume(returning: $0) }
        }
        if opened || !allowBrowserFallback { return opened }
        return await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { continuation.resume(returning: $0) }
        }
        #else
        return false // macOS is included for host integration tests only.
        #endif
    }
}
