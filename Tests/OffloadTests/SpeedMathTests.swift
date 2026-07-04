import XCTest
@testable import OffloadCore

final class SpeedMathTests: XCTestCase {
    func testEWMAConvergesToConstantInput() {
        var ewma = EWMA(tau: 5)
        for _ in 0..<200 { ewma.add(sample: 100, dt: 0.1) }
        XCTAssertEqual(ewma.value!, 100, accuracy: 0.5)
    }

    func testEWMAFirstSampleSeeds() {
        var ewma = EWMA(tau: 5)
        ewma.add(sample: 250, dt: 0.1)
        XCTAssertEqual(ewma.value, 250)
    }

    func testEWMATimeCorrectness() {
        // One big dt step should move further than one small dt step.
        var a = EWMA(tau: 5), b = EWMA(tau: 5)
        a.add(sample: 0, dt: 0.1); b.add(sample: 0, dt: 0.1)
        a.add(sample: 100, dt: 0.1)
        b.add(sample: 100, dt: 2.0)
        XCTAssertLessThan(a.value!, b.value!)
    }

    func testOverheadModelLearnsFixedCost() {
        // Files of 10 MB at 100 MB/s = 0.1 s of IO, wall 0.15 s → overhead 0.05 s.
        var model = OverheadModel(seed: 0.015)
        for _ in 0..<100 {
            model.observe(fileWall: 0.15, size: 10 << 20, rate: Double(10 << 20) / 0.1)
        }
        XCTAssertEqual(model.seconds, 0.05, accuracy: 0.005)
    }

    func testStageRemainingSmallFilesHonest() {
        // 1000 small files, 1 MB each at 100 MB/s: naive = 10 s.
        // With 80 ms per-file overhead on 1 worker: + 80 s.
        let r = ETAMath.stageRemaining(bytesRemaining: 1000 << 20, filesRemaining: 1000,
                                       rate: 100 * 1024 * 1024, overheadSeconds: 0.08, workers: 1)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!, 10 + 80, accuracy: 1.0)
    }

    func testStageRemainingNilWhenCold() {
        XCTAssertNil(ETAMath.stageRemaining(bytesRemaining: 1, filesRemaining: 1,
                                            rate: nil, overheadSeconds: 0, workers: 1))
    }

    func testStageRemainingZeroWhenDone() {
        XCTAssertEqual(ETAMath.stageRemaining(bytesRemaining: 0, filesRemaining: 0,
                                              rate: nil, overheadSeconds: 1, workers: 1), 0)
    }

    func testPipelineETAIsMaxPlusTail() {
        XCTAssertEqual(ETAMath.pipelineETA(stages: [10, 30, 20], tail: 5), 35)
        XCTAssertNil(ETAMath.pipelineETA(stages: [10, nil], tail: 5))
    }

    func testWarmupGate() {
        XCTAssertFalse(ETAMath.isWarm(sampledSeconds: 1, bytesObserved: 1 << 30, filesObserved: 100))
        XCTAssertFalse(ETAMath.isWarm(sampledSeconds: 10, bytesObserved: 1 << 20, filesObserved: 2))
        XCTAssertTrue(ETAMath.isWarm(sampledSeconds: 4, bytesObserved: 64 << 20, filesObserved: 0))
        XCTAssertTrue(ETAMath.isWarm(sampledSeconds: 4, bytesObserved: 0, filesObserved: 6))
    }

    func testDownsampleBoundsAndMeans() {
        let samples = (0..<6000).map {
            SpeedSample(t: Double($0) / 10, sdReadBps: 100, nasWriteBps: 50)
        }
        let down = ETAMath.downsample(samples, maxBuckets: 600)
        XCTAssertLessThanOrEqual(down.count, 600)
        XCTAssertEqual(down.first!.sdReadBps, 100, accuracy: 0.001)
        XCTAssertEqual(down.last!.nasWriteBps, 50, accuracy: 0.001)
        // Short inputs pass through untouched.
        XCTAssertEqual(ETAMath.downsample(Array(samples.prefix(10)), maxBuckets: 600).count, 10)
    }
}
