import XCTest
@testable import ClashDashKit

final class SubscriptionTransportTests: XCTestCase {
    func testHTTPRequiresConsentEvenWhenWrapped() throws {
        let address = "http://127.0.0.1:8888/sub.yaml"
        let wrapped = "clash://install-config?url=" + address.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let url = try ImportAddress.subscriptionURL(from: wrapped)
        XCTAssertEqual(url.absoluteString, address)
        XCTAssertThrowsError(try SubscriptionTransport.validate(url))
        XCTAssertNoThrow(try SubscriptionTransport.validate(url, allowInsecureHTTP: true))
        XCTAssertNoThrow(try SubscriptionTransport.validate(URL(string: "https://example.com/sub")!))
        for bad in ["file:///etc/passwd", "http://user:password@example.com/sub", "https://user:password@example.com/sub"] {
            XCTAssertThrowsError(try SubscriptionTransport.validate(URL(string: bad)!, allowInsecureHTTP: true))
        }
    }
    func testHTTPApprovalIsLimitedToSameOriginAndDoesNotAllowDowngrade() throws {
        let origin = URL(string: "http://example.com:8888/sub")!
        func redirect(_ text: String, from source: URL? = nil, approved: URL? = nil) -> URLRequest? {
            SubscriptionTransport.redirect(URLRequest(url: URL(string: text)!), from: source ?? origin, approvedHTTPOrigin: approved)
        }
        XCTAssertNil(redirect("http://example.com:8888/next"))
        XCTAssertNotNil(redirect("http://example.com:8888/next", approved: origin))
        XCTAssertNil(redirect("http://example.com:8889/next", approved: origin))
        XCTAssertNil(redirect("http://other.example/next", approved: origin))
        XCTAssertNotNil(redirect("https://other.example/next", approved: origin))
        XCTAssertNil(redirect(origin.absoluteString, from: URL(string: "https://example.com/sub")!, approved: origin))
        XCTAssertNil(redirect("https://user:password@example.com/sub", approved: origin))
    }
    func testCrossOriginRedirectStripsCredentialsIncludingPortChanges() {
        let source = URL(string: "https://example.com/sub")!
        var request = URLRequest(url: URL(string: "https://example.com:8443/next")!)
        request.setValue("synthetic-test-only", forHTTPHeaderField: "Authorization")
        request.setValue("session=test", forHTTPHeaderField: "Cookie")
        let safe = SubscriptionTransport.redirect(request, from: source)
        XCTAssertNotNil(safe)
        XCTAssertNil(safe?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(safe?.value(forHTTPHeaderField: "Cookie"))
    }
}
