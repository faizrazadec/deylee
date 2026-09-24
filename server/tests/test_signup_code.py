"""The sign-up code itself.

Everything else about sign-up verification lives in SQL and is exercised by
`scripts/smoke-auth.sh` against a real database — the attempt cap and the expiry are
transaction behaviour, and a mock would only prove the mock works. What is worth pinning
here is the shape of the digits, because both failures are silent: a code that loses a
leading zero is rejected by a server that generated it, and a biased draw shrinks the
space a guesser has to cover.
"""

import secrets

from deylee_api import mail
from deylee_api.mail import generate_signup_code


def test_is_always_six_digits():
    for _ in range(2_000):
        code = generate_signup_code()
        assert len(code) == 6
        assert code.isdigit()


def test_never_starts_with_zero():
    """No code may begin with a zero. The Resend template types `otp` as a number, and a
    number cannot carry one: "042931" would be mailed as "42931" and then refused by the
    server that generated it, for one code in ten.

    20,000 draws is far past the point where a surviving zero would be bad luck — under
    the old range roughly 2,000 of them would start with one."""
    assert not any(generate_signup_code().startswith("0") for _ in range(20_000))


def test_survives_the_round_trip_through_an_integer():
    """A code must survive the round trip the mailer puts it through — parsed to an
    integer and rendered back. That is the exact equality `Mailer.send_signup_code` guards
    on, so a generator change that broke it would fail here rather than in production."""
    for _ in range(2_000):
        code = generate_signup_code()
        assert str(int(code)) == code


def test_covers_the_whole_range():
    """Every digit position should reach both ends of its range. A modulo-folded draw
    would skew the leading digit in particular."""
    values = [int(generate_signup_code()) for _ in range(20_000)]
    # The floor is 100,000 now, not zero, so the low bound moves with it.
    assert min(values) < 150_000
    assert max(values) > 950_000


def test_draws_from_the_csprng():
    """`random` is a Mersenne twister seeded from the clock: watch a handful of codes and
    you can predict the rest. The range test above cannot tell the two apart, so the
    source is asserted directly."""
    assert generate_signup_code.__globals__["secrets"] is secrets
    assert not hasattr(mail, "random")
