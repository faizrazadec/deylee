"""The process: read the configuration, build the pieces, bind the port.

Configuration is read before anything binds. A missing variable should stop the process
here, with the name of the variable, rather than surface as a 500 on whichever request
first needed it.
"""

from __future__ import annotations

import logging
import os
import sys
from typing import NoReturn

import uvicorn

from deylee_api.app import create_app
from deylee_api.config import ConfigError, dotenv_merged, load_config
from deylee_api.db import Store, StoreError
from deylee_api.mail import Mailer
from deylee_api.ratelimit import RateLimiter
from deylee_api.tokens import TokenService


def _die(error: Exception) -> NoReturn:
    """A refusal to start is a sentence somebody has to act on, not a stack trace."""
    sys.stderr.write(f"deylee-api: {error}\n")
    raise SystemExit(1)


def main() -> None:
    env_path = os.environ.get("DEYLEE_ENV_FILE") or os.path.join(os.getcwd(), ".env")
    try:
        config = load_config(dotenv_merged(env_path))
    except ConfigError as error:
        _die(error)

    # Raiseable without a rebuild. Connection-pool faults are only explained at debug
    # level, and needing a redeploy to find out why the database is unreachable is
    # exactly the wrong time to need one. An unknown value falls back to info.
    level = logging.getLevelNamesMapping().get(
        os.environ.get("LOG_LEVEL", "info").upper(), logging.INFO
    )
    logging.basicConfig(level=level, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    logger = logging.getLogger("deylee-api")

    tokens = TokenService(config)

    try:
        store = Store(
            config.database_url,
            tls=config.database_tls,
            ca_certificate_path=config.database_ca_certificate_path,
            logger=logger,
        )
    except StoreError as error:
        _die(error)

    app = create_app(
        config=config,
        store=store,
        tokens=tokens,
        mailer=Mailer(
            api_key=config.resend_api_key,
            sender=config.resend_from,
            template_id=config.resend_otp_template_id,
            logger=logger,
        ),
        limiter=RateLimiter(),
        logger=logger,
    )

    logger.info(
        "listening address=%s:%d audiences=%d google client(s) hostedDomain=%s",
        config.host,
        config.port,
        len(config.google_audiences),
        config.google_allowed_hosted_domain or "any",
    )

    # log_config=None so uvicorn leaves the level set above alone instead of installing
    # its own handlers. No wrapper around this call: uvicorn already reports a bind
    # failure or a lifespan refusal itself and exits non-zero, which is all the Swift
    # equivalent's third catch was doing.
    uvicorn.run(app, host=config.host, port=config.port, log_config=None)


if __name__ == "__main__":
    main()
