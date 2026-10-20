#if canImport(HushRT)
import HushRT
#endif
import Foundation
import os

/// shm w/ the driver (see Shared/hush_shm.h). survives coreaudiod restarts
/// since the driver reopens the same object so our mapping stays valid
final class SharedMemory {
    let pointer: UnsafeMutableRawPointer

    init() throws {
        var err: Int32 = 0
        guard let p = hush_app_map(&err) else {
            Logger(subsystem: "io.github.showdown76py.Hush", category: "shm").error("hush_app_map: errno \(err)")
            throw HushError.sharedMemoryUnavailable
        }
        pointer = p
        // margin past one client buffer + slack before dropping the excess (see driver)
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

    /// `driverAlive`: driver read the ring recently (a client is active)
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
