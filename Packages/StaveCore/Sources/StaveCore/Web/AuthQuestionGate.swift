import Foundation

/// What one sign-in question is about: the protection space (host and port as `AuthChallenge.host` names them, scheme, realm, method, proxy
/// or not). Challenges with the same space are one question; `http` and `https` never share an answer.
public struct AuthSpace: Hashable, Sendable {
    public let host: String
    /// The protection space's `protocol`, lowercased (`http`, `https`; empty for none).
    public let scheme: String
    public let realm: String?
    public let method: String
    public let isProxy: Bool

    public init(host: String, scheme: String?, realm: String?, method: String, isProxy: Bool) {
        self.host = host
        self.scheme = scheme?.lowercased() ?? ""
        self.realm = realm
        self.method = method
        self.isProxy = isProxy
    }
}

/// Keeps a page's sign-in challenges from locking its window (plan 5, Task 11), one gate per page, like `PageDialogGate` for dialogs.
///
/// - Challenges for the same space that arrive while its question is open join it: one sheet answers them all, and every waiter gets the
///   same answer.
/// - At most `waitingLimit` different questions are open at once; a challenge beyond that is refused without asking.
/// - After `cancelLimit` questions the user cancelled in one document (`document`, the page's main-frame commit count), every later
///   challenge is refused without asking until the page commits a new document. Only the user's Cancel counts: a question the system
///   dropped (stale page, commit, failed load, closed tab) has no reply (nil) and costs nothing.
///
/// A refused, dropped or cancelled challenge all give nil: the caller sends `.rejectProtectionSpace`.
@MainActor
public final class AuthQuestionGate {
    public static let cancelLimit = 3
    public static let waitingLimit = 5

    private var open: [AuthSpace: [CheckedContinuation<AuthReply?, Never>]] = [:]
    private var document: Int?
    private var cancels = 0

    public init() {}

    /// How many different questions are open now (for tests).
    public var openCount: Int { open.count }

    /// The answer for `space`. `perform` asks the user (it is called only for the question's first challenge): the user's reply, or nil when
    /// the system dropped the question.
    public func ask(_ space: AuthSpace, document current: Int, perform: @MainActor () async -> AuthReply?) async -> AuthAnswer? {
        guard let reply = await reply(space, document: current, perform: perform), case .signedIn(let answer) = reply else { return nil }
        return answer
    }

    private func reply(_ space: AuthSpace, document current: Int, perform: @MainActor () async -> AuthReply?) async -> AuthReply? {
        if document != current {
            document = current
            cancels = 0
        }
        guard cancels < Self.cancelLimit else { return nil }
        if open[space] != nil {
            return await withCheckedContinuation { open[space]?.append($0) }
        }
        guard open.count < Self.waitingLimit else { return nil }
        open[space] = []
        let reply = await perform()
        // The user's Cancel counts against the document it was asked in, not a newer one.
        if reply == .cancelled, document == current { cancels += 1 }
        let joined = open.removeValue(forKey: space) ?? []
        for waiter in joined { waiter.resume(returning: reply) }
        return reply
    }
}
