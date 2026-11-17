import UIKit

@MainActor
final class CanvasSessionCache: NSObject {
    private var cache = CanvasMemoryCache<CanvasSession>(capacity: 2, onEvict: { session in
        MainActor.assumeIsolated { session.discard() }
    })

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(memoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    func session(baseURL: URL, workflowID: String, serverID: String? = nil) -> CanvasSession {
        let key = CanvasCacheKey(baseURL: baseURL, workflowID: workflowID, serverID: serverID)
        return cache.acquire(key) { let session = CanvasSession(); session.cacheKey = key; return session }
    }
    func attach(_ session: CanvasSession) { if let key = session.cacheKey { cache.attach(key) } }
    func detach(_ session: CanvasSession) { if let key = session.cacheKey { cache.detach(key) } }
    func remove(workflowID: String) { cache.discardInactive(workflowID: workflowID) }
    @objc private func memoryWarning() { cache.discardInactive() }
}
