/// Bounded selection of an Accessibility focus source. This type never reads
/// UI data itself, making its cross-process rejection policy testable without
/// contacting another application.
public enum FocusedTargetResolver {
    public enum Source: Equatable { case systemWide, application }
    public enum Lookup<Element> {
        case found(Element, processID: Int32)
        /// Only a genuinely unavailable focus query may permit another source.
        case unavailable(Error)
    }
    public enum Failure: Error, Equatable { case foregroundChanged, foreignProcess }

    public static func resolve<Element>(
        expectedProcessID: Int32,
        currentForegroundProcessID: () -> Int32?,
        query: (Source) throws -> Lookup<Element>
    ) throws -> Element {
        // No delays, no tree search and at most two queries. A successful but
        // foreign/invalid target is never replaced with a more convenient one.
        func checkForeground() throws {
            guard currentForegroundProcessID() == expectedProcessID else { throw Failure.foregroundChanged }
        }
        func accept(_ element: Element, processID: Int32) throws -> Element {
            guard processID == expectedProcessID else { throw Failure.foreignProcess }
            return element
        }
        try checkForeground()
        let system = try query(.systemWide)
        try checkForeground()
        switch system {
        case .found(let element, let processID): return try accept(element, processID: processID)
        case .unavailable:
            try checkForeground()
            let application = try query(.application)
            try checkForeground()
            switch application {
            case .found(let element, let processID): return try accept(element, processID: processID)
            case .unavailable(let error): throw error
            }
        }
    }
}
