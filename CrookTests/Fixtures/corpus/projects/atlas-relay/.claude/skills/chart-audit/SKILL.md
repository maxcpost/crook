---
name: chart-audit
description: Check a chart against the house palette and axis rules
---

# Chart audit  

Compare every series colour against
`/Users/nobody-here/Projects/beacon-shop/palette/tokens.json`.

Rules:

- No more than six categorical colours in one chart.
- Axes start at zero unless the caption says otherwise.
- One encoding per variable.
