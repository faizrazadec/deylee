"""Outbound mail, through Resend.

The body of the mail is not here. It lives in a Resend template, addressed by id,
with the code passed as the `otp` variable; copy changes are then a dashboard edit
rather than a deploy. The cost is that the template is state outside this repository
— if the variable is ever renamed there, mail keeps sending with an empty code and
nothing here fails.
"""

import logging
import secrets

import httpx

ENDPOINT = "https://api.resend.com/emails"
TIMEOUT_SECONDS = 10.0


class MailError(Exception):
    """A send that did not happen. `str(e)` is the sentence that reaches the logs."""


class Mailer:
    def __init__(
        self,
        *,
        api_key: str,
        sender: str,
        template_id: str,
        logger: logging.Logger,
        client: httpx.AsyncClient | None = None,
    ) -> None:
        self.api_key = api_key
        self.sender = sender
        self.template_id = template_id
        self.logger = logger
        # An injected client is used as given — that is how tests substitute a
        # transport. Without one, a client per send: the API mails a handful of codes
        # in its whole life, which does not earn a pooled client's lifecycle.
        self.client = client

    async def send_signup_code(self, code: str, to: str) -> None:
        """Send a sign-up code.

        Raises on anything other than a 2xx. The caller must treat that as a failed
        request rather than swallowing it: a person staring at a code entry screen
        with no mail coming is worse than being told the send failed.
        """
        # The template declares `otp` as a number and refuses a string outright, so
        # the code goes over the wire as an integer. That is lossless only because
        # `generate_signup_code` never draws a leading zero — this line is why that
        # rule exists, and changing either one without the other mails the wrong
        # digits.
        try:
            otp = int(code)
        except ValueError:
            otp = None
        if otp is None or str(otp) != code:
            raise MailError(f"Code {code} is not a whole number and cannot be templated")

        # `subject` is required even when a template supplies the body, and
        # html/text/react may not be combined with a template — Resend rejects that
        # pairing outright.
        body = {
            "from": self.sender,
            "to": [to],
            "subject": "Your Deylee code",
            "template": {"id": self.template_id, "variables": {"otp": otp}},
        }
        headers = {"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json"}

        try:
            if self.client is not None:
                response = await self.client.post(
                    ENDPOINT, json=body, headers=headers, timeout=TIMEOUT_SECONDS
                )
            else:
                async with httpx.AsyncClient(timeout=TIMEOUT_SECONDS) as client:
                    response = await client.post(ENDPOINT, json=body, headers=headers)
        except httpx.HTTPError as error:
            reason = str(error) or type(error).__name__
            raise MailError(f"Could not reach Resend: {reason}") from error

        if not 200 <= response.status_code < 300:
            # Resend's error body names the offending field, which is most of the
            # value when a template id or a sending domain is wrong.
            detail = response.text or "no detail"
            raise MailError(f"Resend refused the message ({response.status_code}): {detail}")


def generate_signup_code() -> str:
    """A six-digit code, uniformly distributed, never starting with a zero.

    `secrets.randbelow` draws from the OS CSPRNG over an exact range, so this is not
    the `arc4random_uniform`-modulo trap: there is no fold and no bias.

    The range starts at 100000 because the Resend template types `otp` as a number,
    and a number cannot carry a leading zero: "042931" would arrive as "42931" and be
    rejected by the server that made it, for one code in ten. Excluding those codes
    outright is the honest fix — padding a number back to six digits in the template
    would put the invariant somewhere this repository cannot test.

    The cost is 900,000 codes rather than 1,000,000. Against a ten-minute expiry and
    a capped attempt count that is not a meaningful difference; a guesser is stopped
    by the cap long before the size of the space matters.
    """
    return str(100_000 + secrets.randbelow(900_000))
