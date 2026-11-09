//
//  LCGameCloudSaves.swift
//  LiveContainerSwiftUI
//
//  云存档接入：同步本体是客体引擎自带的 save_sync（dm/host/
//  save_sync.c + iOS 层 CloudSaves.m，NX2 引擎与 nxnative main 同
//  源同版），GC 一行文件级同步都不写——本文件只补引擎缺的「配置
//  段」：让玩家在 GC 里选一次文件夹、替他保管 security-scoped 书
//  签、每次启动前把书签同步进客体自己的偏好，让客体进程照单机版
//  原流程自己解析、自己持 scope、自己同步。
//
//  为什么走客体偏好、而不是 env 递路径（PR #31/#32 的 env 通道已
//  被真机日志证伪，log-84 存档）：env 版链路全通——boot_env 读到
//  DM_SAVE_SYNC、引擎打出 `save sync: on: <夹>/<TITLEID>/
//  save.dmsync`、本机存档也判定要上云——最后写回恒以 errno=1
//  (EPERM) 失败。根因：security scope 是按进程持的授予；GC 界面
//  进程与客体游戏进程是两个进程实例（启动要交棒重拉），GC 在自
//  己进程里 startAccessing 持有的授予递不到客体进程手里，客体只
//  拿到一个裸路径、碰不了沙箱外文件夹。而单机版能成，靠的正是
//  客体进程自己在 dm_cloud_saves_env() 里解析自己偏好里的书签、
//  自己 startAccessing 并整场持有（CloudSaves.m 的 opened「从不
//  主动停」）——那一步只能在客体进程内发生，GC 替代不了，只能把
//  书签送进它读得到的地方。
//
//  引擎语义（fork main 源码实证，直接据此实现）：
//  - front_ios.m 的 startGame 在首次存档挂载前无条件调
//    dm_cloud_saves_env()（CloudSaves.m）：DM_SAVE_SYNC 若已由
//    env 给出（且不是它自己上次设的）它直接返回——所以旧 env 行
//    必须清掉，否则永远压过书签路径。env 不在场时它读标准偏好
//    域的 cloudSavesBookmark 书签（= 客体容器 Library/Preferences/
//    <bundleId>.plist，正是 GC 设置页经 LCGamePrefs 写 launcher.*
//    的同一份文件）：解析成功即在客体进程内 startAccessing 整场
//    持有、setenv DM_SAVE_SYNC=路径（fromPick）；解析失败打日志
//    关云存档、不挡启动；系统报 stale 时它还会把新书签回写同一
//    键（GC 下次维护以自己的记录为准再同步一次，同夹同值不冲突）。
//  - 云端布局 <所选夹>/<TITLEID 大写>/save.dmsync（引擎 cloud_file
//    () 自拼，所选夹本身就叫该 TITLEID 时不套第二层），与 Mac /
//    单机版 / NX2 壳天然互通：三方选同一文件夹即共用同一份包——
//    本文件同步给客体的书签与玩家在单机版启动器里自选的是同一
//    个键、同一个文件夹，语义完全一致。
//  - 同步时机全自动、没有手动同步概念：首次存档挂载拉取、每次
//    Commit 后 sender 线程静默 3 秒打包推送、切后台 20 秒刷盘；冲
//    突按 <DM_SAVE>.sync 的 base 哈希三方比对，新者赢、输家先整
//    体备份到 <DM_SAVE>-backups（与 GC 导入备份同一个
//    save-backups 目录，引擎命名为「日期 时间 local|cloud」，GC
//    的展示 / 清理不要误删）。
//
//  书签保管（宿主侧、按游戏一份，与 LCCustomCoverStore 的「宿主
//  Documents 下按 bundleId 一游戏一文件」同法）：
//  Documents/CloudSaves/<bundleId>.plist，内容 {bookmark: Data,
//  folderName: String, off: Bool}。书签必须带 security scope 造
//  （PR #32 教训：不带的能解析回路径、却不携带授予）。书签与创
//  建它的 App 签名身份绑定：GC 与客体同属一个签名 App（客体跑
//  在 GC 的进程身份下），GC 造的书签客体解析得了；GC 重签（换
//  证书）后旧书签解析失败是机制固有属性（单机版同理），一律按
//  「失效」处理——启动维护删客体键（视为未配置），设置页提示重
//  新选择，绝不阻塞启动、绝不崩溃。系统报 stale 但仍能解析的，
//  解析时顺手以新书签重写记录。
//
//  交付与关闭语义：启动维护（LCGameMods.refreshEnvOverlay 同一漏
//  斗）里调 syncGuestBookmark——GC 有记录且开启且书签可用：把记
//  录的书签 Data 写进客体偏好 cloudSavesBookmark 键；已关闭 / 书
//  签失效：删掉这个键（= 引擎的 dm_clear_cloud_saves）。「关闭」
//  只置 off 标记（记录里的书签保留，重新开启不用再选夹）；「移
//  除」删整份记录——但已移除（无记录）时启动维护不碰客体键：没
//  有 GC 记录 = 这款游戏的云存档不归 GC 管，玩家可能在客体自带
//  启动器里自选过文件夹，那个键是他的配置，GC 不删。管理动作只
//  动记录本身，一切效果经下次启动维护生效，与 Mod / 金手指同一
//  模式。「设置下次启动生效」的设置页口径不变。
//

import SwiftUI
import UniformTypeIdentifiers

enum LCGameCloudSaves {
    /// 旧 env 通道的键：PR #31/#32 曾用它递路径，已证伪——启动维护
    /// 时只负责把玩家机器上可能残留的这一行删掉（留着会压过书签路
    /// 径，见文件头），不再写入。
    static let legacyEnvKey = "DM_SAVE_SYNC"

    /// 客体偏好里的书签键：与引擎 CloudSaves.m 的 kCloudSaves 同名
    /// 同义——启动器自选文件夹时写的就是它，GC 同步的也是它。
    static let guestBookmarkKey = "cloudSavesBookmark"

    /// 书签造 / 解的 scope 选项：Swift 侧的 .withSecurityScope
    /// （URL / NSURL 两套 OptionSet 静态成员都是）在本仓的 iOS 15
    /// 部署目标 + CI 的 Xcode 26.2 下被 SDK 标为 iOS unavailable
    /// （PR #32 两轮 CI 实证），只能按 ObjC 头里的公开数值常量用
    /// rawValue 构造——NSURLBookmarkCreationWithSecurityScope
    /// (1<<11) / NSURLBookmarkResolutionWithSecurityScope (1<<9)，
    /// iOS 7 起的 ABI 常量，与引擎 CloudSaves.m 传的是同一个值。
    private static let bookmarkCreateOptions = NSURL.BookmarkCreationOptions(rawValue: 1 << 11)
    private static let bookmarkResolveOptions = NSURL.BookmarkResolutionOptions(rawValue: 1 << 9)

    /// 一款游戏的云存档记录（宿主 Documents/CloudSaves/<bundleId>.plist）
    struct Record: Codable {
        var bookmark: Data
        /// 显示用文件夹名（选夹时取所选夹名，之后不随解析结果变）
        var folderName: String
        /// 已关闭（书签保留、引擎不启用）；false = 开启
        var isOff: Bool
    }

    /// 设置页与启动维护共用的状态判定
    enum State: Equatable {
        /// 没有记录
        case notConfigured
        /// 有书签、已关闭
        case off(folderName: String)
        /// 有书签、开启、当前能解析
        case on(folderName: String)
        /// 有书签、开启、解析失败（多为 GC 换签名后旧书签失效）
        case stale(folderName: String)
    }

    // MARK: 记录存取（宿主侧、按游戏一份 plist）

    static var directoryURL: URL {
        LCPath.docPath.appendingPathComponent("CloudSaves", isDirectory: true)
    }

    static func fileURL(forBundleIdentifier bundleIdentifier: String) -> URL {
        directoryURL.appendingPathComponent("\(bundleIdentifier).plist")
    }

    static func record(forBundleIdentifier bundleIdentifier: String) -> Record? {
        let url = fileURL(forBundleIdentifier: bundleIdentifier)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? PropertyListDecoder().decode(Record.self, from: data)
    }

    private static func save(_ record: Record, forBundleIdentifier bundleIdentifier: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        guard let data = try? PropertyListEncoder().encode(record) else {
            return
        }
        // 临时文件 + 替换，避免写一半被读到（与 LCCustomCoverStore.save 同法）
        let target = fileURL(forBundleIdentifier: bundleIdentifier)
        let tmp = directoryURL.appendingPathComponent(".\(bundleIdentifier).tmp.plist")
        guard (try? data.write(to: tmp, options: .atomic)) != nil else {
            return
        }
        if fm.fileExists(atPath: target.path) {
            try? fm.removeItem(at: target)
        }
        try? fm.moveItem(at: tmp, to: target)
    }

    static func removeRecord(forBundleIdentifier bundleIdentifier: String) {
        try? FileManager.default.removeItem(at: fileURL(forBundleIdentifier: bundleIdentifier))
    }

    // MARK: 书签（照 NX2 BookmarkStore / 引擎 CloudSaves.m 的 fresh 口径）

    /// 为刚选的文件夹造书签：必须带 .withSecurityScope 造——不带这
    /// 个选项的书签能解析回路径、却不携带任何沙箱授予，下次启动
    /// startAccessing 返 false、引擎读写文件夹被沙箱拒（首版就栽在
    /// 这里：书签造时 options 传空，设置页显示已开启、env 也递了
    /// 路径，引擎却碰不到文件夹，云端永远不落文件）。造完当场按解
    /// 析口径验一遍：解析得回且授予探针能过才算成。
    private static func freshBookmark(for url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? (url as NSURL).bookmarkData(options: bookmarkCreateOptions, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return nil
        }
        var stale: ObjCBool = false
        guard let resolved = try? NSURL(resolvingBookmarkData: data, options: bookmarkResolveOptions, relativeTo: nil, bookmarkDataIsStale: &stale),
              grantsAccess(resolved as URL) else {
            return nil
        }
        return data
    }

    /// 授予探针：解析出的 URL 真持 startAccessing 一次——返 true 才
    /// 说明书签带着 security scope 授予；返 false = 只有路径没有授
    /// 予（无 scope 的旧书签 / 授予已失），按失效处理。探完即停，
    /// 不留持有（真正的持有在客体进程内、由引擎自己完成）。
    private static func grantsAccess(_ url: URL) -> Bool {
        guard url.startAccessingSecurityScopedResource() else {
            return false
        }
        url.stopAccessingSecurityScopedResource()
        return true
    }

    /// 解析书签。resolvable 但系统报 stale 时把新书签回写进记录
    /// （同签名下可自愈）；解析不出返回 nil（签名已变等），记录原样
    /// 保留——状态判定会把它呈现为「失效」等玩家重选或移除。
    private static func resolve(_ record: Record, forBundleIdentifier bundleIdentifier: String) -> URL? {
        var stale: ObjCBool = false
        guard let resolved = try? NSURL(resolvingBookmarkData: record.bookmark, options: bookmarkResolveOptions, relativeTo: nil, bookmarkDataIsStale: &stale),
              grantsAccess(resolved as URL) else {
            return nil
        }
        let url = resolved as URL
        if stale.boolValue, let fresh = freshBookmark(for: url) {
            var updated = record
            updated.bookmark = fresh
            save(updated, forBundleIdentifier: bundleIdentifier)
        }
        return url
    }

    // MARK: 设置页动作

    /// 玩家刚选完文件夹：造书签存记录（开启态）。失败返回 false，
    /// 什么都不存（不能把验不过的书签当好的存下）。
    static func storePickedFolder(_ url: URL, forBundleIdentifier bundleIdentifier: String) -> Bool {
        guard let bookmark = freshBookmark(for: url) else {
            return false
        }
        save(Record(bookmark: bookmark, folderName: url.lastPathComponent, isOff: false),
             forBundleIdentifier: bundleIdentifier)
        return true
    }

    /// 关闭 / 重新开启：只翻 off 标记，书签与名字保留
    static func setOff(_ off: Bool, forBundleIdentifier bundleIdentifier: String) {
        guard var record = record(forBundleIdentifier: bundleIdentifier) else {
            return
        }
        record.isOff = off
        save(record, forBundleIdentifier: bundleIdentifier)
    }

    /// 当前状态：无记录 / 关 / 开 / 失效。解析只为判定——授予的持有
    /// 发生在客体进程内（引擎自己 startAccessing），GC 侧不持。
    static func state(forBundleIdentifier bundleIdentifier: String) -> State {
        guard let record = record(forBundleIdentifier: bundleIdentifier) else {
            return .notConfigured
        }
        if record.isOff {
            return .off(folderName: record.folderName)
        }
        return resolve(record, forBundleIdentifier: bundleIdentifier) != nil
            ? .on(folderName: record.folderName)
            : .stale(folderName: record.folderName)
    }

    // MARK: 启动维护（书签同步进客体偏好）

    /// 把 GC 记录同步进客体自己的偏好（cloudSavesBookmark 键，写
    /// 通道 = LCGamePrefs，与 launcher.* 同一份 plist）：开启且书
    /// 签可用 → 写入记录的书签（resolve 触发的 stale 自愈会刷新记
    /// 录，写的是自愈后的最新一份）；已关闭 / 书签失效 → 删键（=
    /// 引擎关，失效不把坏书签递给客体让它每启打一遍失败日志）。
    /// GC 没有这款游戏的记录 → 完全不碰这个键（见文件头：那是玩
    /// 家在客体启动器里自选的配置，不归 GC 管）。同步失败静默：
    /// 云存档只是增强，绝不能挡游戏启动。
    static func syncGuestBookmark(container: LCContainer, bundleIdentifier: String) {
        guard let record = record(forBundleIdentifier: bundleIdentifier) else {
            return
        }
        let prefs = LCGamePrefs(container: container, bundleIdentifier: bundleIdentifier)
        guard !record.isOff,
              resolve(record, forBundleIdentifier: bundleIdentifier) != nil,
              let current = self.record(forBundleIdentifier: bundleIdentifier) else {
            prefs.setRawValue(nil, forKey: guestBookmarkKey)
            return
        }
        prefs.setRawValue(current.bookmark, forKey: guestBookmarkKey)
    }
}

// MARK: - 设置页「云存档」组（一行：同步文件夹）

/// 门控与「Mod」组同口径：有默认容器才显示（还没容器的游戏先进一
/// 次游戏再回来配）。行形态与 LCSaveDataSectionView 的导航行同语
/// 言：未选择时点开直接选夹；已开启点开是菜单（更换文件夹 / 关闭
/// 云存档）；已关闭可重新开启；书签失效提示重新选择。
struct LCGameCloudSavesSectionView: View {
    let app: LCAppModel
    /// 宿主页面的状态刷新计数（与 Mod / 金手指组同一信号）
    var refreshToken: Int = 0

    @State private var hasContainer = false
    @State private var state: LCGameCloudSaves.State = .notConfigured
    @State private var picking = false
    @State private var resultTitle: String?
    @State private var resultMessage: String?

    // 与 LCSaveDataSectionView / LCGameSettingsView 的 LCNXColor 同值
    private static let cream = Color(red: 1, green: 0.94, blue: 0.84)
    private static let surface = Color(red: 0.10, green: 0.10, blue: 0.11)
    private static let hairline = Color.white.opacity(0.08)
    private static let attention = Color(red: 1, green: 0.78, blue: 0.24)

    var body: some View {
        // Group 透明包裹：无容器时整组缺席，与「Mod」组自隐同效
        Group {
            if hasContainer {
                section
            }
        }
        .onAppear { reload() }
        .onChange(of: refreshToken) { _ in reload() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                if LCGameCloudSaves.storePickedFolder(url, forBundleIdentifier: app.bundleIdentifier) {
                    reload()
                } else {
                    resultTitle = "lc.cloud.section".loc
                    resultMessage = "lc.cloud.pickFailed".loc
                }
            }
        }
        .alert(resultTitle ?? "", isPresented: resultPresented) {
            Button("lc.common.ok".loc, role: .cancel) {}
        } message: {
            Text(resultMessage ?? "")
        }
    }

    private var resultPresented: Binding<Bool> {
        Binding(
            get: { resultMessage != nil },
            set: { if !$0 { resultMessage = nil; resultTitle = nil } }
        )
    }

    private var section: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("lc.cloud.section".loc.uppercased())
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(1.6)
                .foregroundColor(Self.cream.opacity(0.72))
            VStack(alignment: .leading, spacing: 14) {
                rowWithActions
                Text("lc.cloud.note".loc)
                    .font(.system(size: 12.5))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Self.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Self.hairline, lineWidth: 1)
            }
        }
    }

    /// 那一行：未配置 = 按钮（点开直接选夹）；其余状态 = 菜单
    /// （动作随状态：更换 / 关闭 / 重新开启 / 重新选择 / 移除）
    @ViewBuilder
    private var rowWithActions: some View {
        switch state {
        case .notConfigured:
            Button {
                picking = true
            } label: {
                row(value: "lc.cloud.notPicked".loc, valueColor: .white.opacity(0.5))
            }
            .buttonStyle(.plain)
                case .on(let folderName):
            Menu {
                Button("lc.cloud.changeFolder".loc) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { picking = true }
                }
                Button("lc.cloud.turnOff".loc) {
                    LCGameCloudSaves.setOff(true, forBundleIdentifier: app.bundleIdentifier)
                    reload()
                }
            } label: {
                row(value: folderName, valueColor: Self.cream)
            }
        case .off(let folderName):
            Menu {
                Button("lc.cloud.turnOn".loc) {
                    LCGameCloudSaves.setOff(false, forBundleIdentifier: app.bundleIdentifier)
                    reload()
                }
                Button("lc.cloud.changeFolder".loc) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { picking = true }
                }
                Button("lc.cloud.remove".loc, role: .destructive) {
                    LCGameCloudSaves.removeRecord(forBundleIdentifier: app.bundleIdentifier)
                    reload()
                }
            } label: {
                row(value: "lc.cloud.off".loc, valueColor: .white.opacity(0.5), detail: folderName)
            }
        case .stale:
            Menu {
                Button("lc.cloud.repick".loc) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { picking = true }
                }
                Button("lc.cloud.remove".loc, role: .destructive) {
                    LCGameCloudSaves.removeRecord(forBundleIdentifier: app.bundleIdentifier)
                    reload()
                }
            } label: {
                row(value: "lc.cloud.stale".loc, valueColor: Self.attention)
            }
        }
    }

    /// NX 导航行同语言：标签 15 medium 白、值 14.5 semibold、chevron
    /// 13 bold 白 0.4、行 minHeight 48（与 LCSaveDataSectionView.row 同规格）
    private func row(value: String, valueColor: Color, detail: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text("lc.cloud.folderRow".loc)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(value)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundColor(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    private func reload() {
        hasContainer = LCGameLibraryInfo.defaultContainer(for: app) != nil
        state = LCGameCloudSaves.state(forBundleIdentifier: app.bundleIdentifier)
    }
}
