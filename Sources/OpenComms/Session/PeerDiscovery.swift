import Foundation
import MultipeerConnectivity
import UIKit

/// Finds other phones running OpenComms that are physically near you, using
/// whatever radio is available, and hands a line code between them.
///
/// The nearby list on the server needs location permission, a data connection,
/// and both people to be visible. That is three things that can be off, and
/// every one of them turns "I can see my mate standing there" into an empty
/// screen. This does not use any of them: MultipeerConnectivity discovers over
/// Bluetooth and peer-to-peer Wi-Fi directly, with no infrastructure at all —
/// it works in a gym with no signal, on a plane, in a basement.
///
/// It is the path for the person who has just installed the app and does not
/// want to learn anything. Two phones in the same room see each other within a
/// few seconds, one taps the other's name, and they are on a line. Nobody
/// types a code and nobody grants location.
///
/// The service type is a fixed eight-character identifier because Bonjour
/// requires it: 1–15 characters, lowercase, letters, digits and hyphens only.
@MainActor
final class PeerDiscovery: NSObject, ObservableObject {
    static let shared = PeerDiscovery()

    /// Everybody visible right now, most recently seen first.
    @Published private(set) var peers: [NearbyPeer] = []
    /// A code somebody nearby has just handed us, waiting to be accepted.
    @Published var invitation: PeerInvitation?
    @Published private(set) var running = false

    private static let service = "opencomms"

    private var peerID: MCPeerID
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    /// What each discovered peer told us about themselves. Kept separately
    /// from the published list so a peer that flickers does not lose its name.
    private var names: [MCPeerID: String] = [:]

    private override init() {
        // The peer id carries the display name, which is all anybody else
        // needs to recognise this phone. It is regenerated whenever the name
        // changes, because MCPeerID is immutable.
        let name = Store.shared.prefs.displayName
        peerID = MCPeerID(displayName: PeerDiscovery.sanitise(name))
        super.init()
    }

    /// MCPeerID rejects an empty name and truncates past 63 bytes, and either
    /// one is a crash or a silent failure rather than a message.
    private static func sanitise(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let usable = trimmed.isEmpty ? UIDevice.current.name : trimmed
        return String(usable.prefix(60))
    }

    // MARK: - Lifecycle

    /// Start looking, and let others find us.
    ///
    /// Safe to call repeatedly — opening the app, coming back from the
    /// background, or changing your name all end up here.
    func start() {
        guard !running else { return }
        guard Store.shared.prefs.visibility != .hidden else { return }

        let name = PeerDiscovery.sanitise(Store.shared.prefs.displayName)
        if name != peerID.displayName { peerID = MCPeerID(displayName: name) }

        let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session

        let advertiser = MCNearbyServiceAdvertiser(peer: peerID,
                                                   discoveryInfo: ["v": "1"],
                                                   serviceType: PeerDiscovery.service)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser

        let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: PeerDiscovery.service)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser

        running = true
        Log.audio.info("peer discovery started as \(name)")
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil; browser = nil; session = nil
        peers = []
        names = [:]
        running = false
    }

    /// Called when the name or the visibility setting changes.
    func refresh() {
        guard running else {
            if Store.shared.prefs.visibility != .hidden { start() }
            return
        }
        stop()
        if Store.shared.prefs.visibility != .hidden { start() }
    }

    // MARK: - Handing over a line

    /// Invite somebody standing next to you onto a line.
    ///
    /// The code travels over the same radio that found them, so this works
    /// with no signal at all — though the line itself still needs the
    /// internet, which is why the code is sent rather than the audio.
    func invite(_ peer: NearbyPeer, toCode code: String) {
        guard let session, let browser else { return }
        pendingCode = code
        browser.invitePeer(peer.id, to: session, withContext: Data(code.utf8), timeout: 20)
    }

    private var pendingCode: String?

    private func deliver(_ code: String, from peer: MCPeerID) {
        invitation = PeerInvitation(code: code, from: names[peer] ?? peer.displayName)
    }
}

// MARK: - Types

struct NearbyPeer: Identifiable, Equatable {
    let id: MCPeerID
    let displayName: String
    var initials: String { String(displayName.prefix(2)).uppercased() }
}

struct PeerInvitation: Identifiable, Equatable {
    var id: String { code + from }
    let code: String
    let from: String
}

// MARK: - Browsing

extension PeerDiscovery: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            names[peerID] = peerID.displayName
            guard !peers.contains(where: { $0.id == peerID }) else { return }
            peers.append(NearbyPeer(id: peerID, displayName: peerID.displayName))
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            peers.removeAll { $0.id == peerID }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser,
                             didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            // Almost always the local network permission being refused. Not
            // fatal: the server-side nearby list still works, and codes still
            // work, so this stays quiet rather than nagging.
            Log.audio.error("peer browsing failed: \(error.localizedDescription)")
            running = false
        }
    }
}

// MARK: - Advertising

extension PeerDiscovery: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            // Accepting the connection is not accepting the line. It only
            // opens the channel so the code can arrive; the person still
            // decides whether to join, and nothing about their audio has
            // changed until they do.
            invitationHandler(true, session)
            if let context, let code = String(data: context, encoding: .utf8), code.count == 3 {
                deliver(code, from: peerID)
            }
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in
            Log.audio.error("peer advertising failed: \(error.localizedDescription)")
            running = false
        }
    }
}

// MARK: - Session

extension PeerDiscovery: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID,
                             didChange state: MCSessionState) {
        Task { @MainActor in
            guard state == .connected, let code = pendingCode, let data = code.data(using: .utf8) else { return }
            // Send it again over the established session as well as in the
            // invitation context. The context is limited in size and is not
            // guaranteed to survive every path; this one is reliable.
            try? session.send(data, toPeers: [peerID], with: .reliable)
            pendingCode = nil
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard let code = String(data: data, encoding: .utf8), code.count == 3 else { return }
            deliver(code, from: peerID)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName name: String,
                             fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName name: String,
                             fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName name: String,
                             fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
