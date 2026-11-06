# Yi Camera Viewer

A small Mac app for watching a YI Dome Camera 1080p (YHS-2016) on your home network, with pan/tilt, HD/SD, snapshots and full screen. It talks to the camera directly over RTSP, so it works without Yi's cloud.

- **Setup guide:** [SETUP.md](SETUP.md): preparing the SD card, installing yi-hack-v5 on the camera, and connecting.
- **App source:** `YiCamera/Sources` (Swift, AppKit). Build with `YiCamera/build.sh`; it needs only Apple's Command Line Tools.
- **Ready-built app:** download `Yi-Camera.zip` from the [Releases](../../releases) page.

## Third-party firmware

`SD Card Files/` holds an unmodified build of [yi-hack-v5](https://github.com/alienatedsec/yi-hack-v5) 0.4.1 for the h20 camera family, with its config set up for this viewer (RTSP on, SSH off, all passwords blank). yi-hack-v5 is free software under the GNU GPL v3; its full source code is in that project's repository.
