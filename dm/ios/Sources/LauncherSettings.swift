// Launcher settings, validation and persistence. Shared by the iOS UI, the Mac app's settings window (dm/mac/Launcher.swift) and the native storage regression test.
import Foundation
import Combine

struct Setting: Decodable, Identifiable {
    let env, kind, label, note, def: String
    let section: String?   // heading on the settings screen; absent in older bundles
    let needs: String?     // "<VAR>=<value>": a sub-setting, drawn only while that setting has that value
    let level: String?     // "basic": shown first (the Mac window's Basic settings); any other or none: Advanced settings. The iPhone keeps one list
    let base: Base?        // render scale: the 3D views' size at 1.0, docked and handheld, for the size in pixels (the Mac window)
    struct Base: Decodable { let docked, handheld: [Int] }
    let options: [[String]]?   // choice: [value, label]
    let min, max, step: Double?   // range
    let on, off: String?   // toggle: the values the variable takes (1 / 0 when not given)
    var id: String { env }
    var sectionTitle: String { section ?? "Game" }
    var basic: Bool { level == "basic" }
    var onValue: String { on ?? "1" }
    var offValue: String { off ?? "0" }
    func isDefault(_ v: String) -> Bool {   // a range compares as numbers (a slider writes 1.00 for 1.0)
        kind == "range" ? abs((Double(v) ?? .nan) - (Double(def) ?? .nan)) < 1e-6 : v == def
    }
    func accepts(_ v: String) -> Bool {   // a saved choice the game still offers
        switch kind {
        case "choice": return options?.contains { $0[0] == v } ?? false
        case "range":
            guard !v.contains(where: { $0 == "x" || $0 == "X" }), let n = Double(v), n.isFinite, let lo = min, let hi = max else { return false }   // no hex: launcher.c's check agrees
            return n >= lo && n <= hi
        case "toggle": return v == onValue || v == offValue
        default: return true
        }
    }
    enum CodingKeys: String, CodingKey { case env, kind, label, note, def = "default", section, needs, level, base, options, min, max, step, on, off }
}
struct SettingsFile: Decodable { let settings: [Setting] }

final class LauncherModel: ObservableObject {
    let settings: [Setting]
    let fixed: Set<String>      // set by an env file or by the launch environment: shown, not changed
    let fromLaunch: Set<String>   // of those, the ones the launch environment set (a front end's launch overrides, Xcode; DM_ENV_LAUNCH_KEYS from launcher.c or main.m)
    let ignoreSaved: Bool   // DM_SAVED_CHOICES=0: start from the defaults, and leave the saved choices as they are
    @Published var values: [String: String] = [:]

    private let defaults: UserDefaults
    private let prefix: String   // "game.<title ID>." for an app that holds several games: one game's choices never reach another's

    init(_ settings: [Setting], defaults: UserDefaults = .standard, prefix: String = "") {
        self.defaults = defaults
        self.prefix = prefix.isEmpty ? "" : prefix + "."

        self.settings = settings
        let env = ProcessInfo.processInfo.environment
        fromLaunch = Set((env["DM_ENV_LAUNCH_KEYS"] ?? "").split(separator: " ").map(String.init))
        fixed = fromLaunch.union((env["DM_ENV_FILE_KEYS"] ?? "").split(separator: " ").map(String.init))
        ignoreSaved = env["DM_SAVED_CHOICES"] == "0"
        if ignoreSaved { fputs("launcher: saved choices ignored (DM_SAVED_CHOICES=0)\n", stderr) }
        for s in settings {
            if fixed.contains(s.env), let v = env[s.env] { values[s.env] = v; continue }
            let saved = ignoreSaved ? nil : defaults.object(forKey: key(s.env)) as? String   // a string, as launcher.c reads it: not string(forKey:), which turns a number into one
            values[s.env] = saved.flatMap { s.accepts($0) ? $0 : nil } ?? s.def   // a saved choice the game no longer offers: its default
        }
    }

    var sections: [String] {
        settings.reduce(into: []) { if !$0.contains($1.sectionTitle) { $0.append($1.sectionTitle) } }
    }
    // A row with "needs" is a sub-setting of the row it names: drawn only while that setting has that value, so a
    // setting that cannot do anything is not offered (an upscaler's detail with the upscaler off, rumble strength
    // with rumble off). A row naming a setting this game does not have stays drawn, as it has nothing to hide behind
    func visible(_ s: Setting) -> Bool {
        guard let n = s.needs, let eq = n.firstIndex(of: "=") else { return true }
        let key = String(n[n.startIndex..<eq]), want = String(n[n.index(after: eq)...])
        guard let v = values[key] else { return true }
        return v == want
    }
    func rows(in section: String) -> [Setting] { settings.filter { $0.sectionTitle == section && visible($0) } }
    // The Mac window: Basic settings first, then Advanced settings, each in the list's sections and order
    func sections(basic: Bool) -> [String] {
        settings.filter { $0.basic == basic }.reduce(into: []) { if !$0.contains($1.sectionTitle) { $0.append($1.sectionTitle) } }
    }
    func rows(in section: String, basic: Bool) -> [Setting] { rows(in: section).filter { $0.basic == basic } }
    // A range's label: its percentage, with the size in pixels for the chosen console mode when the list has the base size (the render scale)
    func rangeLabel(_ s: Setting, _ v: Double) -> String {
        let p = "\(Int((v * 100).rounded())) %"
        guard let b = s.base else { return p }
        let size = (values["DM_OPMODE"] ?? "1") == "0" ? b.handheld : b.docked
        guard size.count == 2 else { return p }
        return "\(Int((Double(size[0]) * v).rounded())) × \(Int((Double(size[1]) * v).rounded())) (\(p))"
    }
    var changed: Bool { settings.contains { !fixed.contains($0.env) && !$0.isDefault(values[$0.env] ?? $0.def) } }

    // Reset every launcher choice to the game's defaults on the screen; values fixed by an env file or at launch stay. The saved choices are forgotten when Play applies
    // the defaults (apply() keeps no default), so Quit after Reset keeps them, and a choice a launch override hides is kept
    func reset() {
        for s in settings where !fixed.contains(s.env) { values[s.env] = s.def }
        fputs("launcher: settings reset to the game's defaults\n", stderr)
    }

    // Before the game starts: every setting not set by an env file goes into the environment (DM_LANG replaces the packed language main.m set as a default). Only a choice that
    // differs from the game's default is stored: a setting the player left at its default follows the defaults of a later build (the settings it was tested with)
    // Saves what this screen shows, without putting it in the environment: the library's own settings page uses it, and the environment is
    // set by applySaved() when the game starts -- after main.m has read the game's dm/env.txt, whose values must win.
    func save() {
        for s in settings where !fixed.contains(s.env) { store(s, values[s.env] ?? s.def) }
    }

    func apply() {
        for s in settings {
            let v = values[s.env] ?? s.def
            if fixed.contains(s.env) { fputs("launcher: \(s.env) kept at \(v) (\(fromLaunch.contains(s.env) ? "launch environment" : "env file"))\n", stderr); continue }
            store(s, v)
            setenv(s.env, v, 1); fputs("launcher: \(s.env)=\(v)\(s.isDefault(v) ? "" : " (changed)")\n", stderr)
        }
    }
    // The key a choice is saved under: "<prefix>launcher.<env>". Empty prefix = the one-game app, the key it always used.
    func key(_ env: String) -> String { prefix + "launcher." + env }
    private func store(_ s: Setting, _ v: String) {
        if !ignoreSaved { if s.isDefault(v) { defaults.removeObject(forKey: key(s.env)) } else { defaults.set(v, forKey: key(s.env)) } }
    }

    // A choice made while the game runs (the iOS in-game menu, GameMenu.swift): saved as Play saves it, so the settings screen shows it at the next start, and put in the environment.
    // A value an env file or the launch fixed stays
    func choose(_ s: Setting, _ v: String) {
        guard !fixed.contains(s.env), s.accepts(v) else { return }
        values[s.env] = v; store(s, v); setenv(s.env, v, 1)
        fputs("launcher: \(s.env)=\(v) (in-game menu)\n", stderr)
    }

    // DM_LAUNCHER=0: no screen, but the saved choices still apply (only DM_SAVED_CHOICES=0 ignores them); nothing is written
    func applySaved() {
        for s in settings where !fixed.contains(s.env) {
            let v = values[s.env] ?? s.def
            if !s.isDefault(v) { setenv(s.env, v, 1); fputs("launcher: \(s.env)=\(v) (saved choice)\n", stderr) }
        }
    }
}

// 全量简体中文 UI 标签映射；环境变量与配置值本身保持原样
enum DMChineseUI {
    private static let labels: [String: String] = [
        "Game": "游戏",
        "Controls": "操作",
        "Performance": "性能",
        "Frame rate": "目标帧率",
        "30 fps": "30 帧",
        "60 fps": "60 帧",
        "120 fps": "120 帧",
        "Dynamic resolution": "动态分辨率",
        "Lets the game lower its resolution under load. Turn off to keep full resolution for the selected console mode.": "负载高时允许游戏自动降低分辨率；关闭则保持所选运行模式的完整分辨率。",
        "Render scale": "渲染分辨率倍率",
        "Console mode": "运行模式",
        "Docked": "主机模式（高画质/高负载）",
        "Handheld": "掌机模式（较省电）",
        "Upscaling": "画面放大处理",
        "Uses more GPU time and can increase heat.": "会增加图形处理器负担，设备可能更热。",
        "Standard": "标准",
        "MetalFX": "MetalFX（苹果画面增强）",
        "Game's upscaler": "游戏自带画面放大",
        "Game's own": "使用游戏自带方式",
        "Game language": "游戏语言",
        "Display mode": "显示模式",
        "Window": "窗口",
        "Fullscreen": "全屏",
        "Picture": "画面显示范围",
        "Fill crops the game's 16:9 picture to cover the screen. Health bars, subtitles or maps near the edges can be cut off. A full-screen picture without cropping needs a patch for each game.": "铺满屏幕会裁剪 16:9 画面边缘，可能遮挡血条、字幕或地图；想完整显示请选“适应屏幕”。",
        "Fit": "适应屏幕（完整画面）",
        "Fill": "铺满屏幕（可能裁剪）",
        "Frame-rate counter": "显示帧率",
        "Touch feedback": "触摸震动反馈",
        "Game rumble": "手柄震动",
        "Rumble strength": "震动强度",
        "Rumble cutoff": "震动触发阈值",
        "Press a button to join": "按任意键加入玩家槽位",
        "Switch 2 controllers": "Switch 2 手柄",
        "Picture shape": "画面比例",
        "Match screen": "自适应屏幕比例",
        "iPhone Duo screen (1.43:1)": "双屏比例 (1.43:1)",
        "16:9 (Switch)": "16:9 (Switch 原生)",
        "Renders about a quarter more pixels: a little slower and warmer.": "会多渲染约四分之一的像素，速度略慢且发热略高。",
        "Frame buffering": "帧缓冲",
        "Up to one frame more display latency.": "最多可能增加 1 帧显示延迟。",
        "Metal 4 pipelines": "Metal 4 管线缓存",
        "Keeps a pipeline archive; uses more memory.": "保留管线缓存档案，会占用更多运行内存。",
        "Pipeline prebuild": "管线预编译",
        "The first start waits a few minutes for it, once.": "首次启动会一次性等待几分钟完成编译。",
        "Encode thread": "独立编码线程",
        "Hold frames when late": "超时帧等待",
        "Performance HUD": "显示 Metal 性能面板",
        "Set at launch": "已由启动参数固定",
        "Set by an env file": "已由 env.txt 固定",
        "Controller layout": "虚拟手柄布局",
        "2D": "2D（简洁）",
        "3D": "3D（完整）",
        "Tap": "触屏",
        "More settings on the start screen": "更多设置请在启动界面修改",
        "English": "英语",
        "Japanese": "日语",
        "French": "法语",
        "German": "德语",
        "Spanish": "西班牙语",
        "Italian": "意大利语",
        "Dutch": "荷兰语",
        "Portuguese": "葡萄牙语",
        "Russian": "俄语",
        "Korean": "韩语",
        "Simplified Chinese": "简体中文",
        "Traditional Chinese": "繁体中文"
    ]
    static func text(_ english: String) -> String { labels[english] ?? english }
}
