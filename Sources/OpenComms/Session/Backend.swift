import Foundation

/// Every call the app makes to its own server.
///
/// Two rules hold this file together. Everything goes through a named RPC
/// rather than table access, because that is what lets the server enforce a
/// rule instead of merely suggesting it. And every request has a timeout: a
/// backend that hangs must produce an error somebody can act on, never a
/// spinner that lasts forever. That exact bug stranded people on "opening the
/// line" in the previous app.
actor Backend {
    static let shared = Backend()

    private let timeout: TimeInterval = 10

    struct JoinResult {
        let outcome: JoinOutcome
        let retryAfter: Int
        let squad: Squad?
    }

    // MARK: - Lines

    func createSquad(code: String, name: String, displayName: String) async throws -> JoinResult {
        let rows: [CreateRow] = try await rpc("create_squad", [
            "p_code": code, "p_name": name,
            "p_device_id": DeviceIdentity.id, "p_display_name": displayName
        ])
        guard let row = rows.first else { return JoinResult(outcome: .invalid, retryAfter: 0, squad: nil) }
        let outcome = JoinOutcome(rawValue: row.r_outcome) ?? .invalid
        guard outcome == .ok, let id = row.r_squad_id else {
            return JoinResult(outcome: outcome, retryAfter: 0, squad: nil)
        }
        return JoinResult(outcome: .ok, retryAfter: 0,
                          squad: Squad(id: id, name: row.r_squad_name ?? name,
                                       code: row.r_join_code ?? code, isHost: row.r_is_creator))
    }

    func joinSquad(code: String, displayName: String) async throws -> JoinResult {
        let rows: [JoinRow] = try await rpc("join_squad", [
            "p_code": code, "p_device_id": DeviceIdentity.id, "p_display_name": displayName
        ])
        guard let row = rows.first else { return JoinResult(outcome: .invalid, retryAfter: 0, squad: nil) }
        let outcome = JoinOutcome(rawValue: row.r_outcome) ?? .invalid
        guard outcome == .ok, let id = row.r_squad_id else {
            return JoinResult(outcome: outcome, retryAfter: row.r_retry_after, squad: nil)
        }
        return JoinResult(outcome: .ok, retryAfter: 0,
                          squad: Squad(id: id, name: row.r_squad_name ?? "Squad",
                                       code: row.r_join_code ?? code, isHost: row.r_is_creator))
    }

    func heartbeat(squadID: String) async {
        _ = try? await rpcVoid("heartbeat", ["p_squad_id": squadID, "p_device_id": DeviceIdentity.id])
    }

    func leave(squadID: String) async {
        _ = try? await rpcVoid("leave_squad", ["p_squad_id": squadID, "p_device_id": DeviceIdentity.id])
    }

    func endLine(squadID: String) async {
        _ = try? await rpcVoid("end_squad", ["p_squad_id": squadID, "p_device_id": DeviceIdentity.id])
    }

    /// Called when the host disappears. Somebody has to own the line, or it
    /// expires on the schedule of a person who already walked away.
    func claimHost(squadID: String) async {
        _ = try? await rpcVoid("claim_host", ["p_squad_id": squadID, "p_device_id": DeviceIdentity.id])
    }

    // MARK: - This device

    func registerDevice(displayName: String, phoneHash: String?, hidden: Bool) async {
        _ = try? await rpcVoid("register_device", [
            "p_device_id": DeviceIdentity.id, "p_display_name": displayName,
            "p_phone_hash": phoneHash as Any, "p_ghost": hidden, "p_identity": DeviceIdentity.id
        ])
    }

    /// Who else is within the chosen radius right now.
    ///
    /// Distance and bearing come back already computed — the server never
    /// hands out anybody's coordinates, because knowing somebody is thirty
    /// metres away is the feature and knowing exactly where they are standing
    /// is surveillance.
    func nearby(lat: Double, lon: Double, radius: Double) async -> [NearbyRow] {
        (try? await rpc("nearby_devices", [
            "p_device_id": DeviceIdentity.id,
            "p_lat": lat, "p_lon": lon, "p_radius_m": radius
        ])) ?? []
    }

    /// Which of these hashes belong to somebody who has the app. Failure is
    /// an empty list rather than an error: the Contacts screen has nothing
    /// useful to say about a network blip except "nobody yet".
    func matchContacts(hashes: [String]) async -> [ContactRow] {
        (try? await rpc("match_contacts", ["p_hashes": hashes])) ?? []
    }

    func updateLocation(lat: Double, lon: Double) async {
        _ = try? await rpcVoid("update_location", [
            "p_device_id": DeviceIdentity.id, "p_lat": lat, "p_lon": lon
        ])
    }

    /// Hidden erases the stored coordinates rather than merely stopping new
    /// ones. Halting writes leaves your last known position on a server
    /// forever, which is the opposite of what somebody turning this on wants.
    func setHidden(_ hidden: Bool) async {
        _ = try? await rpcVoid("set_ghost_mode", ["p_device_id": DeviceIdentity.id, "p_ghost": hidden])
    }

    func deleteEverything() async {
        _ = try? await rpcVoid("delete_device", ["p_device_id": DeviceIdentity.id])
    }

    // MARK: - Safety

    func unblock(_ deviceID: String) async {
        _ = try? await rpcVoid("unblock_device", ["p_blocker": DeviceIdentity.id, "p_blocked": deviceID])
    }

    func blocked() async -> [BlockedRow] {
        (try? await rpc("blocked_devices", ["p_blocker": DeviceIdentity.id])) ?? []
    }

    /// Reporting always blocks too. Asking "and would you also like to stop
    /// hearing them?" straight after somebody reports abuse is a bad question.
    func report(_ deviceID: String, squadID: String?, reason: String, detail: String?) async {
        _ = try? await rpcVoid("report_device", [
            "p_reporter": DeviceIdentity.id, "p_reported": deviceID,
            "p_squad": squadID as Any, "p_reason": reason, "p_detail": detail as Any
        ])
    }

    // MARK: - LiveKit

    /// The token is minted server side and the API secret never ships inside
    /// the app, where anybody could pull it out of the binary.
    func livekitToken(squadID: String, displayName: String) async throws -> String {
        var request = URLRequest(url: URL(string: "\(Config.supabaseURL)/functions/v1/mint-livekit-token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "squadId": squadID, "deviceId": DeviceIdentity.id, "displayName": displayName
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BackendError.tokenRefused
        }
        struct TokenBody: Decodable { let token: String }
        return try JSONDecoder().decode(TokenBody.self, from: data).token
    }

    // MARK: - Plumbing

    private func rpc<T: Decodable>(_ function: String, _ body: [String: Any]) async throws -> [T] {
        let data = try await post(function, body)
        if data.isEmpty { return [] }
        return try JSONDecoder().decode([T].self, from: data)
    }

    private func rpcVoid(_ function: String, _ body: [String: Any]) async throws {
        _ = try await post(function, body)
    }

    private func post(_ function: String, _ body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: URL(string: "\(Config.supabaseURL)/rest/v1/rpc/\(function)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body.compactMapValues { $0 })

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BackendError.noResponse }
        guard (200..<300).contains(http.statusCode) else {
            Log.session.error("\(function) failed \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
            throw BackendError.server(http.statusCode)
        }
        return data
    }
}

enum BackendError: Error {
    case noResponse
    case server(Int)
    case tokenRefused
}

// MARK: - Row shapes

struct CreateRow: Decodable {
    let r_outcome: String
    let r_squad_id: String?
    let r_squad_name: String?
    let r_join_code: String?
    let r_is_creator: Bool
}

struct JoinRow: Decodable {
    let r_outcome: String
    let r_retry_after: Int
    let r_squad_id: String?
    let r_squad_name: String?
    let r_join_code: String?
    let r_is_creator: Bool
}

struct ContactRow: Decodable {
    let phone_hash: String
    let display_name: String
}

/// Decoded straight from the RPC, so the field names are the server's.
struct NearbyRow: Decodable {
    let device_id: String
    let display_name: String
    let metres: Double
    let bearing: Double
}

struct BlockedRow: Decodable, Identifiable {
    var id: String { device_id }
    let device_id: String
    let display_name: String
}
