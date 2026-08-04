import XCTest
@testable import RemoteMini

/// N5 (spec §3-7): a 3xx from rc-backend must never be auto-followed -- `URLSession`
/// strips `Authorization` on a cross-origin redirect, and re-attaching it would mean
/// this client decides on its own to send the bearer key wherever `Location` points.
///
/// This exercises `RedirectRefusingDelegate`'s method directly rather than driving a
/// full redirect through `MockURLProtocol`: whether a custom `URLProtocol` subclass
/// actually triggers `URLSession`'s redirect machinery for a 3xx response is
/// undocumented behavior specific to this Foundation version, and this sprint has no
/// need to depend on it -- the delegate method is a plain, directly callable function,
/// and testing it directly is both more reliable and a tighter unit under test.
final class RedirectRefusalTests: XCTestCase {
    private func makeRedirectArgs() -> (session: URLSession, task: URLSessionTask, response: HTTPURLResponse, newRequest: URLRequest) {
        let session = URLSession(configuration: .ephemeral)
        let originalURL = URL(string: "https://unit-test.invalid/healthz")!
        let redirectURL = URL(string: "https://unit-test-redirect-target.invalid/healthz")!
        let task = session.dataTask(with: originalURL)
        let response = HTTPURLResponse(
            url: originalURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirectURL.absoluteString]
        )!
        let newRequest = URLRequest(url: redirectURL)
        return (session, task, response, newRequest)
    }

    func testDelegateRefusesTheRedirectByPassingNilToTheCompletionHandler() {
        let args = makeRedirectArgs()
        let delegate = RedirectRefusingDelegate()

        var receivedRequest: URLRequest? = args.newRequest // non-nil sentinel: catches "handler never called" too
        delegate.urlSession(args.session, task: args.task, willPerformHTTPRedirection: args.response, newRequest: args.newRequest) { result in
            receivedRequest = result
        }

        XCTAssertNil(receivedRequest, "must refuse by passing nil -- the 3xx response itself becomes the task's result")
    }

    func testBackendSessionIsActuallyWiredWithTheRefusingDelegate() {
        // Prove the delegate above is the one `BackendSession` really installs, not
        // just a class that happens to exist unused in the module.
        let backendSession = BackendSession()
        XCTAssertTrue(backendSession.session.delegate is RedirectRefusingDelegate)
    }

    func testFollowingDelegateNegativeControl() {
        // Negative control: prove the assertion above can fail. A delegate that
        // makes the easy mistake -- calling the completion handler with the new
        // request instead of nil -- is exactly what N5 exists to prevent. If this
        // control did NOT diverge from the real delegate, the real test would be
        // vacuous.
        final class FollowingDelegate: NSObject, URLSessionTaskDelegate {
            func urlSession(
                _ session: URLSession,
                task: URLSessionTask,
                willPerformHTTPRedirection response: HTTPURLResponse,
                newRequest request: URLRequest,
                completionHandler: @escaping (URLRequest?) -> Void
            ) {
                completionHandler(request) // the mistake N5 exists to prevent
            }
        }

        let args = makeRedirectArgs()
        var receivedRequest: URLRequest?
        FollowingDelegate().urlSession(args.session, task: args.task, willPerformHTTPRedirection: args.response, newRequest: args.newRequest) { result in
            receivedRequest = result
        }

        XCTAssertEqual(receivedRequest, args.newRequest, "control must actually follow, proving the real assertion can fail")
    }
}
