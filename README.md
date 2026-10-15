# Display Desk

A standalone native macOS utility for brightness, resolution/refresh rate, and saved display profiles. Inspired by the monitor-management workflow of BetterDisplay, with its own interface and implementation.

![Display dashboard](Preview/Dashboard-dark.png)

The screenshot uses illustrative data. The running app discovers your actual displays.

## What works

- Per-display hardware brightness through Apple display controls or verified DDC/CI on compatible Apple silicon external-monitor connections.
- Separate software dimming for displays without hardware brightness support.
- Resolution/scaling and refresh-rate choices from the modes that macOS exposes, including available HiDPI modes.
- A 15-second keep/revert confirmation for mode and profile changes. Unconfirmed changes restore the previous settings.
- Named profiles capturing all connected displays' modes, brightness, and dimming.
- Profile matching by stable display UUID rather than display order or name; missing monitors or unavailable modes are reported before applying the profile.
- Menu bar operation by default, with brightness, dimming, modes, colour/HDR, profiles, and Keep/Revert in the dropdown. The dashboard is optional; its Dock icon disappears when you close it.
- Hot-plug/wake refresh and light/dark appearance.
- RGB display ICC profile selection and import, with a 15-second keep/revert preview and a session-original restore button.
- HDR/SDR switching on displays where macOS exposes it, with verified state and the same keep/revert preview.
- Optional experimental HDR desktop boost: a colour-curve method plus a Metal desktop-rendering alternative for systems that clamp colour curves. Boost stops on quit and can be reset from the menu bar or dashboard.

## Build and run

Requires macOS 26+, Xcode with Swift 6.3 or later, and an internet connection for the initial package dependency fetch. The project was built with Xcode 27 / Swift 6.4.

From this directory:

```sh
./scripts/build-app.sh
open "build/Display Desk.app"
```

The script builds a Release executable, wraps it in a local app bundle, and ad-hoc signs it. Copy `build/Display Desk.app` into Applications to launch it independently of your editor. This is a local development build, not a notarized distribution.

For development, open `Package.swift` in Xcode and select the DisplayDesk executable and My Mac, or run `swift build`.

## Using it

1. Launch Display Desk and click its menu bar icon. It starts without a dashboard or Dock icon. Select a display in the dropdown, or explicitly choose **Open dashboard** for the larger workspace.
2. Use **Brightness** for the actual backlight. If unavailable, enable DDC/CI in your monitor's on-screen menu and check the connection. Software dimming is a separate image-darkening control and does not reduce backlight power.
3. Choose a **Looks like** resolution and refresh rate, then click **Apply mode**. Click **Keep changes** within 15 seconds, or let the app revert.
4. In the dropdown's **Profiles** tab, name and save the current setup, or apply an existing profile. Keep or revert changes directly in the dropdown. The dashboard also offers profile controls.
5. Use **More display controls** for arrangement, diagnostics, resetting software adjustments, or quitting. Settings opens from the gear button without adding a Dock icon. **⌥⌘0** resets software dimming while the dashboard is active.

Software dimming resets when the app quits. Display modes are applied for the current macOS login session. Profiles remain saved for later use. Automatic application at login or monitor connection is opt-in under Settings.

## Colour and extra brightness

Select an unlocked preset such as **User** in the monitor's own menu before using hardware brightness. The Lenovo Pro 27UD-10's DCI-P3 preset can lock both its physical brightness control and DDC writes. Display Desk cannot bypass that firmware restriction.

Under **Colour & HDR**, choose an installed RGB display ICC profile or import an `.icc`/`.icm` file made for this monitor and its current preset. Imported profiles are copied into Display Desk's Application Support directory. Generic **Display P3** describes an assumed display; it is not a measured calibration and does not reproduce the monitor's factory DCI-P3 gamut clamp. Accurate matching requires a suitable measured profile, typically produced with a colorimeter. This app assigns profiles; it does not measure or automatically calibrate the panel. Colour-managed applications use the selected profile; other applications may behave differently.

HDR mode is a separate switch and can change the monitor's colours. Colour-profile and HDR changes revert after 15 seconds unless kept. **Restore original colour & HDR** previews the settings captured before this app first changed the display during the current run. Kept profile and HDR selections remain active after quitting. Profiles now save colour-profile paths, HDR state, boost level and method; older saved profiles still load without requiring these fields. Move or delete an assigned ICC file and a saved setup using it may no longer apply.

**HDR desktop boost** uses available EDR brightness headroom, with a requested range of 100–200%. It is a multiplier, not measured nits or a guarantee that the panel will get twice as bright. HDR must already be enabled. Reset software dimming to zero first. Boost may alter colour rendering or HDR highlights and is unsuitable for judging calibrated colour or mastering HDR content. It cannot exceed the panel's power, temperature, sustained-brightness or content-dependent limits.

- **Colour curves** scales a captured copy of the display's existing channel curves, then verifies the readback. Values above 1.0 rely on experimental OS behaviour beyond Apple's documented gamma-table range. Some macOS/hardware paths clamp these values; the app restores the original curves and reports failure instead of claiming success. It yields to another app if that app changes the curves.
- **Try Metal boost** uses ScreenCaptureKit to capture only the selected display, excluding its own output window, and renders the desktop into an EDR Metal surface using Display P3. It requires macOS Screen Recording permission, requested only by **Allow Screen Recording…**. Frames stay in memory on this Mac; no audio, microphone, recording files or uploads are used. Protected content may be blank. Capture is tone-mapped to SDR before boosting, so this does not preserve original HDR highlights. It adds GPU work and display latency, renders at up to 60 fps, and is not intended for competitive gaming or colour-critical work. The app refuses to start if it cannot explicitly exclude its output window.

Use **Reset boost & dimming** to remove software adjustments immediately (also **⌥⌘0** while the dashboard is active). Quitting removes active boost windows and restores owned colour-curve adjustments. The app does not repeatedly rewrite curves to fight other display utilities. Disable other apps' colour adjustments before testing boost. macOS may require restarting Display Desk after changing Screen Recording access.

## Hardware support and limits

Apple display brightness uses the MIT-licensed [MacBrightnessKit](https://github.com/taketaku/MacBrightnessKit), pinned to version 0.1.0. The license is included in Resources and copied into the built app. Framebuffer discovery follows the approach documented by [m1ddc](https://github.com/waydabber/m1ddc); its MIT license is included as well.

Generic external brightness uses a separate DDC/CI implementation that resolves the exact OS-provided framebuffer route (with an EDID-validated fallback), then validates brightness replies and packet checksums. Hardware writes are read back; ignored writes are reported and hardware control is marked read-only until Refresh is used. Software dimming remains available. If two identical monitors cannot be uniquely matched, hardware control is disabled rather than sending a command to an uncertain display. Software dimming and mode selection remain available. DDC compatibility depends on the monitor, cable, port, and dock; DisplayLink and some HDMI paths may not support it.

Brightness access uses private Apple interfaces, so this development build runs without App Sandbox. It does not request administrator privileges, install a background helper, or make runtime network requests.

This version covers brightness, exposed display modes, profiles, ICC assignment, HDR switching, and experimental desktop brightness boosting. It does not implement virtual displays, custom HiDPI injection, automatic colour calibration, rotation, mirroring, or EDID overrides. BetterDisplay's branding and proprietary implementation are not included.

## Tests and validation

```sh
swift test
```

Tests cover profile round trips, legacy profile decoding, invalid values, duplicate names, disconnected displays, unsupported modes, EDID validation, DDC reply checksums, ambiguous identical-monitor routing, and preservation/validation of channel curves for HDR boost.

Native detection, brightness read/write at the existing value, profile application/confirmation, and automatic rollback at the existing mode were verified on the development Mac's built-in display. The connected Pro 27UD-10 external monitor was detected through DDC/CI; current-mode profile application and rollback were verified. Its DCI-P3 monitor preset was subsequently identified as locking brightness, including physical controls; an unlocked preset is required.

For the colour/HDR additions, the development monitor passed alternate ICC assignment/readback, 15-second automatic ICC rollback, HDR switching/readback and manual restoration, and SDR boost rejection. The Metal shader compiled and a live local stream started, survived reconciliation, and stopped cleanly. A requested 110% boost was capped at the currently reported 1.0905× EDR headroom. Original SDR state and the original colour profile were restored afterward. The colour-curve boost path was clamped to 1.0 by this macOS configuration and correctly reported failure. The automated suite covers profiles, DDC, colour curves, keyboard steps, automatic rules, diagnostics, and layouts. Physical luminance and colour accuracy have not been measured; permission availability and Metal output on other displays still require local verification.

## Local data

Profiles live in `~/Library/Application Support/DisplayDesk/profiles.json`. They contain display UUIDs, names, and settings. Keep that file private if you export it; it is not stored in the source repository.

## Structure

```text
Sources/DisplayDesk/           Native UI, display service, and hardware control
Sources/DisplayDeskCore/       Profile models, validation, and DDC protocol helpers
Tests/DisplayDeskCoreTests/    Hardware-independent regression checks
Resources/                    App metadata and third-party license
scripts/build-app.sh          Builds the standalone app bundle
Preview/                      Native renders with illustrative data
```

## Startup

Open **Settings → Startup** to enable launch at login. This uses macOS Login Items and is off by default. Keep the app at a permanent path before enabling it. If macOS requests approval, use **Open Login Items…** to approve the registration. Turning it off unregisters the item; it does not install a helper or change display settings.

## Automatic profiles

In **Settings → Automatic profiles**, choose a saved profile and use it for the currently connected external-monitor setup. Enable automation separately. Rules match the exact external display UUID set, not connection order or display names. Startup and monitor connection changes are considered after discovery settles. Missing profiles, ambiguous rules, or unavailable saved displays/modes are not applied. The app previews changes without opening the dashboard. A countdown appears in the menu bar: open it and choose **Keep changes** within 15 seconds, or the previous setup is restored. One attempt is made per topology change; merely refocusing the app does not reapply a rule. Rules are stored locally in `~/Library/Application Support/DisplayDesk/automation.json`; this file contains device identities and should stay private.

## Brightness keyboard controls

In **Settings → Brightness keys**, enable global **Control–Option–Up/Down** shortcuts, optional native brightness keys, or both. Choose the monitor under the pointer, the dashboard-selected monitor, or all connected monitors. Normal steps are 5%; Shift plus a native brightness key uses 1%. Unsupported hardware falls back to software dimming, never HDR upscaling. Shortcuts work without Accessibility permission. Intercepting native brightness keys requires Accessibility permission, requested only with **Allow Accessibility…**. Both are off by default. Only brightness events and the registered shortcuts are handled; other keys pass through. Native events pass through during display changes or when no target is available, allowing normal system behavior. Avoid enabling native-key interception in several display utilities at once.

## Sleep and wake

System and display sleep pause keyboard interception, cancel queued brightness/discovery/automation work, remove software overlays, and stop HDR boost. Wake performs three bounded refreshes while controls are paused, clears stale DDC read-only results, restores software dimming and keyboard registration, and checks automatic-profile rules once the connection settles. An unconfirmed configuration is reverted after wake rather than being kept accidentally. HDR boost is not silently resumed by recovery; an explicitly configured automatic profile may request it as part of its normal confirmation preview.

## Diagnostics

Open the dashboard’s **Diagnostics** button to inspect hardware-control status, the current mode, HDR headroom, colour-profile assignment, and relevant permissions. Suggestions distinguish observed failures from possible causes: the app cannot read the monitor’s physical colour preset or identify a faulty cable from a failed DDC write. **Copy report** and **Export report…** produce an allowlisted JSON report with numbered screens, OS/app versions, mode/control readings and permission booleans. Device names, UUIDs, serials, ICC paths, raw logs and arbitrary error strings are excluded. Nothing is uploaded. Review the report before sharing; it still describes your display capabilities.

## Display arrangement

Open **Arrange displays** in the dashboard header. Drag screens to match your desk; nearby edges snap together. Select a screen to edit its X/Y coordinates or make it the main display. Side-by-side and vertical presets provide a starting point. Screens must share edges without overlapping, so the pointer can move between them.

**Preview layout** applies the arrangement for the current login session. Keep it within 15 seconds or the previous layout is restored. Layout changes stop HDR boost; re-enable it afterward if needed. Arrangement edits do not send brightness, colour-profile, or HDR commands. Software dimming follows the moved displays.

New profiles include positions and the main display when the current layout is supported. Applying such a profile requires exactly its saved set of displays. Existing profiles keep working without changing arrangement. Mirrored or rotated setups retain settings-only profiles; arrangement editing for those setups is currently unavailable. If displays disconnect during a preview, rollback restores available modes and lets macOS arrange the remaining screens.

## Menu bar and Dock behaviour

Display Desk runs in the background and shows its menu bar icon only while an external display is connected, including when launched at login. The icon disappears when the last external display disconnects and returns automatically when one connects. A built-in laptop display alone does not show the icon. Discovery continues while it is hidden; there is no polling loop added for icon visibility. It does not restore an old dashboard window at startup. Brightness, software dimming, resolution/refresh rate, colour/HDR controls, saving/applying/deleting profiles, and preview confirmation are available from the dropdown. Colour/HDR controls expand on demand. Errors and status messages appear there too.

**Open dashboard** shows the larger window and a Dock icon. Closing that window removes the Dock icon while keeping monitoring, shortcuts, and display adjustments active. Minimizing it keeps the dashboard open and its Dock icon available. Settings, arrangement, and diagnostics can be opened without a dashboard or Dock icon. Automatic profiles do not open the dashboard; unconfirmed changes still time out normally. Explicitly reopening the running app from Finder brings up the dashboard, even when no external display is connected and the menu bar icon is hidden.

To check the AppKit Dock lifecycle on a Mac with an active graphical login:

```sh
./scripts/check-window-lifecycle.sh
```

This records activation-policy requests and exercises real window-close notifications in a separate test process. It never registers in the Dock, activates itself, opens visible windows, or changes display settings. Failed checks exit normally rather than triggering crash dialogs. A 15-second watchdog stops and reaps a hung check before its temporary executable is removed.
