import CoreGraphics
import XCTest
@testable import iosApp

final class NativeMediaGalleryTests: XCTestCase {
    func testGalleryDestinationPreservesAllMediaAndSelectedIdentity() throws {
        let media = [
            CommentMediaDTO(kind: .image, url: URL(string: "https://pic.zhimg.com/one.jpg")!),
            CommentMediaDTO(kind: .image, url: URL(string: "https://pic.zhimg.com/two.jpg")!),
            CommentMediaDTO(kind: .sticker, url: URL(string: "https://pic.zhimg.com/three.png")!),
        ]

        let destination = try XCTUnwrap(
            CommentMediaGalleryDestination(media: media, selectedID: media[1].id)
        )

        XCTAssertEqual(destination.urls, media.map(\.url))
        XCTAssertEqual(destination.initialIndex, 1)
    }

    func testVerticalDismissalAcceptsUpAndDownAtOneScalePolicyBoundary() {
        XCTAssertFalse(NativeMediaDismissalPolicy.isVertical(CGSize(width: 120, height: 30)))
        XCTAssertTrue(
            NativeMediaDismissalPolicy.shouldDismiss(
                translation: CGSize(width: 4, height: -150),
                predictedEndTranslation: CGSize(width: 6, height: -190),
                viewportHeight: 800
            )
        )
        XCTAssertTrue(
            NativeMediaDismissalPolicy.shouldDismiss(
                translation: CGSize(width: 4, height: 50),
                predictedEndTranslation: CGSize(width: 6, height: 230),
                viewportHeight: 800
            )
        )
    }

    func testPagingUsesViewportWidthAndStopsAtBothBoundaries() {
        XCTAssertEqual(
            NativeMediaPagingPolicy.targetIndex(
                currentIndex: 1,
                pageCount: 3,
                translationWidth: -90,
                predictedEndTranslationWidth: -120,
                pageWidth: 400
            ),
            2
        )
        XCTAssertEqual(
            NativeMediaPagingPolicy.targetIndex(
                currentIndex: 0,
                pageCount: 3,
                translationWidth: 120,
                predictedEndTranslationWidth: 180,
                pageWidth: 400
            ),
            0
        )
        XCTAssertEqual(
            NativeMediaPagingPolicy.targetIndex(
                currentIndex: 2,
                pageCount: 3,
                translationWidth: -120,
                predictedEndTranslationWidth: -180,
                pageWidth: 400
            ),
            2
        )
    }
}
