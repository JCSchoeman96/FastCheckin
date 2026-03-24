# Android Environment Selection

FastCheck Android uses Gradle properties for backend selection. No Kotlin source
edits are required to change environments.

## Supported Targets

- `release`
  - default target
  - resolves to `https://scan.voelgoed.co.za/`
  - `FASTCHECK_API_BASE_URL_RELEASE` is exceptional-only and, if used, must be
    non-blank, validated, and `https`
- `emulator`
  - resolves only to `http://10.0.2.2:4000/`
  - intended for local debug against a backend running on the host machine
- `dev`
  - requires `FASTCHECK_API_BASE_URL_DEV`
  - accepts `http` or `https`
- `device`
  - requires `FASTCHECK_API_BASE_URL_DEVICE`
  - must be `https`

## Example Commands

```powershell
.\gradlew.bat :app:assembleDebug -PFASTCHECK_API_TARGET=emulator
.\gradlew.bat :app:assembleDebug -PFASTCHECK_API_TARGET=dev -PFASTCHECK_API_BASE_URL_DEV=https://dev.example.com/
.\gradlew.bat :app:assembleDebug -PFASTCHECK_API_TARGET=device -PFASTCHECK_API_BASE_URL_DEVICE=https://device.example.com/
.\gradlew.bat :app:assembleRelease -PFASTCHECK_API_TARGET=release
```

## Operational Notes

- Release tasks must use `FASTCHECK_API_TARGET=release`.
- Emulator cleartext support is debug-only and limited to `10.0.2.2`.
- Diagnostics remain visible in release.
- Release disables HTTP BASIC logging by default.
