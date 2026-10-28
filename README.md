# Export a TIC-80 game as a standalone Android APK

TIC-80 cannot export an APK. Its export menu has HTML and desktop builds only
([issue #1953](https://github.com/nesbox/TIC-80/issues/1953) is the long answer:
build the Android app yourself). This repo does that for you.

You give it a `.tic` cart, a name, a package id and an icon. You get a signed
APK that:

- starts straight into your game, with no TIC-80 splash
- has no code editor, sprite editor, console or SURF game browser
- has no "CLOSE GAME" menu item, and "QUIT TIC-80" reads "QUIT GAME"
- uses your app name and icon

It builds TIC-80's own Android app from source (MIT license) with a few small
patches and your cart bundled as an asset.

> **TIC-80 Pro is not required.** The APK is built from TIC-80's free MIT
> source (`PRO=OFF`), and you only need a `.tic` cart, which any TIC-80 build
> can save. The author wrote the example cart in TIC-80 **Pro** 1.3.1, and the
> build was tested with that cart on one Android 14 device.
>
> - If your cart uses Pro-only features, try `--pro` (`-PPRO=ON`). That path is
>   **untested** here, so check the cart on a device.
> - Pro's `export html` is another route (a WebView wrapper). This repo does
>   not use it.

## What you need

| Tool | Notes |
| --- | --- |
| Android SDK | Command-line tools are enough. Set `ANDROID_HOME`. |
| Android NDK | Any recent one. Newest installed is used. Tested with 27.1. |
| CMake (SDK) | `sdkmanager "cmake;3.22.1"` |
| Android platform | `sdkmanager "platforms;android-34"` |
| JDK 17+ | Tested with 21. `keytool` ships with it. |
| git, python3 | |
| `sips` (macOS) or ImageMagick | Only to resize the icon. |

An Android phone with USB debugging and `adb` is handy for testing.

## Quick start

```sh
git clone https://github.com/<you>/tic80-apk-export
cd tic80-apk-export

scripts/build-apk.sh \
    --cart example/unicorn-den.tic \
    --name "Unicorn Den" \
    --app-id com.example.unicornden \
    --icon example/icon.jpeg

adb install -r out/unicorn-den.apk
```

The first build downloads Gradle and compiles all of TIC-80 and its language
runtimes. Expect about 5 minutes. Later builds with the same `work/` folder are
faster.

Options:

| Flag | Meaning |
| --- | --- |
| `--cart FILE` | Your `.tic` cart (required) |
| `--name TEXT` | App name shown under the icon (required) |
| `--app-id ID` | Package id, like `com.you.game` (required, lowercase) |
| `--icon FILE` | Any square image. Resized to all launcher sizes. |
| `--out DIR` | Where the APK and signing key go. Default `./out` |
| `--work DIR` | Where TIC-80 is cloned and built. Default `./work` |
| `--keystore FILE` | Reuse an existing signing key |
| `--pro` | Build TIC-80 with `PRO=ON` (untested, see above) |

Environment: `NDK_VERSION`, `COMPILE_SDK`, `TIC80_REF` override the defaults.

## Keep your signing key

The first run creates `out/<name>.keystore` and `out/<name>-password.txt`.
Android only installs an update over an app signed with the same key. Back both
files up, and never commit them. The `.gitignore` here excludes them.

## How it works

The stock Android app already accepts a cart handed to it by an intent. The
script reuses that and changes five things.

1. **Fetch TIC-80** at a pinned commit and apply `patches/`.
2. **`TIC.java`** copies `assets/cart.tic` to the cache dir on start and passes
   `--skip <cart>` to the native code.
3. **`studio.c`** makes `--skip` work in builds without editors. Upstream only
   honors it when editors are compiled in, so without this patch the splash
   still plays.
4. **`mainmenu.c`** renames the last menu entry to "QUIT GAME".
5. **Gradle config** is edited: your `applicationId`, app name, installed SDK
   and NDK versions, and two CMake flags: `-DBUILD_EDITORS=OFF` and
   `-DBUILD_SURF=OFF`. The menu builds "CLOSE GAME" only when editors or SURF
   exist, so removing both removes the item.

Then it builds the `release` variant and signs it with your key.

## Gotchas we hit

- **`call to undeclared library function 'bzero'`.** Newer NDKs treat implicit
  function declarations as errors, and a vendored library (gravity) uses them.
  NDK 30 also flags `strtok` as deprecated, and TIC-80 builds with `-Werror`.
  The script downgrades these errors to warnings with `cFlags`.
- **Upstream's NDK 23 is not installed on most machines.** The script uses
  whichever NDK you have.
- **Black screenshots from `adb`.** Handhelds sleep fast. Wake the screen
  (`adb shell input keyevent KEYCODE_WAKEUP`) before judging a black frame.
- **Old icon still showing.** Launchers cache icons per package. Restart the
  launcher, or reboot.
- **`-PEDITORS=OFF` alone is not enough.** It gives you SURF as the home
  screen. You need `BUILD_SURF=OFF` too.
- **Only arm64.** The upstream build targets `arm64-v8a`. Very old 32-bit
  devices are not supported.

## Testing on a device

```sh
adb devices
adb -s <serial> install -r out/unicorn-den.apk
adb -s <serial> shell monkey -p com.example.unicornden -c android.intent.category.LAUNCHER 1
adb -s <serial> shell input keyevent KEYCODE_ESCAPE   # opens the game menu
adb -s <serial> exec-out screencap -p > shot.png
```

The menu should show RESUME GAME, RESET GAME, OPTIONS and QUIT GAME. Nothing
else.

## Limits and honesty

- The menu still has TIC-80's header ("TIC-80 tiny computer") and footer
  (`dev.tic80.com`). Changing them needs another patch.
- Selling a game made this way is fine under the MIT license, but credit and
  link the [TIC-80 repository](https://github.com/nesbox/TIC-80) in your store
  listing. The maintainer confirmed this in #1953.
- The patches target one TIC-80 commit. A newer TIC-80 may need them rebased.
- Tested on one Android 14 device and macOS only. Linux should work. The icon
  step needs `sips` or ImageMagick.

## License

MIT for the scripts and patches here. TIC-80 is MIT, by Vadim Grigoruk (nesbox).
The example cart and icon are the author's; replace them with your own.
