import Testing
import AgentProtocol
@testable import AgentTestKit

@Suite struct FakeCLITests {
    @Test func matchingIgnoresVolatileFields() {
        let a: JSONValue = ["type": "control_request", "request_id": "req_1_abc", "request": ["subtype": "initialize"]]
        let b: JSONValue = ["type": "control_request", "request_id": "req_9_zzz", "request": ["subtype": "initialize"]]
        #expect(FakeCLIScript.matches(expected: a, actual: b))
    }
}
