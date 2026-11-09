//
//  LCGameMods.swift
//  LiveContainerSwiftUI
//
//  Mod 支持：照搬 NX2Apple 壳的 GameMods 方案（上游 #557）。玩家把散装
//  RomFS 替换文件按 mod 分夹放进数据容器 Documents/mods/<mod 名>/，
//  GC 在每次启动前按 NX2 同规则扫描、拼出 DM_ROMFS_OVERLAY，行级维护
//  进容器 Documents/env.txt——客体宿主 boot_env()（dm/ios main.m）启动
//  时先读 Documents/env.txt（优先于包内 dm/env.txt），hle_fs.c 挂载
//  RomFS 时逐文件先探 overlay、再查镜像本体，等于在 romfs.img 之上叠
//  一层散文件补丁：不改数据包本体、不动 romfs.id，数据包状态判定仍
//  只看 img（LCGameLibraryInfo.isDatapackReady），与本功能互不相干。
//
//  与 env 锁定逻辑的关系（LCGameProfile.envLockedValues）：该函数把
//  env.txt 里出现的键一律视为「被 env 文件固定」而在设置页锁定，
//  DM_ROMFS_OVERLAY 写入后同样落入这一口径——正确且无冲突：这行本来
//  就不该由启动器设置驱动，它由 mods 目录现状决定、GC 独占维护。
//  代价是玩家手写在 Documents/env.txt 里的 DM_ROMFS_OVERLAY 行会在
//  下次启动时被扫描结果覆盖（有 mods 按扫描写、无 mods 删行）——GC
//  自此是这一行的唯一写者，与 NX2 壳「壳现算的值优先」同义。
//
//  维护点：LCAppModel.runApp 的派发漏斗（与 LCPlayStats.beginSession
//  同处，已越过全部早退分支）——主页 / 牌组 / 列表 / 深链等入口最终都
//  过这里，且转交其他 LC 副本时由接手进程自己的漏斗维护。经桌面网
//  页剪辑 / 扩展直启客体时不经此漏斗，沿用上一次维护出的一行（mods
//  没变就仍然正确）。
//
//  金手指的 DM_CHEATS 行搭同一条维护通道（LCGameCheats）：refresh
//  EnvOverlay 在同一次维护里先处理 overlay 行、再处理 DM_CHEATS
//  行，两行共用 maintainEnvLine 这一个写者——绝不另开第二个 env.txt
//  写者。两行口径相同：都由容器目录现状决定、GC 独占维护、玩家手
//  写同名行在下次启动被维护结果覆盖。
//
//  云存档不走 env（LCGameCloudSaves）：同一次维护里只把旧 env 通
//  道（PR #31/#32）可能写过的 DM_SAVE_SYNC 残行删掉——留着它会
//  压过客体自己的书签路径。云存档配置改经客体偏好书签同步（客体
//  进程自己持 security scope，env 递裸路径已被真机日志证伪为
//  EPERM），细节见 LCGameCloudSaves 文件头；同步本体仍全在引擎
//  内（save_sync），GC 不写任何文件级同步。
//
//  导入与管理（设置页「Mod」组）：导入把所选文件夹按扫描同规则校验
//  后 staging 换入 Documents/mods/；管理动作（启停 / 排序 / 删除）只
//  动 mods 本层的文件夹与顺序记录，绝不直接写 env.txt——一切效果都
//  经由上面这条启动前扫描在下次启动生效，没有第二条写 env 的路。
//  启停按 NX2 约定就是文件夹改名加 / 去「.」前缀，与玩家在「文件」
//  App 里手改的结果互通。优先级顺序由 GC 维护一份记录（mods 夹内的
//  .gamecase-mod-order.json，存基础名数组）：扫描器与管理界面共用同
//  一排序函数——记录里有的按记录序、没记录的新夹按名字序兜底排在
//  后面；没有记录时整体退化为 NX2 原生的纯名字序。记录是点开头文
//  件，扫描枚举本来就跳过它，不会把自己当成 mod。
//

import SwiftUI

enum LCGameModError: Error {
    /// 所选文件夹解析不出 RomFS 根（纯 exefs / 空夹 / 结构层里没有真文件）
    case invalidMod
    /// 启停改名时目标名已被另一个文件夹占用
    case nameConflict
}

enum LCGameMods {
    /// 一个生效中的 mod：文件夹名 + 解析出的 RomFS 根（绝对路径）
    struct EffectiveMod: Identifiable {
        let name: String
        let romfsPath: String
        var id: String { name }
    }

    /// mods 夹里的一个文件夹（管理名单用）：含已停用的
    struct ModEntry: Identifiable {
        /// 磁盘原名（停用时带「.」前缀）
        let folderName: String
        /// 基础名（去掉「.」前缀）
        let name: String
        let isEnabled: Bool
        /// 已启用且能解析出 RomFS 根时非 nil；停用或纯代码 / 空夹为 nil
        let romfsPath: String?
        /// 是否真正进 overlay（已启用且有 RomFS 根）
        var isEffective: Bool { isEnabled && romfsPath != nil }
        var id: String { folderName }
    }

    static let envKey = "DM_ROMFS_OVERLAY"

    /// 优先级顺序记录文件名（mods 夹内、点开头，扫描跳过）
    static let orderFileName = ".gamecase-mod-order.json"

    /// 导入 staging 夹名前缀（同卷临时落点，点开头 + 此前缀双重避开扫描）
    static let stagingPrefix = ".mod-import-staging-"

    /// 导入提交时旧夹的临时挪开夹名前缀（同上，避开扫描与名单）
    static let replacedPrefix = ".mod-replaced-"

    /// titleID：客体 bundle id 末段（org.nxnative.<titleID>），大写——
    /// 与 LCKnownGame.from 的归一化同法，也对齐 Atmosphere 目录惯例
    static func titleID(bundleIdentifier: String) -> String? {
        guard let last = bundleIdentifier.split(separator: ".").last, !last.isEmpty else {
            return nil
        }
        return last.uppercased()
    }

    /// 基础名：去掉全部前导「.」（NX2 禁用约定只加一个，多个一并归一）
    static func baseName(of folderName: String) -> String {
        String(folderName.drop(while: { $0 == "." }))
    }

    /// 解析一个 mod 文件夹的 RomFS 根（扫描与导入校验共用同一判据）：
    /// candidates 依次为 romfs、atmosphere/contents/<titleID>/romfs、
    /// contents/<titleID>/romfs；都不在则文件夹根本身即 RomFS 根，
    /// 但顶层只有 exefs/atmosphere/contents 的（纯代码 mod 改的是代码、
    /// 引擎不吃；或只有结构层没有真文件）与空夹返回 nil。
    static func resolveRomfsRoot(of mod: URL, titleID: String, _ fm: FileManager = .default) -> String? {
        let candidates = ["romfs", "atmosphere/contents/\(titleID)/romfs", "contents/\(titleID)/romfs"]
            .map { mod.appendingPathComponent($0).path }
        if let found = candidates.first(where: { fm.fileExists(atPath: $0) }) {
            return found
        }
        let top = ((try? fm.contentsOfDirectory(atPath: mod.path)) ?? []).filter { !$0.hasPrefix(".") }
        let codeOnly = !top.isEmpty && top.allSatisfy { ["exefs", "atmosphere", "contents"].contains($0.lowercased()) }
        return codeOnly || top.isEmpty ? nil : mod.path
    }

    /// mods 夹内的全部文件夹名（含点开头；排除导入 staging 残留）
    static func modFolderNames(in mods: URL, _ fm: FileManager = .default) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: mods.path)) ?? []).filter { name in
            guard !name.hasPrefix(stagingPrefix), !name.hasPrefix(replacedPrefix) else { return false }
            var dir: ObjCBool = false
            return fm.fileExists(atPath: mods.appendingPathComponent(name).path, isDirectory: &dir) && dir.boolValue
        }
    }

    // MARK: 优先级顺序（扫描器与管理界面共用）

    /// 顺序记录：基础名数组。读不到 / 损坏一律当空（退化为名字序）。
    static func loadOrder(in mods: URL, _ fm: FileManager = .default) -> [String] {
        let url = mods.appendingPathComponent(orderFileName)
        guard let data = try? Data(contentsOf: url),
              let names = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return names
    }

    static func saveOrder(_ order: [String], in mods: URL, _ fm: FileManager = .default) {
        let url = mods.appendingPathComponent(orderFileName)
        guard let data = try? JSONEncoder().encode(order) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// 共用排序：记录里有的按记录序在前（同名记录只认首个位置），
    /// 没记录的按文件夹名 localizedStandard 序兜底排在后面。
    static func sortEntries(_ entries: [ModEntry], order: [String]) -> [ModEntry] {
        func rank(of entry: ModEntry) -> Int {
            order.firstIndex(of: entry.name) ?? Int.max
        }
        return entries.sorted { a, b in
            let ra = rank(of: a), rb = rank(of: b)
            if ra != rb { return ra < rb }
            return a.folderName.localizedStandardCompare(b.folderName) == .orderedAscending
        }
    }

    /// mods 夹现状的完整名单（启用 + 停用），按共用顺序排好
    static func allMods(in mods: URL, titleID: String, _ fm: FileManager = .default) -> [ModEntry] {
        let entries = modFolderNames(in: mods, fm).map { folderName in
            let enabled = !folderName.hasPrefix(".")
            let romfs = enabled
                ? resolveRomfsRoot(of: mods.appendingPathComponent(folderName), titleID: titleID, fm)
                : nil
            return ModEntry(folderName: folderName, name: baseName(of: folderName), isEnabled: enabled, romfsPath: romfs)
        }
        return sortEntries(entries, order: loadOrder(in: mods, fm))
    }

    /// NX2 GameMods.romfsFolders 同构：生效 mod 名单（已启用、能解析出
    /// RomFS 根），顺序即优先级——点开头跳过（禁用约定）、纯代码 mod
    /// 与空夹跳过（解析判据见 resolveRomfsRoot）。多个 mod 替换同一
    /// 文件时，overlay 串里先列者先被探到、先到者赢（与 NX2 / Mac
    /// 启动器一致）。排序走共用排序：有顺序记录按记录、无记录退化
    /// 为这里的兜底——即 NX2 原生的文件夹名 localizedStandard 序。
    static func effectiveMods(in mods: URL, titleID: String, _ fm: FileManager = .default) -> [EffectiveMod] {
        allMods(in: mods, titleID: titleID, fm).compactMap { entry in
            guard entry.isEnabled, let romfsPath = entry.romfsPath else { return nil }
            return EffectiveMod(name: entry.folderName, romfsPath: romfsPath)
        }
    }

    /// DM_ROMFS_OVERLAY 的值：各 mod RomFS 根的真实绝对路径冒号连接，
    /// 无可用 mod 返回 nil。路径本身含冒号时不转义（与 NX2 同构）：
    /// 引擎按冒号拆分 overlay，这类夹名会错位——别给 mod 文件夹起带
    /// 冒号的名字。
    static func overlayValue(in mods: URL, titleID: String, _ fm: FileManager = .default) -> String? {
        let mods = effectiveMods(in: mods, titleID: titleID, fm)
        return mods.isEmpty ? nil : mods.map(\.romfsPath).joined(separator: ":")
    }

    // MARK: 管理动作（只动 mods 本层；效果经启动前扫描生效）

    /// 启停 = 文件夹改名加 / 去「.」前缀。目标名已被占用抛 nameConflict
    /// （只能由玩家在「文件」里先整理，GC 不擅自覆盖）。
    static func setEnabled(_ entry: ModEntry, enabled: Bool, in mods: URL, _ fm: FileManager = .default) throws {
        guard entry.isEnabled != enabled else { return }
        let newName = enabled ? entry.name : "." + entry.name
        let target = mods.appendingPathComponent(newName)
        guard !fm.fileExists(atPath: target.path) else {
            throw LCGameModError.nameConflict
        }
        try fm.moveItem(at: mods.appendingPathComponent(entry.folderName), to: target)
    }

    /// 上移 / 下移一格（direction = -1 / +1）：把当前显示顺序的全部基础
    /// 名物化成记录后交换相邻两项。与显示共用 allMods 的顺序，写完
    /// 记录后扫描与界面的顺序恒一致。
    static func move(_ entry: ModEntry, direction: Int, in mods: URL, titleID: String, _ fm: FileManager = .default) {
        let entries = allMods(in: mods, titleID: titleID, fm)
        guard let index = entries.firstIndex(where: { $0.folderName == entry.folderName }) else { return }
        let other = index + direction
        guard entries.indices.contains(other) else { return }
        var names: [String] = []
        for entry in entries where !names.contains(entry.name) {
            names.append(entry.name)
        }
        let a = entries[index].name, b = entries[other].name
        guard a != b, let ia = names.firstIndex(of: a), let ib = names.firstIndex(of: b) else { return }
        names.swapAt(ia, ib)
        saveOrder(names, in: mods, fm)
    }

    /// 删除 mod 文件夹；同基础名的文件夹都删净后顺带从顺序记录除名
    static func delete(_ entry: ModEntry, in mods: URL, _ fm: FileManager = .default) throws {
        try fm.removeItem(at: mods.appendingPathComponent(entry.folderName))
        if !modFolderNames(in: mods, fm).contains(where: { baseName(of: $0) == entry.name }) {
            var order = loadOrder(in: mods, fm)
            if order.contains(entry.name) {
                order.removeAll { $0 == entry.name }
                saveOrder(order, in: mods, fm)
            }
        }
    }

    /// 导入一个 mod 文件夹：先按扫描同判据校验（resolveRomfsRoot 解析
    /// 不出根 → invalidMod，什么都不拷）；再逐文件分块拷进 mods 夹内
    /// staging（同卷、逐个校验大小），全成才提交——同基础名的现存夹
    /// （启用 / 停用任一形态）先挪到临时名、新夹就位后删旧夹，提交
    /// 失败回滚旧夹。任一步失败只删 staging、现有内容原样。成功后把
    /// 基础名追加进顺序记录（已在记录中则不动），导入即启用态。
    /// 安全作用域由调用方在拷贝期间持有。返回落位的基础名。
    static func importMod(from source: URL, into mods: URL, titleID: String,
                          isCancelled: () -> Bool,
                          onProgress: (Int64, Int64) async -> Void) async throws -> String {
        let fm = FileManager.default
        guard resolveRomfsRoot(of: source, titleID: titleID, fm) != nil else {
            throw LCGameModError.invalidMod
        }
        let name = baseName(of: source.lastPathComponent)
        guard !name.isEmpty, name != ".", name != ".." else {
            throw LCGameModError.invalidMod
        }
        try fm.createDirectory(at: mods, withIntermediateDirectories: true)
        let staging = mods.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        if fm.fileExists(atPath: staging.path) {
            try fm.removeItem(at: staging)
        }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let files = LCDatapackImportView.treeFiles(source)
            let total = LCDatapackImportView.treeSize(source)
            await onProgress(0, total)
            var copied: Int64 = 0
            for file in files {
                let relative = LCDatapackImportView.relativePath(of: file, under: source)
                let dest = staging.appendingPathComponent(relative)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let base = copied
                let written = try await LCDatapackImportView.chunkedCopyFile(from: file, to: dest, isCancelled: isCancelled) { done in
                    await onProgress(base + done, total)
                }
                guard written == LCDatapackImportView.fileSize(file) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                copied += written
            }
            // 提交：旧夹先挪开（可回滚），新夹就位后删旧夹
            let replaced = mods.appendingPathComponent(replacedPrefix + UUID().uuidString, isDirectory: true)
            var movedAside: [URL] = []
            do {
                for folderName in modFolderNames(in: mods, fm) where baseName(of: folderName) == name {
                    let aside = replaced.appendingPathComponent(folderName, isDirectory: true)
                    try fm.createDirectory(at: replaced, withIntermediateDirectories: true)
                    try fm.moveItem(at: mods.appendingPathComponent(folderName), to: aside)
                    movedAside.append(aside)
                }
                try fm.moveItem(at: staging, to: mods.appendingPathComponent(name))
            } catch {
                for aside in movedAside {
                    try? fm.moveItem(at: aside, to: mods.appendingPathComponent(aside.lastPathComponent))
                }
                try? fm.removeItem(at: replaced)
                throw error
            }
            try? fm.removeItem(at: replaced)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        var order = loadOrder(in: mods, fm)
        if !order.contains(name) {
            order.append(name)
            saveOrder(order, in: mods, fm)
        }
        return name
    }

    // MARK: env.txt 维护

    /// 客体启动页的逐游戏开关（设置页「高级」组）：默认隐藏——启动
    /// 维护写 DM_LAUNCHER=0、点开直进游戏；玩家打开「显示游戏启动
    /// 页」后维护改为删行，客体下次启动恢复自带启动页。标记只存宿
    /// 主 UserDefaults（gc.launcherGate.show.<bundleId>，默认 false
    /// = 隐藏）：这是 GC 自己的呈现开关，不进客体偏好、与
    /// launcher.json 镜像无关。
    enum LauncherGate {
        private static func key(forBundleIdentifier bundleIdentifier: String) -> String {
            "gc.launcherGate.show.\(bundleIdentifier)"
        }

        static func showsLauncher(forBundleIdentifier bundleIdentifier: String) -> Bool {
            UserDefaults.standard.bool(forKey: key(forBundleIdentifier: bundleIdentifier))
        }

        static func setShowsLauncher(_ show: Bool, forBundleIdentifier bundleIdentifier: String) {
            UserDefaults.standard.set(show, forKey: key(forBundleIdentifier: bundleIdentifier))
        }
    }

    /// 按容器当前 mods / cheats 现状、同一次维护里顺序维护其
    /// Documents/env.txt 的三行：先 DM_ROMFS_OVERLAY（mods 现
    /// 算，无可用 mod 删行）、次 DM_CHEATS（cheats 夹内有文件名
    /// 合规的 .txt 才写 cheats、否则删行，判据见 LCGameCheats）、
    /// 末 DM_LAUNCHER（按逐游戏开关，见下）。三行共用 maintainEnvLine 这
    /// 一个写者，他行逐字保留。同一漏斗里另有两件不经 env 的事：
    /// 删除旧云存档通道残留的 DM_SAVE_SYNC 行、把云存档书签同步
    /// 进客体偏好（均见下）。维护失败静默吞掉：都只是增强 / 呈现
    /// 层的事，绝不能挡游戏启动。
    static func refreshEnvOverlay(container: LCContainer, bundleIdentifier: String) {
        guard let titleID = titleID(bundleIdentifier: bundleIdentifier) else { return }
        let documents = container.containerURL.appendingPathComponent("Documents")
        let envFile = documents.appendingPathComponent("env.txt")
        let overlay = overlayValue(in: documents.appendingPathComponent("mods", isDirectory: true), titleID: titleID)
        maintainEnvLine(envFile: envFile, key: envKey, value: overlay)
        maintainEnvLine(envFile: envFile, key: LCGameCheats.envKey, value: LCGameCheats.cheatsEnvValue(in: documents))
        // 云存档不经 env：删掉旧通道（PR #31/#32）写过的残行（留
        // 着会压过客体自己的书签路径）；配置改经客体偏好同步——
        // 客体进程自己解析书签、自己持 security scope（GC 进程持
        // 的授予递不过交棒，env 递裸路径真机实证写回 EPERM），细
        // 节见 LCGameCloudSaves 文件头。
        maintainEnvLine(envFile: envFile, key: LCGameCloudSaves.legacyEnvKey, value: nil)
        LCGameCloudSaves.syncGuestBookmark(container: container, bundleIdentifier: bundleIdentifier)
        // GC 默认在 env 里关客体自带启动页：GC 的设置页就是那套
        // 设置的呈现层，库里点开应当直进游戏。客体语义（nxnative
        // dm/ios main.m boot_env + Launcher.swift）：Documents/
        // env.txt 优先于包内 dm/env.txt，DM_LAUNCHER=0 时启动器
        // applySaved（GC 设置页写的那份偏好照常生效）后直接开局。
        // 等价于此前 gc-* 专用包在构建时往包内烘焙同一行——有了这
        // 行，单装版 IPA 装进 GC 也直进游戏，不必再出专用包。逐游
        // 戏开关（LauncherGate，设置页「高级」组）：打开「显示游戏
        // 启动页」的那款改为删行，客体下次启动恢复自带启动页。

        // 解除 GC 的环境变量压制，让游戏内悬浮菜单默认完整显示（性能监控/震动/帧率/主机模式等）
        maintainEnvLine(envFile: envFile, key: "DM_LAUNCHER", value: nil)
    }

    /// 启动漏斗入口：容器取 runApp 即将启动的那一个（与
    /// LCGameLibraryInfo.defaultContainer 同源：selected 优先）。
    static func refreshEnvOverlay(for app: LCAppModel) {
        guard let container = LCGameLibraryInfo.defaultContainer(for: app) else { return }
        refreshEnvOverlay(container: container, bundleIdentifier: app.bundleIdentifier)
    }

    /// 行级维护 env 文件中的一行 `KEY=VALUE`：
    /// - value 非 nil：文件中恰有一行该键、值即 value——替换首个旧行，
    ///   其余同键行删除（客体 boot 按首个同名键胜出，多行会让旧值残留
    ///   生效）；没有旧行则追加到文件末尾；
    /// - value 为 nil：删掉全部该键行；
    /// - 其余行（注释、空行、其他键、怪格式）逐字保留，连各自的行尾
    ///   符（\n / \r\n）都不动；
    /// - 文件不存在且 value 为 nil 时什么都不做，绝不建空文件；
    /// - 文件不是 UTF-8 时整体不动（客体同样按 UTF-8 读，读不出等于
    ///   没有这个文件，不能冒险按字节改）。
    /// 键的识别与 LCGameProfile.envLockedValues 同口径：整行去空白后
    /// 按首个「=」切分、键再去空白比对；注释行永远不算、原样保留。
    static func maintainEnvLine(envFile: URL, key: String, value: String?) {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: envFile.path)
        guard exists || value != nil else { return }
        var original = ""
        if exists {
            guard let text = try? String(contentsOf: envFile, encoding: .utf8) else { return }
            original = text
        }
        // 拆成（行内容, 行尾）对，行尾逐字保留
        var lines: [(content: String, ending: String)] = []
        var rest = original[original.startIndex...]
        while !rest.isEmpty {
            if let nl = rest.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                var end = rest.index(after: nl)
                if rest[nl] == "\r", end < rest.endIndex, rest[end] == "\n" {
                    end = rest.index(after: end)
                }
                lines.append((String(rest[..<nl]), String(rest[nl..<end])))
                rest = rest[end...]
            } else {
                lines.append((String(rest), ""))
                rest = rest[rest.endIndex...]
            }
        }
        func isKeyLine(_ content: String) -> Bool {
            let t = content.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { return false }
            if t == key { return true }
            guard let eq = t.firstIndex(of: "=") else { return false }
            return t[..<eq].trimmingCharacters(in: .whitespaces) == key
        }
        let newline = lines.first(where: { !$0.ending.isEmpty })?.ending ?? "\n"
        var out: [(content: String, ending: String)] = []
        var written = false
        for line in lines {
            if isKeyLine(line.content) {
                if let value, !written {
                    out.append(("\(key)=\(value)", line.ending.isEmpty ? newline : line.ending))
                    written = true
                }
                continue
            }
            out.append(line)
        }
        if let value, !written {
            if !out.isEmpty, out[out.count - 1].ending.isEmpty {
                out[out.count - 1].ending = newline
            }
            out.append(("\(key)=\(value)", newline))
        }
        let result = out.map { $0.content + $0.ending }.joined()
        guard result != original else { return }
        do {
            // 原地截断重写、不换文件，与 LCGamePrefs.save 同理（跟踪方看同一文件）
            if exists, let handle = try? FileHandle(forWritingTo: envFile) {
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: Data(result.utf8))
                try handle.synchronize()
                try? handle.close()
            } else {
                try Data(result.utf8).write(to: envFile)
            }
        } catch {
            // 维护失败不挡启动，下次启动再试
        }
    }

    // MARK: 设置页呈现的数据

    /// 设置页「Mod」组的上下文：默认容器 + mods 夹 + titleID。
    /// 无容器 / 取不到 titleID 返回 nil（整组自隐）。
    static func modsContext(for app: LCAppModel) -> (container: LCContainer, modsDir: URL, titleID: String)? {
        guard let container = LCGameLibraryInfo.defaultContainer(for: app),
              let titleID = titleID(bundleIdentifier: app.bundleIdentifier) else {
            return nil
        }
        let modsDir = container.containerURL.appendingPathComponent("Documents/mods", isDirectory: true)
        return (container, modsDir, titleID)
    }
}

// MARK: - 设置页「Mod」组（名单 + 导入 + 管理）

/// 名单即管理：列出 mods 夹内全部 mod（停用的也列），可启停（改名
/// 加 / 去点前缀）、上下移调优先级（顺序 = overlay 叠加序）、删除；
/// 底部「导入 Mod…」从文件夹导入一个新 mod。所有动作只动 mods 本
/// 层，生效仍走启动前扫描维护 env.txt，本组不直接碰 env.txt。
/// 排版与 LCSaveDataSectionView 同语言（自带同值常量）。
struct LCGameModsSectionView: View {
    let app: LCAppModel
    /// 宿主页面的状态刷新计数：数据包导入等动作关页后 bump，本组随之重算
    var refreshToken: Int = 0

    @State private var entries: [LCGameMods.ModEntry] = []
    @State private var hasContainer = false
    @State private var picking = false
    @State private var pendingImport: URL?
    @State private var pendingImportName = ""
    @State private var confirmImportOverwrite = false
    @State private var pendingDelete: LCGameMods.ModEntry?
    @State private var confirmDelete = false
    @State private var busy = false
    @State private var importing = false
    @State private var progress: Double = 0
    @State private var resultTitle: String?
    @State private var resultMessage: String?

    private final class CancelBox { var cancelled = false }
    @State private var cancelBox = CancelBox()

    // 与 LCSaveDataSectionView / LCGameSettingsView 的 LCNXColor 同值
    private static let cream = Color(red: 1, green: 0.94, blue: 0.84)
    private static let surface = Color(red: 0.10, green: 0.10, blue: 0.11)
    private static let hairline = Color.white.opacity(0.08)

    var body: some View {
        // Group 透明包裹：无容器时条件为空，整组在宿主 VStack 里缺席
        // （不占间隔），与 LCSaveDataSectionView 的自隐同效
        Group {
            if hasContainer {
                section
            }
        }
        .onAppear { reload() }
        .onChange(of: refreshToken) { _ in reload() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                pickedModFolder(url)
            }
        }
        .confirmationDialog("lc.mods.importOverwriteTitle".loc, isPresented: $confirmImportOverwrite, titleVisibility: .visible) {
            Button("lc.mods.replace".loc, role: .destructive) {
                if let source = pendingImport {
                    runImport(source: source)
                }
                pendingImport = nil
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                pendingImport = nil
            }
        } message: {
            Text("lc.mods.importOverwriteMessage".loc.localizeWithFormat(pendingImportName))
        }
        .confirmationDialog("lc.mods.deleteConfirmTitle".loc, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("lc.mods.delete".loc, role: .destructive) {
                if let entry = pendingDelete {
                    runDelete(entry)
                }
                pendingDelete = nil
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("lc.mods.deleteConfirmMessage".loc.localizeWithFormat(pendingDelete?.name ?? ""))
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
            Text("lc.mods.section".loc.uppercased())
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(1.6)
                .foregroundColor(Self.cream.opacity(0.72))
            VStack(alignment: .leading, spacing: 14) {
                // 名单与导入按钮在导入期间禁用；进度区（含取消）不在此列
                VStack(alignment: .leading, spacing: 14) {
                    if entries.isEmpty {
                        Text("lc.mods.none".loc)
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.72))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 {
                                Rectangle()
                                    .fill(Color.white.opacity(0.06))
                                    .frame(height: 1)
                            }
                            modRow(entry, at: index)
                        }
                    }
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 1)
                    Button {
                        picking = true
                    } label: {
                        HStack(spacing: 8) {
                            Text("lc.mods.import".loc)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.white)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white.opacity(0.4))
                        }
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .disabled(busy)
                if importing {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: progress)
                            .tint(Self.cream)
                        HStack(spacing: 8) {
                            Text("lc.mods.importing".loc)
                                .font(.system(size: 12.5))
                                .foregroundColor(.white.opacity(0.5))
                            Spacer(minLength: 0)
                            Button("lc.common.cancel".loc) {
                                cancelBox.cancelled = true
                            }
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(.red.opacity(0.85))
                        }
                    }
                }
                Text("lc.mods.note".loc)
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

    /// 一行 mod：序号 = 生效顺序位（没生效的显示「–」）；第二行是启停 /
    /// 删除动作与状态小字。上下移交换的是顺序记录，与启动扫描同序。
    private func modRow(_ entry: LCGameMods.ModEntry, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(positionText(for: entry))
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundColor(entry.isEffective ? Self.cream : .white.opacity(0.35))
                    .frame(minWidth: 18, alignment: .leading)
                Text(entry.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(entry.isEnabled ? .white : .white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                moveButton(systemName: "chevron.up", label: "lc.mods.moveUp".loc, disabled: index == 0) {
                    runMove(entry, direction: -1)
                }
                moveButton(systemName: "chevron.down", label: "lc.mods.moveDown".loc, disabled: index == entries.count - 1) {
                    runMove(entry, direction: 1)
                }
            }
            HStack(spacing: 16) {
                Button {
                    runToggle(entry)
                } label: {
                    Text(entry.isEnabled ? "lc.mods.disable".loc : "lc.mods.enable".loc)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(Self.cream)
                }
                .buttonStyle(.plain)
                Button {
                    pendingDelete = entry
                    confirmDelete = true
                } label: {
                    Text("lc.mods.delete".loc)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(.red.opacity(0.85))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                if !entry.isEnabled {
                    Text("lc.mods.disabledState".loc)
                        .font(.system(size: 12.5))
                        .foregroundColor(.white.opacity(0.4))
                } else if entry.romfsPath == nil {
                    Text("lc.mods.ineffectiveState".loc)
                        .font(.system(size: 12.5))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            .padding(.leading, 28)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func moveButton(systemName: String, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white.opacity(disabled ? 0.18 : 0.75))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    /// 生效顺序位：第几个真正进 overlay 的 mod；没生效返回「–」
    private func positionText(for entry: LCGameMods.ModEntry) -> String {
        guard entry.isEffective else { return "–" }
        var position = 0
        for other in entries {
            if other.isEffective {
                position += 1
            }
            if other.folderName == entry.folderName {
                break
            }
        }
        return "\(position)"
    }

    // MARK: 动作

    private func reload() {
        if let context = LCGameMods.modsContext(for: app) {
            hasContainer = true
            entries = LCGameMods.allMods(in: context.modsDir, titleID: context.titleID)
        } else {
            hasContainer = false
            entries = []
        }
    }

    private func runToggle(_ entry: LCGameMods.ModEntry) {
        guard let context = LCGameMods.modsContext(for: app) else { return }
        do {
            try LCGameMods.setEnabled(entry, enabled: !entry.isEnabled, in: context.modsDir)
            reload()
        } catch LCGameModError.nameConflict {
            resultTitle = "lc.mods.section".loc
            resultMessage = "lc.mods.nameConflict".loc
        } catch {
            resultTitle = "lc.mods.section".loc
            resultMessage = "lc.mods.failed".loc.localizeWithFormat(error.localizedDescription)
        }
    }

    private func runMove(_ entry: LCGameMods.ModEntry, direction: Int) {
        guard let context = LCGameMods.modsContext(for: app) else { return }
        LCGameMods.move(entry, direction: direction, in: context.modsDir, titleID: context.titleID)
        reload()
    }

    private func runDelete(_ entry: LCGameMods.ModEntry) {
        guard let context = LCGameMods.modsContext(for: app) else { return }
        do {
            try LCGameMods.delete(entry, in: context.modsDir)
            reload()
        } catch {
            resultTitle = "lc.mods.section".loc
            resultMessage = "lc.mods.failed".loc.localizeWithFormat(error.localizedDescription)
        }
    }

    private func pickedModFolder(_ url: URL) {
        let name = LCGameMods.baseName(of: url.lastPathComponent)
        pendingImport = url
        pendingImportName = name
        if entries.contains(where: { $0.name == name }) {
            confirmImportOverwrite = true
        } else {
            pendingImport = nil
            runImport(source: url)
        }
    }

    private func runImport(source: URL) {
        guard let context = LCGameMods.modsContext(for: app) else { return }
        let box = CancelBox()
        cancelBox = box
        busy = true
        importing = true
        progress = 0
        let modsDir = context.modsDir
        let titleID = context.titleID
        Task.detached(priority: .userInitiated) {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            do {
                _ = try await LCGameMods.importMod(from: source, into: modsDir, titleID: titleID, isCancelled: { box.cancelled }) { done, total in
                    await MainActor.run {
                        progress = total > 0 ? Double(done) / Double(total) : 0
                    }
                }
                await MainActor.run {
                    busy = false
                    importing = false
                    reload()
                    resultTitle = "lc.mods.import".loc
                    resultMessage = "lc.mods.importDone".loc
                }
            } catch LCDatapackCopyError.cancelled {
                await MainActor.run {
                    busy = false
                    importing = false
                }
            } catch LCGameModError.invalidMod {
                await MainActor.run {
                    busy = false
                    importing = false
                    resultTitle = "lc.mods.import".loc
                    resultMessage = "lc.mods.importInvalid".loc
                }
            } catch {
                await MainActor.run {
                    busy = false
                    importing = false
                    resultTitle = "lc.mods.import".loc
                    resultMessage = "lc.mods.failed".loc.localizeWithFormat(error.localizedDescription)
                }
            }
        }
    }
}
