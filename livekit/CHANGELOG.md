## Unreleased

* **Breaking:** raise the minimum SDK to Dart 3.10.0 and Flutter 3.38.0.
  These are the real floors of `livekit_client 2.13.1` and newer. The previous
  declaration (`^3.6.0` / `>=3.27.0`) let apps resolve with an SDK that cannot
  install the adapter's dependency. Apps already on Dart 3.10 and Flutter 3.38
  need no code change.

## 0.2.0

* `LiveKitVirtualBackground` wraps the core kit: `attach` to a LiveKit
  `LocalVideoTrack`, `setEffect`, `detach`, and `dispose`.
* Optional `room:` enables re-attach on camera switch, unmute, and track
  restart, plus detach on unpublish and re-attach on republish (mechanism C).
  Without a room, only track-level re-attach works. Remote and non-camera
  tracks remain unsupported.
* The example LiveKit page now uses the adapter; the integration guide recommends
  it and keeps the manual `flutter_webrtc` recipe for apps without the extra
  dependency.
