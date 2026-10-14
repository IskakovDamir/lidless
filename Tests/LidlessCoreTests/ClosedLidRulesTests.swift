import XCTest
@testable import LidlessCore

final class ClosedLidRulesTests: XCTestCase {
    let now: Double = 1_800_000_000

    func lease(battery: Bool = false, cutoff: Int = 30, limit: Int = 0, ends: Double? = nil,
               heartbeat: Double? = nil) -> ClosedLidLease {
        ClosedLidLease(sessionID: "s1", heartbeat: heartbeat ?? now, sessionEnds: ends,
                       allowBattery: battery, batteryCutoff: cutoff, closedLimitMinutes: limit)
    }

    func power(_ source: PowerSnapshot.Source, _ percent: Int? = 80, thermal: Bool = true) -> PowerSnapshot {
        PowerSnapshot(source: source, batteryPercent: percent, hasBattery: true, thermalOK: thermal)
    }

    func testHoldsOnCharger() {
        XCTAssertEqual(ClosedLidRules.evaluate(lease: lease(), now: now, power: power(.adapter), closedFor: 0), .hold)
    }

    func testStaleHeartbeatStops() {
        let l = lease(heartbeat: now - 31)
        XCTAssertEqual(ClosedLidRules.evaluate(lease: l, now: now, power: power(.adapter), closedFor: 0), .stop(.contactLost))
    }

    func testFutureHeartbeatStops() {
        let l = lease(heartbeat: now + 120)
        XCTAssertEqual(ClosedLidRules.evaluate(lease: l, now: now, power: power(.adapter), closedFor: 0), .stop(.contactLost))
    }

    func testBatteryRequiresOptIn() {
        XCTAssertEqual(ClosedLidRules.evaluate(lease: lease(), now: now, power: power(.battery), closedFor: 0),
                       .stop(.chargerRequired))
        XCTAssertEqual(ClosedLidRules.evaluate(lease: lease(battery: true), now: now, power: power(.battery), closedFor: 0),
                       .hold)
    }

    func testBatteryCutoffAndFloor() {
        XCTAssertEqual(ClosedLidRules.evaluate(lease: lease(battery: true, cutoff: 30), now: now,
                                               power: power(.battery, 30), closedFor: 0), .stop(.lowBattery))
        // A cutoff below the floor is raised to the floor.
        XCTAssertEqual(ClosedLidRules.evaluate(lease: lease(battery: true, cutoff: 0), now: now,
                                               power: power(.battery, 9), closedFor: 0), .stop(.lowBattery))
        XCTAssertEqual(ClosedLidRules.evaluate(lease: lease(battery: true, cutoff: 0), now: now,
                                               power: power(.battery, 11), closedFor: 0), .hold)
    }

    func testThermalStops() {
        XCTAssertEqual(ClosedLidRules.evaluate(lease: lease(), now: now, power: power(.adapter, thermal: false), closedFor: 0),
                       .stop(.thermal))
    }

    func testUnknownPowerStops() {
        XCTAssertEqual(ClosedLidRules.evaluate(lease: lease(), now: now, power: power(.unknown), closedFor: 0),
                       .stop(.powerUnknown))
    }

    func testClosedLimit() {
        let l = lease(limit: 30)
        XCTAssertEqual(ClosedLidRules.evaluate(lease: l, now: now, power: power(.adapter), closedFor: 29 * 60), .hold)
        XCTAssertEqual(ClosedLidRules.evaluate(lease: l, now: now, power: power(.adapter), closedFor: 30 * 60),
                       .stop(.closedLimitReached))
        // 0 means the whole session.
        XCTAssertEqual(ClosedLidRules.evaluate(lease: lease(limit: 0), now: now, power: power(.adapter),
                                               closedFor: 20 * 3600), .hold)
    }

    func testSessionEnd() {
        XCTAssertEqual(ClosedLidRules.evaluate(lease: lease(ends: now - 1), now: now, power: power(.adapter), closedFor: 0),
                       .stop(.sessionEnded))
    }

    func testInvalidLease() {
        var l = lease()
        l.version = 99
        XCTAssertEqual(ClosedLidRules.evaluate(lease: l, now: now, power: power(.adapter), closedFor: 0), .stop(.invalidLease))
        l = lease(limit: 100_000)
        XCTAssertEqual(ClosedLidRules.evaluate(lease: l, now: now, power: power(.adapter), closedFor: 0), .stop(.invalidLease))
    }

    func testSessionRules() {
        let strict = SessionPowerRules(requireCharger: true, endOnLowBattery: true, batteryCutoff: 20)
        XCTAssertEqual(strict.violation(for: power(.battery, 90)), .chargerRequired)
        XCTAssertNil(strict.violation(for: power(.adapter, 5)))

        let loose = SessionPowerRules(requireCharger: false, endOnLowBattery: true, batteryCutoff: 20)
        XCTAssertNil(loose.violation(for: power(.battery, 21)))
        XCTAssertEqual(loose.violation(for: power(.battery, 20)), .lowBattery(20))

        let none = SessionPowerRules(requireCharger: false, endOnLowBattery: false, batteryCutoff: 20)
        XCTAssertNil(none.violation(for: power(.battery, 3)))
        XCTAssertEqual(none.leaseBatteryCutoff, ClosedLidRules.batteryFloor)
    }

    func testDesktopIgnoresBatteryRules() {
        let rules = SessionPowerRules(requireCharger: true, endOnLowBattery: true, batteryCutoff: 20)
        let desktop = PowerSnapshot(source: .adapter, batteryPercent: nil, hasBattery: false, thermalOK: true)
        XCTAssertNil(rules.violation(for: desktop))
    }

    func testFormat() {
        XCTAssertEqual(DurationFormat.clock(3725), "1:02:05")
        XCTAssertEqual(DurationFormat.clock(65), "1:05")
        XCTAssertEqual(DurationFormat.compact(3725), "1:02")
        XCTAssertEqual(DurationFormat.compact(600), "10m")
        XCTAssertEqual(DurationFormat.words(minutes: 150), "2 h 30 min")
        XCTAssertEqual(DurationFormat.words(minutes: 60), "1 h")
    }

    func testStatusRoundTrip() throws {
        let status = DaemonStatus(daemonVersion: "0.1.0", updatedAt: now, state: .stopped, sessionID: "s1",
                                  reason: .lowBattery, lidClosed: true, closedSince: now - 10, lastError: nil)
        let data = try JSONEncoder().encode(status)
        XCTAssertEqual(try JSONDecoder().decode(DaemonStatus.self, from: data), status)
    }
}
