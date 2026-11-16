## 0.2.0 (belum dirilis)

* `LiveKitVirtualBackground` wraps the core kit: `attach` to a LiveKit
  `LocalVideoTrack`, `setEffect`, `detach`, and `dispose`.
* Optional `room:` enables re-attach on camera switch, unmute, and track
  restart, plus detach on unpublish and re-attach on republish (mechanism C).
  Without a room, only track-level re-attach works. Remote and non-camera
  tracks remain unsupported.
* The example LiveKit page now uses the adapter; the integration guide recommends
  it and keeps the manual `flutter_webrtc` recipe for apps without the extra
  dependency.
