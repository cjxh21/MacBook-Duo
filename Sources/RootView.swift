import SwiftUI
import AppKit
import Combine
import QuartzCore

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            switch model.page {
            case .setup: SetupView(model: model)
            case .test: TestView(model: model, sensor: model.sensor)
            }
        }
        .tint(.blue)
    }
}

private struct SetupView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var sensor: LidAngleSensor

    init(model: AppModel) {
        self.model = model
        self.sensor = model.sensor
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                Label("MacBook Duo", systemImage: "circle.lefthalf.filled")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                List(AppModel.SettingsPage.allCases, selection: $model.settingsPage) { page in
                    Label(page.rawValue, systemImage: page.symbol)
                        .padding(.vertical, 5)
                        .tag(page)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                Spacer()
                Label(model.effectSummary, systemImage: model.globalRunning ? "circle.fill" : "circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            .padding(12)
            .frame(width: 160)
            .background(.regularMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(model.settingsPage.rawValue)
                    .font(.system(size: 24, weight: .bold))
                    .padding(.horizontal, 28).padding(.top, 25).padding(.bottom, 20)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        // Actionable status remains visible regardless of the selected page.
                        if model.permissionsPreparing {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("正在检查屏幕录制权限…")
                            }.font(.callout)
                        } else if !model.globalNotice.isEmpty {
                            Text(model.globalNotice)
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !sensor.isAvailable {
                            Label(sensor.statusText, systemImage: "exclamationmark.circle")
                                .font(.callout).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        switch model.settingsPage {
                        case .effect: effectPage
                        case .appearance: appearancePage
                        case .wallpaper: wallpaperPage
                        case .advanced: advancedPage
                        }
                    }
                    .padding(.horizontal, 28).padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var effectPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard {
                HStack(spacing: 14) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 25, weight: .light))
                        .foregroundStyle(.blue)
                        .frame(width: 48, height: 48)
                        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("实时桌面效果").font(.headline)
                        Text("随屏幕开合，呈现玻璃效果。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    Button(model.globalRunning ? "停止效果" : "启用效果") { model.toggleGlobal?() }
                        .buttonStyle(.borderedProminent)
                    Button("预览 8 秒") { model.previewGlobal?() }
                        .help("无需移动屏幕；画面准备好后开始计时。")
                }
                .controlSize(.large)
                .disabled(model.permissionsPreparing)
            }
            SettingsCard("息屏唤醒动画") {
                Text("启用效果后，未锁屏息屏再唤醒时自动播放翻盖动画。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("动画耗时", selection: $model.desktopWakeDuration) {
                    ForEach(DesktopWakeAnimation.durations, id: \.self) { duration in
                        Text(String(format: "%.1f 秒", duration)).tag(duration)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("desktopWakeDuration")
                Text("时间越短，翻盖越快。设置会自动保存。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsCard("展开位置") {
                HStack(alignment: .firstTextBaseline) {
                    angleValue("当前角度", value: sensor.isAvailable ? "\(Int(sensor.angle.rounded()))°" : "—")
                    Spacer()
                    angleValue("已保存", value: "\(Int(model.openAngle.rounded()))°")
                    Spacer()
                }
                Divider()
                HStack {
                    Text("将屏幕调到日常使用的位置。")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("设为展开位置") { model.calibrateGlobal?() }
                        .disabled(!sensor.isAvailable)
                        .help("此位置及更大角度保持清晰，附近保留约 2° 清晰余量。")
                }
                if !model.calibrationMessage.isEmpty { feedback(model.calibrationMessage) }
            }
        }
    }

    private func angleValue(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit()
        }
    }

    private var appearancePage: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard("性能") {
                Picker("性能模式", selection: $model.performanceMode) {
                    ForEach(PerformanceMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.pickerStyle(.segmented).labelsHidden()
                    .help("自动模式随电源切换，低电量模式优先省电；手动选择会保留。")
                Text(model.effectivePolicy).font(.caption).foregroundStyle(.secondary)
            }
            SettingsCard("玻璃质感") {
                sliderRow("磨砂", value: $model.frost, range: 0...0.18)
                Divider()
                sliderRow("边缘柔和度", value: $model.edgeSoftness, range: 0.25...2)
                HStack { Spacer(); Button("恢复默认") { model.resetAppearance() } }
            }
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 20) {
            Text(title).frame(width: 88, alignment: .leading)
            Slider(value: value, in: range).accessibilityLabel(title)
        }
    }

    private var wallpaperPage: some View {
        SettingsCard("锁屏壁纸") {
            Group {
                if let image = model.wallpaperImage {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Color(nsColor: .controlBackgroundColor)
                        VStack(spacing: 10) {
                            Image(systemName: "photo").font(.system(size: 30, weight: .light))
                            Text("Duo 默认背景").font(.callout)
                        }.foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 190).frame(maxWidth: .infinity)
            .clipped().clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Text(model.wallpaperFileName.isEmpty ? "默认背景" : model.wallpaperFileName)
                    .lineLimit(1).truncationMode(.middle)
                    .help(model.wallpaperFileName)
                Spacer(minLength: 8)
                Button("更换…", action: model.importWallpaper)
            }
            feedback(model.wallpaperStatus)
            Text("在系统设置的墙纸中选择“Duo · 随开合变化”。")
                .font(.caption).foregroundStyle(.secondary)
                .help("时钟、密码框和输入控件由 macOS 管理。")
        }
    }

    private var advancedPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard {
                Toggle("运动预测", isOn: $model.predictionEnabled)
                    .toggleStyle(.switch).controlSize(.small)
                    .help("根据近期角度变化预测运动，减轻视觉滞后。")
            }
            SettingsCard("开合记录") {
                Toggle("自动记录", isOn: Binding(get: { model.recordingEnabled }, set: {
                    model.recorder.setEnabled($0); model.refreshRecordingStatus()
                })).toggleStyle(.switch).controlSize(.small)
                feedback(model.recordingStatus)
                Text("仅在本机保存角度与时间，不记录桌面内容。")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("采集 7 天或达到 100 MB 后停止并保留数据；不会自动训练模型。")
                HStack {
                    Button("开始新的 7 天") { model.beginRecording() }
                    Spacer()
                    Button("导出…") { model.exportRecording() }
                    Button("清空…") { model.clearRecording() }
                }
                if !model.recordingMessage.isEmpty { feedback(model.recordingMessage) }
            }
            SettingsCard("截图测试") {
                HStack(spacing: 12) {
                    if let image = model.desktopImage {
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: 64, height: 42).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    Text(model.importedFileName.isEmpty ? "导入截图，单独预览玻璃效果。" : model.importedFileName)
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(model.importedFileName)
                    Spacer(minLength: 0)
                }
                HStack {
                    Button(model.desktopImage == nil ? "导入截图…" : "更换截图…", action: model.importScreenshot)
                    Spacer()
                    Button("开始测试", action: model.startTest).disabled(model.desktopImage == nil)
                }
                if !model.screenshotMessage.isEmpty { feedback(model.screenshotMessage) }
            }
            SettingsCard {
                DisclosureGroup("运行诊断") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.runtimeStatus)
                        Text(model.effectivePolicy)
                        Text(sensor.statusText)
                    }.font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                        .textSelection(.enabled)
                }
                Divider()
                DisclosureGroup("快捷键") {
                    VStack(spacing: 8) {
                        shortcut("启用／停止效果", "⇧⌘G")
                        shortcut("设为展开位置", "⇧⌘K")
                        shortcut("紧急停止", "⇧⌘Esc")
                        shortcut("设置", "⌘,")
                        shortcut("桌面截图（系统）", "⇧⌘3")
                    }.padding(.top, 10)
                }
            }
        }
    }

    private func shortcut(_ title: String, _ keys: String) -> some View {
        HStack { Text(title); Spacer(); Text(keys).foregroundStyle(.secondary) }.font(.caption)
    }

    private func feedback(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
}

private struct SettingsCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title { Text(title).font(.headline) }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.065)) }
    }
}

private struct TestView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sensor: LidAngleSensor
    @State private var strength = 1.0
    @State private var distance = 2.4
    @State private var expanded = false

    private var angle: Double {
        model.useSensor && sensor.isAvailable ? sensor.angle : model.simulatedAngle
    }

    var body: some View {
        ZStack {
            if let image = model.desktopImage {
                GlassSurface(image: image, tilt: tilt(at: CACurrentMediaTime()),
                             frost: model.frost, distance: distance, softness: model.edgeSoftness,
                             angleProvider: { tilt(at: CACurrentMediaTime()) },
                             movingProvider: { model.useSensor && model.sensor.snapshot.moving(at: CACurrentMediaTime()) },
                             opacityProvider: { opacity(at: CACurrentMediaTime()) },
                             motionUpdates: model.sensor.motionEvents.eraseToAnyPublisher(),
                             enabled: model.settingsVisible, maximumFPS: model.effectiveRenderFPS)
                    .ignoresSafeArea()
            }
            if !model.controlsHidden {
                VStack {
                    HStack {
                        Button(action: model.returnToSetup) { Label("返回", systemImage: "chevron.left") }
                        Spacer()
                        Toggle("原图对比", isOn: $model.showOriginal).toggleStyle(.button).help("⌘B")
                        Button("隐藏控制") { model.controlsHidden = true }.help("⌘H 隐藏或恢复，Esc 显示控制")
                    }
                    .controlSize(.large)
                    .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 24).padding(.top, 40)
                    Spacer()
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("\(Int(angle.rounded()))°").font(.title2).monospacedDigit()
                            Text("展开位置 \(Int(model.openAngle.rounded()))°").foregroundStyle(.secondary)
                            Spacer()
                            Button("设为展开位置") { model.saveOpenAngle() }.help("⌘K")
                        }
                        HStack {
                            Text("磨砂").frame(width: 88, alignment: .leading)
                            Slider(value: $model.frost, in: 0...0.18).accessibilityLabel("磨砂")
                        }
                        HStack {
                            Text("边缘柔和度").frame(width: 88, alignment: .leading)
                            Slider(value: $model.edgeSoftness, in: 0.25...2).accessibilityLabel("边缘柔和度")
                        }
                        DisclosureGroup("更多控制", isExpanded: $expanded) {
                            VStack(alignment: .leading, spacing: 12) {
                                if sensor.isAvailable {
                                    Toggle("实时铰链", isOn: $model.useSensor).toggleStyle(.switch).controlSize(.small)
                                }
                                if !model.useSensor || !sensor.isAvailable {
                                    HStack {
                                        Text("模拟角度").frame(width: 88, alignment: .leading)
                                        Slider(value: $model.simulatedAngle, in: 0...180).accessibilityLabel("模拟角度")
                                    }
                                }
                                HStack {
                                    Text("深度强度").frame(width: 88, alignment: .leading)
                                    Slider(value: $strength, in: 0.5...2).accessibilityLabel("深度强度")
                                    Text(String(format: "%.1f×", strength)).monospacedDigit()
                                }
                                HStack {
                                    Toggle("运动预测", isOn: $model.predictionEnabled)
                                    Spacer()
                                    Button("恢复默认") { model.resetAppearance() }
                                }
                                Text("⌘H 隐藏／恢复 · Esc 显示控制 · ⌘B 原图对比 · ⌘K 保存位置 · ⌘Q 退出")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.top, 10)
                        }
                        if !model.calibrationMessage.isEmpty {
                            Text(model.calibrationMessage).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout).padding(18).frame(width: 520)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.bottom, 24)
                }
            }
        }
        .background(.black)
        .focusable().focusEffectDisabled()
    }
    private func tilt(at now: Double) -> Double {
        guard !model.showOriginal else { return 0 }
        let snapshot = model.sensor.snapshot
        let actual: Double
        let predicted: Double
        if model.useSensor && sensor.isAvailable {
            guard snapshot.sample.valid, now - snapshot.lastValid < 0.5 else { return 0 }
            actual = snapshot.sample.angle
            predicted = snapshot.predicted(at: now, enabled: model.predictionEnabled)
        } else { actual = model.simulatedAngle; predicted = actual }
        guard HingeMotion.remaining(angle: actual, endpoint: model.openAngle) > 0 else { return 0 }
        return HingeMotion.tilt(angle: predicted, endpoint: model.openAngle, strength: strength)
    }
    private func opacity(at now: Double) -> Double {
        guard !model.showOriginal else { return 0 }
        let snapshot = model.sensor.snapshot
        if model.useSensor && sensor.isAvailable {
            guard snapshot.sample.valid, now - snapshot.lastValid < 0.5 else { return 0 }
            return HingeMotion.effectOpacity(angle: snapshot.sample.angle, endpoint: model.openAngle)
        }
        return HingeMotion.effectOpacity(angle: model.simulatedAngle, endpoint: model.openAngle)
    }
}
