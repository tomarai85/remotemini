import Foundation

/// Spec §5-4's counter, in one place instead of two.
///
/// Before Sprint 6 this lived as a bare `Int` plus a threshold constant inside
/// `ListViewModel`, and Conversation had no equivalent at all: its poll loop's
/// `.unreachable` step result returned `true` and touched nothing, so a phone that
/// had lost the backend mid-conversation showed a perfectly normal, perfectly stale
/// screen forever. Spec §5-4 asks for the opposite -- "List/Conversation 共通の
/// コンポーネントとして文言・見た目を1箇所にまとめる".
///
/// **What counts is the caller's decision, not this type's.** §5-4 defines the state
/// as 接続不可・タイムアウト・5xx -- all three of which arrive at both screens as
/// exactly one value (`.unreachable`; see `PollClient`/`SessionsClient`'s `default:`
/// arm mapping every non-200/401 status there). Conversation feeds it precisely that
/// set. List feeds it a superset (its pre-Sprint-6 behaviour, kept deliberately:
/// `.contractViolation`/`.malformedBody`/`.notFound` also increment, because List has
/// no second escalation surface and a screen that stays quiet forever under a
/// repeating server-shape regression is worse than one that says "3 回続けて取れて
/// いません").
///
/// That superset is only defensible because the banner this drives **states what was
/// measured and never names a cause** -- see `UnreachableBanner`. §5-5's own table
/// lists three different causes for §5-4 (電波 / edith 停止 / tailnet 切断) and the
/// phone can distinguish none of them, so any wording that picks one is a guess
/// printed as a fact.
///
/// Not to be confused with `UnreadableMeter` (§5-5), which counts a genuinely
/// different thing: responses that *arrive* and cannot be trusted. Spec: 「片方を
/// もう片方で代用しない —— 代用した瞬間、200 で返る壊れた配信が『接続は健全』に見える」.
struct ReachabilityMeter: Equatable {
    /// Named constant, never a bare literal. Resolves the spec's own §5-4 vs §3-6
    /// numeric inconsistency the same way Sprint 2 did: 3 is correct.
    static let unreachableThreshold = 3

    private(set) var consecutiveFailures = 0

    /// §5-4: 「復帰(1回でも成功)したら即座に消す」 -- reset, not decay.
    mutating func recordSuccess() {
        consecutiveFailures = 0
    }

    mutating func recordFailure() {
        consecutiveFailures += 1
    }

    /// `>=` rather than `==` on purpose: the banner must stay up on the 4th, 5th and
    /// 40th consecutive failure, not blink off after the 3rd.
    var isUnreachable: Bool { consecutiveFailures >= Self.unreachableThreshold }
}
