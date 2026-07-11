# ESP32 Light Control Skeleton

This workspace contains a basic ESP32 S3 program skeleton and an Apple device app skeleton for pool light control.

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

## App Side (`ios/LightControlApp.swift`)

Features:
- SwiftUI skeleton with fields to send SSID/password
- Sends HTTP POST requests to the ESP32 setup endpoint
- Sends color commands to the ESP32 device

## Notes

- The Apple device must connect to the ESP32's `LIGHT_SETUP` Wi-Fi network for initial setup.
- After the device receives configuration, it reboots and connects to the customer Wi-Fi.
- You can extend the iOS app to use `NEHotspotConfiguration` or instructions to help users join the Wi-Fi network.
