import SwiftUI

/// 画面全体の意匠の正本(2026-08-17、Tom「UI が綺麗じゃない」→ 同日「全体的に完璧じゃない」)。
///
/// ★2回目の指摘で方針を改めた: 標準部品への tint だけでは「設定画面」の形が残る。
/// 変えるのは色でなく**面の系**(地・カード・縁・角丸・文字の階層)。ただし趣味の
/// 収束は具体物の選択でしか起きないので、同じレイアウトに雰囲気違いの variant を
/// 3方向持ち、実機のスクショで Tom に選ばせる。選ばれた物が既定に昇格する。
///
/// ★variant の切替は DEBUG 限定の環境変数(`RC_THEME_VARIANT`)。Release には
/// 綴りごと存在しない(`RC_UI_FIXTURE` と同じ判断 — 出荷物に実験の口を残さない)。
/// 色は此処にだけ書く。散らすと画面ごとに微妙に違う紫が生える。
enum RCTheme {
    enum Variant: String {
        /// A: Claude 公式アプリ系の暖色ダーク(墨色の地 + テラコッタ)。
        case claudeWarm = "claude"
        /// B: ライトミニマル(白カード + 藍紫 = 今のアイコンと同系)。
        case lightMinimal = "light"
        /// C: グラファイトダーク(青黒の地 + 藍紫)。
        case graphite = "graphite"
        /// D: Liquid Glass・ダーク(Tom 指名 2026-08-17「Glass っぽい感じ」)。
        /// 地は深い藍黒 + 柔らかい光彩、カードは iOS 26 の glassEffect(旧 OS は material)。
        case glassDark = "glassdark"
        /// E: Liquid Glass・ライト。
        case glassLight = "glasslight"
    }

    static let variant: Variant = resolveVariant()

    private static func resolveVariant() -> Variant {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["RC_THEME_VARIANT"],
           let v = Variant(rawValue: raw) {
            return v
        }
        #endif
        // 既定 = D(Liquid Glass ダーク)。2026-08-17 Tom 裁定(5案の実機スクショ比較から)。
        return .glassDark
    }

    /// ボタン・リンク・選択の tint。
    static let accent: Color = {
        switch variant {
        case .claudeWarm: return Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
        case .lightMinimal: return Color(red: 0x6D / 255.0, green: 0x5C / 255.0, blue: 0xFF / 255.0)
        case .graphite: return Color(red: 0x7C / 255.0, green: 0x6C / 255.0, blue: 0xFF / 255.0)
        case .glassDark: return Color(red: 0x8B / 255.0, green: 0x7C / 255.0, blue: 0xFF / 255.0)
        case .glassLight: return Color(red: 0x6D / 255.0, green: 0x5C / 255.0, blue: 0xFF / 255.0)
        }
    }()

    /// 承認の危険度(2026-08-26)。**押せる物は変えない** —— 読む前に押すのを止めるだけの色。
    /// 直値を画面へ置かず此処に集める理由は他のトークンと同じ: 5案の切替が効かなくなる。
    static let danger: Color = {
        switch variant {
        case .claudeWarm:   return Color(red: 0xF2 / 255.0, green: 0x7A / 255.0, blue: 0x6E / 255.0)
        case .lightMinimal: return Color(red: 0xC4 / 255.0, green: 0x28 / 255.0, blue: 0x20 / 255.0)
        case .graphite:     return Color(red: 0xFF / 255.0, green: 0x7B / 255.0, blue: 0x72 / 255.0)
        case .glassDark:    return Color(red: 0xFF / 255.0, green: 0x8A / 255.0, blue: 0x80 / 255.0)
        case .glassLight:   return Color(red: 0xC0 / 255.0, green: 0x2A / 255.0, blue: 0x22 / 255.0)
        }
    }()

    /// 外へ出る操作(戻せるが他人から見える)。danger より弱い段。
    static let caution: Color = {
        switch variant {
        case .claudeWarm:   return Color(red: 0xE8 / 255.0, green: 0xB3 / 255.0, blue: 0x39 / 255.0)
        case .lightMinimal: return Color(red: 0x9A / 255.0, green: 0x6B / 255.0, blue: 0x00 / 255.0)
        case .graphite:     return Color(red: 0xE3 / 255.0, green: 0xB3 / 255.0, blue: 0x41 / 255.0)
        case .glassDark:    return Color(red: 0xF5 / 255.0, green: 0xC2 / 255.0, blue: 0x4E / 255.0)
        case .glassLight:   return Color(red: 0x8F / 255.0, green: 0x63 / 255.0, blue: 0x00 / 255.0)
        }
    }()

    /// 持ち出しバッジ等の第二アクセント。
    static let violet: Color = {
        switch variant {
        case .claudeWarm: return Color(red: 0xB8 / 255.0, green: 0xA7 / 255.0, blue: 0xEA / 255.0)
        case .lightMinimal: return Color(red: 0xB0 / 255.0, green: 0x5C / 255.0, blue: 0xFF / 255.0)
        case .graphite: return Color(red: 0xB7 / 255.0, green: 0x8C / 255.0, blue: 0xFF / 255.0)
        case .glassDark: return Color(red: 0xC0 / 255.0, green: 0x9A / 255.0, blue: 0xFF / 255.0)
        case .glassLight: return Color(red: 0xA8 / 255.0, green: 0x6B / 255.0, blue: 0xFF / 255.0)
        }
    }()

    /// 画面の地(glass では光彩の下に敷く基調色)。
    static let background: Color = {
        switch variant {
        case .claudeWarm: return Color(red: 0x26 / 255.0, green: 0x24 / 255.0, blue: 0x20 / 255.0)
        case .lightMinimal: return Color(red: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF7 / 255.0)
        case .graphite: return Color(red: 0x0F / 255.0, green: 0x11 / 255.0, blue: 0x15 / 255.0)
        case .glassDark: return Color(red: 0x0B / 255.0, green: 0x0C / 255.0, blue: 0x14 / 255.0)
        case .glassLight: return Color(red: 0xF1 / 255.0, green: 0xF0 / 255.0, blue: 0xF8 / 255.0)
        }
    }()

    /// カードの面(glass では旧 OS の fallback tint にだけ使う)。
    static let surface: Color = {
        switch variant {
        case .claudeWarm: return Color(red: 0x32 / 255.0, green: 0x30 / 255.0, blue: 0x2B / 255.0)
        case .lightMinimal: return .white
        case .graphite: return Color(red: 0x1A / 255.0, green: 0x1E / 255.0, blue: 0x26 / 255.0)
        case .glassDark: return Color.white.opacity(0.06)
        case .glassLight: return Color.white.opacity(0.55)
        }
    }()

    /// カードの縁(暗い variant はこれが影の代わり)。
    static let surfaceStroke: Color = {
        switch variant {
        case .claudeWarm: return Color.white.opacity(0.07)
        case .lightMinimal: return Color.black.opacity(0.06)
        case .graphite: return Color.white.opacity(0.08)
        case .glassDark: return Color.white.opacity(0.12)
        case .glassLight: return Color.white.opacity(0.65)
        }
    }()

    /// カードの影(ライト系のみ。暗い地に影は描かれず費用だけ掛かる)。
    static let cardShadowOpacity: Double = {
        switch variant {
        case .lightMinimal: return 0.05
        case .glassLight: return 0.07
        case .claudeWarm, .graphite, .glassDark: return 0
        }
    }()

    /// 系全体の明暗。nil にしない — OS 設定で片側だけ検証されないまま出るのを防ぐ。
    static let colorScheme: ColorScheme = {
        switch variant {
        case .claudeWarm, .graphite, .glassDark: return .dark
        case .lightMinimal, .glassLight: return .light
        }
    }()

    /// Liquid Glass の面か(カードの描き方が fill から material/glass に替わる)。
    static let usesGlass: Bool = variant == .glassDark || variant == .glassLight

    /// カードの角丸(glass はひと回り丸く — Liquid Glass の意匠は丸みが強い)。
    static let cardRadius: CGFloat = usesGlass ? 20 : 14
}

/// 画面の地。glass では柔らかい光彩を敷く — 平色の上の glass は屈折する物が無く
/// ただの灰色に見えるので、地の光彩が glass を glass に見せる当の部品。
struct RCBackdrop: View {
    var body: some View {
        ZStack {
            RCTheme.background.ignoresSafeArea()
            if RCTheme.usesGlass {
                let glow: Double = RCTheme.colorScheme == .dark ? 0.32 : 0.38
                Circle().fill(RCTheme.accent.opacity(glow))
                    .frame(width: 420, height: 420).blur(radius: 110)
                    .offset(x: -130, y: -220)
                Circle().fill(RCTheme.violet.opacity(glow * 0.9))
                    .frame(width: 380, height: 380).blur(radius: 100)
                    .offset(x: 170, y: 60)
                Circle().fill(Color.cyan.opacity(glow * 0.45))
                    .frame(width: 380, height: 380).blur(radius: 120)
                    .offset(x: -40, y: 430)
            }
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Form / List を意匠の地に載せる(標準の不透明な地を退けて RCBackdrop を敷く)。
    /// 行の面は標準のまま — HIG の Liquid Glass は glass を**操作の層**に限り、
    /// 内容の面まで透かさない。ここでも glass はカード・帯・ボタンの側に置く。
    func rcThemedSurface() -> some View {
        scrollContentBackground(.hidden)
            .background(RCBackdrop())
    }
}

/// カード1枚の面。glass 系は iOS 26 の Liquid Glass(旧 OS は material に落ちる)、
/// それ以外は塗り + 縁。`emphasized` = choice 行(机側の Enter が承認/課金になり得る
/// 唯一の状態)だけ橙で名指しする。
struct RCCard: ViewModifier {
    var emphasized = false

    func body(content: Content) -> some View {
        if RCTheme.usesGlass {
            glassBody(content)
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: RCTheme.cardRadius, style: .continuous)
                        .fill(emphasized ? Color.orange.opacity(0.12) : RCTheme.surface)
                        .shadow(color: .black.opacity(RCTheme.cardShadowOpacity), radius: 6, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RCTheme.cardRadius, style: .continuous)
                        .stroke(emphasized ? Color.orange.opacity(0.45) : RCTheme.surfaceStroke, lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private func glassBody(_ content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(
                emphasized ? .regular.tint(Color.orange.opacity(0.30)) : .regular,
                in: .rect(cornerRadius: RCTheme.cardRadius)
            )
        } else {
            // iOS 17-25: 素の material。屈折は無いが「透ける面」までは同じ。
            content
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: RCTheme.cardRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: RCTheme.cardRadius, style: .continuous)
                        .stroke(emphasized ? Color.orange.opacity(0.45) : RCTheme.surfaceStroke, lineWidth: 1)
                )
        }
    }
}
