import Foundation

/// One choice a provider offers in its settings window (File ▸ Connect to External
/// Files ▸ …): a question with two to five answers, shown as radio buttons. The
/// chosen answer's `id` is stored in `UserDefaults` under `defaultsKey`.
public struct ProviderOption {
    public struct Choice: Equatable {
        /// What's stored when this answer is chosen. Keep it stable across versions.
        public let id: String
        public let title: String
        /// A one-line explanation shown under the answer. Optional.
        public let note: String?

        public init(id: String, title: String, note: String? = nil) {
            self.id = id
            self.title = title
            self.note = note
        }
    }

    public let title: String
    public let choices: [Choice]
    public let defaultsKey: String
    /// The `id` used when nothing (or an unknown id) is stored.
    public let defaultChoice: String

    public init(title: String, choices: [Choice], defaultsKey: String, defaultChoice: String) {
        precondition((2...5).contains(choices.count), "an option offers two to five choices")
        precondition(choices.contains { $0.id == defaultChoice }, "the default must be one of the choices")
        self.title = title
        self.choices = choices
        self.defaultsKey = defaultsKey
        self.defaultChoice = defaultChoice
    }

    /// The chosen answer's id: what's stored, or the default when nothing valid is.
    public func current(in defaults: UserDefaults = .standard) -> String {
        if let stored = defaults.string(forKey: defaultsKey), choices.contains(where: { $0.id == stored }) {
            return stored
        }
        return defaultChoice
    }

    /// Store `id` as the answer. Ignored if it isn't one of the choices.
    public func set(_ id: String, in defaults: UserDefaults = .standard) {
        guard choices.contains(where: { $0.id == id }) else { return }
        defaults.set(id, forKey: defaultsKey)
    }
}
