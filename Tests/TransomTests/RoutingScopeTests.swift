import Foundation
import Testing
@testable import Transom

struct RoutingScopeTests {
    @Test func narrowerRulesWinAndDuplicateUpdatesPersist() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rules.json")
        let store = RoutingStore(fileURL: file)
        func add(_ pattern: String, _ profile: String, exact: Bool = false) {
            store.add(RoutingRule(matcher: exact ? .hostPathExact : .hostPathPrefix,
                                  pattern: pattern, browser: .chrome, profileID: profile))
        }
        add("github.com/acme/widget", "repo")
        add("github.com/acme", "owner")
        add("github.com", "site")
        let repoURL = try #require(URL(string: "https://github.com/acme/widget/issues"))
        #expect(store.matchingRule(for: repoURL)?.profileID == "repo")
        #expect(store.matchingRule(for: try #require(URL(string: "https://github.com/acme/other")))?.profileID == "owner")
        #expect(store.matchingRule(for: try #require(URL(string: "https://github.com/other")))?.profileID == "site")
        add("GITHUB.COM/acme/widget/", "replacement")
        #expect(store.rules.count == 3)
        #expect(RoutingStore(fileURL: file).matchingRule(for: repoURL)?.profileID == "replacement")
        add("github.com/acme/widget/issues", "exact", exact: true)
        #expect(store.matchingRule(for: repoURL)?.profileID == "exact")
        store.add(RoutingRule(matcher: .urlRegex, pattern: "^https://github\\.com/acme/widget/issues$",
                              browser: .chrome, profileID: "advanced"))
        add("github.com", "new-site")
        #expect(store.matchingRule(for: repoURL)?.profileID == "advanced")
    }

    @Test func legacyRulesStillLoad() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","enabled":true,"matcher":"Host glob","pattern":"*.example.com","browser":"chrome"}
        """
        let rule = try JSONDecoder().decode(RoutingRule.self, from: Data(json.utf8))
        #expect(URLRuleMatcher.matches(rule, url: try #require(URL(string: "https://docs.example.com/test"))))
    }

    @Test func matchesHostAndPathBoundaries() throws {
        let scope = try #require(RoutingScope(host: "github.com", path: "/acme/widget"))
        for link in ["https://github.com/acme/widget", "http://github.com/acme/widget/pull/1?tab=files#diff"] {
            #expect(scope.matches(try #require(URL(string: link))))
        }
        for link in ["https://github.com/acme/widget-tools", "https://other.example/acme/widget", "https://sub.github.com/acme/widget"] {
            #expect(!scope.matches(try #require(URL(string: link))))
        }
    }

    @Test func exactPathIgnoresQueryButNotDescendants() throws {
        let scope = try #require(RoutingScope(host: "GITHUB.COM", path: "/acme/widget", exact: true))
        #expect(scope.matches(try #require(URL(string: "https://github.com/acme/widget?q=1#top"))))
        #expect(!scope.matches(try #require(URL(string: "https://github.com/acme/widget/issues"))))
        #expect(!scope.matches(try #require(URL(string: "https://github.com/acme/Widget"))))
    }

    @Test func suggestionsAreGenericAndPreserveEncodedSlashes() throws {
        let url = try #require(URL(string: "https://example.com/team/a%2Fb/item?q=1"))
        let suggestions = RoutingScope.suggestions(for: url)
        #expect(suggestions.map(\.pattern) == [
            "example.com", "example.com/team", "example.com/team/a%2Fb",
            "example.com/team/a%2Fb/item", "example.com/team/a%2Fb/item",
        ])
        #expect(suggestions.last?.exact == true)
        #expect(suggestions.allSatisfy { $0.matches(url) })
    }

    @Test func invalidScopesAreRejected() {
        #expect(RoutingScope(host: "example.com", path: "no-slash") == nil)
        #expect(RoutingScope(host: "example.com", path: "/path?query=1") == nil)
        #expect(RoutingScope(host: "example.com", path: "/path#fragment") == nil)
        #expect(RoutingScope(pattern: "https://example.com/path", exact: false) == nil)
    }

    @Test func scopesRoundTripThroughExistingRuleFormat() throws {
        let scope = try #require(RoutingScope(host: "example.com", path: "/team/"))
        let rule = RoutingRule(matcher: scope.matcher, pattern: scope.pattern, browser: .chrome, profileID: "synthetic-profile")
        let decoded = try JSONDecoder().decode(RoutingRule.self, from: JSONEncoder().encode(rule))
        #expect(decoded == rule)
        #expect(URLRuleMatcher.matches(decoded, url: try #require(URL(string: "https://example.com/team/page"))))
    }
}
