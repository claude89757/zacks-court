import Foundation

/// One input of the live shot rules, in the order `IndependentLiveEngine` applied it. A run's trace
/// replays the rules without the ball model, Vision or the video (`court-analyze independent-replay`),
/// so a rule change can be measured in seconds. Diagnostics only; the App never records it.
public enum IndependentLiveTraceEvent: Sendable, Codable, Equatable {
    /// A new stream: a fresh shot chain (the published list starts over).
    case newStream
    /// A batch of ball candidates appended to the chain.
    case candidates([IndependentShotCandidate])
    /// Person boxes stored for a frame (1/60 s units).
    case people(frame: Int, boxes: [IndependentPersonBox])
    case peopleReset
    /// The camera the rules use from now on (nil: the court was lost).
    case camera(IndependentPinholeCamera?)
    case freeze
    case reset
    case trim(now: Double)
    case update(now: Double)
    case catchUp(now: Double)
}

public enum IndependentLiveTrace {
    /// Replays a trace through `IndependentLiveShots` with the current rules. Returns the last version of
    /// every published shot, per stream, in publication order: what the lane's rows end as.
    public static func replay(_ events: [IndependentLiveTraceEvent]) -> [[IndependentShotResult]] {
        var streams = [[IndependentShotResult]]()
        var shots = IndependentLiveShots(), started = false
        var people = [Int: [IndependentPersonBox]](), camera: IndependentPinholeCamera?
        let pendingSeconds = IndependentLiveEngine.pendingSeconds
        func close() { if started { streams.append(shots.published.map(\.shot)) } }
        for event in events {
            switch event {
            case .newStream:
                close(); shots = IndependentLiveShots(); started = true
            case .candidates(let batch): shots.append(batch)
            case .people(let frame, let boxes): IndependentLivePeople.store(boxes, frame: frame, in: &people)
            case .peopleReset: people.removeAll()
            case .camera(let c): camera = c
            case .freeze: shots.freeze()
            case .reset: shots.reset()
            case .trim(let now): shots.trim(keeping: pendingSeconds, now: now)
            case .update(let now):
                if let camera { shots.update(now: now, camera: camera, people: IndependentPeople(people)) }
            case .catchUp(let now):
                if let camera { shots.catchUp(now: now, camera: camera, people: IndependentPeople(people)) }
            }
        }
        close()
        return streams
    }
}
