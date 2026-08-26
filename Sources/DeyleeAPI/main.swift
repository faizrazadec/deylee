import Foundation
import Hummingbird
import Logging
import PostgresNIO

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
// Raiseable without a rebuild. Connection-pool faults are only explained at debug
// level, and needing a redeploy to find out why the database is unreachable is
// exactly the wrong time to need one.
logger.logLevel = Logger.Level(
    rawValue: ProcessInfo.processInfo.environment["LOG_LEVEL"] ?? "info"
) ?? .info

let tokens = try await TokenService(config: config)

let store: Store
do {
    store = try Store(
        url: config.databaseURL,
        tls: config.databaseTLS,
        caCertificatePath: config.databaseCACertificatePath,
        logger: logger
    )
} catch {
    FileHandle.standardError.write(Data("deylee-api: \(error)\n".utf8))
    exit(1)
}

let router = Router(context: DeyleeRequestContext.self)
router.add(middleware: ErrorLogging(logger: logger))

// Before anything expensive. Every password attempt costs a quarter-second of database
// CPU by design, so an unauthenticated caller turns one cheap request into real money;
// closing the timing channel made an unknown address cost the same as a real one, which
// is why this lands with it rather than after it.
let rateLimiter = RateLimiter()
router.add(middleware: RateLimitMiddleware(
    limiter: rateLimiter, limit: 600, window: .seconds(60), logger: logger
))

// Liveness only. Deliberately does not touch the database: a health check that
// fails when Postgres is briefly unreachable invites an orchestrator to kill a
// process that would otherwise have recovered on its own.
router.get("/health") { _, _ -> [String: String] in
    ["status": "ok"]
}

// The Mac app's update feed, when a directory is configured to serve it from.
//
// Public and unauthenticated on purpose: Sparkle fetches the appcast and the archive
// with no credentials, which is also why this cannot live behind a private repository.
// Authenticity does not come from the transport — every archive carries an EdDSA
// signature the app checks against a public key compiled into it, so a tampered file
// served from here is refused by the client rather than trusted because it arrived
// over HTTPS.
//
// `FileMiddleware` rather than a handler of our own: it is the piece that has already
// thought about a request path containing `../`, and a static file server is exactly
// the kind of thing that looks trivial until it serves `/etc/passwd`.
if let updates = config.updatesDirectory {
    router.add(middleware: FileMiddleware(
        updates,
        urlBasePath: "/updates",
        cacheControl: .init([(.text, [.maxAge(300)])]),
        logger: logger
    ))
    logger.info("serving updates", metadata: ["directory": .string(updates)])
}

let mailer = Mailer(
    apiKey: config.resendAPIKey,
    from: config.resendFrom,
    templateID: config.resendOTPTemplateID,
    logger: logger
)

AuthController(store: store, tokens: tokens, config: config, mailer: mailer,
               limiter: rateLimiter, logger: logger)
    .addRoutes(to: router)
SyncController(store: store, tokens: tokens, logger: logger).addRoutes(to: router)
WitnessController(store: store, tokens: tokens, logger: logger).addRoutes(to: router)
FeedbackController(store: store, tokens: tokens, logger: logger).addRoutes(to: router)

var app = Application(
    router: router,
    configuration: .init(
        address: .hostname(config.host, port: config.port),
        serverName: "deylee-api"
    ),
    services: [store.client],
    logger: logger
)

// After the pool is up and before a single request is served. Tenancy rests on the
// row-level-security policies binding, and they bind only to an ordinary role — so a
// process connected as a superuser is one that would serve every customer's hours to
// whoever asked, while looking entirely healthy.
app.beforeServerStarts {
    try await store.assertNotBypassingRowLevelSecurity()
}

logger.info("listening", metadata: [
    "address": .string("\(config.host):\(config.port)"),
    "audiences": .string("\(config.googleAudiences.count) google client(s)"),
    "hostedDomain": .string(config.googleAllowedHostedDomain ?? "any"),
])

do {
    try await app.runService()
} catch {
    // A refusal to start is a sentence somebody has to act on, not a stack trace.
    // Same shape as the configuration failure above, for the same reason.
    FileHandle.standardError.write(Data("deylee-api: \(error)\n".utf8))
    exit(1)
}
