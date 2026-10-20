import Foundation
import os

/// Mémoire partagée avec le driver (voir Shared/hush_shm.h). Elle survit aux redémarrages de
/// coreaudiod : le driver rouvre le même objet, donc notre mapping reste valide.
final class SharedMemory {
    let pointer: UnsafeMutableRawPointer

    init() throws {
        var err: Int32 = 0
        guard let p = hush_app_map(&err) else {
            Logger(subsystem: "io.github.showdown76py.Hush", category: "shm").error("hush_app_map: errno \(err)")
            throw HushError.sharedMemoryUnavailable
        }
        pointer = p
        // Marge au-delà d'un buffer client, et tolérance avant de jeter l'excédent (voir le driver).
        hush_app_set_latency(p, 256, 1024)
    }

    deinit {
        hush_app_stop(pointer)
        hush_app_unmap(pointer)
    }

    struct Stats: Equatable {
        var clients: Int
        var underruns: UInt64
        var fill: UInt32
        var driverAlive: Bool
    }

    /// `driverAlive` : le driver a lu le ring récemment (un client est actif).
    var stats: Stats {
        let s = hush_app_reader_stats(pointer)
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let now = mach_absolute_time()
        let ageNs = now > s.readerHeartbeat ? Double(now - s.readerHeartbeat) * Double(tb.numer) / Double(tb.denom) : 0
        return Stats(clients: Int(s.clientsRunning), underruns: s.underruns, fill: s.lastFill,
                     driverAlive: s.readerHeartbeat != 0 && ageNs < 1e9)
    }
}
