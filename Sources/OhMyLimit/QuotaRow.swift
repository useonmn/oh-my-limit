import OhMyLimitCore
import SwiftUI

struct QuotaRow: View {
    let window: CodexQuotaWindow
    let now: Date

    private var awaitingReset: Bool { window.hasExpired(at: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.panelSmall + 1) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.panelCompact) {
                Text([window.label, durationLabel == window.label ? nil : durationLabel]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.panelBody)
                    .lineLimit(1).help(window.label)
                Spacer(minLength: Theme.panelCompact)
                Text(window.usageKnown ? "\(window.usedPercent, specifier: "%.0f")%" : "알 수 없음")
                    .font(window.usageKnown ? Theme.panelValue : Theme.panelCaption)
                    .foregroundStyle(window.usageKnown && !awaitingReset ? Theme.panelPrimary : Theme.panelSecondary)
            }
            if window.usageKnown {
                ProgressView(value: min(max(window.usedPercent, 0), 100), total: 100)
                    .progressViewStyle(QuotaProgressStyle(
                        color: awaitingReset ? Theme.panelSecondary : Theme.usageColor(window.usedPercent)
                    ))
                    .accessibilityLabel([window.label, durationLabel].compactMap { $0 }.joined(separator: " "))
                    .accessibilityValue("\(String(format: "%.0f", window.usedPercent))퍼센트 사용")
            } else {
                Capsule().fill(Theme.panelTrack)
                    .frame(height: Theme.barHeight).accessibilityHidden(true)
            }
            HStack(alignment: .firstTextBaseline, spacing: Theme.panelCompact) {
                Group {
                    if awaitingReset {
                        WarningLabel(text: resetDescription, systemImage: "exclamationmark.circle.fill")
                    } else {
                        Text(resetDescription).monospacedDigit()
                    }
                }
                .help(window.resetsAt?.formatted(date: .complete, time: .complete)
                      ?? window.resetDescription ?? "초기화 시각 미제공")
                Spacer(minLength: Theme.panelCompact)
                if window.usageKnown && !awaitingReset {
                    Text("\(max(0, 100 - window.usedPercent), specifier: "%.0f")% 남음").monospacedDigit()
                }
            }
            .font(Theme.panelCaption)
            .foregroundStyle(Theme.panelSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var durationLabel: String? {
        window.windowDurationMins.map(CodexQuotaWindow.durationLabel(minutes:))
    }

    private var resetDescription: String {
        guard let reset = window.resetsAt else { return window.resetDescription ?? "초기화 시각 미제공" }
        if awaitingReset { return "초기화 시각 지남 · 다시 확인 필요" }
        let remaining = max(1, Int(ceil(reset.timeIntervalSince(now) / 60)))
        let duration: String
        if remaining >= 1_440 {
            duration = "\(remaining / 1_440)일 \((remaining % 1_440) / 60)시간"
        } else if remaining >= 60 {
            duration = "\(remaining / 60)시간 \(remaining % 60)분"
        } else {
            duration = "\(remaining)분"
        }
        return "\(duration) 후 초기화"
    }
}

/// Warning colour on the symbol only; the words keep label contrast over vibrancy.
struct WarningLabel: View {
    let text: String
    var systemImage = "exclamationmark.triangle.fill"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.panelSmall) {
            Image(systemName: systemImage).foregroundStyle(Theme.panelWarning).accessibilityHidden(true)
            Text(text).foregroundStyle(Theme.panelPrimary).fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.panelCaption)
    }
}

private struct QuotaProgressStyle: ProgressViewStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            Capsule().fill(Theme.panelTrack)
                .overlay(alignment: .leading) {
                    Capsule().fill(color)
                        .frame(width: geometry.size.width * (configuration.fractionCompleted ?? 0))
                }
        }
        .frame(height: Theme.barHeight)
    }
}
