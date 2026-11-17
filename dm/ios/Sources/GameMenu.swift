// 全简体中文游戏内快捷设置与手柄管理菜单：分层标签页 + 卡片化 UI，同时支持触屏点击与纯物理手柄操作
import SwiftUI
import UIKit

var gameMenuModel: LauncherModel?   // 启动器设置模型（Launcher.swift）；为 nil 时仅显示手柄与布局

@_cdecl("dm_game_menu")
public func dmGameMenu() -> UnsafeMutableRawPointer {
    let menu = UIMenu(title: "", children: [])
    return Unmanaged.passRetained(menu).toOpaque()
}

private enum MenuTab: Int, CaseIterable {
    case display = 0
    case controls = 1
    case system = 2

    var title: String {
        switch self {
        case .display: return "画面与性能"
        case .controls: return "手柄与触控"
        case .system: return "系统"
        }
    }

    var icon: String {
        switch self {
        case .display: return "sparkles.tv"
        case .controls: return "gamecontroller.fill"
        case .system: return "gearshape.2.fill"
        }
    }
}

private struct MenuItem: Identifiable {
    let id: String
    let icon: String
    let section: String
    let title: String
    let valueText: String
    let subtitle: String?
    let badgeText: String?
    let disabled: Bool
    let action: (_ dir: Int) -> Void
}

private final class GameMenuState: ObservableObject {
    static let shared = GameMenuState()
    @Published var isOpen = false
    @Published var currentTab: MenuTab = .display
    @Published var selectedIndex = 0
    @Published var items: [MenuItem] = []
    @Published var statusNote: String = ""
    @Published var showMultiPadOptions = false

    private weak var hostVC: UIViewController?

    private func iconForEnv(_ env: String) -> String {
        switch env {
        case "DM_OPMODE": return "tv.and.mediabox"
        case "DM_QUALITY_PRESET": return "paintpalette.fill"
        case "DM_UE_RES_SCALE": return "viewfinder"
        case "DM_RENDER_SCALE": return "arrow.up.left.and.arrow.down.right"
        case "DM_PRESENT_UPSCALE": return "wand.and.stars"
        case "DM_FPS_TARGET": return "speedometer"
        case "DM_PICTURE_FIT": return "aspectratio"
        case "DM_SHOW_FPS": return "gauge.with.dots.needle.67percent"
        case "DM_TOUCH_HAPTICS": return "hand.tap.fill"
        case "DM_RUMBLE": return "waveform.path"
        default: return "slider.horizontal.3"
        }
    }

    private func appendSettingItem(_ s: Setting, model m: LauncherModel, sectionOverride: String, into list: inout [MenuItem]) {
        let now = m.values[s.env] ?? s.def
        let fixed = m.fixed.contains(s.env)
        let title = DMChineseUI.text(s.label)
        let icon = iconForEnv(s.env)
        let isLive = dm_setting_live(s.env, nil)
        let noteText = s.note.isEmpty ? nil : DMChineseUI.text(s.note)
        let sub = fixed ? "已由 env.txt 固定" : (!isLive ? (noteText ?? "修改后将在下次重新打开游戏时生效") : noteText)
        let badge = fixed ? nil : (isLive ? "实时" : "重开生效")

        if s.kind == "toggle" {
            let isOn = (now == s.onValue)
            list.append(MenuItem(
                id: "set.\(s.env)",
                icon: icon,
                section: sectionOverride,
                title: title,
                valueText: isOn ? "已开启" : "已关闭",
                subtitle: sub,
                badgeText: badge,
                disabled: fixed
            ) { _ in
                let next = isOn ? s.offValue : s.onValue
                m.choose(s, next)
                _ = dm_setting_live(s.env, next)
                self.statusNote = "已切换「\(title)」为\(isOn ? "关闭" : "开启")"
                self.rebuild()
            })
        } else if s.kind == "choice" {
            let opts = s.options ?? []
            let currentLabel = opts.first { $0[0] == now }?[1] ?? now
            list.append(MenuItem(
                id: "set.\(s.env)",
                icon: icon,
                section: sectionOverride,
                title: title,
                valueText: DMChineseUI.text(currentLabel),
                subtitle: sub,
                badgeText: badge,
                disabled: fixed || opts.count <= 1
            ) { dir in
                guard !opts.isEmpty else { return }
                let curPos = opts.firstIndex { $0[0] == now } ?? 0
                let step = dir < 0 ? -1 : 1
                let nextPos = (curPos + step + opts.count) % opts.count
                let nextVal = opts[nextPos][0]
                let nextLabel = DMChineseUI.text(opts[nextPos][1])
                m.choose(s, nextVal)
                _ = dm_setting_live(s.env, nextVal)
                self.statusNote = isLive
                    ? "已将「\(title)」调整为：\(nextLabel)"
                    : "已保存「\(title)」为 \(nextLabel)（重开游戏生效）"
                self.rebuild()
            })
        } else if s.kind == "range", let lo = s.min, let hi = s.max {
            let cur = Double(now) ?? (Double(s.def) ?? lo)
            let label = m.rangeLabel(s, cur)
            list.append(MenuItem(
                id: "set.\(s.env)",
                icon: icon,
                section: sectionOverride,
                title: title,
                valueText: label,
                subtitle: sub,
                badgeText: badge,
                disabled: fixed
            ) { dir in
                let jump = (s.env == "DM_RENDER_SCALE") ? 0.25 : (s.step ?? 0.1)
                let delta = (dir < 0 ? -jump : jump)
                var next = cur + delta
                if next > hi + 1e-6 { next = lo }
                if next < lo - 1e-6 { next = hi }
                next = (next / jump).rounded() * jump
                next = min(hi, max(lo, next))
                let nextStr = String(format: "%.2f", next)
                m.choose(s, nextStr)
                _ = dm_setting_live(s.env, nextStr)
                let nextLabel = m.rangeLabel(s, next)
                self.statusNote = isLive
                    ? "已将「\(title)」调整为：\(nextLabel)"
                    : "已保存「\(title)」为 \(nextLabel)（重开游戏生效）"
                self.rebuild()
            })
        }
    }

    func selectTab(_ tab: MenuTab) {
        currentTab = tab
        selectedIndex = 0
        rebuild()
    }

    func rebuild() {
        var list: [MenuItem] = []

        switch currentTab {
        case .display:
            if let m = gameMenuModel {
                for section in m.sections where section == "Game" || section == "Performance" {
                    for s in m.rows(in: section) where (s.kind == "choice" || s.kind == "toggle" || s.kind == "range") && (dm_setting_live(s.env, nil) || s.env == "DM_RENDER_SCALE") {
                        let secTitle = section == "Performance" ? "性能监控" : "显示与性能调节"
                        appendSettingItem(s, model: m, sectionOverride: secTitle, into: &list)
                    }
                }
            }
            if list.isEmpty {
                list.append(MenuItem(
                    id: "disp.empty",
                    icon: "info.circle",
                    section: "显示与性能调节",
                    title: "暂无可实时切换的画面项",
                    valueText: "请在启动页设置",
                    subtitle: nil,
                    badgeText: nil,
                    disabled: true
                ) { _ in })
            }

        case .controls:
            // 虚拟手柄布局
            let layoutNames = ["2D（简洁）", "3D（完整）", "触屏"]
            let offeredLayouts = (0..<3).filter { dm_pad_layout_offered(Int32($0)) }
            let curLayout = Int(dm_pad_layout())
            let curLayoutName = (0..<layoutNames.count).contains(curLayout) ? layoutNames[curLayout] : "2D（简洁）"
            list.append(MenuItem(
                id: "pad.layout",
                icon: "rectangle.on.rectangle.angled",
                section: "触控与虚拟按键",
                title: "虚拟手柄布局",
                valueText: curLayoutName,
                subtitle: "切换屏幕虚拟按键样式或纯触屏模式",
                badgeText: "实时",
                disabled: offeredLayouts.count <= 1
            ) { dir in
                guard !offeredLayouts.isEmpty else { return }
                let curPos = offeredLayouts.firstIndex(of: curLayout) ?? 0
                let step = dir < 0 ? -1 : 1
                let nextPos = (curPos + step + offeredLayouts.count) % offeredLayouts.count
                dm_pad_layout_set(Int32(offeredLayouts[nextPos]))
                self.statusNote = "已切换虚拟手柄布局"
                self.rebuild()
            })

            if let m = gameMenuModel {
                for s in m.rows(in: "Controls") where (s.kind == "choice" || s.kind == "toggle") && dm_setting_live(s.env, nil) {
                    appendSettingItem(s, model: m, sectionOverride: "震动与反馈", into: &list)
                }
            }

            let padCount = Int(dm_pad_connected_count())
            let multiPadVisible = (padCount >= 2) || showMultiPadOptions
            list.append(MenuItem(
                id: "pad.multi.toggle",
                icon: "person.2.fill",
                section: "多人手柄管理",
                title: multiPadVisible ? "收起多人 1P / 2P 分配" : "多人 1P / 2P 分配选项",
                valueText: padCount == 0 ? "未连手柄" : "已连 \(padCount) 个",
                subtitle: padCount <= 1 ? "单人游玩默认自动识别 1P，通常无需调整" : "检测到多个手柄，可在此切换 1P 主手柄",
                badgeText: multiPadVisible ? "展开中" : "折叠",
                disabled: false
            ) { _ in
                self.showMultiPadOptions.toggle()
                self.rebuild()
            })

            if multiPadVisible {
                let mergeOn = dm_pad_get_merge()
                list.append(MenuItem(
                    id: "pad.merge",
                    icon: "arrow.triangle.merge",
                    section: "多人手柄管理",
                    title: "所有手柄合并控制 1P",
                    valueText: mergeOn ? "已开启" : "已关闭",
                    subtitle: mergeOn ? "任意手柄都直接控制 1P" : "每个手柄独立对应 1P / 2P",
                    badgeText: nil,
                    disabled: false
                ) { _ in
                    dm_pad_set_merge(!dm_pad_get_merge())
                    self.statusNote = dm_pad_get_merge() ? "已开启合并控制：所有手柄均控制 1P" : "已切换为独立玩家模式"
                    self.rebuild()
                })

                list.append(MenuItem(
                    id: "pad.reclaim",
                    icon: "arrow.clockwise",
                    section: "多人手柄管理",
                    title: "重新分配 1P / 2P 顺序",
                    valueText: dm_pad_get_press_to_join() ? "等待按键…" : "按任意键认领",
                    subtitle: "清空绑定后，先按任意键的手柄成为 1P",
                    badgeText: nil,
                    disabled: false
                ) { _ in
                    dm_pad_reclaim_order()
                    self.statusNote = "已重置手柄顺序：关闭菜单后按任意键成为 1P"
                    self.rebuild()
                })

                for idx in 0..<padCount {
                    let cName = dm_pad_connected_name(Int32(idx)).map { String(cString: $0) } ?? "手柄"
                    let player = Int(dm_pad_connected_player(Int32(idx)))
                    let roleText: String
                    if mergeOn {
                        roleText = "已合并为 1P"
                    } else if player == 1 {
                        roleText = "当前 1P（主手柄）"
                    } else if player > 1 {
                        roleText = "当前 \(player)P · 设为主手柄"
                    } else {
                        roleText = "未分配 · 设为主手柄"
                    }
                    list.append(MenuItem(
                        id: "pad.dev.\(idx)",
                        icon: "gamecontroller",
                        section: "多人手柄管理",
                        title: "手柄 \(idx + 1)：\(cName)",
                        valueText: roleText,
                        subtitle: nil,
                        badgeText: nil,
                        disabled: mergeOn || player == 1
                    ) { _ in
                        dm_pad_set_as_p1(Int32(idx))
                        self.statusNote = "已将「\(cName)」设为 1P 主手柄"
                        self.rebuild()
                    })
                }
            }

        case .system:
            let padCount = Int(dm_pad_connected_count())
            list.append(MenuItem(
                id: "sys.info",
                icon: "cpu",
                section: "运行状态",
                title: "外接物理手柄",
                valueText: padCount == 0 ? "未连接" : "已连接 \(padCount) 个",
                subtitle: "设置更改会自动保存；需重启生效的高级项请在启动页修改",
                badgeText: nil,
                disabled: true
            ) { _ in })

            list.append(MenuItem(
                id: "menu.close",
                icon: "play.fill",
                section: "快捷操作",
                title: "返回游戏",
                valueText: "按 B 键关闭",
                subtitle: nil,
                badgeText: nil,
                disabled: false
            ) { _ in
                self.close()
            })
        }

        self.items = list
        if selectedIndex >= list.count { selectedIndex = max(0, list.count - 1) }
    }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        guard !isOpen else { return }
        guard let win = keyWindow(), let root = win.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }

        statusNote = ""
        currentTab = .display
        showMultiPadOptions = false
        rebuild()
        selectedIndex = 0
        isOpen = true
        dm_game_menu_set_open(true)

        let vc = UIHostingController(rootView: InGameMenuOverlay(state: self))
        vc.modalPresentationStyle = .overFullScreen
        vc.modalTransitionStyle = .crossDissolve
        vc.view.backgroundColor = .clear
        top.present(vc, animated: false)
        hostVC = vc
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        dm_game_menu_set_open(false)
        hostVC?.dismiss(animated: false)
        hostVC = nil
    }

    func handleNav(dirX: Int, dirY: Int, a: Bool, b: Bool) {
        guard isOpen else { return }
        if b {
            close()
            return
        }
        if dirY != 0 && !items.isEmpty {
            let count = items.count
            selectedIndex = (selectedIndex + dirY + count) % count
        }
        if dirX != 0 && selectedIndex >= 0 && selectedIndex < items.count {
            let item = items[selectedIndex]
            if item.disabled {
                let all = MenuTab.allCases
                let nextIdx = (currentTab.rawValue + (dirX > 0 ? 1 : -1) + all.count) % all.count
                selectTab(all[nextIdx])
            } else {
                item.action(dirX)
            }
        }
        if a && selectedIndex >= 0 && selectedIndex < items.count {
            let item = items[selectedIndex]
            if !item.disabled { item.action(1) }
        }
    }

    private func keyWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            if let kw = ws.windows.first(where: { $0.isKeyWindow }) { return kw }
            if let first = ws.windows.first { return first }
        }
        return nil
    }
}

private struct InGameMenuOverlay: View {
    @ObservedObject var state: GameMenuState

    private var groupedSections: [(String, [(Int, MenuItem)])] {
        var result: [(String, [(Int, MenuItem)])] = []
        var map: [String: Int] = [:]
        for (idx, item) in state.items.enumerated() {
            if let pos = map[item.section] {
                result[pos].1.append((idx, item))
            } else {
                map[item.section] = result.count
                result.append((item.section, [(idx, item)]))
            }
        }
        return result
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.68)
                .ignoresSafeArea()
                .onTapGesture { state.close() }

            VStack(spacing: 14) {
                // 标题栏
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11)
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 0.95, green: 0.75, blue: 0.30), Color(red: 0.72, green: 0.48, blue: 0.14)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 38, height: 38)
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.black.opacity(0.88))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("游戏快捷设置")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                        Text("手柄操作：十字键/左摇杆选择 · 左右键切换选项 · A 确认 · B 返回游戏")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.68))
                    }
                    Spacer()
                    Button {
                        state.close()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                        }
                        .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(.horizontal, 4)

                // 分组标签栏
                HStack(spacing: 8) {
                    ForEach(MenuTab.allCases, id: \.rawValue) { tab in
                        let active = (state.currentTab == tab)
                        Button {
                            state.selectTab(tab)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: tab.icon)
                                    .font(.caption.weight(.semibold))
                                Text(tab.title)
                                    .font(.subheadline.weight(active ? .bold : .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .foregroundStyle(active ? Color.black.opacity(0.9) : Color.white.opacity(0.78))
                            .background(
                                RoundedRectangle(cornerRadius: 11)
                                    .fill(
                                        active
                                            ? LinearGradient(
                                                colors: [Color(red: 0.96, green: 0.78, blue: 0.34), Color(red: 0.85, green: 0.62, blue: 0.20)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                            : LinearGradient(
                                                colors: [Color.white.opacity(0.08), Color.white.opacity(0.05)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !state.statusNote.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(state.statusNote)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                }

                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(groupedSections, id: \.0) { secTitle, rows in
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(secTitle)
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(Color(red: 0.95, green: 0.80, blue: 0.42).opacity(0.9))
                                        .padding(.horizontal, 4)

                                    VStack(spacing: 6) {
                                        ForEach(rows, id: \.0) { idx, item in
                                            let selected = (idx == state.selectedIndex)
                                            Button {
                                                state.selectedIndex = idx
                                                if !item.disabled { item.action(1) }
                                            } label: {
                                                HStack(spacing: 12) {
                                                    Image(systemName: item.icon)
                                                        .font(.system(size: 15, weight: .semibold))
                                                        .foregroundStyle(selected ? Color(red: 0.98, green: 0.80, blue: 0.35) : .white.opacity(0.72))
                                                        .frame(width: 30, height: 30)
                                                        .background(
                                                            RoundedRectangle(cornerRadius: 8)
                                                                .fill(selected ? Color(red: 0.95, green: 0.75, blue: 0.30).opacity(0.18) : Color.white.opacity(0.08))
                                                        )

                                                    VStack(alignment: .leading, spacing: 2) {
                                                        HStack(spacing: 6) {
                                                            Text(item.title)
                                                                .font(.subheadline.weight(.semibold))
                                                                .foregroundStyle(item.disabled ? .white.opacity(0.45) : .white)
                                                            if let badge = item.badgeText {
                                                                Text(badge)
                                                                    .font(.system(size: 10, weight: .bold))
                                                                    .foregroundStyle(Color(red: 0.45, green: 0.92, blue: 0.65))
                                                                    .padding(.horizontal, 6)
                                                                    .padding(.vertical, 2)
                                                                    .background(Color.green.opacity(0.16), in: Capsule())
                                                            }
                                                        }
                                                        if let sub = item.subtitle, !sub.isEmpty {
                                                            Text(sub)
                                                                .font(.caption2)
                                                                .foregroundStyle(.white.opacity(0.58))
                                                                .lineLimit(2)
                                                        }
                                                    }
                                                    Spacer()
                                                    Text(item.valueText)
                                                        .font(.caption.weight(.bold))
                                                        .foregroundStyle(
                                                            selected
                                                                ? Color(red: 0.98, green: 0.82, blue: 0.35)
                                                                : (item.disabled ? .white.opacity(0.45) : Color.cyan)
                                                        )
                                                        .padding(.horizontal, 10)
                                                        .padding(.vertical, 5)
                                                        .background(
                                                            Capsule()
                                                                .fill(selected ? Color(red: 0.98, green: 0.80, blue: 0.35).opacity(0.18) : Color.white.opacity(0.08))
                                                        )
                                                }
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 10)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 12)
                                                        .fill(selected ? Color.white.opacity(0.16) : Color.white.opacity(0.06))
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 12)
                                                        .stroke(selected ? Color(red: 0.96, green: 0.78, blue: 0.34).opacity(0.9) : Color.white.opacity(0.06), lineWidth: selected ? 1.5 : 0.8)
                                                )
                                            }
                                            .buttonStyle(.plain)
                                            .id(idx)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onChange(of: state.selectedIndex) { newIdx in
                        withAnimation(.easeInOut(duration: 0.12)) {
                            proxy.scrollTo(newIdx, anchor: .center)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 620, maxHeight: 540)
            .background(
                ZStack {
                    Color(red: 0.08, green: 0.09, blue: 0.12).opacity(0.88)
                    Rectangle().fill(.ultraThinMaterial)
                }
                .clipShape(RoundedRectangle(cornerRadius: 22))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .stroke(
                        LinearGradient(
                            colors: [Color(red: 0.95, green: 0.78, blue: 0.38).opacity(0.45), Color.white.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.2
                    )
            )
            .shadow(color: .black.opacity(0.55), radius: 28, y: 12)
            .padding(20)
            .preferredColorScheme(.dark)
        }
    }
}

@_cdecl("dm_game_menu_toggle")
public func dmGameMenuToggle() {
    DispatchQueue.main.async { GameMenuState.shared.toggle() }
}

@_cdecl("dm_game_menu_nav")
public func dmGameMenuNav(_ dirX: Int32, _ dirY: Int32, _ a: Bool, _ b: Bool) {
    DispatchQueue.main.async {
        GameMenuState.shared.handleNav(dirX: Int(dirX), dirY: Int(dirY), a: a, b: b)
    }
}
