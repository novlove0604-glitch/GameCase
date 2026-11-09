//
//  LCGameSettingsView.swift
//  LiveContainerSwiftUI
//
//  每游戏设置页：改动写进这个游戏在容器里的偏好 plist，与游戏内启动器、
//  按键编辑器共用一份，下次启动生效。档案由 LCGameProfile 从客体自带的
//  dm/launcher.json 解析（纯镜像），没有档案的游戏给通用提示。
//
//  Phase 17（用户 2026-11-05 定：游戏设置页全部照搬 NX2 壳）：本页呈现层
//  逐项镜像 NX 壳每游戏设置页（ShellUI 的 PaneBanner / GameDetailView /
//  SettingControl / SegmentedChoice / CreamToggleStyle / RangeControl）：
//  大封面头 + 左下信息簇、左上浮排「‹ 游戏库」胶囊（ChipButtonStyle）、
//  选项类分段控件（2–4 项且放得下时）、奶油开关、滑杆行、分组卡与分隔。
//  数据与语义仍是 LC 的：头部状态/胶囊走数据包状态，胶囊仅缺包时出现
//  （「导入数据包…」），不加开始游戏；写路径（LCGamePrefs）零改。
//  NX 独有内容（选数据文件夹 / 云存档 / 删除游戏）不搬；LC 独有行
//  （数据包 / 封面图 / 存档 / Mod / 金手指 / 高级 / 恢复默认）保留
//  功能、按 NX 的行语言排。字型：NX 用 Manrope，本页用系统字体同
//  字号/字重代。
//  按键布局入口已临时下架（Phase 21）：编辑页与布局数据留在仓里，
//  后续调整好再恢复入口；已保存的自定义布局仍由客体引擎读取生效。
//
//  Phase 29（滑动掉帧修复，用户 2026-11-07 真机报）：滚动时头部背景
//  的 GeometryReader 逐帧把 minY 回写本页 @State（Phase 28 出血条
//  耦合），整页 body 逐帧重算——而 body 求值路径上全是现算的磁盘
//  活：封面解析每次现读现解码整幅 1920×1080（bannerResolution 自
//  注「不做缓存」）、游戏状态每次枚举容器目录 + 读 romfs.id、日志
//  大小每次取文件属性，且各被读 3–4 次。修法两条、呈现零改：①滚动
//  位置改走引用模型 LCSettingsHeaderScroll，出血条拆成独立子视图
//  单独订阅，逐帧只重排它自己；②封面 / 状态 / 日志大小改为事件驱
//  动的 @State 缓存（coverRefresh / statusRefresh 变化时各重算一
//  次），body 只读缓存。
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers


/// 裁剪页呈现载荷（fullScreenCover item）
private struct LCCoverCropItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// 封面头滚动位置的传递模型（Phase 29）：头部量测逐帧写、页面根
/// 出血条逐帧读；走引用模型使这两处都不经设置页 body——写方写它
/// 不触发本页重算，读方（LCSettingsTopBleed）单独订阅重排。
private final class LCSettingsHeaderScroll: ObservableObject {
    @Published var originY: CGFloat = 0
}

/// NX ShellPalette 的逐值移植（Phase 17）：页底 / 卡面 / 奶油 / 就绪绿 /
/// 注意琥珀 / 发丝线。LCGameTheme 的奶油色是近似值，本页照搬后统一用这里。
private enum LCNXColor {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.06)
    static let surface = Color(red: 0.10, green: 0.10, blue: 0.11)
    static let cream = Color(red: 1, green: 0.94, blue: 0.84)
    static let ready = Color(red: 0.25, green: 0.84, blue: 0.47)
    static let attention = Color(red: 1, green: 0.78, blue: 0.24)
    /// 已损坏（状态机三态新增，与 LCGameTheme.brokenRed / 主页同值）
    static let broken = Color(red: 1, green: 0.42, blue: 0.38)
    static let hairline = Color.white.opacity(0.08)
}

/// NX ChipButtonStyle 移植：「‹ 游戏库」深色胶囊（ultraThinMaterial 叠
/// 黑 0.5、按下 0.62，白 0.14 描边，强制暗色环境渲染材质）。
/// iOS 26 + Liquid Glass 可用时背景换原生玻璃（浮在封面图上，前景
/// 白字不动，按压反馈由玻璃 interactive 自带）；否则逐字保留原实现。
private struct LCNXChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .foregroundColor(.white)
            .modifier { content in
                if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                    content
                        .glassEffect(.regular.tint(.black.opacity(0.35)).interactive(), in: .capsule)
                } else {
                    content
                        .background {
                            ZStack {
                                Capsule().fill(.ultraThinMaterial)
                                Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.62 : 0.5))
                            }
                        }
                        .overlay {
                            Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                        }
                }
            }
            .contentShape(Capsule())
    }
}

/// NX PrimaryPillStyle 移植：奶油底黑字大胶囊（bold 17、minHeight 50、
/// 横向内距 26，按下 opacity 0.78 + scale 0.98）
private struct LCNXPrimaryPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 26)
            .frame(minHeight: 50)
            .foregroundColor(.black)
            .background(LCNXColor.cream, in: Capsule())
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// NX ShellButtonStyle(fills: true) 移植：满宽浅底钮（14 semibold、
/// minHeight 44、白 0.055 底——按下 0.13、圆角 9、白 0.10 描边）
private struct LCNXShellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundColor(.white)
            .background(Color.white.opacity(configuration.isPressed ? 0.13 : 0.055),
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            }
    }
}

/// NX CreamSwitch 移植：46×28 奶油轨开关。NX 用本地 shown 态驱动钮位
/// 动画（外部值变化时 onChange 同步），本版同法；动画曲线 NX 为
/// .snappy（iOS 17+），部署目标 iOS 15，用等效 spring 代（报告注明）。
private struct LCCreamSwitch: View {
    let isOn: Bool
    var onToggle: (Bool) -> Void
    @State private var shown: Bool?

    private var displayOn: Bool { shown ?? isOn }

    var body: some View {
        Button {
            let target = !displayOn
            withAnimation(.spring(response: 0.2, dampingFraction: 0.75)) {
                shown = target
            }
            onToggle(target)
        } label: {
            ZStack(alignment: displayOn ? .trailing : .leading) {
                Capsule()
                    .fill(displayOn ? LCNXColor.cream : Color.white.opacity(0.14))
                    .frame(width: 46, height: 28)
                Circle()
                    .fill(displayOn ? LCNXColor.background : Color.white.opacity(0.85))
                    .padding(3)
                    .frame(width: 28, height: 28)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onChange(of: isOn) { newValue in
            shown = newValue
        }
    }
}

/// NX 的 choice 行移植（SettingControl + SegmentedChoice + ChoiceValueRow）：
/// 选项 2–4 个且每个标签在等宽段内放得下（按 NX 的判定式，字宽用
/// UIFont 实测代入）→ 分段条；否则整行值选择器（LC 既有 Menu 承载）。
/// 行宽与 NX SettingControl 同法：背景 GeometryReader 实测进 @State。
private struct LCChoiceRow: View {
    let setting: LCLauncherSetting
    let currentValue: String
    let locked: Bool
    var onPick: (String) -> Void
    @State private var rowWidth: CGFloat = 0

    var body: some View {
        Group {
            if useSegments {
                VStack(alignment: .leading, spacing: 12) {
                    labelBlock
                    segmentedBar
                }
            } else {
                Menu {
                    ForEach(setting.options, id: \.value) { option in
                        Button {
                            onPick(option.value)
                        } label: {
                            if option.value == currentValue {
                                Label(option.label, systemImage: "checkmark")
                            } else {
                                Text(option.label)
                            }
                        }
                    }
                } label: {
                    valueRow
                }
            }
        }
        .disabled(locked)
        .opacity(locked ? 0.45 : 1)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { rowWidth = geo.size.width }
                    .onChange(of: geo.size.width) { rowWidth = $0 }
            }
        }
    }

    /// NX SettingControl.label：标题 15 medium + 说明 12.5 白 0.5，spacing 4
    private var labelBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(setting.label)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
            if locked || !setting.note.isEmpty {
                Text(locked ? "由 env 文件固定，在这里改不了" : setting.note)
                    .font(.system(size: 12.5))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// NX 的分段判定（ChoicePresentation）：2–4 段，且最宽标签
    /// （13.5 bold 实测字宽 + 左右内距 28）不超过等宽段宽
    private var useSegments: Bool {
        let options = setting.options
        guard (2...4).contains(options.count), rowWidth > 0 else { return false }
        let segmentWidth = (rowWidth - 6 - 2 * CGFloat(options.count - 1)) / CGFloat(options.count)
        let font = UIFont.systemFont(ofSize: 13.5, weight: .bold)
        return options.allSatisfy { option in
            (option.label as NSString).size(withAttributes: [.font: font]).width + 28 <= segmentWidth
        }
    }

    /// NX SegmentedChoice：轨道 padding 3、白 0.055、圆角 11、白 0.08
    /// 描边；段间距 2 等宽，字 13.5（选中 bold 黑字奶油底圆角 8，
    /// 未选 medium 白 0.75），段 minHeight 40、横向内距 14。
    /// 等宽用 HStack + maxWidth .infinity（NX 的 EqualRow 是 iOS 16
    /// Layout 协议，部署目标 iOS 15 不可用，报告注明）。
    private var segmentedBar: some View {
        HStack(spacing: 2) {
            ForEach(setting.options, id: \.value) { option in
                let chosen = option.value == currentValue
                Button {
                    onPick(option.value)
                } label: {
                    Text(option.label)
                        .font(.system(size: 13.5, weight: chosen ? .bold : .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .foregroundColor(chosen ? .black : .white.opacity(0.75))
                        .background(chosen ? LCNXColor.cream : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    /// NX ChoiceValueRow：整行浅底（白 0.055、圆角 11、白 0.08 描边、
    /// 内距横 14 纵 8、minHeight 48），值 14.5 semibold 奶油右置，
    /// chevron 13 bold 白 0.4
    private var valueRow: some View {
        HStack(spacing: 12) {
            labelBlock
            Text(setting.optionLabel(for: currentValue))
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundColor(LCNXColor.cream)
                .multilineTextAlignment(.trailing)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 11))
    }
}

struct LCGameSettingsView: View {
    @ObservedObject var app: LCAppModel
    var onOpenDataFolder: () -> Void
    /// 横屏侧面板呈现时的关闭回调（Phase 14，列表层注入）：面板不是
    /// 系统呈现，dismiss 环境无效，关闭走此回调；nil = sheet 呈现，
    /// 「‹ 游戏库」钮用 dismiss 环境关闭（列表层包 NavigationView 供
    /// 页内子页推进），与原来一致。
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false
    @State private var appSettingsPresented = false
    @State private var prefs: LCGamePrefs?
    @State private var settings: [LCLauncherSetting] = []
    @State private var hasProfile = false
    @State private var lockedValues: [String: String] = [:]
    /// env → 当前生效值（已保存选择 ?? env 固定值 ?? 档案默认值），驱动所有行显示
    @State private var currentValues: [String: String] = [:]
    @State private var datapackRequest: LCDatapackRequest?
    @State private var logPresented = false // 日志查看器（游戏组日志行 / 损坏帮助卡共用）
    @State private var showGuestLauncher = false // 「高级」组：显示游戏启动页（LCGameMods.LauncherGate）
    @State private var statusRefresh = 0 // 数据包导入完成后 bump，刷新状态点
    @State private var confirmReset = false
    @State private var headerWidth: CGFloat = 0 // 封面头实测宽（NX PaneBanner 同法，背景 GeometryReader 回填）
    @State private var headerHeight: CGFloat = 0 // 封面头实测高（Phase 28：页面根出血条的帧高 = 本值 + topInset）
    // 封面头滚动位置（Phase 29 改走引用模型，见类注）：逐帧回写不再进本页 @State
    @StateObject private var headerScroll = LCSettingsHeaderScroll()
    // 事件驱动缓存（Phase 29）：封面解析 / 游戏状态 / 日志大小原先在
    // body 里现算（磁盘读 + 整图解码 + 目录枚举），现只在 coverRefresh /
    // statusRefresh 变化时各重算一次，body 只读这三份缓存
    @State private var coverCache: (image: UIImage?, source: LCGameLibraryInfo.BannerSource) = (nil, .icon)
    @State private var stateCache: LCGameState = .needsDatapack
    @State private var logSizeCache: Int64?

    // 自定义封面流程（选图 → 16:9 裁剪 → 存宿主 Documents/CustomCovers）
    @State private var coverRefresh = 0 // 换/删自定义封面后 bump，刷新本页封面头与封面行
    @State private var coverMenuPresented = false
    @State private var photoPickerPresented = false
    @State private var filePickerPresented = false
    @State private var cropItem: LCCoverCropItem?
    @State private var coverErrorPresented = false

    private static let pageBackground = Color(red: 0.055, green: 0.055, blue: 0.059)

    /// 页面根坐标系名（Phase 28）：封面头的背景量测 GeometryReader 以
    /// 此读头部在页面内的 minY，驱动页面根出血条随滚动同速移动
    private static let pageCoordinateSpace = "LCGameSettingsPage"

    private var knownGame: LCKnownGame? {
        LCKnownGame.from(bundleIdentifier: app.bundleIdentifier)
    }

    private var container: LCContainer? {
        LCGameLibraryInfo.defaultContainer(for: app)
    }

    var body: some View {
        // 版式（Phase 17 照搬 NX settingsPane）：ScrollView 顶格放封面头
        // （出血到页/面板边缘），其下内容列横向 24、上 18、下 32、块距 30；
        // 「‹ 游戏库」胶囊浮排在封面左上（NX 返回钮排法：leading 16、
        // top 6），导航栏隐藏（Phase 16 的工具栏标题删除后，本轮连
        // 工具栏一并撤掉，关闭动作只剩这颗浮排钮 + 下滑关 sheet）。
        // 横屏 640 收窄仍由 LCSettingsColumn 在根层给 ScrollView 本体
        // 定宽居中（视口层，见 LCSettingsColumn.swift 注释），头部与
        // 内容列同在列内，宽随列宽。
        LCSettingsColumn { _ in
        ZStack(alignment: .topLeading) {
            coverTopBleed
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    coverHeader
                        .fullScreenCover(item: $cropItem) { item in
                            NavigationView {
                                LCCoverCropView(image: item.image) { cropped in
                                    saveCroppedCover(cropped)
                                }
                            }
                        }
                    VStack(alignment: .leading, spacing: 30) {
                        detailLead
                        if !hasProfile {
                            noProfileHint
                        } else if prefs == nil {
                            noContainerHint
                        } else {
                            profileSections
                        }
                        gameInfoSection
                            .confirmationDialog("封面图", isPresented: $coverMenuPresented, titleVisibility: .visible) {
                                Button("从相册选择") { photoPickerPresented = true }
                                Button("从文件选择") { filePickerPresented = true }
                                if coverHasCustom || coverHasFetched {
                                    Button("恢复默认", role: .destructive) { removeCustomCover() }
                                }
                                Button("lc.common.cancel".loc, role: .cancel) {}
                            } message: {
                                Text("自定义封面只替换游戏库里的显示图，存在本机，不影响游戏本体。")
                            }
                            .sheet(isPresented: $photoPickerPresented) {
                                LCPhotoImagePicker(
                                    onPick: { image in
                                        photoPickerPresented = false
                                        presentCrop(for: image)
                                    },
                                    onFail: {
                                        photoPickerPresented = false
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                            coverErrorPresented = true
                                        }
                                    },
                                    onCancel: { photoPickerPresented = false }
                                )
                                .ignoresSafeArea()
                            }
                            .fileImporter(isPresented: $filePickerPresented, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
                                handleCoverFileImport(result)
                            }
                            .alert("无法使用这张图片", isPresented: $coverErrorPresented) {
                                Button("好", role: .cancel) {}
                            } message: {
                                Text("所选内容不是有效的图片，或保存失败，请换一张再试。")
                            }
                        // 存档导入/导出组：存档目录（Documents/save）不存在时
                        // 子视图自隐（判据与依据见 LCSaveDataTransfer.swift 文件头）
                        LCSaveDataSectionView(app: app)
                        // 云存档组：选 iCloud Drive 文件夹 + 书签保管，
                        // 启动前经 env 维护把路径递给引擎自带 save_sync
                        //（候选 B，有容器才显示，见 LCGameCloudSaves.swift 文件头）
                        LCGameCloudSavesSectionView(app: app, refreshToken: statusRefresh)
                        // Mod 组：名单 + 导入 + 管理（启停 / 排序 / 删除），
                        // 无容器时子视图自隐（判据与维护机制见 LCGameMods.swift 文件头）
                        LCGameModsSectionView(app: app, refreshToken: statusRefresh)
                        // 金手指组：导入 .txt + 逐条开关（.enabled）+ 删除，
                        // 无容器时子视图自隐（引擎语义与 env 维护见
                        // LCGameCheats.swift 文件头）
                        LCGameCheatsSectionView(app: app, refreshToken: statusRefresh)
                        if hasProfile, prefs != nil, hasSavedValues {
                            resetRow
                        }
                        advancedSection
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
            }
            Button {
                if let onClose {
                    onClose()
                } else {
                    dismiss()
                }
            } label: {
                Label("游戏库", systemImage: "chevron.left")
            }
            .buttonStyle(LCNXChipButtonStyle())
            .padding(.leading, 16)
            .padding(.top, 6)
        }
        .coordinateSpace(name: Self.pageCoordinateSpace)
        .navigationBarHidden(true)
        }
        .background(Self.pageBackground.ignoresSafeArea())
        .onAppear {
            // 每次进页都按磁盘现状重解析封面与数据包状态（两个计数器被封面头 /
            // 封面行 / 数据包行读取，bump 即重算），不依赖上一次会话的快照
            coverRefresh += 1
            statusRefresh += 1
            loadState()
            // 联网封面懒抓（Phase 19）：展示时无缓存、无负缓存则补抓一次，
            // 成功回调 bump 本页 coverRefresh，封面头与封面行即时换上新图
            LCCoverFetchService.shared.ensureFetched(appInfo: app.appInfo) {
                self.coverRefresh += 1
            }
        }
        // Phase 29：两计数器是本页既有的刷新信号（进页 / 导入关页 /
        // 换封面 / 联网封面抓到），缓存重算统一挂在它们的变化上，各一次
        .onChange(of: coverRefresh) { _ in
            coverCache = LCGameLibraryInfo.bannerResolution(for: app.appInfo)
        }
        .onChange(of: statusRefresh) { _ in
            stateCache = LCGameLibraryInfo.gameState(for: app)
            logSizeCache = LCGameLibraryInfo.guestLogSize(for: app)
        }
        // onDismiss 覆盖导入页的全部退出路径：原先刷新只挂在导入视图的
        // onFinished 上，而它仅由「完成」钮触发——用工具栏「取消」或下滑关页
        // 时状态行不重算（导入失败 / 取消同理要回到与磁盘一致的状态）。
        .sheet(item: $datapackRequest, onDismiss: {
            statusRefresh += 1
            // 导入可能伴随容器注册变化，关页后整页按磁盘重读（含偏好值）
            loadState()
        }) { request in
            LCDatapackImportView(request: request, apps: [app])
        }
        .sheet(isPresented: $logPresented) {
            LCGameLogView(app: app)
        }
        .confirmationDialog("恢复默认设置？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("恢复默认", role: .destructive) {
                resetAll()
            }
            Button("lc.common.cancel".loc, role: .cancel) {}
        } message: {
            Text("清掉这个游戏在库里保存的全部启动器选择，回到打包时的默认值。按键布局不受影响。")
        }
    }

    // MARK: 封面头（NX PaneBanner 移植）

    /// 头部高度与 topInset（Phase 26 按 NX 原式找回）：NX 的头部顶
    /// 在物理顶（ScrollView 忽略安全区），bannerHeight = 有横图
    /// min(宽×9/16, 220) + topInset、无横图 topInset + 64，信息簇以
    /// padding.top = bannerHeight − 22 压在图下缘——topInset 项的作
    /// 用是让整幅图与簇一起下移，簇相对安全区的位置不变。
    /// LC 的坐标系不同：头部布局顶在安全线（外包 NavigationView
    /// 把设备顶部安全区还给内容），簇的布局公式（padding.top =
    /// min(宽×9/16, 220) − 22 / 无横图 64）与既有逐点一致、簇与
    /// 「‹ 游戏库」钮相对安全区的位置都不动；NX 的 +topInset 在此
    /// 坐标系里等价于「只把背景层向上出血 topInset」——背景帧扩到
    /// 物理顶后，底图的总高（帧高 + 160 溢出）与 NX 逐点相同（图
    /// 顶同为物理顶、图高同为 bannerHeight − 22 + 簇高 + 160）。
    /// 切勿把 topInset 加进布局公式：那会让簇在安全线之下再下移
    /// 一整段（双算）。
    /// topInset 取窗口顶部安全区真值（LCSidePanelSpec
    /// .windowTopSafeInset），逐次求值现读：竖屏为设备值（59）、
    /// 手机横屏状态栏隐藏时为 0，旋转后即为新方向的值，两形态
    /// 同式、不残留。封面走既有解析链（自定义 → 客体横版图 →
    /// 内置原画 → 联网获取 → 图标）；来源为图标时按 NX 无横图
    /// 路：图标自体模糊底 + 96×96 缩略图。
    ///
    /// Phase 28（Phase 26 出血在真机失效，跟进修复）：main/15c7795
    /// 真机裁决顶部仍是黑带、封面仍从安全线才起。失效根因两层、
    /// 任一独立成立：①协商被吃——ignoresSafeArea 只能把视图扩进
    /// 「其自身安全区里尚存的 inset」，而外包 NavigationView 已把
    /// 设备顶部 inset 解析进内容布局帧（内容顶缘 = 安全线，Phase
    /// 24 实测），提案到达头部背景时继承到的 top inset 已是 0，
    /// 修饰符扩 0、恒为无操作（本工程安全区数值一律取 UIKit 真值
    /// 同因）；②视口裁剪——背景身处 ScrollView 内容内、视口顶缘
    /// 即安全线，内容绘制被裁在视口内，纵使扩得出、安全线以上
    /// 那段也会被切掉（现行 +160 向下溢出能存活，只因始终在视口
    /// 内）。修法改显式几何、两处配合：头内背景以 .offset(y:
    /// −topInset) 显式上移、绘制总高相应 += topInset（extraTop
    /// 参数），把图像映射定死为「图顶 = 物理顶、总高 = 帧高 +
    /// topInset + 160」与 NX 逐点一致；其安全线以上一段仍会被视
    /// 口裁掉，由页面根的 coverTopBleed 以同一映射补画该带（挂在
    /// ScrollView 之外、无从裁剪），且随头部滚动同速移动、两份
    /// 在安全线处严丝合缝。信息簇 / 胶囊 / scrim 逐点不动
    /// （scrim 在背景体内、锚点随背景顶回到物理顶，即 Phase 26
    /// 的设计位置）。横屏面板 topInset = 0：offset 与 extraTop
    /// 皆 0、出血条不渲染，逐点同现行。
    private var coverHeader: some View {
        let resolution = coverCache
        let hasBanner = resolution.source != .icon
        let width = headerWidth > 0 ? headerWidth : 430
        let bannerHeight = hasBanner ? min(width * 9 / 16, 220) : 64.0
        let topInset = LCSidePanelSpec.windowTopSafeInset
        return ZStack(alignment: .bottomLeading) {
            headerCluster(hasBanner: hasBanner, image: resolution.image, wide: width >= 560)
                .padding(.horizontal, 24)
                .padding(.top, bannerHeight - (hasBanner ? 22 : 0))
        }
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .background {
            // 背景层显式上移 topInset 到物理顶（布局帧不动）：绘制
            // 总高经 extraTop 同步加 topInset，图像映射与 NX 一致；
            // 安全线以上一段被 ScrollView 视口裁掉，由页面根的
            // coverTopBleed 同映射补画（Phase 28，见头部注）
            LCSettingsHeaderBackdrop(image: resolution.image, hasBanner: hasBanner, topInset: topInset, extraTop: topInset)
                .offset(y: -topInset)
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        headerWidth = geo.size.width
                        headerHeight = geo.size.height
                        headerScroll.originY = geo.frame(in: .named(Self.pageCoordinateSpace)).minY
                    }
                    .onChange(of: geo.size.width) { headerWidth = $0 }
                    .onChange(of: geo.size.height) { headerHeight = $0 }
                    // 逐帧滚动位置只写引用模型（Phase 29），不回本页 @State
                    .onChange(of: geo.frame(in: .named(Self.pageCoordinateSpace)).minY) { headerScroll.originY = $0 }
            }
        }
    }

    /// 顶部出血条（Phase 28 形态，Phase 29 拆独立子视图
    /// LCSettingsTopBleed）：与封面头同体的一份封面背景，挂在页面
    /// 根 ZStack（ScrollView 之外，不受滚动视口裁剪），专画安全线
    /// 以上那一带。帧高 = 头部实高 + topInset、extraTop = 0，绘制
    /// 总高与头内那份相同（帧高 + 160），图像映射一致；纵向位置
    /// = 头部当前 minY − topInset：静止时其顶落在物理顶，上滚时
    /// 与头内背景同速同向移动（头内背景在安全线处显出的图像行与
    /// 本条下缘严丝合缝，推导：两者在窗口坐标里的绘制原点恒为同
    /// 一值 minY − topInset）。minY 经 LCSettingsHeaderScroll 传
    /// 递（Phase 29），逐帧只重排出血条子视图。topInset = 0（横
    /// 屏面板形态）时不渲染、逐点同现行；无横图（图标模糊兜底）
    /// 时同体背景同样出血。不拦截触摸。
    private var coverTopBleed: some View {
        LCSettingsTopBleed(
            scroll: headerScroll,
            image: coverCache.image,
            hasBanner: coverCache.source != .icon,
            headerHeight: headerHeight,
            topInset: LCSidePanelSpec.windowTopSafeInset
        )
    }

    /// 信息簇的排布（NX PaneBanner.words / cluster）：有横图 = 仅信息簇；
    /// 无横图 = 宽 ≥560 时缩略图与信息簇 HStack(bottom, spacing 22)，
    /// 否则 VStack(leading, spacing 16) 上下排。
    @ViewBuilder
    private func headerCluster(hasBanner: Bool, image: UIImage?, wide: Bool) -> some View {
        if hasBanner {
            headerWords
        } else if wide {
            HStack(alignment: .bottom, spacing: 22) {
                headerThumbnail(image: image)
                headerWords
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                headerThumbnail(image: image)
                headerWords
            }
        }
    }

    /// 左下信息簇（NX PaneBanner.words）：状态行（7pt 圆点 + eyebrow
    /// 大写粗字，状态色）/ 大标题（heavy 26、tracking −0.6、限 2 行，
    /// ZStack 内藏隐藏「M\nM」预留两行高）/ 副行（「游戏设置」分组
    /// 小题 + 版本 note），簇内 spacing 8、副行 padding.top 2。
    /// 文案是 LC 语义：状态 ← 数据包状态，副行 ← 版本。
    private var headerWords: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 7, height: 7)
                Text(stateHeadline)
                    .font(.system(size: 11.5, weight: .bold))
                    .tracking(1.3)
                    .foregroundColor(stateColor)
                    .lineLimit(1)
            }
            ZStack(alignment: .bottomLeading) {
                Text("M\nM")
                    .font(.system(size: 26, weight: .heavy))
                    .tracking(-0.6)
                    .hidden()
                Text(app.displayName)
                    .font(.system(size: 26, weight: .heavy))
                    .tracking(-0.6)
                    .foregroundColor(.white)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Text("游戏设置")
                    .font(.system(size: 11.5, weight: .semibold))
                    .tracking(1.6)
                    .foregroundColor(LCNXColor.cream.opacity(0.72))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text("版本 \(app.version)")
                    .font(.system(size: 12.5))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.top, 2)
        }
    }

    /// NX CoverThumbnail 移植：96×96、圆角 18、白 0.14 描边、
    /// 阴影 black 0.4 / radius 16 / y 6
    private func headerThumbnail(image: UIImage?) -> some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let icon = app.appInfo.iconIsDarkIcon(darkModeIcon) {
                Image(uiImage: icon).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color.white.opacity(0.08))
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }

    // MARK: 头部以下（NX GameDetailView 的头部块与分组）

    /// NX GameDetailView 头部块：说明行（14、白 0.72）+ 状态区；
    /// LC 语义——说明行固定文案，状态区照 NX GameStateView 的形态：
    /// 可玩时什么都不出；缺数据包 / 已损坏时出一张修复帮助卡
    /// （状态 + 怎么修 + 动作：导入数据包 / 查看日志 + 重新导入，
    /// 见 LCGameStateHelpCard），动作仍走既有导入流程与本页日志页；
    /// 不加开始游戏（用户早前已把启动撤出设置页）。
    private var detailLead: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置写入游戏容器，下次启动生效")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.72))
            if !gameState.isPlayable {
                LCGameStateHelpCard(state: gameState, onImportDatapack: {
                    datapackRequest = LCDatapackRequest(app: app)
                }, onShowLog: {
                    logPresented = true
                })
            }
        }
    }

    /// NX 导航行语言（LC 独有行适配用）：标签 15 medium 白、值 14.5
    /// semibold 奶油（或 note 12.5 白 0.5）、chevron.right 13 bold
    /// 白 0.4、行 minHeight 48
    private func navRow<Value: View>(label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
            Spacer(minLength: 8)
            value()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    /// NX 组内分隔：白 0.06、高 1
    private var nxDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
    }

    // MARK: 游戏（LC 独有组：NX 无对应，按 NX 行语言适配）

    private var datapackReady: Bool {
        // Phase 29：改读状态缓存。三态里只有 .needsDatapack 表示「没
        // 探到任何数据包条目」，与旧二态（探到镜像条目或 romfs 文件
        // 夹即 true）在全部分支上等价（无容器同为 false）；重算挂在
        // body 的 .onChange(of: statusRefresh)，求值仍走共用入口
        stateCache != .needsDatapack
    }

    /// 游戏状态（三态，与库主页共用 LCGameLibraryInfo.gameState 解析，
    /// 判定口径见 LCGameState.swift 文件头）。本页头部状态行、detailLead
    /// 帮助卡、数据包行都读它；旧 datapackReady 二态保留给其余既有
    /// 读数（两套口径的差异只在损坏态：二态把异常文件也算「在」，
    /// 三态把异常单列已损坏，导入链复核仍走二态、未动）。
    private var gameState: LCGameState {
        // Phase 29：只读缓存（重算挂在 .onChange(of: statusRefresh)，
        // 仍走 LCGameLibraryInfo.gameState 共用入口）；此前每次 body
        // 求值都要枚举容器目录 + 读 romfs.id，且被读 3–4 次
        stateCache
    }

    private var stateColor: Color {
        switch gameState {
        case .playable: return LCNXColor.ready
        case .needsDatapack: return LCNXColor.attention
        case .broken: return LCNXColor.broken
        }
    }

    /// 头部状态文案：可玩 / 缺包沿用旧文案；损坏照 NX StatusLabel 的
    /// broken 形态直接显示短原因（全文在帮助卡里，头部限一行）
    private var stateHeadline: String {
        switch gameState {
        case .playable: return "随时可玩"
        case .needsDatapack: return "需要导入数据包"
        case .broken(let reason, _, _): return reason
        }
    }

    /// 数据包行右侧值（文字 + 色，与状态三态对应）
    private var datapackRowValue: (text: String, color: Color) {
        switch gameState {
        case .playable: return ("已就绪", LCNXColor.ready)
        case .needsDatapack: return ("未导入", LCNXColor.attention)
        case .broken: return ("已损坏", LCNXColor.broken)
        }
    }

    /// 日志行右侧值：有日志显示大小，无日志（或还没容器）显示「暂无」
    private var logRowValue: String {
        // Phase 29：大小读缓存（与状态同挂 statusRefresh 重算）
        guard let size = logSizeCache else {
            return "暂无"
        }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private var gameInfoSection: some View {
        sectionCard(title: "游戏") {
            Button {
                datapackRequest = LCDatapackRequest(app: app)
            } label: {
                navRow(label: "数据包 romfs.img") {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(datapackRowValue.color)
                            .frame(width: 7, height: 7)
                        Text(datapackRowValue.text)
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundColor(datapackRowValue.color)
                    }
                }
            }
            .buttonStyle(.plain)
            nxDivider
            Button {
                coverMenuPresented = true
            } label: {
                navRow(label: "封面图") {
                    coverRowThumbnail
                    Text(coverResolution.source.displayName)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundColor(LCNXColor.cream)
                }
            }
            .buttonStyle(.plain)
            nxDivider
            Button {
                onOpenDataFolder()
            } label: {
                navRow(label: "存档") {
                    Text("在本机")
                        .font(.system(size: 12.5))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .buttonStyle(.plain)
            nxDivider
            Button {
                logPresented = true
            } label: {
                navRow(label: "日志") {
                    Text(logRowValue)
                        .font(.system(size: 12.5))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 自定义封面（来源/缩略图/选图与保存）

    /// 当前封面解析结果（来源 + 图）：Phase 29 起只读缓存——解析链
    /// 每次现读现解码整幅封面，重算挂在 .onChange(of: coverRefresh)，
    /// 换图后计数器一变缓存即新图，本行随同一次刷新换上
    private var coverResolution: (image: UIImage?, source: LCGameLibraryInfo.BannerSource) {
        coverCache
    }

    private var coverHasCustom: Bool {
        LCCustomCoverStore.exists(forBundleIdentifier: app.bundleIdentifier)
    }

    private var coverHasFetched: Bool {
        LCFetchedCoverStore.exists(forBundleIdentifier: app.bundleIdentifier)
    }

    @ViewBuilder
    private var coverRowThumbnail: some View {
        Group {
            if let image = coverResolution.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let icon = app.appInfo.iconIsDarkIcon(darkModeIcon) {
                Image(uiImage: icon).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color.white.opacity(0.08))
            }
        }
        .frame(width: 44, height: 25)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .clipped()
    }

    /// 选图器关掉后再呈现裁剪页（错开两个呈现，避免同帧抢呈现失败）
    private func presentCrop(for image: UIImage) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            cropItem = LCCoverCropItem(image: image)
        }
    }

    private func handleCoverFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            coverErrorPresented = true
            return
        }
        presentCrop(for: image)
    }

    private func saveCroppedCover(_ cropped: UIImage) {
        do {
            try LCCustomCoverStore.save(cropped, forBundleIdentifier: app.bundleIdentifier)
            coverRefresh += 1
        } catch {
            coverErrorPresented = true
        }
    }

    private func removeCustomCover() {
        LCCustomCoverStore.remove(forBundleIdentifier: app.bundleIdentifier)
        // 恢复默认连联网抓取缓存一并删，并清掉负缓存记录——删完之后
        // 主页 / 设置页再次展示时允许重新抓（Phase 19）
        LCFetchedCoverStore.remove(forBundleIdentifier: app.bundleIdentifier)
        LCCoverFetchService.shared.clearNegativeCache(forBundleIdentifier: app.bundleIdentifier)
        coverRefresh += 1
    }

    // MARK: 档案分组

    private var hasSavedValues: Bool {
        guard let prefs else { return false }
        return prefs.hasLauncherValues(settings)
    }

    @ViewBuilder
    private var profileSections: some View {
        let groups = groupedSettings()
        ForEach(groups, id: \.title) { group in
            sectionCard(title: group.title) {
                ForEach(group.rows) { setting in
                    if setting.id != group.rows.first?.id {
                        nxDivider
                    }
                    settingRow(setting)
                }
            }
        }
    }

    /// 档案分组 → 预览分组：Game 显示 / Controls 按键 / Performance 性能；
    /// 按键组内皮肤行排最前，其余行保持档案顺序；needs 不满足的行隐藏
    private func groupedSettings() -> [(title: String, rows: [LCLauncherSetting])] {
        let titles: [(String, String)] = [("Game", "显示"), ("Controls", "按键"), ("Performance", "性能")]
        var result: [(title: String, rows: [LCLauncherSetting])] = []
        for (rawSection, title) in titles {
            var rows = settings.filter { $0.section == rawSection && isVisible($0) }
            if rawSection == "Controls", let skinEnv = knownGame?.skinEnv,
               let i = rows.firstIndex(where: { $0.env == skinEnv }) {
                let skin = rows.remove(at: i)
                rows.insert(skin, at: 0)
            }
            if !rows.isEmpty {
                result.append((title: title, rows: rows))
            }
        }
        // 档案里未认得的分组原样排在最后
        let knownSections = Set(titles.map { $0.0 })
        for section in settings.map({ $0.section }).filter({ !knownSections.contains($0) }) {
            let rows = settings.filter { $0.section == section && isVisible($0) }
            if !rows.isEmpty && !result.contains(where: { $0.title == section }) {
                result.append((title: section, rows: rows))
            }
        }
        return result
    }

    private func isVisible(_ setting: LCLauncherSetting) -> Bool {
        guard let needs = setting.needs, let eq = needs.firstIndex(of: "=") else { return true }
        let key = String(needs[..<eq])
        let want = String(needs[needs.index(after: eq)...])
        guard let current = currentValues[key] else { return true }
        return current == want
    }

    // MARK: 行（NX SettingControl 三种控件形态）

    /// NX SettingControl.label：标题在上、说明在下（15 medium /
    /// 12.5 白 0.5，spacing 4），toggle 与 range 共用
    private func settingLabelBlock(_ setting: LCLauncherSetting, locked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(setting.label)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
            if locked || !setting.note.isEmpty {
                Text(locked ? "由 env 文件固定，在这里改不了" : setting.note)
                    .font(.system(size: 12.5))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func settingRow(_ setting: LCLauncherSetting) -> some View {
        let locked = lockedValues[setting.env] != nil
        let value = currentValues[setting.env] ?? setting.defaultValue
        switch setting.kind {
        case "choice":
            LCChoiceRow(setting: setting, currentValue: value, locked: locked) { newValue in
                apply(setting, newValue)
            }
        case "toggle":
            // NX CreamToggleStyle：标签占满左、奶油开关右，行 minHeight 44
            HStack(alignment: .center, spacing: 16) {
                settingLabelBlock(setting, locked: locked)
                LCCreamSwitch(isOn: value == setting.onValue) { isOn in
                    apply(setting, isOn ? setting.onValue : setting.offValue)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .disabled(locked)
            .opacity(locked ? 0.45 : 1)
        case "range":
            rangeRow(setting, locked: locked, value: value)
        default:
            HStack(spacing: 10) {
                settingLabelBlock(setting, locked: locked)
                Text(value)
                    .foregroundColor(.gray)
            }
        }
    }

    /// NX RangeControl：行 1 = 标签块 + 值（15 bold 奶油、等宽数字）基线
    /// 对齐；行 2 = minus 圆钮 44 + Slider（tint 奶油、minHeight 44）+
    /// plus 圆钮 44（圆钮白 0.055 底、白 0.10 描边、符号 14 semibold）。
    /// 写值仍走既有 apply / stepRange（步进对齐不变）。
    private func rangeRow(_ setting: LCLauncherSetting, locked: Bool, value: String) -> some View {
        let raw = Double(value) ?? setting.minValue
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                settingLabelBlock(setting, locked: locked)
                Text(LCLauncherSetting.formatRange(raw))
                    .font(.system(size: 15, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(LCNXColor.cream)
            }
            HStack(spacing: 10) {
                rangeStepButton("minus", setting: setting, direction: -1)
                Slider(
                    value: Binding(
                        get: { raw },
                        set: { apply(setting, LCLauncherSetting.formatRange($0)) }
                    ),
                    in: setting.minValue...setting.maxValue,
                    step: setting.stepValue
                )
                .tint(LCNXColor.cream)
                .frame(minHeight: 44)
                rangeStepButton("plus", setting: setting, direction: 1)
            }
        }
        .disabled(locked)
        .opacity(locked ? 0.45 : 1)
    }

    private func rangeStepButton(_ symbol: String, setting: LCLauncherSetting, direction: Double) -> some View {
        Button {
            stepRange(setting, by: direction)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.055), in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    /// NX 的恢复默认块（ShellButtonStyle fills + 其下注文 12.5 白 0.45，
    /// spacing 10）移植；确认对话框沿用既有（body 的 confirmationDialog）
    private var resetRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                confirmReset = true
            } label: {
                Text("恢复默认设置")
            }
            .buttonStyle(LCNXShellButtonStyle())
            Text("清掉这个游戏在库里保存的全部启动器选择，回到打包时的默认值。按键布局不受影响。")
                .font(.system(size: 12.5))
                .foregroundColor(.white.opacity(0.45))
        }
    }

    // MARK: 高级与提示（LC 独有，按 NX 行/文语言适配）

    private var advancedSection: some View {
        sectionCard(title: "高级") {
            Button {
                appSettingsPresented = true
            } label: {
                navRow(label: "容器与高级设置") {
                    Text("GameCase")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundColor(LCNXColor.cream)
                }
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $appSettingsPresented) {
                NavigationView {
                    LCAppSettingsView(model: app)
                }
            }
            nxDivider
            // GC 默认隐藏客体自带启动页、点开直进游戏（env 维护
            // DM_LAUNCHER=0）；这一行逐游戏放行：打开后启动维护改
            // 为删行，下次启动恢复显示启动页。值存 LauncherGate。
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("显示游戏启动页")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)
                    Text("开启后，下次启动先显示游戏自带启动页；关闭则直接进入游戏。")
                        .font(.system(size: 12.5))
                        .foregroundColor(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                LCCreamSwitch(isOn: showGuestLauncher) { isOn in
                    showGuestLauncher = isOn
                    LCGameMods.LauncherGate.setShowsLauncher(isOn, forBundleIdentifier: app.bundleIdentifier)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
    }

    private var noProfileHint: some View {
        sectionCard(title: "游戏设置") {
            Text("该游戏暂无内置档案，请进游戏内启动器调整。")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.72))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var noContainerHint: some View {
        sectionCard(title: "游戏设置") {
            Text("这个游戏还没有数据容器：先启动一次游戏，容器生成后回到这里即可调整设置。")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.72))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 分组卡片（NX SettingsGroup + shellCard 移植）

    /// 分组小题（SectionHeading：11.5 semibold、tracking 1.6、奶油 0.72、
    /// 大写）+ 卡（内容 spacing 14、padding 18、surface 底、圆角 16、
    /// hairline 描边 1pt）；组内行间分隔由调用方插入 nxDivider。
    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(1.6)
                .foregroundColor(LCNXColor.cream.opacity(0.72))
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(LCNXColor.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(LCNXColor.hairline, lineWidth: 1)
            }
        }
    }

    // MARK: 状态装载与写入

    private func loadState() {
        // 先把模型里的容器选择对齐到 appInfo 当前记录，再按对齐后的容器读盘：
        // 客体启动器写偏好走的是被启动容器的 plist，读侧容器若停在模型创建时的
        // 快照上，就会整页读旧容器的值（客体改了 120、这里还显示 60）。
        app.refreshContainerSelection()
        showGuestLauncher = LCGameMods.LauncherGate.showsLauncher(forBundleIdentifier: app.bundleIdentifier)
        let loaded = LCGameProfile.loadSettings(app: app)
        settings = loaded ?? []
        hasProfile = loaded != nil
        lockedValues = LCGameProfile.envLockedValues(app: app, container: container)
        if let container {
            let p = LCGamePrefs(container: container, bundleIdentifier: app.bundleIdentifier)
            prefs = p
            var values: [String: String] = [:]
            for setting in settings {
                if let locked = lockedValues[setting.env] {
                    values[setting.env] = setting.accepts(locked) ? locked : setting.defaultValue
                } else if let saved = p.launcherValue(setting.env), setting.accepts(saved) {
                    values[setting.env] = saved
                } else {
                    values[setting.env] = setting.defaultValue
                }
            }
            currentValues = values
        } else {
            prefs = nil
            currentValues = [:]
        }
    }

    private func apply(_ setting: LCLauncherSetting, _ value: String) {
        guard let prefs, lockedValues[setting.env] == nil else { return }
        prefs.setLauncherValue(setting, to: value)
        currentValues[setting.env] = value
    }

    private func stepRange(_ setting: LCLauncherSetting, by direction: Double) {
        let current = Double(currentValues[setting.env] ?? setting.defaultValue) ?? setting.minValue
        let next = min(max(current + direction * setting.stepValue, setting.minValue), setting.maxValue)
        // 浮点步进对齐，避免 0.30000000004 之类的值落盘
        let aligned = (next / setting.stepValue).rounded() * setting.stepValue
        apply(setting, LCLauncherSetting.formatRange(aligned))
    }

    private func resetAll() {
        guard let prefs else { return }
        prefs.resetLauncherValues(settings)
        var values = currentValues
        for setting in settings where lockedValues[setting.env] == nil {
            values[setting.env] = setting.defaultValue
        }
        currentValues = values
    }
}

private struct LCSettingsHeaderBackdrop: View {
    let image: UIImage?
    let hasBanner: Bool
    let topInset: CGFloat
    let extraTop: CGFloat

/// NX PaneBanner.background 移植：底图按头部实高 +160 绘制（向下
/// 溢出垫进内容区）、整体罩 NX 的渐隐 mask。有横图：原图 +
/// 压暗渐变（clear@0.3 → 黑 0.4@0.6 → 黑 0.55@1）；无横图：
/// 图标自体放大 1.4 + blur 40 + saturation 1.2 + 黑 0.38 叠加。
/// mask stops：黑@0 / 黑@0.45 / 黑 0.55@0.68 / 黑 0.18@0.85 / clear@1。
/// 状态栏 scrim（Phase 26 补回，NX 原规格）：叠在图层之上、mask
/// 之内，topInset > 0 时黑 0.5 → clear、高 topInset + 50，锚在
/// 图顶（背景帧已出血到物理顶）——亮封面下状态栏的时钟与电量
/// 靠它保可读；NX 结构里此 overlay 盖在图层组全体之上，有 /
/// 无横图都生效。
/// 绘制总高（Phase 28）：geo 高 + extraTop + 160。两个实例共用
/// 本视图且映射恒等——头内实例帧高 = 头部高、extraTop =
/// topInset（帧再经 .offset 上移 topInset）；页面根出血条实例
/// 帧高 = 头部高 + topInset、extraTop = 0。两者总高同为头部高
/// + topInset + 160、绘制原点同为物理顶 + 滚动位移。
var body: some View {
    GeometryReader { geo in
        Group {
            if hasBanner, let image {
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height + extraTop + 160)
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0.3),
                        .init(color: .black.opacity(0.4), location: 0.6),
                        .init(color: .black.opacity(0.55), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                    .frame(width: geo.size.width, height: geo.size.height + extraTop + 160)
                }
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height + extraTop + 160)
                    .scaleEffect(1.4)
                    .blur(radius: 40)
                    .saturation(1.2)
                    .overlay(Color.black.opacity(0.38))
            } else {
                Color.clear
            }
        }
        .frame(width: geo.size.width, height: geo.size.height + extraTop + 160, alignment: .top)
        .overlay(alignment: .top) {
            if topInset > 0 {
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: topInset + 50)
            }
        }
    }
    .mask {
        LinearGradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: 0.45),
            .init(color: .black.opacity(0.55), location: 0.68),
            .init(color: .black.opacity(0.18), location: 0.85),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}

}

/// 页面根出血条（Phase 28 形态、Phase 29 拆为独立子视图）：与封面头
/// 同体的一份 LCSettingsHeaderBackdrop，挂在页面根（ScrollView 之
/// 外，不受滚动视口裁剪），专画安全线以上那一带。帧高 = 头部实高
/// + topInset、extraTop = 0，绘制总高与头内那份相同、图像映射一
/// 致；纵向位置 = 头部当前 minY − topInset，随头部滚动同速同向。
/// 单独订阅 LCSettingsHeaderScroll：滚动逐帧只重排本视图，设置页
/// body 不再逐帧重算（Phase 29）。topInset = 0（横屏面板形态）时
/// 不渲染；无横图（图标模糊兜底）时同体背景同样出血。不拦截触摸。
private struct LCSettingsTopBleed: View {
    @ObservedObject var scroll: LCSettingsHeaderScroll
    let image: UIImage?
    let hasBanner: Bool
    let headerHeight: CGFloat
    let topInset: CGFloat

    var body: some View {
        if topInset > 0, headerHeight > 0 {
            LCSettingsHeaderBackdrop(image: image, hasBanner: hasBanner, topInset: topInset, extraTop: 0)
                .frame(height: headerHeight + topInset)
                .offset(y: scroll.originY - topInset)
                .allowsHitTesting(false)
        }
    }
}
