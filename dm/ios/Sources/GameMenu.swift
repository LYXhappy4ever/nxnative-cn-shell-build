// 全简体中文游戏内设置与手柄管理菜单：同时支持触屏点击与纯物理手柄操作（十字键/左摇杆移动，A 确认，B 关闭，-/+ 或 L3+R3 呼出）
import SwiftUI
import UIKit

var gameMenuModel: LauncherModel?   // 启动器设置模型（Launcher.swift）；为 nil 时仅显示手柄分配与布局

@_cdecl("dm_game_menu")
public func dmGameMenu() -> UnsafeMutableRawPointer {
    let menu = UIMenu(title: "", children: [])
    return Unmanaged.passRetained(menu).toOpaque()
}

private struct MenuItem: Identifiable {
    let id: String
    let section: String
    let title: String
    let valueText: String
    let subtitle: String?
    let disabled: Bool
    let action: (_ dir: Int) -> Void
}

private final class GameMenuState: ObservableObject {
    static let shared = GameMenuState()
    @Published var isOpen = false
    @Published var selectedIndex = 0
    @Published var items: [MenuItem] = []
    @Published var statusNote: String = ""

    private weak var hostVC: UIViewController?

    func rebuild() {
        var list: [MenuItem] = []

        // 1. 手柄与玩家分配
        let mergeOn = dm_pad_get_merge()
        list.append(MenuItem(
            id: "pad.merge",
            section: "手柄与玩家分配",
            title: "所有手柄合并控制 1P",
            valueText: mergeOn ? "开启" : "关闭",
            subtitle: mergeOn ? "任意手柄都直接控制 1P" : "每个手柄独立对应 1P / 2P（适合双人游玩）",
            disabled: false
        ) { _ in
            dm_pad_set_merge(!dm_pad_get_merge())
            self.statusNote = dm_pad_get_merge() ? "已开启合并控制：所有手柄均控制 1P" : "已切换为独立玩家模式"
            self.rebuild()
        })

        list.append(MenuItem(
            id: "pad.reclaim",
            section: "手柄与玩家分配",
            title: "重新分配 1P / 2P 顺序",
            valueText: dm_pad_get_press_to_join() ? "等待按键…" : "按任意键认领",
            subtitle: "清空当前绑定，先按任意键的手柄成为 1P，第二个成为 2P",
            disabled: false
        ) { _ in
            dm_pad_reclaim_order()
            self.statusNote = "已重置手柄顺序：关闭菜单后，先按任意键的手柄将成为 1P"
            self.rebuild()
        })

        let padCount = Int(dm_pad_connected_count())
        if padCount == 0 {
            list.append(MenuItem(
                id: "pad.none",
                section: "手柄与玩家分配",
                title: "未检测到蓝牙/有线物理手柄",
                valueText: "使用屏幕虚拟手柄",
                subtitle: nil,
                disabled: true
            ) { _ in })
        } else {
            for idx in 0..<padCount {
                let cName = dm_pad_connected_name(Int32(idx)).map { String(cString: $0) } ?? "手柄"
                let player = Int(dm_pad_connected_player(Int32(idx)))
                let roleText: String
                if mergeOn {
                    roleText = "已合并为 1P"
                } else if player == 1 {
                    roleText = "当前 1P（主手柄）"
                } else if player > 1 {
                    roleText = "当前 \(player)P · 点按设为主手柄 1P"
                } else {
                    roleText = "未分配 · 点按设为主手柄 1P"
                }
                list.append(MenuItem(
                    id: "pad.dev.\(idx)",
                    section: "手柄与玩家分配",
                    title: "手柄 \(idx + 1)：\(cName)",
                    valueText: roleText,
                    subtitle: nil,
                    disabled: mergeOn || player == 1
                ) { _ in
                    dm_pad_set_as_p1(Int32(idx))
                    self.statusNote = "已将「\(cName)」设为 1P 主手柄"
                    self.rebuild()
                })
            }
        }

        // 触屏虚拟手柄布局
        let layoutNames = ["2D（简洁）", "3D（完整）", "触屏"]
        let offeredLayouts = (0..<3).filter { dm_pad_layout_offered(Int32($0)) }
        let curLayout = Int(dm_pad_layout())
        let curLayoutName = (0..<layoutNames.count).contains(curLayout) ? layoutNames[curLayout] : "2D（简洁）"
        list.append(MenuItem(
            id: "pad.layout",
            section: "手柄与玩家分配",
            title: "虚拟手柄布局",
            valueText: curLayoutName,
            subtitle: nil,
            disabled: offeredLayouts.count <= 1
        ) { dir in
            guard !offeredLayouts.isEmpty else { return }
            let curPos = offeredLayouts.firstIndex(of: curLayout) ?? 0
            let step = dir < 0 ? -1 : 1
            let nextPos = (curPos + step + offeredLayouts.count) % offeredLayouts.count
            dm_pad_layout_set(Int32(offeredLayouts[nextPos]))
            self.rebuild()
        })

        // 2. 游戏与运行设置（实时生效）
        if let m = gameMenuModel {
            for section in m.sections {
                for s in m.rows(in: section) where (s.kind == "choice" || s.kind == "toggle") && dm_setting_live(s.env, nil) {
                    let now = m.values[s.env] ?? s.def
                    let fixed = m.fixed.contains(s.env)
                    let secName = DMChineseUI.text(section)
                    let title = DMChineseUI.text(s.label)
                    if s.kind == "toggle" {
                        let isOn = (now == s.onValue)
                        list.append(MenuItem(
                            id: "set.\(s.env)",
                            section: secName,
                            title: title,
                            valueText: isOn ? "开启" : "关闭",
                            subtitle: fixed ? "已由 env.txt 固定" : nil,
                            disabled: fixed
                        ) { _ in
                            let next = isOn ? s.offValue : s.onValue
                            m.choose(s, next)
                            _ = dm_setting_live(s.env, next)
                            self.rebuild()
                        })
                    } else {
                        let opts = s.options ?? []
                        let currentLabel = opts.first { $0[0] == now }?[1] ?? now
                        list.append(MenuItem(
                            id: "set.\(s.env)",
                            section: secName,
                            title: title,
                            valueText: DMChineseUI.text(currentLabel),
                            subtitle: fixed ? "已由 env.txt 固定" : nil,
                            disabled: fixed || opts.count <= 1
                        ) { dir in
                            guard !opts.isEmpty else { return }
                            let curPos = opts.firstIndex { $0[0] == now } ?? 0
                            let step = dir < 0 ? -1 : 1
                            let nextPos = (curPos + step + opts.count) % opts.count
                            let nextVal = opts[nextPos][0]
                            m.choose(s, nextVal)
                            _ = dm_setting_live(s.env, nextVal)
                            self.rebuild()
                        })
                    }
                }
            }
        }

        list.append(MenuItem(
            id: "menu.close",
            section: "操作",
            title: "关闭菜单并返回游戏",
            valueText: "按 B 键",
            subtitle: gameMenuModel != nil ? "更多需重启生效的设置请在启动界面修改" : nil,
            disabled: false
        ) { _ in
            self.close()
        })

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
            if !item.disabled { item.action(dirX) }
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
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .onTapGesture { state.close() }

            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("快捷设置与手柄管理")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                        Text("手柄操作：方向键/左摇杆选择 · A 确认/切换 · B 关闭（快捷键：-/+ 或 L3+R3）")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    Spacer()
                    Button {
                        state.close()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(.horizontal, 4)

                if !state.statusNote.isEmpty {
                    Text(state.statusNote)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(groupedSections, id: \.0) { secTitle, rows in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(secTitle)
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white.opacity(0.65))
                                        .padding(.horizontal, 4)

                                    VStack(spacing: 4) {
                                        ForEach(rows, id: \.0) { idx, item in
                                            let selected = (idx == state.selectedIndex)
                                            Button {
                                                state.selectedIndex = idx
                                                if !item.disabled { item.action(1) }
                                            } label: {
                                                HStack(spacing: 10) {
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text(item.title)
                                                            .font(.subheadline.weight(.semibold))
                                                            .foregroundStyle(item.disabled ? .white.opacity(0.45) : .white)
                                                        if let sub = item.subtitle, !sub.isEmpty {
                                                            Text(sub)
                                                                .font(.caption2)
                                                                .foregroundStyle(.white.opacity(0.6))
                                                        }
                                                    }
                                                    Spacer()
                                                    Text(item.valueText)
                                                        .font(.subheadline.weight(.medium))
                                                        .foregroundStyle(selected ? .yellow : (item.disabled ? .white.opacity(0.45) : .cyan))
                                                }
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 9)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 10)
                                                        .fill(selected ? Color.white.opacity(0.22) : Color.white.opacity(0.08))
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 10)
                                                        .stroke(selected ? Color.yellow.opacity(0.95) : Color.clear, lineWidth: 1.5)
                                                )
                                            }
                                            .buttonStyle(.plain)
                                            .id(idx)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: state.selectedIndex) { newIdx in
                        withAnimation(.easeInOut(duration: 0.12)) {
                            proxy.scrollTo(newIdx, anchor: .center)
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: 560, maxHeight: 540)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.18), lineWidth: 1))
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
