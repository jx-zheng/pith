import XCTest
@testable import PithCore

final class OutputNamingTests: XCTestCase {
    func testPlainNameBesideSource() {
        let path = OutputNamer.destination(
            sourcePath: "/tmp/Page 001.pdf",
            outputExtension: "jpg",
            location: .besideSource,
            exists: { _ in false }
        )
        XCTAssertEqual(path, "/tmp/Page 001.jpg")
    }

    func testCollisionSuffixSkipsExisting() {
        let existing: Set<String> = ["/tmp/Page 001.jpg", "/tmp/Page 001 2.jpg"]
        let path = OutputNamer.destination(
            sourcePath: "/tmp/Page 001.pdf",
            outputExtension: "jpg",
            location: .besideSource,
            exists: { existing.contains($0) }
        )
        XCTAssertEqual(path, "/tmp/Page 001 3.jpg")
    }

    func testNeverReturnsTheSourcePath() {
        let path = OutputNamer.destination(
            sourcePath: "/tmp/photo.jpg",
            outputExtension: "jpg",
            location: .besideSource,
            exists: { _ in false }
        )
        XCTAssertEqual(path, "/tmp/photo 2.jpg")
        XCTAssertNotEqual(path, "/tmp/photo.jpg")
    }

    func testFixedDirectory() {
        let path = OutputNamer.destination(
            sourcePath: "/Users/kevin/Desktop/scan.png",
            outputExtension: "pdf",
            location: .directory("/Users/kevin/Converted"),
            exists: { _ in false }
        )
        XCTAssertEqual(path, "/Users/kevin/Converted/scan.pdf")
    }

    func testSuffixStyle() {
        let path = OutputNamer.destination(
            sourcePath: "/tmp/Page 001.jpg",
            outputExtension: "jpg",
            location: .besideSource,
            style: .suffix(" Cropped"),
            exists: { _ in false }
        )
        XCTAssertEqual(path, "/tmp/Page 001 Cropped.jpg")
    }

    func testPageNames() {
        let single = OutputNamer.destination(
            sourcePath: "/tmp/Page 001.pdf",
            outputExtension: "png",
            location: .besideSource,
            style: .page(number: 1, count: 1),
            exists: { _ in false }
        )
        XCTAssertEqual(single, "/tmp/Page 001.png")
        let many = OutputNamer.destination(
            sourcePath: "/tmp/Page 001.pdf",
            outputExtension: "png",
            location: .besideSource,
            style: .page(number: 2, count: 4),
            exists: { _ in false }
        )
        XCTAssertEqual(many, "/tmp/Page 001 page 2.png")
    }

    func testBatchPlanReservesNames() {
        let plan = BatchPlanner.plan(
            sources: ["/tmp/a.png", "/tmp/b.png"],
            outputExtension: "jpg",
            location: .directory("/out"),
            exists: { _ in false }
        )
        XCTAssertEqual(plan.map(\.destinationPath), ["/out/a.jpg", "/out/b.jpg"])

        let clash = BatchPlanner.plan(
            sources: ["/tmp/a.png", "/elsewhere/a.png"],
            outputExtension: "jpg",
            location: .directory("/out"),
            exists: { _ in false }
        )
        XCTAssertEqual(clash.map(\.destinationPath), ["/out/a.jpg", "/out/a 2.jpg"])
    }
}
