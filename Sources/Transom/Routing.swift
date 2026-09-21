import AppKit
import Foundation

struct RoutingRule: Codable, Equatable, Identifiable {
    enum Matcher: String, Codable, CaseIterable {
        case hostGlob = "Host glob"
        case pathRegex = "Path regex"
        case urlRegex = "URL regex"
        case hostPathPrefix = "Site + path prefix"
        case hostPathExact = "Site + exact path"
    }

    let id: UUID
    var enabled: Bool
    var matcher: Matcher
    var pattern: String
    var browser: BrowserKind
    var profileID: String?

    init(
        id: UUID = UUID(),
        enabled: Bool = true,
        matcher: Matcher,
        pattern: String,
        browser: BrowserKind,
        profileID: String?
    ) {
        self.id = id
        self.enabled = enabled
        self.matcher = matcher
        self.pattern = pattern
        self.browser = browser
        self.profileID = profileID
    }
}

struct RoutingScope: Equatable {
    let host: String
    let path: String
    let exact: Bool

    init?(host: String, path: String, exact: Bool = false) {
        guard !host.isEmpty, !host.contains("*"),
            path.isEmpty || path.hasPrefix("/"),
            let components = URLComponents(string: "https://\(host)\(path)"),
            components.host?.lowercased() == host.lowercased(),
            components.user == nil, components.password == nil,
            components.port == nil, components.query == nil, components.fragment == nil
        else { return nil }
        self.host = host.lowercased()
        let encoded = components.percentEncodedPath
        self.path = exact ? (encoded.isEmpty ? "/" : encoded)
            : String(encoded.reversed().drop(while: { $0 == "/" }).reversed())
        self.exact = exact
    }

    init?(pattern: String, exact: Bool) {
        let parts = pattern.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let host = parts.first else { return nil }
        self.init(host: String(host), path: parts.count == 2 ? "/" + parts[1] : "", exact: exact)
    }

    var pattern: String { host + path }
    var matcher: RoutingRule.Matcher { exact ? .hostPathExact : .hostPathPrefix }
    var specificity: Int { path.split(separator: "/").count * 2 + (exact ? 1 : 0) }

    func matches(_ url: URL) -> Bool {
        guard url.host?.lowercased() == host,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return false }
        let candidate = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        return exact ? candidate == path
            : path.isEmpty || candidate == path || candidate.hasPrefix(path + "/")
    }

    static func suggestions(for url: URL) -> [RoutingScope] {
        guard let host = url.host,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let site = RoutingScope(host: host, path: "")
        else { return [] }
        var scopes = [site]
        var path = ""
        for part in components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).dropFirst() {
            path += "/" + part
            if let scope = RoutingScope(host: host, path: path), !scopes.contains(scope) {
                scopes.append(scope)
            }
        }
        if let exact = RoutingScope(host: host, path: components.percentEncodedPath, exact: true) {
            scopes.append(exact)
        }
        return scopes
    }
}

final class RoutingStore {
    private(set) var rules: [RoutingRule] = []
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            load()
            return
        }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Transom", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        self.fileURL = directory.appendingPathComponent("routing.json")
        load()
    }

    func matchingRule(for url: URL) -> RoutingRule? {
        let matches = rules.filter { $0.enabled && URLRuleMatcher.matches($0, url: url) }
        // Explicit regex rules retain their ordered precedence. Everyday
        // scopes prefer a specific path over a broader site rule.
        if let advanced = matches.first(where: { $0.matcher == .pathRegex || $0.matcher == .urlRegex }) {
            return advanced
        }
        return matches.enumerated().sorted { lhs, rhs in
            let left = URLRuleMatcher.specificity(lhs.element)
            let right = URLRuleMatcher.specificity(rhs.element)
            return left == right ? lhs.offset < rhs.offset : left > right
        }.first?.element
    }

    func add(_ rule: RoutingRule) {
        var rule = rule
        if rule.matcher == .hostPathPrefix || rule.matcher == .hostPathExact,
            let scope = RoutingScope(pattern: rule.pattern, exact: rule.matcher == .hostPathExact)
        {
            rule.pattern = scope.pattern
        }
        rules.removeAll {
            if $0.matcher == rule.matcher {
                if rule.matcher == .hostPathPrefix || rule.matcher == .hostPathExact {
                    return RoutingScope(pattern: $0.pattern, exact: $0.matcher == .hostPathExact)?.pattern == rule.pattern
                }
                return $0.pattern == rule.pattern
            }
            // Replace the old opener's exact-host rule when saving a site scope.
            return rule.matcher == .hostPathPrefix && !rule.pattern.contains("/")
                && $0.matcher == .hostGlob && $0.pattern.lowercased() == rule.pattern
        }
        rules.insert(rule, at: 0)
        save()
    }

    func replace(_ rules: [RoutingRule]) {
        self.rules = rules
        save()
    }

    func remove(id: UUID) {
        rules.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard
            let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([RoutingRule].self, from: data)
        else {
            return
        }
        rules = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder.pretty.encode(rules) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

enum URLRuleMatcher {
    static func specificity(_ rule: RoutingRule) -> Int {
        switch rule.matcher {
        case .hostPathPrefix, .hostPathExact:
            return RoutingScope(pattern: rule.pattern, exact: rule.matcher == .hostPathExact)?.specificity ?? -1
        case .hostGlob: return rule.pattern.contains("*") ? -1 : 0
        default: return 0
        }
    }

    static func matches(_ rule: RoutingRule, url: URL) -> Bool {
        switch rule.matcher {
        case .hostGlob:
            guard let host = url.host?.lowercased() else { return false }
            return glob(rule.pattern.lowercased(), matches: host)
        case .pathRegex:
            return regex(rule.pattern, matches: url.path)
        case .urlRegex:
            return regex(rule.pattern, matches: url.absoluteString)
        case .hostPathPrefix, .hostPathExact:
            return RoutingScope(pattern: rule.pattern, exact: rule.matcher == .hostPathExact)?.matches(url) ?? false
        }
    }

    private static func glob(_ pattern: String, matches value: String) -> Bool {
        var expression = "^"
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "*" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    expression += ".*"
                    index = pattern.index(after: next)
                    continue
                }
                expression += "[^.]*"
            } else {
                expression += NSRegularExpression.escapedPattern(for: String(character))
            }
            index = pattern.index(after: index)
        }
        return regex(expression + "$", matches: value)
    }

    private static func regex(_ pattern: String, matches value: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return false
        }
        let range = NSRange(value.startIndex..., in: value)
        return expression.firstMatch(in: value, range: range) != nil
    }
}

struct BrowserLauncher {
    @discardableResult
    func launch(
        url: URL,
        browser: InstalledBrowser,
        profile: BrowserProfile?
    ) -> Result<Void, Error> {
        let process = Process()
        process.executableURL = browser.executableURL
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        var arguments: [String] = []
        switch browser.family {
        case .chromium:
            arguments.append("--user-data-dir=\(browser.profileRoot.path)")
            if let profile {
                arguments.append("--profile-directory=\(profile.id)")
            }
            arguments.append(url.absoluteString)
        case .firefox:
            if let profile {
                arguments.append(contentsOf: ["-P", profile.name])
            }
            arguments.append(contentsOf: ["-new-window", url.absoluteString])
        }
        process.arguments = arguments

        do {
            try process.run()
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}

struct DefaultBrowserRegistrar {
    func register(applicationURL: URL, completion: @escaping (Error?) -> Void) {
        registerNext(schemes: ["http", "https"], applicationURL: applicationURL, completion: completion)
    }

    private func registerNext(
        schemes: [String], applicationURL: URL, completion: @escaping (Error?) -> Void
    ) {
        guard let scheme = schemes.first else {
            completion(nil)
            return
        }
        let remaining = Array(schemes.dropFirst())
        if let url = URL(string: "\(scheme)://example.com"),
            NSWorkspace.shared.urlForApplication(toOpen: url)?.standardizedFileURL
                == applicationURL.standardizedFileURL
        {
            registerNext(schemes: remaining, applicationURL: applicationURL, completion: completion)
        } else {
            NSWorkspace.shared.setDefaultApplication(
                at: applicationURL,
                toOpenURLsWithScheme: scheme
            ) { error in
                DispatchQueue.main.async {
                    if let error {
                        completion(error)
                    } else {
                        registerNext(schemes: remaining, applicationURL: applicationURL, completion: completion)
                    }
                }
            }
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
