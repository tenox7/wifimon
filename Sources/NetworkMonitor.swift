import Foundation
import CoreWLAN

@MainActor
final class NetworkMonitor: ObservableObject {
    struct DataPoint: Identifiable {
        let id = UUID()
        let time: Date
        let value: Double
    }

    @Published var rssi: [DataPoint] = []
    @Published var noise: [DataPoint] = []
    @Published var gatewayPing: [DataPoint] = []
    @Published var cloudflarePing: [DataPoint] = []
    @Published var gatewayJitter: [DataPoint] = []
    @Published var cloudflareJitter: [DataPoint] = []

    @Published var currentRSSI: Int = 0
    @Published var currentNoise: Int = 0
    @Published var currentGatewayPing: Double = -1
    @Published var currentCloudflarePing: Double = -1
    @Published var currentGatewayJitter: Double = 0
    @Published var currentCloudflareJitter: Double = 0
    @Published var gatewayAddress: String = ""
    @Published var ssid: String = ""
    @Published var channelInfo: String = ""
    @Published var phyMode: String = ""
    @Published var txRateMbps: Double = 0
    @Published var lastTick: Date = Date()

    let windowSeconds: TimeInterval = 120
    private let maxPoints = 120
    private let wifi = CWWiFiClient.shared()
    private var timer: Timer?
    private var gatewayRefreshCounter = 0

    private var gatewayPinger: IcmpPinger?
    private let cloudflarePinger: IcmpPinger?

    private var gatewayInFlight = false
    private var cloudflareInFlight = false

    private var lastValidGatewayPing: Double?
    private var lastValidCloudflarePing: Double?
    private var smoothedGatewayJitter: Double = 0
    private var smoothedCloudflareJitter: Double = 0

    init() {
        cloudflarePinger = IcmpPinger(host: "1.1.1.1", timeoutMs: 900)
    }

    func start() {
        refreshGateway()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = Date()
        lastTick = now

        let iface = wifi.interface()
        currentRSSI = iface?.rssiValue() ?? 0
        currentNoise = iface?.noiseMeasurement() ?? 0
        ssid = iface?.ssid() ?? ""
        channelInfo = Self.channelString(iface?.wlanChannel())
        phyMode = Self.phyModeString(iface?.activePHYMode() ?? .modeNone)
        txRateMbps = iface?.transmitRate() ?? 0
        append(DataPoint(time: now, value: Double(currentRSSI)), to: &rssi)
        append(DataPoint(time: now, value: Double(currentNoise)), to: &noise)

        gatewayRefreshCounter += 1
        if gatewayRefreshCounter >= 15 {
            gatewayRefreshCounter = 0
            refreshGateway()
        }

        if let pinger = gatewayPinger {
            if !gatewayInFlight {
                gatewayInFlight = true
                Task.detached(priority: .utility) { [weak self] in
                    let result = pinger.ping()
                    await self?.recordGatewayPing(result ?? -1, at: now)
                }
            }
        } else {
            currentGatewayPing = -1
            append(DataPoint(time: now, value: -1), to: &gatewayPing)
        }

        if let pinger = cloudflarePinger, !cloudflareInFlight {
            cloudflareInFlight = true
            Task.detached(priority: .utility) { [weak self] in
                let result = pinger.ping()
                await self?.recordCloudflarePing(result ?? -1, at: now)
            }
        }
    }

    private func recordGatewayPing(_ value: Double, at time: Date) {
        gatewayInFlight = false
        currentGatewayPing = value
        append(DataPoint(time: time, value: value), to: &gatewayPing)

        if value >= 0 {
            if let prev = lastValidGatewayPing {
                let diff = abs(value - prev)
                smoothedGatewayJitter += (diff - smoothedGatewayJitter) / 16.0
            }
            lastValidGatewayPing = value
        }
        currentGatewayJitter = smoothedGatewayJitter
        append(DataPoint(time: time, value: smoothedGatewayJitter), to: &gatewayJitter)
    }

    private func recordCloudflarePing(_ value: Double, at time: Date) {
        cloudflareInFlight = false
        currentCloudflarePing = value
        append(DataPoint(time: time, value: value), to: &cloudflarePing)

        if value >= 0 {
            if let prev = lastValidCloudflarePing {
                let diff = abs(value - prev)
                smoothedCloudflareJitter += (diff - smoothedCloudflareJitter) / 16.0
            }
            lastValidCloudflarePing = value
        }
        currentCloudflareJitter = smoothedCloudflareJitter
        append(DataPoint(time: time, value: smoothedCloudflareJitter), to: &cloudflareJitter)
    }

    private func append(_ point: DataPoint, to array: inout [DataPoint]) {
        array.append(point)
        let overflow = array.count - maxPoints
        if overflow > 0 { array.removeFirst(overflow) }
    }

    private func refreshGateway() {
        let newGW = findDefaultGatewayIPv4() ?? ""
        if newGW != gatewayAddress {
            gatewayAddress = newGW
            gatewayPinger = newGW.isEmpty ? nil : IcmpPinger(host: newGW, timeoutMs: 900)
        }
    }

    private static func phyModeString(_ mode: CWPHYMode) -> String {
        switch mode {
        case .modeNone: return ""
        case .mode11a: return "802.11a"
        case .mode11b: return "802.11b"
        case .mode11g: return "802.11g"
        case .mode11n: return "802.11n"
        case .mode11ac: return "802.11ac"
        case .mode11ax: return "802.11ax"
        @unknown default:
            if mode.rawValue == 7 { return "802.11be" }
            return ""
        }
    }

    private static func channelString(_ ch: CWChannel?) -> String {
        guard let ch else { return "" }
        let band: String
        switch ch.channelBand {
        case .band2GHz: band = "2.4 GHz"
        case .band5GHz: band = "5 GHz"
        case .band6GHz: band = "6 GHz"
        default: band = ""
        }
        let width: String
        switch ch.channelWidth {
        case .width20MHz: width = "20"
        case .width40MHz: width = "40"
        case .width80MHz: width = "80"
        case .width160MHz: width = "160"
        default: width = ""
        }
        var s = "Ch \(ch.channelNumber)"
        if !band.isEmpty { s += " · \(band)" }
        if !width.isEmpty { s += " · \(width) MHz" }
        return s
    }
}
