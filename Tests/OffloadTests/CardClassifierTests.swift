import XCTest
@testable import OffloadEngine
import OffloadCore

final class CardClassifierTests: XCTestCase {
    private func volume(name: String = "SD Card", mediaRoot: Bool = true,
                        diskImage: Bool = false, network: Bool = false,
                        internalDevice: Bool = false) -> CandidateVolume {
        CandidateVolume(info: CardInfo(volumeUUID: "test-card", bsdName: "disk4s1",
            mountPath: "/Volumes/\(name)", volumeName: name,
            capacityBytes: 1024, freeBytes: 512, hasMediaRoot: mediaRoot),
            isRemovable: !internalDevice, isEjectable: !internalDevice,
            isInternal: internalDevice, isNetwork: network, isDiskImage: diskImage)
    }

    func testSimulatorDiskImageDoesNotClassifyAsCardEvenWithMediaFolder() {
        var config = AppConfig()
        config.defaultCardAction = .alwaysIngest
        for mediaRoot in [false, true] {
            XCTAssertEqual(CardClassifier.classify(volume(name: "iOS 26.1 Simulator",
                mediaRoot: mediaRoot, diskImage: true), config: config), .ignore)
        }
    }

    func testOnlyExplicitlyAllowlistedDiskImagesFollowInsertAction() {
        var config = AppConfig()
        config.testVolumeAllowlist = ["OFFLOADTEST"]
        let testImage = volume(name: "OFFLOADTEST-regression", diskImage: true)
        config.defaultCardAction = .alwaysIngest
        XCTAssertEqual(CardClassifier.classify(testImage, config: config), .ingest)
        config.defaultCardAction = .ask
        XCTAssertEqual(CardClassifier.classify(testImage, config: config), .ask)
        config.defaultCardAction = .ignore
        XCTAssertEqual(CardClassifier.classify(testImage, config: config), .ignore)
        config.defaultCardAction = .alwaysIngest
        config.testVolumeAllowlist = [""]
        XCTAssertEqual(CardClassifier.classify(testImage, config: config), .ignore)
    }

    func testPhysicalCardKeepsGlobalActionAndMediaFolderRequirement() {
        var config = AppConfig()
        config.defaultCardAction = .alwaysIngest
        XCTAssertEqual(CardClassifier.classify(volume(), config: config), .ingest)
        XCTAssertEqual(CardClassifier.classify(volume(mediaRoot: false), config: config), .ignore)
        config.defaultCardAction = .ask
        XCTAssertEqual(CardClassifier.classify(volume(), config: config), .ask)
        config.defaultCardAction = .ignore
        XCTAssertEqual(CardClassifier.classify(volume(), config: config), .ignore)
    }

    func testNetworkAndFixedInternalVolumesStayExcluded() {
        var config = AppConfig()
        config.defaultCardAction = .alwaysIngest
        XCTAssertEqual(CardClassifier.classify(volume(network: true), config: config), .ignore)
        XCTAssertEqual(CardClassifier.classify(volume(internalDevice: true), config: config), .ignore)
    }

    func testDiskImageProtocolDoesNotExcludeUSBOrOtherPhysicalReaders() {
        XCTAssertTrue(CardClassifier.isDiskImage(deviceProtocol: "Disk Image"))
        XCTAssertTrue(CardClassifier.isDiskImage(deviceProtocol: " disk image\n"))
        for deviceProtocol in [nil, "USB", "Secure Digital", "PCI-Express", ""] {
            XCTAssertFalse(CardClassifier.isDiskImage(deviceProtocol: deviceProtocol))
        }
    }

    func testAPFSSimulatorMetadataIsRecognizedByDeviceModel() {
        // Direct Disk Arbitration descriptions captured from the mounted iOS
        // and XROS runtimes; diskutil instead displays bus protocol "Disk Image".
        XCTAssertTrue(CardClassifier.isDiskImage(deviceProtocol: "Virtual Interface", deviceModel: "Disk Image"))
        XCTAssertTrue(CardClassifier.isDiskImage(deviceProtocol: nil, deviceModel: " disk image\n"))
        XCTAssertFalse(CardClassifier.isDiskImage(deviceProtocol: "Virtual Interface", deviceModel: "External SSD"))
        XCTAssertFalse(CardClassifier.isDiskImage(deviceProtocol: "USB", deviceModel: "SD Card Reader"))
    }
}
