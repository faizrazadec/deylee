import Foundation
import Hummingbird
import Logging

// Configuration is read before anything binds a port. A missing variable should
// stop the process here, with the name of the variable, rather than surface as a
// 500 on whichever request first needed it.
let envPath = ProcessInfo.processInfo.environment["DEYLEE_ENV_FILE"]
    ?? FileManager.default.currentDirectoryPath + "/../.env"

let config: Config
do {
    config = try Config.load(DotEnv.merged(with: envPath))
} catch {
    FileHandle.standardError.write(Data("deylee-api: \(error)\n".utf8))
    exit(1)
}

var logger = Logger(label: "deylee-api")
logger.logLevel = .info

let tokens = try await TokenService(config: config)

let router = Router()

// Liveness only. Deliberately does not touch the database: a health check that
// fails when Postgres is briefly unreachable invites an orchestrator to kill a
// process that would otherwise have recovered on its own.
router.get("/health") { _, _ -> [String: String] in
    ["status": "ok"]
}

let app = Application(
    router: router,
    configuration: .init(
        address: .hostname("127.0.0.1", port: config.port),
        serverName: "deylee-api"
    ),
    logger: logger
)

logger.info("listening", metadata: [
    "port": .string("\(config.port)"),
    "audiences": .string("\(config.googleAudiences.count) google client(s)"),
    "hostedDomain": .string(config.googleAllowedHostedDomain ?? "any"),
])

try await app.runService()
