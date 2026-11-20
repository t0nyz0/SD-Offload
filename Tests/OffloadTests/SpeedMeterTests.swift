import XCTest
@testable import OffloadEngine

final class SpeedMeterTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testColdNASWaitAndSingleBurstDoNotProduceAnETA() {
        let meter = SpeedMeter()
        meter.sample(now: start)
        for second in 1...30 { meter.sample(now: start.addingTimeInterval(Double(second))) }
        XCTAssertNil(meter.etaRate(.nasWrite, now: start.addingTimeInterval(30)))

        meter.addBytes(16 << 20, stage: .nasWrite)
        meter.sample(now: start.addingTimeInterval(31))
        for second in 32...45 {
            let now = start.addingTimeInterval(Double(second))
            meter.sample(now: now)
            XCTAssertNil(meter.etaRate(.nasWrite, now: now), "Idle time is not sustained throughput")
        }
    }

    func testEstimateHoldsBetweenBurstsAndExpiresAfterAStall() throws {
        let meter = SpeedMeter()
        meter.sample(now: start)
        for tick in 1...6 {
            meter.addBytes(32 << 20, stage: .nasWrite)
            meter.sample(now: start.addingTimeInterval(Double(tick) / 2))
        }
        let rate = try XCTUnwrap(meter.etaRate(.nasWrite, now: start.addingTimeInterval(3)))
        XCTAssertEqual(rate, Double(64 << 20), accuracy: 1)
        for second in 4...12 {
            let now = start.addingTimeInterval(Double(second))
            meter.sample(now: now)
            XCTAssertEqual(meter.etaRate(.nasWrite, now: now), rate, "An idle rate must not produce a growing countdown")
        }
        XCTAssertNil(meter.etaRate(.nasWrite, now: start.addingTimeInterval(13)))
    }

    func testResumedProgressWarmsAgainWithoutTheOldConnectionDelay() throws {
        let meter = SpeedMeter()
        meter.sample(now: start)
        meter.addBytes(16 << 20, stage: .nasWrite)
        meter.sample(now: start.addingTimeInterval(1))
        meter.sample(now: start.addingTimeInterval(100))

        for second in 101...104 {
            meter.addBytes(32 << 20, stage: .nasWrite)
            let now = start.addingTimeInterval(Double(second))
            meter.sample(now: now)
            if second < 103 { XCTAssertNil(meter.etaRate(.nasWrite, now: now)) }
        }
        XCTAssertEqual(try XCTUnwrap(meter.etaRate(.nasWrite, now: start.addingTimeInterval(104))),
                       Double(32 << 20), accuracy: 1)
    }
}
