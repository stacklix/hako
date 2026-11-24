import Foundation

@main struct RandomStringGeneratorTests {
    static func main() throws {
        let groups = [RandomStringGenerator.digits, RandomStringGenerator.lowercase,
                      RandomStringGenerator.uppercase, RandomStringGenerator.punctuation]
        precondition(groups.map { $0.count } == [10, 26, 26, 32])
        precondition(Set(groups.flatMap { $0 }).count == 94)

        for mask in 1..<16 {
            let selected = groups.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            let allowed = Set(selected.flatMap { $0 })
            for length in [selected.count, 16, 1024] {
                let options = RandomStringGenerator(length: length,
                    includesDigits: mask & 1 != 0, includesLowercase: mask & 2 != 0,
                    includesUppercase: mask & 4 != 0, includesPunctuation: mask & 8 != 0)
                for _ in 0..<20 {
                    let result = try options.generate()
                    precondition(result.count == length)
                    precondition(result.allSatisfy { allowed.contains($0) })
                    for group in selected {
                        precondition(result.contains { group.contains($0) }, "Every selected type must be present")
                    }
                }
            }
        }

        func rejects(_ options: RandomStringGenerator) {
            precondition(options.validationMessage != nil)
            do {
                _ = try options.generate()
                preconditionFailure("Invalid configuration must fail")
            } catch {
                precondition(error.localizedDescription == options.validationMessage)
            }
        }
        for length in [Int.min, -1, 0, 1025, Int.max] {
            rejects(RandomStringGenerator(length: length))
        }
        rejects(RandomStringGenerator(includesDigits: false, includesLowercase: false, includesUppercase: false))
        rejects(RandomStringGenerator(length: 1))
        rejects(RandomStringGenerator(length: 3, includesPunctuation: true))
        let defaultResult = try RandomStringGenerator().generate()
        precondition(defaultResult.count == 16)
        print("Random string generator tests passed")
    }
}
