# SKT VoLTE on the Xiaomi Mi 9T (`davinci`)

This procedure restored VoLTE on a global Xiaomi Mi 9T running LineageOS `23.2-20260531-NIGHTLY-davinci` with an SKT MVNO SIM in slot 1. Before the fix, LTE data worked and calls dropped to H+. After activating the `Commercial-SKT` modem profile, IMS Service Status showed **Voice over LTE: Available** and a regular call connected and stayed on LTE with Wi-Fi off. Persistence across reboot or SIM changes is unverified.

| Item | Tested setup |
| --- | --- |
| Device | Xiaomi Mi 9T Global, `davinci` |
| Baseband | `4.3.c5-00123-1103_1230_c29e3075c0` |
| SIM | SKT MVNO, slot 1, network `45005` |
| Host | Windows 11, Ubuntu under WSL 2, `usbipd-win` 5.3.0 |
| Modem tool | `qmicli` 1.38.0 with the loader workaround below |

## Compatibility

The **diagnostic approach** can apply to other Qualcomm phones that expose QMI and support PDC. The exact USB mode, permissions, available MBN profiles, and way the modem selects them depend on the device, firmware, ROM and carrier. This guide is tested only on `davinci` with the combination above. Other LineageOS builds, other Xiaomi models and stock MIUI are untested. Stock MIUI may select a carrier profile differently or restrict access to the USB mode used here. Use the profile from your own device's installed firmware. Keep the MBN local.

## 1. Confirm the failure and fix APN selection if needed

1. Turn Wi-Fi off and make a regular call. On the phone, dial `*#*#4636#*#*`, open **Phone information → ⋮ → IMS Service Status**, and check **IMS Registration** and **Voice over LTE** for SIM 1. A VoLTE toggle in Settings does not establish registration.
2. If available, test the same SIM in a handset that already supports SKT VoLTE. In this case an LG-Y110L registered and made an LTE call with the same SIM. Device-specific OMD provisioning can still matter on the Mi 9T.
3. If the radio log shows `SKT LTE Roaming` being used for an IMS request, open **Settings → Network & internet → SIMs → your SIM → Access Point Names**. Record the original entries. On the tested build both SKT roaming entries showed a blank APN type, which Android interpreted as including IMS. Setting their types explicitly to `default,mms,supl,dun,fota,cbs` made Android use the dedicated **SKT IMS** profile. The **SKT IMS** entry itself was left as supplied. The change addresses APN selection only. APN reset restores presets and clears custom APNs.

In this case the dedicated IMS connection then came up, but Android still reported IMS unregistered. An empty `pcscf` list in the data-call response was a clue; it did not establish the root cause on its own.

To reproduce that diagnosis, run the following in PowerShell after toggling airplane mode and waiting for LTE. It finds the APN used for each recent data setup and pairs the latest dedicated IMS request with its response. The raw response can contain IP addresses. Redact network addresses and subscriber identifiers before publishing logs.

```powershell
$adb = 'C:\platform-tools\adb.exe'
& $adb shell dumpsys carrier_config |
    Select-String 'Phone\s*Id|Default Values from CarrierConfigManager|mConfigFrom(Default|Carrier)App|carrier_volte_available_bool'
$radio = & $adb logcat -b radio -d -t 5000
$radio | Select-String 'SETUP_DATA_CALL.*?\[ApnSetting\]\s+[^,]+|getImsRegistrationTechnology\s*=\s*-?\d+' |
    ForEach-Object { $_.Matches[0].Value } | Select-Object -Unique
$request = $radio | Select-String '\[(\d+)\]\s*>\s*SETUP_DATA_CALL\b.*\[ApnSetting\]\s+SKT IMS,' |
    Select-Object -Last 1
if ($request) {
    $serial = $request.Matches[0].Groups[1].Value
    $radio | Select-String "\[$serial\]\s*[<>]\s*SETUP_DATA_CALL"
}
```

## 2. Expose the Qualcomm WWAN interface

With Android USB debugging authorized and rooted debugging enabled on the phone, first check the supported composition from Windows PowerShell. `$adb` should point to your platform-tools `adb.exe`.

```powershell
$adb = 'C:\platform-tools\adb.exe'
& $adb shell "grep -nH -e 9091 /vendor/etc/usb_compositions.conf /odm/etc/usb_compositions.conf 2>/dev/null"
```

On the tested build this showed `diag,serial_cdev,rmnet,adb` with USB ID `05C6:9091`. The init-script rule for that mode required `sys.usb.configfs=1`, while the phone used `2`, so the working route was the USB Gadget HAL's temporary vendor override. Run these only after confirming the composition on the phone:

```powershell
& $adb root
& $adb wait-for-device
& $adb shell setprop vendor.usb.config diag,serial_cdev,rmnet,adb
& $adb shell svc usb setFunctions mtp
# ADB may briefly disconnect. Wait until the device is visible again.
& $adb shell svc usb setFunctions
Get-PnpDevice -PresentOnly |
    Where-Object { $_.InstanceId -match 'VID_05C6&PID_9091' } |
    Select-Object Status, Class, FriendlyName
```

In the observed run, the `mtp` command raced with the USB reconnect and reported no devices. The next `svc usb setFunctions` succeeded when ADB came back. Windows then showed **Qualcomm HS-USB WWAN Adapter 9091** alongside ADB and DIAG. PDC uses the WWAN interface. The COM port alone is insufficient.

## 3. Hand the phone to Linux

On Windows, install [Ubuntu on WSL 2](https://ubuntu.com/wsl/docs/stable/howto/install-ubuntu-wsl2/) and [usbipd-win](https://learn.microsoft.com/en-us/windows/wsl/connect-usb). Open Ubuntu and keep it running. In Administrator PowerShell, find the current bus ID for `05c6:9091` and replace `<BUSID>` with that value:

```powershell
$usbipd = 'C:\Program Files\usbipd-win\usbipd.exe'
& $usbipd list
& $usbipd bind --busid <BUSID>
& $usbipd attach --wsl --busid <BUSID>
```

If Windows reports `Device busy (exported)`, use `unbind --busid <BUSID>` and then `bind --force --busid <BUSID>` for this phone only. The forced binding is persistent and may need a **Windows** restart. Keep the phone powered on through that restart if possible, reopen Ubuntu and check the bus ID again. Windows ADB is unavailable while Ubuntu owns the USB device.

In Ubuntu, install the tools and check for the modem interface:

```bash
sudo apt update
sudo apt install adb libqmi-utils
ls /dev/cdc-wdm*
sudo adb devices
```

Authorize the Ubuntu ADB key on the phone if prompted. The examples below use `/dev/cdc-wdm0`. If you have multiple modems, identify the node belonging to the phone first and set `QMI_DEVICE` to it when running the helper. Native Linux can use the same commands once it sees the phone's QMI and ADB interfaces.

## 4. List, extract, load, then activate

Run these from the directory containing `skt-volte.sh`. Save the original active profile's description, version and full ID before doing any writes:

```bash
sudo bash skt-volte.sh profiles | tee profiles-before.txt
sudo bash skt-volte.sh extract
```

The tested phone had `ROW_Commercial` (`0x8010811`) active and no SKT entry in PDC, even though the firmware contained the SKT file. Extraction reads the file from `/vendor/firmware_mnt/image/modem_pr/mcfg/configs/mcfg_sw/generic/korea/skt/commerci/mcfg_sw.mbn` on `davinci` and checks the local hash against the device hash. The tested copy was 40,184 bytes and SHA-256 `26f5ce45c53a3e0ea900f23abe140cda0e6a9a299463bb851975563369ca9a79`. Other basebands can ship a different revision. If PDC already lists the matching SKT profile, reuse its ID and skip loading.

When the SKT profile is missing, load the local copy, then list again. On Ubuntu `libqmi-utils` `1.38.0-1` amd64, use the workaround below for the load step. On other builds the ordinary command is:

```bash
sudo bash skt-volte.sh load ./davinci-skt-mcfg.mbn
sudo bash skt-volte.sh profiles
```

If a load fails, list profiles before retrying. Continue once `Commercial-SKT` is present and you have both profile IDs recorded. Activation can temporarily interrupt cellular service. Use the ID reported by **your own** modem:

```bash
sudo bash skt-volte.sh activate <COMMERCIAL_SKT_ID>
sudo bash skt-volte.sh profiles
```

Confirm `Commercial-SKT` is **Active**. Check IMS Service Status and make a regular Wi-Fi-off call that stays on LTE. A separate VoLTE status-bar icon is not required. If cellular service fails to recover, run the same `activate` command with your original ROW profile ID. Verify the actual result after any requested activation, since a success message only confirms the activation request. Once finished, use `usbipd detach --busid <BUSID>` in PowerShell and, if you used a forced bind, `usbipd unbind --busid <BUSID>` from Administrator PowerShell to return access to Windows. A normal phone restart clears the temporary vendor USB override. Test a call again after reboot to verify persistence on your build.

## Ubuntu 1.38.0 loader workaround

On Ubuntu `libqmi-utils` `1.38.0-1` amd64, `--pdc-load-config` crashed at `qmicli-pdc.c:1130` when it called `g_free()` on the mapped buffer. The workaround used GDB to skip that single invalid call for one execution. The instruction addresses below describe the observed binary. Verify both instructions first, and use a corrected loader instead if the binary differs. The installed executable and firmware file are not patched.

```bash
sudo apt install gdb
sudo gdb -q -nx \
  -ex starti \
  -ex 'break *0x5555555c0fa6' \
  -ex continue \
  --args /usr/bin/qmicli -d /dev/cdc-wdm0 \
  --pdc-load-config="$PWD/davinci-skt-mcfg.mbn"
```

At the breakpoint, run `x/2i $pc`. Only proceed if the first instruction is `call ... <g_free@plt>` at `0x5555555c0fa6` and the next is at `0x5555555c0fab`. If they differ, use `quit` and stop that run.

```gdb
set $pc = 0x5555555c0fab
continue
quit
```

Run `sudo bash skt-volte.sh profiles` afterward. The observed SKT entry was `Commercial-SKT` `0x8012810` and initially **Inactive**. No debugger was needed to activate it.

## References

- [QMI and PDC on Android by Alexander Couzens](https://www.openimsd.de/android-activate-volte-qmi-pdc-service.html)
- [libqmi command-line documentation](https://www.freedesktop.org/software/libqmi/man/latest/qmicli.1.html)
- [Microsoft guide to attaching USB devices to WSL](https://learn.microsoft.com/en-us/windows/wsl/connect-usb)
- [GLib mapped-file ownership](https://docs.gtk.org/glib/struct.MappedFile.html)
- [Android APN type handling](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/telephony/java/android/telephony/data/ApnSetting.java)
