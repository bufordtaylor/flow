# Contributing to Flow

Thanks for your interest. Flow is a small, focused macOS dictation app, and contributions are welcome.

## Ground rules

- **Keep `FlowCore` free of AppKit.** All logic lives in `FlowCore` behind protocols so it stays testable and portable; anything touching AppKit, Accessibility, or the menu bar belongs in the `Flow` target.
- **The privacy guarantee is the point.** No cloud calls, no telemetry, no accounts, no API keys. Only `ModelDownloader.swift` and `OllamaCleaner.swift` may use a networking API, and Ollama stays on the loopback interface. A test enforces this; don't work around it.
- **Add a test with behavior changes.** `FlowCore` has fakes for every protocol; see `Tests/FlowCoreTests`. Run `make test` before opening a PR.
- **Windows are size-checked.** If you touch the UI, run `make check-windows` and look at the PNGs in `build/windows/` before and after.

## Building

See the README for the toolchain notes (macOS 26 SDK via Command Line Tools, XCTest borrowed from Xcode). In short:

```sh
make build      # compile
make test       # run the suite
make run        # bundle and launch
make check-windows
```

## Pull requests

- Keep changes focused; one concern per PR.
- Describe what you changed and how you verified it.
- By contributing, you agree your contributions are licensed under the MIT License.

## Reporting bugs

Open an issue with your macOS version, whether you're on the Apple / Ollama / rules cleaner, and the relevant lines from `~/Library/Logs/Flow/flow.log` (transcript text is never logged unless you set `FLOW_DEBUG=1`).
