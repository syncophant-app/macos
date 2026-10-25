import Testing
@testable import CoreKit

@Test func generatedSetupPasswordsAlwaysMeetProviderPolicy() throws {
    for _ in 0..<1000 {
        let password = try PasswordGenerator.make()
        #expect(password.count >= 12)
        #expect(password.contains { $0.isUppercase })
        #expect(password.contains { $0.isLowercase })
        #expect(password.contains { $0.isNumber })
        #expect(password.contains { !$0.isLetter && !$0.isNumber })
    }
}
