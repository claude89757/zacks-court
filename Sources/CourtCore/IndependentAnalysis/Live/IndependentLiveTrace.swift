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
    /// Region poses stored for a frame (v29).
    case poses(frame: Int, samples: [IndependentPoseSample])
    /// The camera the rules use from now on (nil: the court was lost).
    case camera(IndependentPinholeCamera?)
    case freeze
    case reset
    case trim(now: Double)
    /// The picture moved: candidates before `before` were seen by another pose and are dropped.
    case discard(before: Double)
    case update(now: Double)
    case catchUp(now: Double)
}

public enum IndependentLiveTrace {
    /// Swaps a trace's ball candidates for another detector's candidate set, keeping every other event
    /// where it was: a replacement lands in the first candidate batch whose last candidate is not later
    /// than it, so trims, resets and updates between batches still apply to the candidates in their own
    /// time. Used to measure a model end to end without running the live lane (`independent-replay
    /// --candidates`); candidates must be sorted by time.
    public static func replacingCandidates(in events: [IndependentLiveTraceEvent],
                                           with candidates: [IndependentShotCandidate]) -> [IndependentLiveTraceEvent] {
        var next = 0, merged = [IndependentLiveTraceEvent]()
        for event in events {
            guard case .candidates(let batch) = event else { merged.append(event); continue }
            guard let last = batch.map(\.time).max() else { merged.append(event); continue }
            var take = [IndependentShotCandidate]()
            while next < candidates.count, candidates[next].time <= last { take.append(candidates[next]); next += 1 }
            merged.append(.candidates(take.isEmpty ? batch : take))
        }
        if next < candidates.count { merged.append(.candidates(Array(candidates[next...]))) }
        return merged
    }

    /// A trace with one frame of region poses kept in `every` (0: none). A research run records the poses
    /// denser than the App reads them (20 Hz for 10), so the same run can be replayed at several rates and
    /// without poses, as under load shedding.
    public static func thinningPoses(in events: [IndependentLiveTraceEvent], every: Int) -> [IndependentLiveTraceEvent] {
        var n = 0
        return events.filter { event in
            guard case .poses = event else { return true }
            n += 1
            return every > 0 && n % every == 0
        }
    }

    /// Replays a trace through `IndependentLiveShots` with the current rules. Returns the last version of
    /// every published shot, per stream, in publication order: what the lane's rows end as.
    public static func replay(_ events: [IndependentLiveTraceEvent]) -> [[IndependentShotResult]] {
        var streams = [[IndependentShotResult]]()
        var shots = IndependentLiveShots(), started = false
        var people = [Int: [IndependentPersonBox]](), poses = [Int: [IndependentPoseSample]](), camera: IndependentPinholeCamera?
        let pendingSeconds = IndependentLiveEngine.pendingSeconds
        func close() { if started { streams.append(shots.published.map(\.shot)) } }
        for event in events {
            switch event {
            case .newStream:
                close(); shots = IndependentLiveShots(); started = true
            case .candidates(let batch): shots.append(batch)
            case .people(let frame, let boxes): IndependentLivePeople.store(boxes, frame: frame, in: &people)
            case .peopleReset: people.removeAll(); poses.removeAll()
            case .poses(let frame, let samples): IndependentLivePoses.store(samples, frame: frame, in: &poses)
            case .camera(let c): camera = c
            case .freeze: shots.freeze()
            case .reset: shots.reset()
            case .trim(let now): shots.trim(keeping: pendingSeconds, now: now)
            case .discard(let before): shots.trim(keeping: 0, now: before)
            case .update(let now):
                if let camera { shots.update(now: now, camera: camera, people: IndependentPeople(people, poses: poses)) }
            case .catchUp(let now):
                if let camera { shots.catchUp(now: now, camera: camera, people: IndependentPeople(people, poses: poses)) }
            }
        }
        close()
        return streams
    }
}
