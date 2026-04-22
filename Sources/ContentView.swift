import SwiftUI
import Charts
import CoreLocation

struct ContentView: View {
    @StateObject private var monitor = NetworkMonitor()
    @StateObject private var location = LocationPermission()

    private var xDomain: ClosedRange<Date> {
        let end = monitor.lastTick
        return end.addingTimeInterval(-monitor.windowSeconds)...end
    }

    private var wifiInfo: String {
        var parts: [String] = []
        if !monitor.channelInfo.isEmpty { parts.append(monitor.channelInfo) }
        if !monitor.phyMode.isEmpty { parts.append(monitor.phyMode) }
        if monitor.txRateMbps > 0 { parts.append(String(format: "%.0f Mbps", monitor.txRateMbps)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 10) {
            ChartCard(
                title: monitor.ssid.isEmpty ? "RSSI" : "\(monitor.ssid) — RSSI",
                subtitle: monitor.currentRSSI == 0 ? "RSSI —" : "RSSI \(monitor.currentRSSI) dBm",
                color: rssiColor(monitor.currentRSSI),
                data: monitor.rssi,
                unit: "dBm",
                yDomain: -100...(-20),
                xDomain: xDomain,
                windowSeconds: monitor.windowSeconds,
                warning: rssiWarning(),
                infoLine: wifiInfo,
                secondarySubtitle: monitor.currentNoise == 0 ? nil : "Noise \(monitor.currentNoise) dBm",
                secondaryData: monitor.noise,
                secondaryColor: .blue
            )

            ChartCard(
                title: monitor.gatewayAddress.isEmpty ? "Gateway" : "\(monitor.gatewayAddress) — Gateway",
                subtitle: formatMs(monitor.currentGatewayPing),
                color: .green,
                data: monitor.gatewayPing,
                unit: "ms",
                yDomain: nil,
                xDomain: xDomain,
                windowSeconds: monitor.windowSeconds,
                warning: nil,
                secondarySubtitle: "Jitter \(String(format: "%.1f", monitor.currentGatewayJitter)) ms",
                secondaryData: monitor.gatewayJitter,
                secondaryColor: .blue
            )

            ChartCard(
                title: "1.1.1.1 — Cloudflare",
                subtitle: formatMs(monitor.currentCloudflarePing),
                color: .orange,
                data: monitor.cloudflarePing,
                unit: "ms",
                yDomain: nil,
                xDomain: xDomain,
                windowSeconds: monitor.windowSeconds,
                warning: nil,
                secondarySubtitle: "Jitter \(String(format: "%.1f", monitor.currentCloudflareJitter)) ms",
                secondaryData: monitor.cloudflareJitter,
                secondaryColor: .blue
            )
        }
        .padding(12)
        .frame(minWidth: 280, idealWidth: 450, minHeight: 320, idealHeight: 640)
        .navigationTitle(monitor.ssid.isEmpty ? "WifiMon" : "WifiMon — \(monitor.ssid)")
        .onAppear {
            location.request()
            monitor.start()
        }
        .onDisappear { monitor.stop() }
    }

    private func formatMs(_ v: Double) -> String {
        v < 0 ? "Latency timeout" : String(format: "Latency %.1f ms", v)
    }

    private func rssiColor(_ v: Int) -> Color {
        if v == 0 { return .gray }
        if v >= -55 { return .green }
        if v >= -70 { return .yellow }
        return .red
    }

    private func rssiWarning() -> String? {
        guard monitor.currentRSSI == 0 else { return nil }
        switch location.status {
        case .notDetermined:
            return "Requesting Location permission to read Wi-Fi signal…"
        case .denied, .restricted:
            return "Location permission denied. Enable it in System Settings › Privacy & Security › Location Services to read dBm."
        default:
            return "No Wi-Fi interface available."
        }
    }
}

struct ChartCard: View {
    let title: String
    let subtitle: String
    let color: Color
    let data: [NetworkMonitor.DataPoint]
    let unit: String
    let yDomain: ClosedRange<Double>?
    let xDomain: ClosedRange<Date>
    let windowSeconds: TimeInterval
    let warning: String?
    var infoLine: String? = nil
    var secondarySubtitle: String? = nil
    var secondaryData: [NetworkMonitor.DataPoint]? = nil
    var secondaryColor: Color? = nil

    private var isDBm: Bool { unit == "dBm" }

    private var validData: [NetworkMonitor.DataPoint] {
        isDBm ? data.filter { $0.value != 0 } : data.filter { $0.value >= 0 }
    }

    private var validSecondary: [NetworkMonitor.DataPoint] {
        guard let s = secondaryData else { return [] }
        return isDBm ? s.filter { $0.value != 0 } : s.filter { $0.value >= 0 }
    }

    private var timeouts: [NetworkMonitor.DataPoint] {
        isDBm ? [] : data.filter { $0.value < 0 }
    }

    private var areaBaseline: Double {
        isDBm ? -20 : 0
    }

    /// RSSI zone color per-sample: each vertical bar is tinted by which threshold
    /// band the sample sits in. No global chart tint — only the bars themselves.
    private static func rssiZoneColor(_ v: Double) -> Color {
        if v >= -55 { return .green }
        if v >= -70 { return .yellow }
        return .red
    }

    /// Returned as an array so we can reverse the axis for dBm (Swift Charts treats the first
    /// array element as the bottom of the scale and the last as the top).
    private var resolvedYDomain: [Double] {
        if isDBm { return [-20, -100] }
        if let yDomain { return [yDomain.lowerBound, yDomain.upperBound] }
        let values = validData.map(\.value)
        guard let maxV = values.max(), maxV > 0 else { return [0, 20] }
        return [0, maxV * 1.25]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let info = infoLine, !info.isEmpty {
                        Text(info)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    if let secondary = secondarySubtitle {
                        Text(secondary)
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Text(subtitle)
                        .font(.title3)
                        .monospacedDigit()
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .fixedSize()
                }
            }

            if let warning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Chart {
                ForEach(timeouts) { point in
                    RuleMark(x: .value("Time", point.time))
                        .foregroundStyle(.red.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
                if isDBm {
                    ForEach(validData) { point in
                        BarMark(
                            x: .value("Time", point.time),
                            yStart: .value(unit, areaBaseline),
                            yEnd: .value(unit, point.value)
                        )
                        .foregroundStyle(Self.rssiZoneColor(point.value).opacity(0.7))
                    }
                } else {
                    ForEach(validData) { point in
                        AreaMark(
                            x: .value("Time", point.time),
                            yStart: .value(unit, areaBaseline),
                            yEnd: .value(unit, point.value)
                        )
                        .foregroundStyle(color.opacity(0.22))
                        .interpolationMethod(.stepEnd)
                    }
                    ForEach(validData) { point in
                        LineMark(
                            x: .value("Time", point.time),
                            y: .value(unit, point.value),
                            series: .value("Series", "primary")
                        )
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineJoin: .miter))
                        .interpolationMethod(.stepEnd)
                    }
                }
                if let sc = secondaryColor {
                    ForEach(validSecondary) { point in
                        LineMark(
                            x: .value("Time", point.time),
                            y: .value(unit, point.value),
                            series: .value("Series", "secondary")
                        )
                        .foregroundStyle(sc)
                        .lineStyle(StrokeStyle(lineWidth: 1, lineJoin: .miter, dash: [3, 2]))
                        .interpolationMethod(.stepEnd)
                    }
                }
            }
            .chartXScale(domain: xDomain)
            .chartYScale(domain: resolvedYDomain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute().second())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel()
                }
            }
            .chartPlotStyle { plot in
                plot
                    .clipShape(Rectangle())
                    .border(Color.secondary.opacity(0.35), width: 1)
            }
            .animation(nil, value: data.count)
            .frame(minHeight: 60)
            .overlay(alignment: .bottomLeading) {
                Text("\(Int(windowSeconds))s")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
