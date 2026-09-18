import Testing
@testable import AgentSession

@Suite struct SteerIntentTests {
    @Test func explicitStopWordsInterrupt() {
        #expect(SteerIntent.keywords("Stop that and list the files instead") == .interrupt)
        #expect(SteerIntent.keywords("cancel") == .interrupt)
        #expect(SteerIntent.keywords("please don't delete anything") == .interrupt)
    }
    @Test func additiveNotesQueue() {
        #expect(SteerIntent.keywords("also add a docstring") == .queue)
        #expect(SteerIntent.keywords("use tabs not spaces") == .queue)
        #expect(SteerIntent.keywords("the nonstop flag is fine") == .queue)   // 'stop' inside a word does not match
    }
}
