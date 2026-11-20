import Testing
@testable import EhCore

@Test func categoryFromString() {
    #expect(EhCategory.from(string: "Artist CG") == .artistCG)
}
