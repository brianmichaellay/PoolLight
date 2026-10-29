# Pool Light Control

Controls a J&J ColorSplash XG pool light with an ESP32-S3 relay controller and an iOS app.

## Device Side (`device/LightControl.ino`)

Features:
- Broadcasts `LIGHT_SETUP` SSID in reset/setup mode
- Accepts Wi-Fi SSID/password from the app via HTTP POST to `/config`
- Stores credentials in flash using `Preferences`
- Reboots and retries indefinitely every 20 seconds until connected
- Serves a simple HTTP endpoint `/color` to receive a color command
- Controls relay on pin `4` by toggling it a set number of times per color
- Uses pin `5` for button input and pin `6` for LED output
- Flashes LED during setup mode, stays solid when connected
- Long button press (10 seconds) resets configuration and returns to setup mode

## App Side (`ios/`)

An iOS/iPadOS SwiftUI app, "J&J ColorSplash XG Light Control". Open `ios/PoolLight.xcodeproj` in Xcode; the app's code is in `ios/PoolLight/LightControlApp.swift`. Requires iOS 17.6 or later.

Features:
- Finds the controller automatically: last known address, Bonjour, `poollight.local`, then a scan of the local subnet
- Wi-Fi setup over the `LIGHT_SETUP` network: the controller scans for networks and the app sends the chosen SSID/password
- Turns the light on/off and picks any of its 12 colors/shows, with a swatch for each
- Color Lock and Return commands, plus an adjustable pulse delay
- Reads the controller's current state so the app matches the light
- Shows a progress ring while a pulse sequence runs and locks the controls until it finishes
- View or clear the controller's log, and reset its network settings

## Notes

- The Apple device must connect to the ESP32's `LIGHT_SETUP` Wi-Fi network for initial setup.
- After the device receives configuration, it reboots and connects to the customer Wi-Fi.
- You can extend the iOS app to use `NEHotspotConfiguration` or instructions to help users join the Wi-Fi network.
