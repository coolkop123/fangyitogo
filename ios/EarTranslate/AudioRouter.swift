import AVFoundation
import Combine

/// 管理音频会话：让麦克风和播放都走蓝牙耳机，并实时显示当前线路。
@MainActor
final class AudioRouter: ObservableObject {
    @Published private(set) var inputName = "—"
    @Published private(set) var outputName = "—"
    @Published private(set) var isBluetooth = false

    private var configured = false
    private var observer: NSObjectProtocol?

    private static let bluetoothPorts: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE]

    func configure() throws {
        let session = AVAudioSession.sharedInstance()
        // playAndRecord + allowBluetooth：蓝牙耳机同时作为麦克风（HFP）和扬声器。
        // defaultToSpeaker：没连耳机时用手机扬声器而不是听筒。
        try session.setCategory(.playAndRecord,
                                mode: .default,
                                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers])
        try session.setActive(true)
        preferBluetoothInput()

        if !configured {
            configured = true
            observer = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.preferBluetoothInput()
                    self?.refresh()
                }
            }
        }
        refresh()
    }

    /// 有蓝牙耳机麦克风时优先用它收音。
    func preferBluetoothInput() {
        let session = AVAudioSession.sharedInstance()
        if let bt = session.availableInputs?.first(where: { Self.bluetoothPorts.contains($0.portType) }) {
            try? session.setPreferredInput(bt)
        }
    }

    /// 临时把声音切到手机扬声器（给对面的人听），结束后恢复耳机。
    func setSpeakerOverride(_ on: Bool) {
        let s = AVAudioSession.sharedInstance()
        if s.category != .playAndRecord { try? configure() }
        try? s.setActive(true)
        try? s.overrideOutputAudioPort(on ? .speaker : .none)
        refresh()
    }

    func refresh() {
        let route = AVAudioSession.sharedInstance().currentRoute
        inputName = route.inputs.first?.portName ?? "无"
        outputName = route.outputs.first?.portName ?? "无"
        isBluetooth = route.outputs.contains { Self.bluetoothPorts.contains($0.portType) }
    }
}
