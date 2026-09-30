import Foundation
import XCTest
@testable import CIStatus

final class PullRequestFailureTests: XCTestCase {
    func testClosedPullRequestClearsItsFailedPushRun() throws {
        let run = try makeRun(event: "push", createdAt: "2026-07-13T18:07:38Z")
        let pullRequest = try makePullRequest(state: "closed", createdAt: "2026-07-13T16:45:58Z", closedAt: "2026-07-13T18:24:18Z")

        XCTAssertTrue(run.needsPullRequestState)
        var refreshedRun = run
        refreshedRun.pullRequestState = run.matchingPullRequest(in: [pullRequest])?.state
        XCTAssertTrue(refreshedRun.isClosedPullRequestFailure)
        XCTAssertTrue(RunSections(runs: [refreshedRun]).unresolvedFailures.isEmpty)
    }

    func testReusedBranchDoesNotUseLaterPullRequest() throws {
        let run = try makeRun(event: "push", createdAt: "2026-07-13T18:07:38Z")
        let laterPullRequest = try makePullRequest(state: "closed", createdAt: "2026-07-14T12:00:00Z", closedAt: "2026-07-14T13:00:00Z")

        XCTAssertNil(run.matchingPullRequest(in: [laterPullRequest]))
        XCTAssertEqual(RunSections(runs: [run]).unresolvedFailures.map(\.id), [1])
    }

    private func makeRun(event: String, createdAt: String) throws -> WorkflowRun {
        let data = Data("""
            {"id":1,"name":"Build","event":"\(event)","status":"completed","conclusion":"failure","head_branch":"feature","head_sha":"abc","html_url":"https://github.com/example/repo/actions/runs/1","created_at":"\(createdAt)","updated_at":"2026-07-13T18:15:00Z"}
            """.utf8)
        return try decoder.decode(WorkflowRun.self, from: data)
    }

    private func makePullRequest(state: String, createdAt: String, closedAt: String) throws -> PullRequestSummary {
        let data = Data("""
            {"state":"\(state)","created_at":"\(createdAt)","closed_at":"\(closedAt)","head":{"sha":"abc"}}
            """.utf8)
        return try decoder.decode(PullRequestSummary.self, from: data)
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
