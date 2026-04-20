"""Canonical PII marker list for all repo scrub tests.

Each consuming test class picks its matching strategy (substring or regex
with word boundary) but the source-of-truth string list lives here. A new
hostname or IP that must never leak is added in one place, not three.

Note on `100.64.0.{1..7}` — these are specific Tailscale IPs in the user's
real mesh per the global CLAUDE.md topology table. They are forbidden
wherever they could be published. The CGNAT subnet itself (`100.64.0.0/10`,
`100.64.x.x`) is generic and fine to mention.
"""

import re

FORBIDDEN: list[str] = [
    "aeyeops",
    "sfspark",
    "office-one",
    "aurora",
    "srv1540558",
    "xps13",
    "100.64.0.1",
    "100.64.0.2",
    "100.64.0.3",
    "100.64.0.4",
    "100.64.0.5",
    "100.64.0.6",
    "100.64.0.7",
]


def compiled_patterns() -> list[re.Pattern[str]]:
    """Return FORBIDDEN as regex with word boundaries for IP patterns.

    Word boundaries on the IP entries prevent `100.64.0.1` from matching
    placeholder addresses like `100.64.0.10+` that legitimately appear in
    example docs. Alphabetic markers are case-insensitive.
    """
    patterns: list[re.Pattern[str]] = []
    for marker in FORBIDDEN:
        if marker[:1].isdigit():
            patterns.append(re.compile(rf"\b{re.escape(marker)}\b"))
        else:
            patterns.append(re.compile(re.escape(marker), re.IGNORECASE))
    return patterns
