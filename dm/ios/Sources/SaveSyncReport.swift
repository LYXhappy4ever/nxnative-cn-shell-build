// Cloud saves, before the start: the host's comparison of this device's save with the cloud's (dm/host/save_sync.h save_sync_report) and what the launcher does with it.
// Shared by the iPhone launcher (Launcher.swift) and the Mac's (dm/mac/Launcher.swift; dm/mac/pack_app.py swift_sources); each calls the C function its own way and asks
// with its own dialogs. The answer goes to the host as DM_SAVE_SYNC_CHOICE (docs/frontends.md, The cloud saves folder).
import Foundation

struct SaveSyncReport {
    /// How long the cloud's file may take to come (an iCloud download) before the launcher says it did not; the player can play without it meanwhile
    static let waitMs: Int32 = 60000

    var sync = false, conflict = false, sameTitle = true
    var cloud = 0   // 1 read, 0 no save there, -1 not read in time
    var localHash = "", cloudHash = "", cloudDevice = ""
    var localSaved = Date(timeIntervalSince1970: 0), cloudSaved = Date(timeIntervalSince1970: 0)
    var localSize: Int64 = 0, cloudSize: Int64 = 0

    /// The report's line; nil when it is not one
    init?(line: String) {
        var f: [String: String] = [:]
        for pair in line.split(whereSeparator: { $0.isWhitespace }) {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { f[String(kv[0])] = String(kv[1]) }
        }
        guard let s = f["sync"], let c = f["conflict"], let cl = f["cloud"].flatMap({ Int($0) }) else { return nil }
        func text(_ k: String) -> String { f[k] == "-" ? "" : (f[k] ?? "") }
        func date(_ k: String) -> Date { Date(timeIntervalSince1970: Double(f[k] ?? "0") ?? 0) }
        sync = s == "1"; conflict = c == "1"; sameTitle = f["sametitle"] != "0"; cloud = cl
        localHash = text("local"); cloudHash = text("chash"); cloudDevice = text("cdevice")
        localSaved = date("saved"); cloudSaved = date("csaved")
        localSize = Int64(f["size"] ?? "0") ?? 0; cloudSize = Int64(f["csize"] ?? "0") ?? 0
    }

    enum Step: Equatable {
        case play(String?)   // start, with this DM_SAVE_SYNC_CHOICE (nil: leave it unset)
        case choose          // both changed: the player picks one
        case unreadable      // the cloud's save did not come: play this device's, try again, or cancel
    }

    /// What the launcher does next. With no report (no save folder, no title ID: the call failed) nothing is set and the host decides as it always did
    static func step(_ r: SaveSyncReport?) -> Step {
        guard let r, r.sync else { return .play(nil) }
        if r.cloud < 0 { return .unreadable }
        if r.conflict { return .choose }
        return .play("ask")   // nothing to choose now; if the cloud's changes before the mount, the mount replaces neither (save_sync.c read_choice)
    }

    var localChoice: String { "local:" + localHash }
    var cloudChoice: String { "cloud:" + cloudHash }

    private static func when(_ d: Date) -> String {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: d)
    }
    private static func size(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    /// The device the cloud's save came from, by its model ("iPhone17,1", "Mac16,1")
    var cloudDeviceKind: String {
        if cloudDevice.hasPrefix("iPhone") { return "iPhone" }
        if cloudDevice.hasPrefix("iPad") { return "iPad" }
        if cloudDevice.contains("Mac") { return "Mac" }
        return cloudDevice.isEmpty ? "another device" : cloudDevice
    }

    /// `here`: "本机" or "Mac"
    func localLabel(here: String) -> String { "\(here)存档：\(Self.when(localSaved))，\(Self.size(localSize))" }
    var cloudLabel: String { "iCloud 云端（\(cloudDeviceKind)）：\(Self.when(cloudSaved))，\(Self.size(cloudSize))" }
    static let chooseTitle = "要使用哪份存档进行游玩？"
    func chooseMessage(here: String) -> String {
        "\(here)与 iCloud 云端的存档自上次同步后均发生了变化。较新的文件不一定进度更多，未选中的那份会保留在 save-backups 备份文件夹中。"
    }
    static let unreadableTitle = "未能获取云端存档"
    func unreadableMessage(here: String) -> String {
        "iCloud 在 \(Self.waitMs / 1000) 秒内未能下载该游戏的存档。如果现在使用\(here)存档游玩，在下次启动比对之前不会覆盖云端存档。"
    }
}
