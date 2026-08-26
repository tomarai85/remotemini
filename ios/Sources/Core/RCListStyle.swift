import SwiftUI

/// Sessions の一覧の**行の作り**を選ぶ(2026-08-26 新設)。
///
/// なぜ設定に出すのか: Tom の「見た目が好きじゃない」は何度も出ているが、私が自分の目で
/// 直して再出荷する型は3連敗している(DESIGN の裁定「趣味の収束方法」)。裁定の中身は
/// **具体物を実機で並べて選ばせる**。だからここは恒久の設定ではなく **選定用の仮設**で、
/// Tom が番号を言ったら勝った1つを直値に畳んで、この file ごと消す。
///
/// ★色・地・glass は触らない(Tom「壁紙の色とか結構好き」2026-08-26)。
///   変えるのは**行の骨格と間の取り方と動き**だけ。
enum RCListStyle: String, CaseIterable, Identifiable {
    /// 今の形。状態の点 + 題名 + 相対時刻 / 本文2行 / バッジ。
    case current
    /// 詰める。本文1行・余白を削り、時刻とバッジを1段に寄せる。画面あたりの件数が増える。
    case compact
    /// 開ける。題名を大きく、余白を広げ、カードが下から順に入って来る。
    case airy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .current: "A 今のまま"
        case .compact: "B 詰める"
        case .airy:    "C 開ける"
        }
    }

    var note: String {
        switch self {
        case .current: "状態の点・題名・時刻・本文2行・バッジ"
        case .compact: "本文1行・余白を削る。一画面に多く入る"
        case .airy:    "題名を大きく・余白広め・下から順に入る動き"
        }
    }

    // MARK: - 行の寸法(ここだけが3案の差)

    var cardPadding: CGFloat {
        switch self { case .current: 14; case .compact: 10; case .airy: 18 }
    }
    var rowSpacing: CGFloat {
        switch self { case .current: 5; case .compact: 3; case .airy: 8 }
    }
    var subtitleLines: Int {
        switch self { case .current: 2; case .compact: 1; case .airy: 2 }
    }
    var titleFont: Font {
        switch self {
        case .current: .body.weight(.semibold)
        case .compact: .subheadline.weight(.semibold)
        case .airy:    .title3.weight(.semibold)
        }
    }
    /// List の行の上下の差し込み(カード同士の間)。
    var listRowVerticalInset: CGFloat {
        switch self { case .current: 5; case .compact: 2; case .airy: 9 }
    }
    /// 入場の動きを持つか。持たない案では transition も delay も一切張らない
    /// (「動かない」を「動きが速い」で代用しない)。
    var animatesEntry: Bool { self == .airy }

    // MARK: - 保存(選定中だけの物なので UserDefaults で足りる)

    private static let key = "RCListStyle"

    static var current_: RCListStyle {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let v = RCListStyle(rawValue: raw) else { return .current }
            return v
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
