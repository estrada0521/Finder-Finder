# Lab Browser

Native macOS browser for the local Lab DB. The supported entry point is
`./native_start`; it builds the Rust + AppKit application at
`/Applications/Lab Browser.app`.

This app should own okadaharuto-DB-specific knowledge and orchestrate Raw-Plot
through generic viewer commands, keeping Raw-Plot itself a thin, reusable data
viewer.

## Boundary

Raw-Plot should stay schema-agnostic and expose generic actions:

- open a data file
- choose axes
- arrange windows
- close windows

Lab Browser may understand DB-specific concepts such as rawdata records,
associated measurements, samples, and experiments, then translate them into
generic Raw-Plot actions.
