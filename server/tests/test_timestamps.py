"""`updated_at` is the client's own claim and it decides every conflict. The server must
not rewrite it — doing so would make every synced row look freshly edited and hand each
conflict to the staler device — but it must refuse an impossible one.

Untreated, `Int64.max` made a row win last-write-wins against every future edit from
every device, permanently, with no way back through the app.
"""

from deylee_api.routes.sync import FUTURE_TOLERANCE, claims_the_future

NOW = 1_786_000_000_000
INT64_MAX = 2**63 - 1


def test_honest_clock_skew_is_accepted():
    # Ordinary machines are minutes off with nobody having done anything wrong. Refusing
    # these would drop real work over a clock.
    assert not claims_the_future(NOW, now=NOW)
    assert not claims_the_future(NOW - 86_400_000, now=NOW), "a slow clock"
    assert not claims_the_future(NOW + 120_000, now=NOW), "two minutes fast"
    assert not claims_the_future(NOW + FUTURE_TOLERANCE, now=NOW), (
        "exactly at the tolerance is still honest"
    )


def test_a_claim_beyond_the_tolerance_is_refused():
    assert claims_the_future(NOW + FUTURE_TOLERANCE + 1, now=NOW)
    assert claims_the_future(NOW + 600_000, now=NOW), "ten minutes fast"
    assert claims_the_future(INT64_MAX, now=NOW), "the row-freezing value"


def test_the_bound_does_not_wrap_near_the_top():
    """Swift saturated the bound because `Int64.max + tolerance` traps, and the value the
    check exists to refuse is exactly `Int64.max`. Python's ints do not overflow, so the
    saturation is gone — but the behaviour it produced has to be identical, and a wrap
    here would flip the comparison and refuse everything."""
    assert not claims_the_future(INT64_MAX, now=INT64_MAX)
    assert not claims_the_future(INT64_MAX - 1, now=INT64_MAX - 1)
