import Foundation
import Testing
import MacSplorerCore

/// A provider's settings choice: stored by id, with a default when nothing is.
final class ProviderOptionTests {
    let suite = "macsplorer-tests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suite)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
    }

    private let provenance = ProviderOption(
        title: "When copying files in, record where they came from:",
        choices: [
            .init(id: "fullPath", title: "Full path on this Mac"),
            .init(id: "nameAndComputer", title: "File name and computer name"),
            .init(id: "nameOnly", title: "File name only", note: "No folder names leave this Mac."),
            .init(id: "nothing", title: "Nothing"),
        ],
        defaultsKey: "test.provenance",
        defaultChoice: "nameAndComputer")

    @Test func showsTheDefaultWhenNothingIsStored() {
        #expect(provenance.current(in: defaults) == "nameAndComputer")
    }

    @Test func persistsTheChosenID() {
        provenance.set("nameOnly", in: defaults)
        #expect(defaults.string(forKey: "test.provenance") == "nameOnly")
        #expect(provenance.current(in: defaults) == "nameOnly")
    }

    @Test func anUnknownStoredIDFallsBackToTheDefault() {
        defaults.set("removedInAnOlderVersion", forKey: "test.provenance")
        #expect(provenance.current(in: defaults) == "nameAndComputer")
    }

    @Test func settingAnUnknownIDChangesNothing() {
        provenance.set("fullPath", in: defaults)
        provenance.set("bogus", in: defaults)
        #expect(provenance.current(in: defaults) == "fullPath")
    }
}
