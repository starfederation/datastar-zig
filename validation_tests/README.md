# Validation test backend

Build and run the validation backend on port 7331

```
zig build run
```

Then run the official test harness against this backend

```
go run github.com/starfederation/datastar/sdk/tests/cmd/datastar-sdk-tests@latest
```

expect ...
```bash
% go run github.com/starfederation/datastar/sdk/tests/cmd/datastar-sdk-tests@latest

go: downloading github.com/starfederation/datastar v1.0.2
go: downloading github.com/starfederation/datastar/sdk/tests v0.0.0-20260602174445-850d0479e947
PASS
```
