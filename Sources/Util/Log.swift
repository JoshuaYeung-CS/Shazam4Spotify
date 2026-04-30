import OSLog

extension Logger {
    private static let subsystem = "com.joshuayeung.shazam4spotify"

    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let api = Logger(subsystem: subsystem, category: "api")
    static let matcher = Logger(subsystem: subsystem, category: "matcher")
    static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
}
