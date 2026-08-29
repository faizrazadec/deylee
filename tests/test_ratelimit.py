"""The limiter, which the Swift version shipped without a test and with two ways to be
silently wrong.

Both failures lock out the people who did nothing wrong rather than the attacker: a
limiter that counts reads meters a person signing in correctly on four devices, and a
`Retry-After: 0` invites an immediate retry that is certain to be refused again.

The clock is substituted rather than slept on — these are branch decisions about elapsed
time, and waiting out a real window would only make the suite slower and flakier.
"""

import pytest
from starlette.requests import Request

from deylee_api import ratelimit
from deylee_api.ratelimit import RateLimiter, caller_of


class _Clock:
    """Stands in for the `time` module the limiter reads `monotonic` off."""

    def __init__(self) -> None:
        self.now = 1_000.0

    def monotonic(self) -> float:
        return self.now


@pytest.fixture
def clock(monkeypatch) -> _Clock:
    frozen = _Clock()
    monkeypatch.setattr(ratelimit, "time", frozen)
    return frozen


def test_reading_does_not_count(clock):
    """Only `record` counts, so a caller can be metered on failures alone. Signing in
    correctly on four devices is not an attack, and charging for it would lock out
    exactly the people who did nothing wrong."""
    limiter = RateLimiter()
    for _ in range(100):
        assert limiter.seconds_until_allowed("ip:1.2.3.4", limit=3, window=60.0) is None


def test_the_nth_request_inside_the_window_is_refused(clock):
    limiter = RateLimiter()
    for _ in range(3):
        assert limiter.seconds_until_allowed("ip:1.2.3.4", limit=3, window=60.0) is None
        limiter.record("ip:1.2.3.4", window=60.0)
    assert limiter.seconds_until_allowed("ip:1.2.3.4", limit=3, window=60.0) is not None


def test_retry_after_rounds_up_and_is_never_zero(clock):
    """A caller told to wait 0 seconds retries at once into a refusal, which is a busy
    loop for both sides. Rounding down would do the same thing a fraction later."""
    limiter = RateLimiter()
    limiter.record("k", window=2.0)

    clock.now += 0.5
    assert limiter.seconds_until_allowed("k", limit=1, window=2.0) == 2, "1.5s left rounds up"

    # A sliver of the window left is still a whole second to the client.
    clock.now += 1.4999999
    assert limiter.seconds_until_allowed("k", limit=1, window=2.0) == 1


def test_the_window_expires_and_the_caller_is_allowed_again(clock):
    limiter = RateLimiter()
    limiter.record("k", window=60.0)
    assert limiter.seconds_until_allowed("k", limit=1, window=60.0) == 60

    clock.now += 60.0
    assert limiter.seconds_until_allowed("k", limit=1, window=60.0) is None


def test_keys_are_independent(clock):
    """One address running out its allowance must not touch anybody else's — the shared
    `unattributed` bucket makes that mistake catastrophic rather than annoying."""
    limiter = RateLimiter()
    limiter.record("ip:1.1.1.1", window=60.0)
    assert limiter.seconds_until_allowed("ip:1.1.1.1", limit=1, window=60.0) is not None
    assert limiter.seconds_until_allowed("ip:2.2.2.2", limit=1, window=60.0) is None


# MARK: Attribution


def _request(**headers: str) -> Request:
    encoded = [
        (name.replace("_", "-").lower().encode(), value.encode()) for name, value in headers.items()
    ]
    return Request(
        {"type": "http", "method": "POST", "path": "/v1/auth/sign-in", "headers": encoded}
    )


def test_cloudflares_header_wins():
    request = _request(CF_Connecting_IP="9.9.9.9", X_Forwarded_For="1.1.1.1")
    assert caller_of(request) == "9.9.9.9"


def test_the_first_hop_of_the_standard_header_is_the_client():
    """The left-most entry is the original client; everything after it is a proxy. Taking
    the last one would bucket the whole world behind whichever proxy is nearest."""
    assert caller_of(_request(X_Forwarded_For="1.1.1.1, 10.0.0.1, 10.0.0.2")) == "1.1.1.1"


def test_no_header_shares_one_bucket():
    """Anything talking to the process directly can forge these, so this is a ceiling on
    damage rather than an identity. The bucket has to be generous for the same reason it
    exists: if the proxy stops setting the header, every customer lands in it at once."""
    assert caller_of(_request()) == "unattributed"


def test_an_empty_header_value_is_ignored():
    """An empty header is not an address. Reading it as one would key every such request
    on the empty string — a second shared bucket nobody sized."""
    assert caller_of(_request(CF_Connecting_IP="", X_Forwarded_For="1.1.1.1")) == "1.1.1.1"
    assert caller_of(_request(X_Forwarded_For=" , 1.1.1.1")) == "unattributed"
