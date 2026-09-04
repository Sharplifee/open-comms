import SwiftUI

struct Avatar: View {
    let text: String
    var live = false
    var body: some View {
        Text(text.prefix(2).uppercased())
            .font(.system(size: 13.5, weight: .bold, design: .rounded))
            .foregroundStyle(live ? Theme.base : Theme.text)
            .frame(width: 40, height: 40)
            .background(live ? Theme.signal : Theme.raised)
            .clipShape(RoundedRectangle(cornerRadius: Theme.avatarRadius, style: .continuous))
    }
}

struct Banner: View {
    let icon: String
    let title: String
    let detail: String?
    var action: (() -> Void)?
    var actionTitle: String = "Open Settings"

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(Theme.danger)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .semibold, design: .rounded))
                if let detail {
                    Text(detail).font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.muted)
                }
                if let action {
                    Button(actionTitle, action: action)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.signal)
                        .padding(.top, 4)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        .background(Theme.danger.opacity(0.1))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Theme.danger.opacity(0.28), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 22).padding(.bottom, 14)
    }
}

struct StateBlock: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 24)).foregroundStyle(Theme.muted).padding(.bottom, 5)
            Text(title).font(.system(size: 14.5, weight: .semibold, design: .rounded))
            Text(detail).font(.system(size: 12.5, design: .rounded))
                .foregroundStyle(Theme.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 26).padding(.horizontal, 20)
    }
}

/// The level meter with everyone on the line riding on it. Presence and
/// loudness as one object, rather than a radar, a grid and a waveform each
/// telling a third of the story.
struct Ribbon: View {
    let level: Double
    let members: [Member]
    let live: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<44, id: \.self) { index in
                    Capsule()
                        .fill(barColour(index))
                        .frame(height: barHeight(index))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: level)

            HStack(spacing: 9) {
                ForEach(members) { member in
                    HStack(spacing: 8) {
                        Text(member.initials)
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundStyle(member.isSpeaking ? Theme.base : Theme.text)
                            .frame(width: 25, height: 25)
                            .background(member.isSpeaking ? Theme.signal : Theme.raised)
                            .clipShape(Circle())
                        Text(member.displayName)
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    }
                    .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 6)
                    .background(Theme.base.opacity(0.86))
                    .overlay(Capsule().stroke(member.isSpeaking ? Theme.signal : Theme.line, lineWidth: 1))
                    .clipShape(Capsule())
                    .opacity(member.mutedForMe ? 0.45 : 1)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 126)
        .cardSurface()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummary)
    }

    private var spokenSummary: String {
        let talking = members.filter(\.isSpeaking).map(\.displayName)
        let who = members.map(\.displayName).joined(separator: ", ")
        return talking.isEmpty ? "On the line: \(who). Nobody talking."
                               : "\(talking.joined(separator: " and ")) talking. On the line: \(who)."
    }

    private func barHeight(_ index: Int) -> CGFloat {
        guard live else { return 10 }
        let wave = abs(sin(Double(index) * 0.7 + level * 6))
        return 9 + wave * level * 60
    }

    private func barColour(_ index: Int) -> Color {
        guard live else { return Theme.line }
        return barHeight(index) > 46 ? Theme.signal : Theme.signal.opacity(0.3)
    }
}

/// Small on purpose. The radar is the most distinctive thing in the app and
/// the reason somebody opens this instead of a group call, but at full height
/// it competed with the thing you actually came to do.
struct RadarStrip: View {
    let people: [NearbyPerson]
    let radius: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = 0.0

    var body: some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let maxR = min(size.width, size.height) / 2 - 4

            for ring in 1...3 {
                let r = maxR * Double(ring) / 3
                context.stroke(Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r,
                                                      width: r * 2, height: r * 2)),
                               with: .color(Theme.line), lineWidth: 0.8)
            }

            if !reduceMotion {
                var wedge = Path()
                wedge.move(to: centre)
                wedge.addArc(center: centre, radius: maxR,
                             startAngle: .degrees(sweep - 90), endAngle: .degrees(sweep - 50), clockwise: false)
                context.fill(wedge, with: .color(Theme.signal.opacity(0.05)))
            }

            context.fill(Path(ellipseIn: CGRect(x: centre.x - 5.5, y: centre.y - 5.5, width: 11, height: 11)),
                         with: .color(Theme.text))

            for person in people {
                let fraction = min(person.metres / radius, 0.88)
                let x = centre.x + sin(person.bearing) * maxR * fraction
                let y = centre.y - cos(person.bearing) * maxR * fraction
                context.fill(Path(ellipseIn: CGRect(x: x - 9, y: y - 9, width: 18, height: 18)),
                             with: .color(Theme.surface))
                context.stroke(Path(ellipseIn: CGRect(x: x - 9, y: y - 9, width: 18, height: 18)),
                               with: .color(Theme.line), lineWidth: 0.8)
                context.draw(Text(person.initials)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.muted), at: CGPoint(x: x, y: y))
            }
        }
        .frame(height: 118)
        .padding(.horizontal, 16)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 2.6).repeatForever(autoreverses: false)) { sweep = 360 }
        }
        .accessibilityElement()
        .accessibilityLabel(people.isEmpty
            ? "Radar. Nobody nearby."
            : "Radar. " + people.map { "\($0.displayName) \($0.distanceText) \($0.bearingText)" }
                                .joined(separator: ", "))
    }
}

struct ConnectingOverlay: View {
    var body: some View {
        ZStack {
            Theme.base.opacity(0.78).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().tint(Theme.signal)
                Text("Opening the line…").font(.system(size: 16.5, weight: .bold, design: .rounded))
                Text("If this takes more than ten seconds it gives up rather than leaving you here.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }
            .padding(26)
            .frame(maxWidth: 300)
            .cardSurface(22)
        }
    }
}
