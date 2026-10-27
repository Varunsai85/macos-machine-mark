import Foundation

// Asks GitHub whether a newer release is out. That one request (no details
// about the Mac in it) is the only thing that leaves the Mac, and the menu
// bar menu turns the automatic check off.
enum Updater {
    static let repo = "Varunsai85/macos-machine-mark"

    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    struct Release { let version: String; let page: URL }

    // The latest release (nil if there is none yet), and whether GitHub
    // answered at all. Calls back on main.
    static func latest(_ done: @escaping (Release?, _ reached: Bool) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var found: Release?
            if let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = o["tag_name"] as? String,
               let page = (o["html_url"] as? String).flatMap(URL.init(string:)) {
                found = Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: page)
            }
            let reached = found != nil || status == 404
            DispatchQueue.main.async { done(found, reached) }
        }.resume()
    }

    // "1.10.0" is newer than "1.9.2"; missing parts count as 0.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
