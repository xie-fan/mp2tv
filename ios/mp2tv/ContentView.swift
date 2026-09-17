import SwiftUI

struct ContentView: View {
    @EnvironmentObject var engine: Engine
    @State private var showScanner = false
    @State private var showLog = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("状态")
                        Spacer()
                        Text(engine.status).foregroundStyle(.secondary)
                    }
                    if engine.phase == .streaming || engine.phase == .reconnecting {
                        Button("退出投屏", role: .destructive) {
                            engine.stop(userInitiated: true)
                        }
                    }
                    if engine.legacyMode && engine.phase == .connecting {
                        VStack(spacing: 8) {
                            Text("点下方按钮选择 mp2tv 开始录屏")
                                .font(.caption).foregroundStyle(.secondary)
                            BroadcastPicker()
                                .frame(width: 60, height: 60)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }

                Section("已配对的电脑") {
                    if engine.devices.isEmpty {
                        Text("还没有配对过电脑\n点下方按钮扫码配对")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(engine.devices, id: \.receiverId) { d in
                        let on = engine.online[d.receiverId] != nil
                        HStack {
                            VStack(alignment: .leading) {
                                Text(d.name)
                                Text(d.invalid ? "已被电脑解除配对" : (on ? "在线" : "离线"))
                                    .font(.caption)
                                    .foregroundStyle(d.invalid ? .red : (on ? .green : .secondary))
                            }
                            Spacer()
                            if engine.phase == .idle {
                                Button("投屏") { engine.toggle(d) }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(d.invalid)
                            }
                        }
                        .swipeActions {
                            Button("解除配对", role: .destructive) { engine.unpair(d) }
                        }
                    }
                }

                Section {
                    Button("扫码配对") { showScanner = true }
                }

                Section("设置") {
                    Toggle("智能截取", isOn: $engine.cropOn)
                    HStack {
                        Text("强制旋转")
                        Spacer()
                        Text(["自动", "90°", "180°", "270°"][engine.forceRot])
                            .foregroundStyle(.secondary)
                    }
                    Button("旋转 90°") { engine.cycleRotate() }
                        .disabled(engine.phase != .streaming)
                    Button("导出日志") { showLog = true }
                }
            }
            .navigationTitle("mp2tv")
            .sheet(isPresented: $showScanner) {
                ScanView { url in
                    showScanner = false
                    engine.pair(url: url)
                }
            }
            .sheet(isPresented: $showLog) {
                if let u = L.fileURL() {
                    ShareLink(item: u) { Label("分享日志", systemImage: "square.and.arrow.up") }
                        .padding()
                }
            }
        }
    }
}
