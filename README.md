# Kulumeter

Kulumeter imports bicycle exercise data from Apple Health and uploads daily totals to
Kilometrikisa directly from the iOS app.

## Provisioning Setup

Kulumeter uses HealthKit, so the app must be signed with a provisioning profile that
includes the HealthKit capability.

1. Open `Kulumeter.xcodeproj` in Xcode.
2. Select the `Kulumeter` project in the navigator, then select the `Kulumeter` app
   target.
3. Open `Signing.xcconfig`.
4. Set `KULUMETER_DEVELOPMENT_TEAM` to your Apple developer team ID.
5. Set `KULUMETER_BUNDLE_IDENTIFIER` to an identifier you own, such as
   `com.example.kulumeter`.
6. Open the `Signing & Capabilities` tab and confirm the app target is using your
   team and bundle identifier from the xcconfig file.
7. Keep `Automatically manage signing` enabled, or select a provisioning profile
   manually if your team manages profiles outside Xcode.
8. Make sure the `HealthKit` capability is present. If it is missing, add it with
   `+ Capability`.
9. In the Apple Developer portal, confirm that the app identifier has HealthKit
   enabled if you manage identifiers manually.
10. Build and run on a physical iPhone. Apple Health data and HealthKit authorization
   are not useful on a generic simulator setup.

The project already includes `Kulumeter/Kulumeter.entitlements` with the HealthKit
entitlement and an Apple Health usage description in the target build settings.

## Runtime Setup

1. Install the app on your iPhone.
2. Grant Apple Health read access when prompted.
3. Enter your Kilometrikisa username and password.
4. Import cycling workouts for the desired date range.
5. Review the preview list. Days already logged in Kilometrikisa are left
   unselected.
6. Upload the selected days.

Passwords are stored in the iOS Keychain. The app talks directly to Kilometrikisa
and does not require a separate server.
