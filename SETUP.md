# Yi Dome Camera → Mac viewer setup

Camera: **YI Dome Camera 1080p, model YHS-2016**, firmware **1.9.2.0I_201812141405** (supported by yi-hack-v5 0.4.1).

> ⚠️ **Do not tap "Update" in the Yi app.** The offered update (1.9.2.0I_202607220937) is newer than the
> version yi-hack supports and may block the install. Also turn off automatic updates in the Yi app if it has that option.

## 1. Prepare a microSD card (about 5 minutes)

You need a microSD card of **32 GB or smaller**. It's erased in this step.

1. Put the card in your Mac (use an adapter if needed).
2. Open **Disk Utility**, select the card on the left, and click **Erase**.
   - Name: `YI`
   - Format: **MS-DOS (FAT)**. Not exFAT; the camera can't read that.
   - Scheme: **Master Boot Record**
3. Open the **SD Card Files** folder and copy all three items to the top level of the card (not inside a folder):
   - `home_h20`
   - `rootfs_h20`
   - `yi-hack-v5` (folder)
4. Eject the card.

The copy in **SD Card Files** is already set up for this viewer. It has the local video stream (RTSP) turned on in both HD and SD, and remote login (SSH) turned off. You can change both later on the camera's web page.

## 2. Install on the camera (about 5 minutes)

1. Unplug the camera.
2. Insert the microSD card.
3. Plug the camera back in and **leave it alone**. The light flashes yellow for a minute or two while it installs. Don't unplug it during this. When the light turns **blue**, it's back on Wi-Fi.
4. Leave the card in the camera permanently; the new firmware runs from it.

## 3. Find the camera's IP address

Use any of these:

- **Yi app:** Camera Settings › Network Info
- **Google Home app:** your router lists connected devices there
- The camera's web page: once you know the address, open `http://<that address>` in Safari. A yi-hack status page means the install worked.

**Optional but recommended:** in your router settings, reserve that IP address for the camera so it never changes.

## 4. Open the viewer

1. Drag **YiCamera › Yi Camera.app** into your **Applications** folder.
2. Open it. The app isn't from the App Store, so the first time you'll need to **right-click › Open**, or allow it in System Settings › Privacy & Security.
3. If macOS asks to let Yi Camera **find devices on your local network**, click **Allow**.
4. Enter the camera's IP address and click **Connect**. Leave the username and password blank, unless you add a password on the camera's web page later; then enter the same one here.

### Using it

| | |
|---|---|
| Pan / tilt | arrow buttons in the bottom bar, or the keyboard arrow keys (hold to keep moving) |
| HD / SD | toggle in the bar, or ⌘D. SD uses less Wi-Fi. |
| Snapshot | camera button or ⌘S. Saves to Pictures › Yi Camera. |
| Full screen | double-click the video, or ⌃⌘F |
| Keep on top | ⌘T keeps a small window floating above other apps |
| Reconnect | ⌘R. It also reconnects automatically after Wi-Fi drops or your Mac wakes. |
| Settings | gear button or ⌘, |

The controls fade out after a few seconds; move the mouse to bring them back.

## Optional: go fully offline

On the camera's web page (`http://<camera IP>`), go to **Configuration** and turn on **Disable cloud**. The camera then stops talking to Yi's servers entirely. The Yi app will stop working, but this viewer keeps working. Set a username and password there too, then enter them in the viewer's settings.

## Rebuilding the app

The source is in `YiCamera/Sources`. To rebuild, run `YiCamera/build.sh` (needs only Apple's Command Line Tools).
