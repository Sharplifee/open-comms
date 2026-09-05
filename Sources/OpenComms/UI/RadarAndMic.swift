import SwiftUI

// MARK: - Radar card

/// The big radar from the design: four labelled rings, crosshairs and
/// diagonals, a sweeping wedge whose speed follows the range, and people
/// placed by real bearing and distance. Sits in a card with the range pill
/// in its header and a nine-stop slider that unfolds beneath it.
struct RadarCard: View {
    let title: String
    let subtitle: String
    let people: [NearbyPerson]
    @Binding var radiusIndex: Int
    @Binding var showRange: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = 0.0

    private var radius: Double { Preferences.ranges[min(max(radiusIndex, 0), 8)].metres }
    private var label: String { Preferences.ranges[min(max(radiusIndex, 0), 8)].label }
    /// Fast close in, slow far out: 1s at 100 ft rising to a 3s cap.
    private var period: Double { min(3.0, 1.0 + Double(min(radiusIndex, 4)) * 0.5) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 20, weight: .bold, design: .rounded))
                    HStack(spacing: 5) {
                        Circle().fill(Theme.signal).frame(width: 6, height: 6)
                        Text(subtitle).font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
                Button { withAnimation { showRange.toggle() } } label: {
                    Text("📍 \(label) \(showRange ? "▲" : "▼")")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .padding(.horizontal, 13).padding(.vertical, 7)
                        .background(Theme.raised, in: Capsule())
                        .foregroundStyle(Theme.text)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 10)

            if showRange {
                VStack(spacing: 6) {
                    HStack {
                        Text("RANGE").font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.muted)
                        Spacer()
                        Text(label).font(.system(size: 10.5, weight: .bold, design: .rounded))
                    }
                    Slider(value: Binding(get: { Double(radiusIndex) },
                                          set: { radiusIndex = Int($0.rounded()) }),
                           in: 0...8, step: 1)
                        .tint(Theme.line)
                    HStack {
                        ForEach(["100ft","250ft","500ft",".25mi","1mi","5mi","25mi","100mi","∞"], id: \.self) {
                            Text($0).font(.system(size: 6.5, design: .rounded)).foregroundStyle(Theme.muted)
                            if $0 != "∞" { Spacer() }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 8)
            }

            ZStack {
                Canvas { context, size in
                    let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                    let maxR = min(size.width, size.height) / 2 - 12
                    for ring in 1...4 {
                        let r = maxR * Double(ring) / 4
                        context.stroke(Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r,
                                                              width: r * 2, height: r * 2)),
                                       with: .color(Theme.line.opacity(0.7)), lineWidth: 1)
                        let metres = radius * Double(ring) / 4
                        let text = metres < 300 ? "\(Int(metres * 3.28084)) ft"
                                                : String(format: "%.1f mi", metres / 1609.34)
                        context.draw(Text(text).font(.system(size: 8.5, design: .rounded))
                                        .foregroundColor(Theme.muted),
                                     at: CGPoint(x: centre.x, y: centre.y - r + 9))
                    }
                    var cross = Path()
                    cross.move(to: CGPoint(x: centre.x - maxR, y: centre.y)); cross.addLine(to: CGPoint(x: centre.x + maxR, y: centre.y))
                    cross.move(to: CGPoint(x: centre.x, y: centre.y - maxR)); cross.addLine(to: CGPoint(x: centre.x, y: centre.y + maxR))
                    context.stroke(cross, with: .color(Theme.line.opacity(0.45)), lineWidth: 0.8)
                    var diag = Path()
                    let d = maxR * 0.7071
                    diag.move(to: CGPoint(x: centre.x - d, y: centre.y - d)); diag.addLine(to: CGPoint(x: centre.x + d, y: centre.y + d))
                    diag.move(to: CGPoint(x: centre.x + d, y: centre.y - d)); diag.addLine(to: CGPoint(x: centre.x - d, y: centre.y + d))
                    context.stroke(diag, with: .color(Theme.line.opacity(0.3)), lineWidth: 0.5)

                    if !reduceMotion {
                        var wedge = Path()
                        wedge.move(to: centre)
                        wedge.addArc(center: centre, radius: maxR,
                                     startAngle: .degrees(sweep - 90), endAngle: .degrees(sweep - 40), clockwise: false)
                        wedge.closeSubpath()
                        context.fill(wedge, with: .color(Theme.signal.opacity(0.06)))
                        var edge = Path()
                        edge.move(to: centre)
                        edge.addLine(to: CGPoint(x: centre.x + maxR * cos((sweep - 90) * .pi / 180),
                                                 y: centre.y + maxR * sin((sweep - 90) * .pi / 180)))
                        context.stroke(edge, with: .color(Theme.signal.opacity(0.26)), lineWidth: 1.2)
                    }

                    let you = CGRect(x: centre.x - 12, y: centre.y - 12, width: 24, height: 24)
                    context.fill(Path(ellipseIn: you), with: .color(Theme.text))
                    context.draw(Text("YOU").font(.system(size: 6, weight: .bold, design: .rounded))
                                    .foregroundColor(Theme.base), at: centre)
                }

                GeometryReader { geo in
                    let centre = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                    let maxR = min(geo.size.width, geo.size.height) / 2 - 12
                    ForEach(people) { person in
                        let frac = min(person.metres / radius, 0.88)
                        let x = centre.x + sin(person.bearing) * frac * maxR
                        let y = centre.y - cos(person.bearing) * frac * maxR
                        VStack(spacing: 2) {
                            Text(person.initials)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .frame(width: 34, height: 34)
                                .background(Theme.surface, in: Circle())
                                .overlay(Circle().stroke(Theme.line, lineWidth: 0.8))
                            Text(person.distanceText)
                                .font(.system(size: 7, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.dim)
                        }
                        .position(x: x, y: y)
                        .opacity(max(0.4, 1 - frac * 0.5))
                    }
                }
            }
            .frame(height: 206)
            .padding(.horizontal, 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Radar. Range \(label). " + (people.isEmpty ? "Nobody in range."
                : people.map { "\($0.displayName) \($0.distanceText) \($0.bearingText)" }.joined(separator: ", ")))

            HStack(spacing: 5) {
                Capsule().fill(Theme.muted.opacity(0.35)).frame(width: 20, height: 5)
                Capsule().fill(Theme.line).frame(width: 8, height: 5)
                Capsule().fill(Theme.line).frame(width: 8, height: 5)
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 14)
        }
        .cardSurface(24)
        .onAppear { startSweep() }
        .onChange(of: radiusIndex) { _, _ in startSweep() }
    }

    private func startSweep() {
        guard !reduceMotion else { return }
        sweep = 0
        withAnimation(.linear(duration: period).repeatForever(autoreverses: false)) { sweep = 360 }
    }
}

// MARK: - Mic card

/// The mic card from the design: the round mic button, the sensitivity pill,
/// the Whisper–Shout slider, a 26-bar meter with the yellow threshold marker
/// you can drag, and the transmitting row underneath.
struct MicCard: View {
    let level: Double
    let live: Bool
    let speaking: Bool
    @Binding var sensitivity: Double
    let onToggleMic: () -> Void

    private var db: Int { Int((-55 + sensitivity * 43).rounded()) }
    private var mode: String {
        let names = ["Whisper","Soft","Low","Medium","Normal","Elevated","Loud","Very Loud","Shout"]
        return names[min(8, Int(sensitivity * 9))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onToggleMic) {
                    Image(systemName: live ? "mic.fill" : "mic.slash.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(live ? Theme.signal : Theme.danger)
                        .frame(width: 46, height: 46)
                        .background((live ? Theme.signal : Theme.danger).opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(live ? "Microphone live. Tap to mute." : "Microphone muted. Tap to unmute.")

                VStack(alignment: .leading, spacing: 2) {
                    Text(live ? "Microphone" : "Microphone muted")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    Text("Sensitivity: \(db) dB · \(mode)")
                        .font(.system(size: 12.5, design: .rounded)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Text("\(db) dB")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.raised, in: Capsule())
            }

            Slider(value: $sensitivity, in: 0...1).tint(Theme.line).padding(.top, 16)
            HStack {
                Text("Whisper"); Spacer(); Text(mode); Spacer(); Text("Shout")
            }
            .font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.muted)
            .padding(.top, 14).padding(.bottom, 8)

            GeometryReader { geo in
                let bars = 26
                let thr = Int((sensitivity * Double(bars - 1)).rounded())
                ZStack(alignment: .leading) {
                    HStack(alignment: .center, spacing: 4) {
                        ForEach(0..<bars, id: \.self) { i in
                            let amp = live ? abs(sin(Double(i) * 0.9 + level * 8)) * level : 0
                            RoundedRectangle(cornerRadius: 2)
                                .fill(live && i <= thr ? Theme.signal : Theme.line)
                                .frame(height: 6 + amp * 26)
                        }
                    }
                    .frame(height: 44)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.signal)
                        .frame(width: 5, height: 44)
                        .offset(x: geo.size.width * Double(thr) / Double(bars - 1) - 2.5)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    sensitivity = min(1, max(0, value.location.x / geo.size.width))
                })
            }
            .frame(height: 44)
            .accessibilityHidden(true)

            HStack {
                HStack(spacing: 7) {
                    Circle().fill(live && speaking ? Theme.signal : Theme.muted).frame(width: 7, height: 7)
                    Text(live && speaking ? "Transmitting" : "Not transmitting")
                        .foregroundStyle(live && speaking ? Theme.signal : Theme.muted)
                }
                Spacer()
                Text(live && speaking ? "WOULD TRANSMIT" : "SPEAK LOUDER")
                    .font(.system(size: 11, weight: .bold, design: .rounded)).kerning(1)
                    .foregroundStyle(Theme.muted)
            }
            .font(.system(size: 12.5, design: .rounded))
            .padding(.top, 12)
            .accessibilityElement(children: .combine)
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 14, trailing: 18))
        .cardSurface()
    }
}
