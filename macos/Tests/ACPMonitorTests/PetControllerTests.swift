import Foundation

@main
enum PetControllerChecks {
    @MainActor
    static func main() throws {
        let controller = PetController()
        do {
            try controller.start(
                executablePath: "",
                projection: PetActivityProjection(agents: []),
                onTermination: { _ in }
            )
            throw PetControllerCheckError.failed("an empty renderer path must not be launched")
        } catch PetControllerError.executablePathRequired {
            // Expected: reject in Swift before Foundation receives an invalid
            // Process.currentDirectoryURL and raises NSInvalidArgumentException.
        }
        print("Swift Pet controller checks passed")
    }
}

private enum PetControllerCheckError: Error {
    case failed(String)
}
