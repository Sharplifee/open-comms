import OSLog

enum Log {
    static let session = Logger(subsystem: "com.connor.opencomms", category: "session")
    static let audio   = Logger(subsystem: "com.connor.opencomms", category: "audio")
    static let nearby  = Logger(subsystem: "com.connor.opencomms", category: "nearby")
}
