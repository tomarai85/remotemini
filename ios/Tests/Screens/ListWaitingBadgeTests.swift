import XCTest
@testable import RemoteMini

/// 一覧の行が **「机が Tom の返事を待っている」を出す**事を測る。2026-08-27 新設。
///
/// ★なぜ要るか(実測 2026-08-26): 会話を開けば digest が「待っている」と言うが、
///   一覧は `route.kind == .choice` の時だけ札を出していた。生きた 2 本とも
///   `route = null` だったので、**あの札は一度も出ていない**。
///   一方 digest は同じ会話を `attention=input` と判定していた ——
///   つまり Tom は**開くまで待たれている事を知れない**。開くまでの時間こそ、
///   この機能が取り戻そうとしている死に時間そのもの(60 分観測)。
///
/// ★Codex 2026-08-27 の指定: **偽陽性と偽陰性を両方**測る。
///   片方だけだと「何にも札を出さない実装」か「全部に札を出す実装」で緑になる。
///
/// ★判定は机が持つ(`requiresOwnerInput`)。電話は描くだけ ——
///   両側で「待っている」を定義すると、必ず片方だけ腐る。
@MainActor
final class ListWaitingBadgeTests: XCTestCase {

    private func row(route kind: RouteLabel.Kind, requiresOwnerInput: Bool?) -> SessionRow {
        SessionRow(
            id: "r", title: "t",
            updatedAt: "2026-08-27T00:00:00Z",
            fromRegistryOnly: nil,
            display: .init(
                route: RouteLabel(kind: kind, short: "s", text: "x", screen: ""),
                subtitle: "sub"),
            machine: nil,
            requiresOwnerInput: requiresOwnerInput)
    }

    /// ★★本命: `route` が無くても、机が「待っている」と言えば札が出る。
    /// これが出ないのが、2026-08-26 に実際に起きていた状態。
    func test_routeが無くても机が待っていると言えば札が出る() {
        let r = row(route: .worker, requiresOwnerInput: true)
        XCTAssertEqual(SessionRowView.statusWord(for: r), "Needs your input",
                       "机が待っていると言ったのに一覧が黙っている(開くまで気付けない)")
        XCTAssertEqual(SessionRowView.statusColor(for: r), .orange,
                       "札と色が別の判定から出ている(一瞥では色しか見えない)")
    }

    /// ★偽陽性の負: 机が「待っていない」と言えば札は出ない。
    func test_机が待っていないと言えば札は出ない() {
        let r = row(route: .worker, requiresOwnerInput: false)
        XCTAssertNil(SessionRowView.statusWord(for: r), "待っていないのに急かしている")
    }

    /// ★★`nil`(古い机 / 判らない)は**急かさない**。
    /// 判らない事を急ぎに見せると、Tom は札そのものを見なくなる(2026-08-26 の裁定)。
    func test_判らない時は急かさない() {
        let r = row(route: .worker, requiresOwnerInput: nil)
        XCTAssertNil(SessionRowView.statusWord(for: r), "判らない事を急ぎに見せている")
    }

    /// `choice` は「返事が要る」の**理由の1つ**であって別の札ではない。
    /// 枠は1つ —— 1 行が2つの急ぎを言うのは「帯3段」の縮小版(§9-4)。
    func test_choiceは同じ1枠へ畳む() {
        let r = row(route: .choice, requiresOwnerInput: nil)   // 古い机を装う
        XCTAssertEqual(SessionRowView.statusWord(for: r), "Needs your input",
                       "古い机でも choice なら札が出る(保険が効いている)")
    }

    /// 静かな行は静かなまま(過剰発火の負)。
    func test_机で動いている行は急かさない() {
        let r = row(route: .tmux, requiresOwnerInput: false)
        XCTAssertEqual(SessionRowView.statusWord(for: r), "On desktop")
        XCTAssertNotEqual(SessionRowView.statusColor(for: r), .orange)
    }
}
