import DeyleeKit
import Foundation

// MARK: - Wire types
//
// These mirror `docs/SYNC_PROTOCOL.md` exactly. They are deliberately separate from
// DeyleeKit's `SyncSegment` and `SyncDay`: the core should not know what JSON is,
// and the wire format should be free to gain a field without reshaping the store.

private struct RowDTO: Codable {
    var id: String
    var dayDate: String?
    var type: String?
    var startedAt: EpochMs?
    var endedAt: EpochMs?
    var note: String?
    var date: String?
    var targetMinutes: Int?
    var createdAt: EpochMs?
    var updatedAt: EpochMs
    var deletedAt: EpochMs?
    var seq: Int64?
}

private struct ChangeDTO: Codable {
    var table: String
    var op: String
    var row: RowDTO
}

private struct SyncRequestDTO: Encodable {
    let protocolVersion: Int
    let deviceId: String
    let cursor: Int64
    let changes: [ChangeDTO]
}

private struct ChangeResultDTO: Decodable {
    let id: String
    let status: String
    let code: String?
    let message: String?
}

private struct SyncResponseDTO: Decodable {
    let protocolVersion: Int
    let cursor: Int64
    let serverTime: EpochMs
    let hasMore: Bool
    let results: [ChangeResultDTO]
    let changes: [ChangeDTO]
}

// MARK: - Service

/// Reconciles this device with the server.
///
/// Never on the path of a user action. Starting a timer writes to SQLite and
/// returns; this runs afterwards, on a schedule, and its failure is a status line
/// rather than an error dialog. A sync that cannot complete must leave the app
/// exactly as usable as it was.
@MainActor
final class SyncService: ObservableObject {
    enum Status: Equatable {
        case idle
        case syncing
        case succeeded(at: EpochMs)
        case failed(String)
        /// Rows the server refused, which the user has to resolve — an overlap
        /// created on two devices at once, most often.
        case rejected([String])
    }

    @Published private(set) var status: Status = .idle

    private let config: ClientConfig
    private let repo: Repository
    private let auth: AuthService
    private let now: () -> EpochMs
    private var inFlight = false

    init(
        config: ClientConfig,
        repo: Repository,
        auth: AuthService,
        now: @escaping () -> EpochMs = { EpochMs(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.config = config
        self.repo = repo
        self.auth = auth
        self.now = now
    }

    /// Push what is pending and pull what is new, repeating while the server says
    /// there is more.
    ///
    /// Reentrancy is refused rather than queued: two syncs racing would push the
    /// same rows twice and interleave their cursor writes. The next scheduled run
    /// picks up anything this one missed.
    func syncNow() async {
        guard !inFlight else { return }
        guard let token = await auth.accessToken() else { return }
        inFlight = true
        defer { inFlight = false }

        status = .syncing
        do {
            var rejections: [String] = []
            var pages = 0
            // Bounded so a server that always reports `hasMore` cannot spin here
            // forever; the next scheduled sync continues from the stored cursor.
            while pages < 50 {
                pages += 1
                let (more, refused) = try await exchangeOnce(token: token)
                rejections.append(contentsOf: refused)
                if !more { break }
            }
            status = rejections.isEmpty ? .succeeded(at: now()) : .rejected(rejections)
        } catch let failure as APIClient.HTTPFailure where failure.needsFullResync {
            // The client is ahead of the server — it is talking to a restored
            // backup. Rewinding to zero re-delivers everything; rows already held
            // are matched by uuid and upserted, so nothing duplicates.
            try? repo.rewindCursor(at: now())
            status = .failed("The server was restored from a backup; resyncing from the start.")
        } catch let failure as APIClient.HTTPFailure where failure.isUnauthorized {
            status = .failed("Signed out. Sign in again to resume syncing.")
        } catch {
            status = .failed(String(describing: error))
        }
    }

    /// One round trip: everything pending goes up, everything past the cursor comes
    /// down. Returns whether the server has more, and any rows it refused.
    private func exchangeOnce(token: String) async throws -> (hasMore: Bool, rejected: [String]) {
        let state = try repo.syncState()
        let pending = try repo.pendingPush()

        var changes: [ChangeDTO] = []
        for day in pending.days { changes.append(Self.encode(day)) }
        for segment in pending.segments { changes.append(Self.encode(segment)) }

        let response: SyncResponseDTO = try await APIClient.post(
            config.apiBaseURL.appending(path: "/v1/sync"),
            body: SyncRequestDTO(
                protocolVersion: 1,
                deviceId: state.deviceID,
                cursor: state.cursor,
                changes: changes
            ),
            bearer: token
        )

        // Only rows the server actually took are cleared, and only if they have not
        // been edited since — `markPushed` checks `updated_at`, so an edit made
        // while this request was in flight stays pending.
        let applied = Set(response.results.filter { $0.status == "applied" }.map(\.id))
        try repo.markPushed(
            pending.days.filter { applied.contains($0.uuid) }.map { ($0.uuid, $0.updatedAt) },
            table: .days
        )
        try repo.markPushed(
            pending.segments.filter { applied.contains($0.uuid) }.map { ($0.uuid, $0.updatedAt) },
            table: .segments
        )

        // Anything else was refused, and every reason the server gives is structural:
        // an overlap clashes next time too, an over-long note is over-long for ever.
        // Left dirty it would be offered again every two minutes, plus every wake and
        // every activation, for the life of the install — a request that cannot ever
        // succeed. Marking it against the version that was refused stops the retry
        // without losing the row: editing it moves `updated_at` past the mark and the
        // row rejoins the queue by itself.
        let refusedByID = Dictionary(
            response.results
                .filter { $0.status != "applied" }
                .map { ($0.id, $0.code ?? $0.status) },
            uniquingKeysWith: { first, _ in first }
        )
        if !refusedByID.isEmpty {
            try repo.markRejected(
                pending.days.compactMap { day in
                    refusedByID[day.uuid].map { (day.uuid, day.updatedAt, $0) }
                },
                table: .days
            )
            try repo.markRejected(
                pending.segments.compactMap { segment in
                    refusedByID[segment.uuid].map { (segment.uuid, segment.updatedAt, $0) }
                },
                table: .segments
            )
        }

        var incomingDays: [SyncDay] = []
        var incomingSegments: [SyncSegment] = []
        var unreadable: [Repository.QuarantinedRow] = []
        var understood: [String] = []
        for change in response.changes {
            if change.table == "days", let day = Self.decodeDay(change.row) {
                incomingDays.append(day)
                understood.append(day.uuid)
            } else if change.table == "segments", let segment = Self.decodeSegment(change.row) {
                incomingSegments.append(segment)
                understood.append(segment.uuid)
            } else if let held = Self.quarantining(change, at: now()) {
                // Set aside rather than dropped. The cursor only moves forwards and the
                // protocol has no way to ask for one row again, so skipping this used to
                // delete it from this device for ever — and the case that produces it is
                // the forward-compatible one, where the row means something this build
                // has not learnt yet.
                unreadable.append(held)
            }
        }

        // Rows held from an earlier sync that this build can read now — an upgrade
        // taught it the shape. Ones still in the current batch are left alone: the
        // copy that just arrived is the newer one.
        let arrivedAgain = Set(unreadable.map(\.uuid)).union(understood)
        var replayed: [String] = []
        for held in try repo.quarantined() where !arrivedAgain.contains(held.uuid) {
            guard let change = Self.decodeQuarantined(held) else { continue }
            if change.table == "days", let day = Self.decodeDay(change.row) {
                incomingDays.append(day)
                replayed.append(held.uuid)
            } else if change.table == "segments", let segment = Self.decodeSegment(change.row) {
                incomingSegments.append(segment)
                replayed.append(held.uuid)
            }
        }

        try repo.applyRemote(days: incomingDays, segments: incomingSegments, serverSeq: response.cursor)

        // After the rows are written and before the cursor moves. Dying anywhere in
        // here costs a repeat, never a row: an unsaved quarantine leaves the cursor
        // where it was so the server sends it again, and a replay that was applied but
        // not released is applied again, which the upsert makes a no-op.
        try repo.quarantine(unreadable)
        try repo.releaseFromQuarantine(replayed + understood)

        // Only after the rows are durably written. A cursor advanced first is a
        // cursor that skips rows if the process dies in between.
        try repo.advanceCursor(to: response.cursor, at: now())

        let refused = response.results
            .filter { $0.status != "applied" }
            .map { $0.message ?? $0.code ?? "rejected" }
        return (response.hasMore, refused)
    }

    // MARK: Encoding

    private static func encode(_ day: SyncDay) -> ChangeDTO {
        ChangeDTO(
            table: "days",
            op: day.deletedAt == nil ? "upsert" : "delete",
            row: RowDTO(
                id: day.uuid, date: day.date.description, targetMinutes: day.targetMinutes,
                createdAt: day.createdAt, updatedAt: day.updatedAt, deletedAt: day.deletedAt
            )
        )
    }

    private static func encode(_ segment: SyncSegment) -> ChangeDTO {
        ChangeDTO(
            table: "segments",
            op: segment.deletedAt == nil ? "upsert" : "delete",
            row: RowDTO(
                id: segment.uuid, dayDate: segment.dayDate.description,
                type: segment.type.rawValue, startedAt: segment.startedAt,
                endedAt: segment.endedAt, note: segment.note,
                createdAt: segment.createdAt, updatedAt: segment.updatedAt,
                deletedAt: segment.deletedAt
            )
        )
    }

    /// Re-encode a change this build could not read, so it can be tried again later.
    ///
    /// Nil only if the row will not round-trip through JSON at all, which for a value
    /// that arrived as JSON means something is wrong with this process rather than
    /// with the row. There is nothing useful to keep in that case.
    private static func quarantining(_ change: ChangeDTO, at now: EpochMs) -> Repository.QuarantinedRow? {
        guard let table = SyncTable(rawValue: change.table),
              let json = try? JSONEncoder().encode(change),
              let text = String(data: json, encoding: .utf8)
        else { return nil }
        return Repository.QuarantinedRow(
            uuid: change.row.id, table: table,
            // The row's own sequence when it has one, so a replay keeps the server's
            // order. Zero sorts it first, which is where a row of unknown age belongs.
            seq: change.row.seq ?? 0,
            payload: text, firstSeen: now
        )
    }

    private static func decodeQuarantined(_ held: Repository.QuarantinedRow) -> ChangeDTO? {
        try? JSONDecoder().decode(ChangeDTO.self, from: Data(held.payload.utf8))
    }

    /// A row that cannot be understood is set aside rather than fatal: a newer server
    /// may send a shape this build does not know, and refusing the whole batch over
    /// one row would strand the client until it updates. It is kept rather than
    /// dropped, because the cursor advances past it either way.
    private static func decodeDay(_ row: RowDTO) -> SyncDay? {
        guard let date = row.date.flatMap(DateKey.init), let target = row.targetMinutes
        else { return nil }
        return SyncDay(
            uuid: row.id, date: date, targetMinutes: target, endedAt: row.endedAt,
            createdAt: row.createdAt ?? row.updatedAt, updatedAt: row.updatedAt,
            deletedAt: row.deletedAt
        )
    }

    private static func decodeSegment(_ row: RowDTO) -> SyncSegment? {
        guard let date = row.dayDate.flatMap(DateKey.init),
              let type = row.type.flatMap(SegmentType.init(rawValue:)),
              let startedAt = row.startedAt
        else { return nil }
        return SyncSegment(
            uuid: row.id, dayDate: date, type: type, startedAt: startedAt,
            endedAt: row.endedAt, note: row.note,
            createdAt: row.createdAt ?? row.updatedAt, updatedAt: row.updatedAt,
            deletedAt: row.deletedAt
        )
    }
}
