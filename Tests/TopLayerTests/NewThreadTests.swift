import Foundation
import Testing
@testable import TopLayer

struct ClaudeCLITests {
    @Test func aSessionIsNamedAfterTheStartOfWhatYouAsked() {
        #expect(ClaudeCLI.name(from: "Fix the login page") == "Fix the login page")
        #expect(ClaudeCLI.name(from: "  Fix the login page\nand the footer") == "Fix the login page")
        let long = ClaudeCLI.name(from: "Refactor the whole persistence layer so that it no longer depends on the old cache")
        #expect(long.count <= 40)
        #expect(long == "Refactor the whole persistence layer so")       // cut at a word, not mid-word
        #expect(ClaudeCLI.name(from: String(repeating: "x", count: 90)).count == 40)
    }

    @Test func thePromptIsPassedAsAnArgumentNotAsShellText() {
        let prompt = "Say \"hi\"; rm -rf ~ $(whoami) `id`"
        let args = ClaudeCLI.arguments(id: "0f3c1a2b-0000-0000-0000-000000000000", name: "Say hi", prompt: prompt,
                                       binary: "/usr/local/bin/claude", shell: "/bin/zsh")
        // The shell is only told to run its arguments; nothing you type becomes part of a command line.
        #expect(args[3...4] == ["-lic", "exec \"$0\" \"$@\""])
        #expect(args.last == prompt)
        #expect(args.contains("--session-id") && args.contains("0f3c1a2b-0000-0000-0000-000000000000"))
        #expect(args[0...1] == ["-dmS", "toplayer-0f3c1a2b"])
    }

    @Test func aChosenModelAndEffortArePassedAndLeftOutWhenNotChosen() {
        func args(model: String?, effort: String?) -> [String] {
            ClaudeCLI.arguments(id: "0f3c1a2b-0000-0000-0000-000000000000", name: "n", prompt: "p", binary: "/c", shell: "/bin/zsh",
                                model: model, effort: effort)
        }
        let chosen = args(model: "opus", effort: "high")
        #expect(chosen.contains("--model") && chosen[chosen.firstIndex(of: "--model")! + 1] == "opus")
        #expect(chosen.contains("--effort") && chosen[chosen.firstIndex(of: "--effort")! + 1] == "high")
        #expect(chosen.last == "p")                                      // the prompt stays last
        // Nothing chosen: no flags, so the session uses what your settings say.
        for unset in [args(model: nil, effort: nil), args(model: "", effort: "")] {
            #expect(!unset.contains("--model") && !unset.contains("--effort"))
        }
    }

    @Test func runningScreensAreReadFromTheList() {
        let list = """
        There are screens on:
        \t77205.toplayer-1422b988\t(Detached)
        \t481.toplayer-87706290\t(Attached)
        \t9912.my-own-session\t(Detached)
        3 Sockets in /var/folders/x/.screen.
        """
        #expect(ClaudeCLI.names(inScreenList: list) == ["toplayer-1422b988", "toplayer-87706290", "my-own-session"])
        #expect(ClaudeCLI.names(inScreenList: "No Sockets found in /var/folders/x/.screen.\n").isEmpty)
    }

    @Test func theDesktopLinksCarryTheFolderAndMessageSafely() throws {
        let link = try #require(Store.claudeDesktopLink(folder: "/Users/me/My Project", prompt: "Fix it & ship? 100%"))
        #expect(link.scheme == "claude" && link.host == "code" && link.path == "/new")
        let items = try #require(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "q" }?.value == "Fix it & ship? 100%")
        #expect(items.first { $0.name == "folder" }?.value == "/Users/me/My Project")
        #expect(Store.claudeImportLink(sessionId: "abc-123")?.absoluteString == "claude://resume?session=abc-123")
    }
}

struct CLIToolsTests {
    @Test func aVersionIsFoundInWhatACommandPrints() {
        #expect(CLITools.version(in: "2.1.322 (Claude Code)\n") == "2.1.322")
        #expect(CLITools.version(in: "codex-cli 0.167.1") == "0.167.1")
        #expect(CLITools.version(in: "no version here") == nil)
    }

    @Test func versionsAreComparedNumberByNumber() {
        #expect(CLITools.isNewer("2.1.322", than: "2.1.221"))
        #expect(CLITools.isNewer("2.10.0", than: "2.9.9"))          // not as text, where "10" < "9"
        #expect(CLITools.isNewer("1.0.1", than: "1.0"))
        #expect(!CLITools.isNewer("2.1.322", than: "2.1.322"))
        #expect(!CLITools.isNewer("0.167.0", than: "0.167.1"))
    }
}
