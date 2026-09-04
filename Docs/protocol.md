# 3X3 Bluetooth Protocol Notes

This document records the protocol behavior needed by the native 3X3 iOS app.
Update it whenever implementation work or hardware testing reveals new behavior.

## Evidence Levels

- **Confirmed (bundle):** directly observed in the 3X3 Service Tool JavaScript bundle.
- **Confirmed (hardware):** reproduced against a physical Gear or Trigger device.
- **Inferred:** likely behavior that still needs a packet capture or hardware test.
- **Unknown:** identified surface whose encoding or semantics are not yet understood.

An implementation or passing unit test is not protocol evidence by itself. Mixed
sections label individual claims rather than assigning one level to the entire
section.

Unless marked otherwise, the findings below are from Service Tool version `3.0.5`,
inspected on 2026-09-03, and are not yet hardware-confirmed.

## Device Discovery

**Confirmed (bundle)**

The web tool requests devices matching at least one of these filters:

| Filter | Value |
| --- | --- |
| Manufacturer company identifier | `3394` (`0x0D42`) |
| Manufacturer company identifier | `3222` (`0x0C96`) |
| Exact local name | `Gear-OTA` |
| Exact local name | `Trigger-OTA` |
| Exact local name | `OTA` |
| Exact local name | `OTA_Trigger` |
| Exact local name | `Zephyr` |
| Local-name prefix | `TSW` |

After connecting and discovering primary services, the web tool classifies a
device exposing the standard Battery service (`0x180F`) as a Trigger. A device
without that service is classified as a Gear.

The connection table's `3X3 device` value is derived from the Model Number
characteristic (`2A24`) or, for the SFT Trigger, its DFU characteristic:

| Evidence | Internal code | Displayed value |
| --- | --- | --- |
| Model prefix `148098`, `142610`, `143035`, or `141903` | `ActuatorETO` | `E9.XP` |
| Model prefix `142729` | `TriggerETO` | `E.TR.ADJ` |
| Model prefix `200000` | `ActuatorHB` | `Actuator HB` |
| Model exactly `300000` | `TriggerHB` | `Trigger HB` |
| Nordic Secure DFU characteristic `8EC90003-F315-4F60-9FB8-838830DAEA50` | `TriggerSFT` | `E.TR.CMD` |

The DFU-characteristic match takes precedence over Model Number matching. The
native detail view applies the same rules and labels the resulting field `Type`.

**Confirmed (hardware):** Gear `3X3GEAR112411700373` advertised with company
identifier `3222`. Trigger `TSW001` advertised with company identifier `3394`.
After service discovery, the native app classified the Gear without service
`180F` as Gear and `TSW001`, which exposes service `180F`, as Trigger.

**Confirmed (hardware):** The third manufacturer-data byte distinguishes the
observed `TSW001` operating modes. Normal short-press wake advertised
`42 0D 00 D2 B4 7F B8 0A 25 01 00 00 00 00`; holding the Trigger for ten
seconds changed the same advertisement to
`42 0D 02 D2 B4 7F B8 0A 25 01 00 00 00 00` before a connection was attempted.
Connections in mode `0x00` timed out, while mode `0x02` connected in about five
seconds. Both advertisements reported `connectable=true`, so that CoreBluetooth
flag alone cannot identify whether the Trigger firmware will accept a new
connection. The app treats `0x00` as awake, `0x02` as pairing, and leaves unknown
values eligible for connection to avoid rejecting other firmware variants.
For the observed payload, bytes 3-8 are the Trigger MAC
`D2:B4:7F:B8:0A:25`, matching the MAC previously read from Gear table 106.

Service Tool 3.0.5 does not inspect these payload bytes. Its `manufacturerData`
usage only filters Web Bluetooth devices by company identifiers `3394` and
`3222`, after which it calls `gatt.connect()` directly.

CoreBluetooth cannot scan-filter by manufacturer data. The iOS implementation
must scan broadly, inspect the first two little-endian manufacturer-data bytes,
and apply the company/name filters in the app.

## GATT Services

**Confirmed (bundle)**

| Name | UUID | Purpose |
| --- | --- | --- |
| Generic Access | `1800` | Standard GAP |
| Generic Attribute | `1801` | Standard GATT |
| Device Information | `180A` | Standard identity and version information |
| Battery | `180F` | Standard battery service; also used for Trigger detection |
| Diagnostics | `E892FDCC-79BD-462F-A1D6-9EF13C3D9B92` | Parameters, logs, TIF commands |
| Shift | `F12D66E5-4E50-4F2F-901F-A1B1C2A8726B` | Shift behavior |
| Authentication | `7F6D0010-B996-5845-90F3-0796DCD321D8` | Device challenge/response |
| Silicon Labs OTA | `1D14D6EE-FD63-4FA1-BFA4-8F47B42119F0` | Firmware update |
| Nordic OTA | `30EFF7A7-6996-4CAB-B5C9-588ACF554B59` | Firmware update |
| Nordic Secure DFU | `FE59` | Firmware update |

Native firmware installation through OTA or DFU remains outside the iOS app's
scope. The app uses the firmware catalog only to report update availability.

## Diagnostics Characteristics

**Confirmed (bundle)**

| Name | UUID | Current understanding |
| --- | --- | --- |
| Parameter Data | `E4B00270-86B2-49DE-983F-701E1845470A` | Parameter-table transport; response envelope and parts of tables 106, 111, and 113 are known |
| Authentication | `87A8E1A7-AF9D-4A4F-BE5A-213F1603839C` | Diagnostics authorization challenge/response |
| Gateway to MCU | `4711` | MCU gateway transport |
| Log | `D0102CD3-F08E-4381-A82A-D6AC015D4879` | Device log stream |
| TIF | `80E9B23C-A7FC-46EB-9AA3-7DE13573E534` | Framed command/response transport |

The short UUID `4711` is equivalent to Bluetooth base UUID
`00004711-0000-1000-8000-00805F9B34FB`.

## Authentication Characteristics

**Confirmed (bundle)**

| Name | UUID |
| --- | --- |
| Challenge | `7F6D0011-B996-5845-90F3-0796DCD321D8` |
| Response FD | `7F6D0012-B996-5845-90F3-0796DCD321D8` |
| Response | `7F6D0013-B996-5845-90F3-0796DCD321D8` |

Gear Diagnostics authentication uses the Diagnostics Authentication
characteristic rather than the three-characteristic TRP exchange above:

1. Enable notifications on
    `87A8E1A7-AF9D-4A4F-BE5A-213F1603839C`.
2. Request level 5 by writing `00 05` (big-endian `UInt16`).
3. Receive a 16-byte challenge.
4. Encrypt that block with AES-128-ECB using the fixed key material present in
    the web bundle.
5. Write a 17-byte response consisting of byte `01` followed by the encrypted
    challenge.
6. Receive a one-byte granted authentication level; success is `05`.

**Confirmed (bundle and hardware):** The Service Tool performs this exchange
before Gear parameter reads. The native app reproduced the complete exchange on
the physical Gear: it received a 16-byte challenge, sent the encrypted response,
was granted level 5, and then read tables 111 and 106 successfully.

## OTA Characteristics

**Confirmed (bundle)**

| Name | UUID |
| --- | --- |
| Control | `F7BF3564-FB6D-4E53-88A4-5E37E0326063` |
| Data | `984227F3-34FC-4045-A5D0-2C581F81A153` |
| App-loader version | `4F4A2368-8CCA-451E-BFFF-CF0E2EE23E9F` |
| Version | `4CC07BCF-0868-4B32-9DAD-BA4CC41E5316` |
| Bootloader version | `25F05C0A-E917-46E9-B2A5-AA2BE1245AFE` |
| Application version | `0D77CC11-4AC1-49F2-BFA9-CD96AC7A92F8` |
| FOTA data | `2958A857-BEBA-4613-AA16-8A90E6779AD0` |

## Software Update

**Confirmed (Service Tool 3.0.5 bundle and live assets, 2026-09-05):** The web
tool loads `/firmware/firmware.json`, sorts each product's entries with a
semantic-version comparator, and selects the last entry as the latest release.
An update is offered only when that version is strictly greater than the
normalized device version. TRP software versions have leading letters and the
suffix beginning with `_` removed before comparison. A manually selected
rollback version bypasses the newer-version check.

The current remote catalog is:

| Product key | Version | Artifact | HTTP result / size |
| --- | --- | --- | --- |
| `triggerETO` | `1.9.13` | `triggerETO_v1.9.13.gbl` | `200` / 205,364 bytes |
| `triggerHB` | `0.0.0` | `triggerHB_v0.0.0.gbl` | `404` / unavailable |
| `actuatorETO` | `1.8.6` | `actuatorETO_v1.8.6.gbl` | `200` / 326,460 bytes |
| `actuatorHB` | `2.0.2` | `actuatorHB_v2.0.2.bin` | `200` / 294,760 bytes |
| `triggerBEU` | `0.32.4` | `triggerBEU_v0.32.4.zip` | `200` / 70,979 bytes |
| `triggerSFT` | `0.32.4` | `triggerSFT_v0.32.4.zip` | `200` / 70,611 bytes |

Firmware bytes are fetched from `/firmware/<artifact>`. The catalog contains
only `version`, `url`, and `releaseDate`; it provides no size, digest, signature,
hardware revision, minimum version, or rollout metadata. The tool can also
store manually uploaded firmware in an IndexedDB database named `firmware`,
versioned from the site's `VERSION` file. No firmware binary is stored in this
repository.

The native app checks this catalog in a cancellable background task after a
device connects. It ignores the local URL cache, uses a 15-second request
timeout, and compares the connected software version with the latest release
for the classified product. A newer version produces an informational notice
directing the user to the 3X3 Web App. Network, decoding, and classification
failures are diagnostic-only and do not block device setup. The native app does
not download or install the artifact. `TriggerBEU` is not checked because the
current runtime characteristics do not distinguish it safely from other
Trigger variants.

### Previous versions

**Confirmed (Internet Archive catalog snapshot from 2026-05-14 and live HTTP
responses checked 2026-09-05):** The archived catalog provides the following
superseded entries:

| Product key | Version | Release date | Artifact status |
| --- | --- | --- | --- |
| `triggerETO` | `1.9.11` | 2024-12-17 | Base and `-s1` `.gbl` files still return `200` |
| `actuatorETO` | `1.8.3` | 2025-10-02 | Base and `-s1` `.gbl` files still return `200` |
| `actuatorHB` | `2.0.0` | 2025-06-17 | URL redirects to `actuatorHB_v2.0.2.bin`; old bytes are not retrievable there |
| `actuatorHB` | `2.0.1` | 2026-03-19 | URL redirects to `actuatorHB_v2.0.2.bin`; old bytes are not retrievable there |

The archive currently exposes only one distinct historical snapshot of
`firmware.json`. It therefore cannot establish a complete release history.
BEU and SFT Trigger version `0.32.4` and the Trigger HB `0.0.0` placeholder are
unchanged between that snapshot and the live catalog, so they are not known
previous releases.

The manifest schema permits multiple entries per product, and the rollback UI
lists all remote entries plus firmware manually cached in IndexedDB. There is
no separate history endpoint in the bundle. A native client should consume only
explicit catalog or trusted archive entries; probing guessed version filenames
would not establish compatibility or provenance.

### ETO update

`ActuatorETO` and `TriggerETO` use the Silicon Labs OTA service and `.gbl`
artifacts:

1. Write `00` with response to the Control characteristic to enter OTA mode.
2. Wait for the application connection to disconnect, pause two seconds, and
    reconnect to the same Web Bluetooth device.
3. Read Bootloader Version as a little-endian `UInt16`.
4. Write `00` to Control again and wait two seconds.
5. For bootloader versions 3 or newer, insert `-s1` before the artifact
    extension. Both currently selected variants are published:
    `triggerETO_v1.9.13-s1.gbl` (205,500 bytes) and
    `actuatorETO_v1.8.6-s1.gbl` (359,708 bytes).
6. Write the artifact to Data in chunks of at most 244 bytes, using writes with
    response. Progress is derived from bytes written.
7. Disconnect, wait approximately 30 seconds, reconnect, and reinitialize the
    device. After an Actuator ETO update, the tool additionally reboots the MCU,
    then the Gear BLE processor, reconnects again, and reloads parameters.

The normal ETO path has no explicit final checksum, status notification, or
post-update version comparison in the bundle. Completion therefore means all
writes returned and the reconnect sequence completed, not that the requested
version was independently verified.

### HB update

`ActuatorHB`, `TriggerHB`, and an OTA-only HB connection use the Nordic OTA
service and the FOTA Data characteristic:

1. Enter OTA mode by writing Diagnostics parameter table 178 with a one-byte
    value of `01`, then wait for disconnect.
2. Ask the user to select the advertising OTA device and reconnect. An
    OTA-only device is recognized by the Nordic OTA service.
3. Require Bootloader Version, read as a little-endian `UInt16`, to be at least
    1.
4. Wait up to five seconds for a FOTA Data notification whose first
    little-endian `UInt32` is `0` (ready).
5. Write the artifact size as a four-byte little-endian value to FOTA Data and
    wait up to five seconds for the device to echo that size.
6. Write the artifact to FOTA Data in chunks of at most 244 bytes, using writes
    with response. No explicit finalize command follows the final chunk.
7. Disconnect and require a user-driven reconnect.

The bundle's reconnect classifier checks `OTAHB` in the Actuator branch before
an unreachable Trigger branch that also includes `OTAHB`. The OTA-only service
therefore does not by itself preserve whether the original HB device was an
Actuator or Trigger. Together with the missing `triggerHB_v0.0.0.gbl`, Trigger
HB update should be treated as unavailable until separately verified.

### BEU and SFT Trigger Secure DFU

`TriggerBEU` and `TriggerSFT` use Nordic Secure DFU ZIP packages:

1. Enable notifications on Buttonless DFU, write `01`, and wait for disconnect.
2. Prompt for a bootloader named exactly `TSW001`, connect to service `FE59`,
    enable Control Point notifications, and obtain the Packet characteristic.
3. Parse `manifest.json` from the ZIP and require
    `manifest.application.bin_file` and `dat_file`.
4. Select the command object with `06 01`, then create it with
    `01 01 <dat-size:UInt32LE>`.
5. Send the init packet in 100-byte Packet writes. After every write, send
    checksum command `03` and verify the returned cumulative offset and CRC32.
    Execute it with `04`.
6. Select the data object with `06 02`. The bundle rejects any nonzero existing
    offset because resume is not implemented.
7. For each maximum-sized object reported by Select, send
    `01 02 <object-size:UInt32LE>`, stream 100-byte Packet writes with a 25 ms
    delay, verify cumulative offset and CRC32 with `03`, and execute with `04`.

Control Point success responses must begin `60 <request-opcode> 01`; each
command has a six-second timeout. CRC32 uses reflected polynomial `0xEDB88320`.
The implementation does not configure packet receipt notifications and cannot
resume an interrupted data transfer.

### Web UI and safety behavior

The normal update page warns not to interrupt e-bike power and requires a bike
restart after completion. Its Start button is disabled when no newer version is
available, the device is disconnected, an update is active, macOS is detected,
or Chrome's newer Web Bluetooth permissions backend is available. BEU/SFT and
HB updates are deliberately staged across Start, Update, and Reconnect actions.
Desired versions and device IDs are retained in local storage across OTA-mode
restarts. Completion opens a dialog that reloads the web app and asks the user
to reconnect.

The Developer role receives a separate manual Silicon Labs updater instead of
the normal product updater. It exposes four explicit steps: enter OTA mode,
connect to the OTA device, choose a `.gbl` file, and start transfer. It checks
the bootloader generation against whether the filename contains `signe`, but
does not inspect or authenticate the file before sending it.

**Not hardware-confirmed:** None of these update paths has been exercised by the
native project. Native implementation should not begin until artifact integrity
policy, HB product continuity, interruption recovery, and post-update version
verification are defined and tested on recoverable hardware.

## TIF Frame Format

**Confirmed (bundle)**

All integer fields are little-endian.

| Offset | Size | Field | Value/meaning |
| ---: | ---: | --- | --- |
| `0` | 2 | Magic | `0xAFFE`; encoded bytes `FE AF` |
| `2` | 2 | Payload length | Number of bytes following the 7-byte header |
| `4` | 2 | CRC16 | Checksum described below |
| `6` | 1 | Command | Request command or response command |
| `7` | variable | Payload | Command-specific data |

### CRC16

The bundle uses a reflected CRC16 with:

| Parameter | Value |
| --- | --- |
| Initial value | `0xFFFF` |
| Polynomial | `0xA001` |
| Input | Entire header and payload |
| CRC field while calculating | `0xFFFF` |

Pseudocode:

```text
crc = 0xFFFF
for byte in frame:
    crc = crc XOR byte
    repeat 8 times:
        if crc bit 0 is set:
            crc = (crc >> 1) XOR 0xA001
        else:
            crc = crc >> 1
```

The calculated value replaces the temporary `0xFFFF` at offsets 4-5.

The Swift implementation is in
`Sources/ThreeByThreeKit/TIFFrame.swift`. Its encode/decode behavior is covered
by unit tests. Hardware traces contain accepted native frames for commands 1, 2,
9, and 13, providing end-to-end confirmation of framing and CRC behavior.

### Responses

**Confirmed (bundle)**

- A normal response command is the request command ORed with `0x80`.
- Response command `0xFF` indicates a device error.
- A zero-length payload is treated as an acknowledgment by the web tool.
- Non-empty payloads contain command-specific response data.

Requests are serialized by the native `TIFClient`; concurrent frames must not
interleave on the characteristic. The native transport waits for CoreBluetooth
to confirm notification subscription before sending the first request, avoiding
loss of a response emitted immediately after a write.

## Gear Commands

**Confirmed (bundle)**

| Value | Bundle name | Current scope |
| ---: | --- | --- |
| 0 | `TIF_GT_REBOOT` | Excluded |
| 1 | `TIF_GT_REBOOT_MCU` | Excluded |
| 2 | `TIF_GT_MCU_UPDATE` | Excluded |
| 3 | `TIF_GT_LOCK_JTAG` | Excluded |
| 4 | `TIF_GT_GREASE_DISTRI` | Excluded |
| 5 | `TIF_GT_BOSH_POWER_TEST` | Excluded |
| 6 | `TIF_GT_TRQ_TEST` | Excluded |
| 7 | `TIF_GT_ANG_SPEED_TEST` | Excluded |
| 8 | `TIF_GT_PWR_CONSUMPTION` | Excluded |
| 9 | `TIF_GT_POSITION` | Included; request and response layout hardware-confirmed |
| 10 | `TIF_GT_CAN_TEST` | Excluded |
| 11 | `TIF_GT_INIT_RUN` | Excluded |
| 12 | `TIF_GT_MCU_COMMAND` | Excluded |
| 13 | `TIF_GT_SHIFT` | Included; up/down payloads hardware-confirmed; select-gear payload bundle-confirmed |
| 14 | `TIF_GT_MCU_INFO` | Not used by the native app; response partially known from bundle |
| 15 | `TIF_GT_LOCK_JTAG_READ` | Excluded |
| 31 | `TIF_GT_COMMIT_HASH_READ` | Useful for diagnostics |
| 32 | `TIF_GT_MCU_BLE_BRIDGE_ENABLE` | Included; sent during normal Gear initialization, matching the web app |
| 33 | `TIF_GT_MCU_BLE_BRIDGE_DISABLE` | Excluded |
| 34 | `TIF_GT_MCU_BLE_BRIDGE_GET_STATUS` | Excluded |

### Known Gear Payloads

**Confirmed (bundle and hardware)**

`POSITION` request payload:

| Offset | Size | Type | Value |
| ---: | ---: | --- | --- |
| 0 | 2 | `UInt16` LE | `1` |

`POSITION` response payload, relative to frame payload offset 0:

| Offset | Size | Type | Meaning |
| ---: | ---: | --- | --- |
| 0 | 1 | `UInt8` | Position/status value |
| 1 | 2 | `UInt16` LE | Position divided by `100` by the web tool |

`MCU_INFO` response payload:

| Offset | Size | Meaning |
| ---: | ---: | --- |
| 0 | 1 | Active image: 0 uninitialized, 1 bootloader, 2 application, 3 unknown |
| 1 | 2 | Bootloader version encoding; helper transformation not yet documented |
| 3 | 2 | Application version encoding; helper transformation not yet documented |

`SHIFT` request payload. Up and down are **confirmed (bundle and hardware)**;
direct select-gear is **confirmed (bundle), not hardware-confirmed**:

| Direction | Command | Payload |
| --- | ---: | --- |
| Down | `13` | `00` |
| Up | `13` | `01` |
| Select gear 1-9 | `13` | `0x80 OR gear` |

Complete encoded manual-shift vectors:

```text
Up:   FE AF 01 00 55 6C 0D 01
Down: FE AF 01 00 94 AC 0D 00
```

The Service Tool sends this command without registering a TIF response callback,
so the native implementation treats manual shifts as one-way writes. Hardware
testing confirmed that the writes shift the Gear; no TIF acknowledgement was
observed or required. Position is read separately after each shift.

## Gear Calibration

**Confirmed (bundle):** Service Tool 3.0.5 starts Gear auto-calibration by
writing the following ten bytes to the Gateway to MCU characteristic (`4711`):

```text
09 08 1A 00 00 FF 00 00 00 00
```

The web tool classifies actuator variants from the standard Model Number
characteristic (`2A24`). Prefixes `148098`, `142610`, `143035`, and `141903`
identify standard ETO actuators. Prefix `200000` identifies an HB actuator.

For a standard actuator, the web UI describes a roughly five-second operation,
keeps controls busy for seven seconds, and then requests fresh Gear state. It
does not receive an explicit calibration-success result on this path. For an HB
actuator, the UI describes a roughly 30-second operation and waits up to 90
seconds for an eight-byte Gateway notification. A calibration-completion frame
starts with `07 06 1A`; byte 4 is `1` for success and any other value is treated
as failure.

The native implementation follows these variant-specific completion rules,
refreshes TIF position after the operation, and leaves calibration unavailable
for unknown model-number prefixes rather than guessing. It requires an explicit
safety confirmation before sending the command. Following the technical manual,
that confirmation requires the rear wheel to be mounted, the pedals to remain
unloaded, and hands, clothing, and tools to remain clear of the drivetrain.
After the operation completes, the app presents the completion result on a
separate sheet that remains open until the user selects `Done`.

**Not hardware-confirmed:** The native Gateway command, standard timing path,
HB completion notification, and resulting mechanical calibration have not yet
been exercised against physical hardware. For a standard actuator, elapsed time
and a successful write do not prove that calibration succeeded; all gears must
be verified before riding.

## Rotate 2nd Gear

**Confirmed (Service Tool 3.0.5 bundle):** The calibration screen provides
counterclockwise and clockwise controls that write these ten-byte requests to
the Gateway to MCU characteristic (`4711`):

```text
Counterclockwise: 09 08 1A 01 00 FE 01 14 00 00
Clockwise:        09 08 1A 01 00 FE 02 14 00 00
```

The production calibration UI maps direction byte `01` to its counterclockwise
button and byte `02` to clockwise. A hidden developer panel labels the same
boolean argument in the opposite direction, so this direction mapping remains
**not hardware-confirmed**. The native app follows the production UI mapping.

**Confirmed ([3X3 NINE E-Shift Technical Manual](https://www.3x3.bike/wp-content/uploads/2025/12/3x3-NINE-E-Shift-Technical-Manual_EN.pdf),
English, page 15):** This is an installation operation for rotating the
half-visible gear until the final gear can be inserted. The manual requires a
calibration ride afterward. After a successful write, the native app displays
that requirement without repeating the selected rotation direction.

The bundle does not wait for a completion notification or verify the resulting
position. A successful characteristic write therefore confirms only that the
request was accepted by Bluetooth, not that the mechanical rotation completed.

## Trigger Commands

**Confirmed (bundle)**

| Value | Bundle name | Current scope |
| ---: | --- | --- |
| 0 | `TIF_TT_REBOOT` | Excluded |
| 3 | `TIF_TT_LOCK_JTAG` | Excluded |
| 4 | `TIF_TT_LED` | Service Tool debug UI only; not implemented by the native app |
| 5 | `TIF_TT_BUTTONS` | Useful during protocol confirmation |
| 6 | `TIF_TT_FLUSH_OTP` | Excluded |
| 7 | `TIF_TT_GET_VBATT` | Decoder implemented; layout bundle-confirmed, not hardware-confirmed |
| 8 | `TIF_TT_SET_MODE` | Not implemented; payload unknown |
| 9 | `TIF_TT_SEND_SHIFT` | Not implemented; payload unknown |
| 10 | `TIF_TT_LOCK_JTAG_READ` | Excluded |
| 11 | `TIF_TT_COMMIT_HASH_READ` | Useful for diagnostics |

The web app sends `TIF_TT_GET_VBATT` with an empty payload. Its response payload
contains a little-endian battery voltage in millivolts at offsets 0-1, battery
percentage at offset 2, and a low-battery warning flag at offset 3. This layout
is bundle-confirmed and unit-tested but not hardware-confirmed. Physical
`TSW001` did not expose the Diagnostics TIF characteristic, so the native app
instead read its standard Battery Level characteristic `2A19`, obtaining `96%`.
While a Trigger remains connected, the native app refreshes battery state once
per second. It uses the full TIF battery response when Diagnostics TIF is
available and otherwise falls back to `2A19`; the fallback provides percentage
only, without voltage or the low-battery flag.

Service Tool 3.0.5 defines `TIF_TT_SEND_SHIFT` but does not expose a corresponding
method that confirms its payload encoding. Trigger shift transmission therefore
remains unimplemented rather than assuming it matches Gear encoding.

**Confirmed (hardware):** On 2026-09-03 the first connection to `TSW001` produced
no CoreBluetooth callback and timed out after ten seconds. A retry while the
Trigger was awake connected in about five seconds and discovered 72
characteristics, including Device Information, Battery, TRP Authentication, and
Shift services. It did not expose the Gear Diagnostics service.

## Trigger Pairing

The encoding below is **confirmed (bundle)**. Hardware confirmation is noted per
step.

For a `TSW` Trigger, the web app authenticates through the TRP Authentication
service before reading its identity:

1. Read the 16-byte challenge characteristic.
2. Encrypt it with AES-128-ECB using the bundle-embedded TRP key.
3. Write the 16-byte ciphertext to the Response FD characteristic.
4. Read parameter table 113 and take the six MAC bytes at value offsets 0-5.

The Gear stores pairing in BLE parameter table 106, whose value is 137 bytes.
The official tool reads the current value, then constructs a fresh zero-filled
137-byte value containing the Trigger MAC at bytes 0-5, RSSI at byte 6, address
type at byte 7, disconnect timeout at bytes 8-11, and device name beginning at
byte 12. Pairing sets address type `4`; unpairing writes a zero MAC and address
type `0`. Bytes not represented by those fields are cleared rather than
preserved by the official tool. The native app's explicit unpair operation uses
the earlier read-modify-write strategy: it changes only the MAC and address type
and preserves all other bytes from the Gear's current table value.

Parameter Data responses may span multiple BLE notifications. A hardware
table-106 read delivered a 152-byte TIF frame as an initial 50-byte fragment;
the transport therefore reassembles notifications using the TIF header payload
length before decoding the frame.

**Confirmed (hardware):** Authenticated Gear reads returned the full 137-byte
table 106 value and paired MAC `D2:B4:7F:B8:0A:25`. Pair and unpair
read-preserve-write operations received valid command `0x81`, table 106,
result-0 acknowledgements, and immediate readback confirmed the requested MAC.
Unpairing remained in effect after reconnecting and rebooting the Gear. It was
also independently confirmed by pairing with the official web app, unpairing
with the native app, and reconnecting through the web app, which reported the
Trigger as unpaired.

**Not hardware-confirmed:** The physical `TSW001` exposed the TRP challenge and
response characteristics, but no Diagnostics Parameter Data characteristic.
Consequently table 113 cannot be read on that firmware. When Parameter Data is
absent, the native app uses manufacturer-data bytes 3-8 as the identity, but only
from a company-3394 advertisement in confirmed pairing mode `0x02`. Physical
pair writes using this fallback stored and read back the expected MAC.

The successful web workflow does not invoke its explicit table-106 pair action.
With an unpaired Gear connected, it connects the Trigger as a second BLE device
and polls Gear table 106 once per second. Gear firmware establishes the pairing;
the web UI recognizes completion when table 106 changes from a zero MAC to the
Trigger MAC. The Trigger is then disconnected before testing physical shifts.

The native pairing UI now follows that workflow. It keeps the primary Gear
session connected, scans for a Trigger, authenticates a temporary Trigger GATT
session, and obtains its identity. For a Trigger without table 113, it uses the
pairing-mode advertisement MAC; other Trigger variants read table 113. While
both sessions remain connected, it polls Gear table 106 once per second without
writing it. When Gear reports the expected MAC, the app disconnects the Trigger
and shows completion while retaining the phone-to-Gear connection.

**Confirmed (hardware):** This native workflow paired the physical Trigger and
Gear, and subsequent shifts from the Trigger operated the Gear. The successful
build included command `32` during normal Gear initialization. This confirms the
complete workflow but does not, by itself, prove that command `32` was the sole
missing prerequisite.

During normal Gear initialization, both the web and native apps send
`TIF_GT_MCU_BLE_BRIDGE_ENABLE` (command `32`) before normal Gear-state activity.
This is distinct from the separate app-free hardware pairing procedure involving
a system restart and both Trigger buttons; the native app does not issue either
Gear reboot command as part of pairing.

## Native Testing Fixtures

**Confirmed (implementation):** Device fixtures are independent of the build
configuration. Setting the `ADD_TESTING_DEVICE_ENTRIES` environment variable
adds six testing entries to discovery after two seconds: latest and outdated
variants of `E9.XP`, `E.TR.ADJ`, and `E.TR.CMD`. Testing sessions emulate
connection metadata and the implemented Gear and Trigger workflows without BLE
hardware. No testing entries are added when the variable is absent.

## Parameter Data and Shift Settings

The table layout is **confirmed (bundle and hardware)**. Individual writes are
qualified below.

The web bundle exposes state for:

- BLE parameters
- Trigger operating parameters
- AutoDownShift enabled state
- AutoDownShift target gear
- Multi-shift step count
- Shift parameters

Shift settings use parameter table ID `111`. A read is TIF command `2` with
payload `6F 00 00 00 01`. The response payload envelope starts with the 4-byte
table ID and a 4-byte result or metadata field. A successful table response then
places the 138-byte table value at offset 8.

A write is TIF command `1` with this payload:

| Offset | Size | Meaning |
| ---: | ---: | --- |
| 0 | 4 | Table ID `111`, little-endian |
| 4 | 1 | Flags, currently `1` |
| 5 | 138 | Complete shift-settings value |

Known value offsets are:

| Offset | Size | Meaning |
| ---: | ---: | --- |
| 0 | 1 | AutoDownShift enabled |
| 1 | 1 | AutoDownShift target gear |
| 2 | 1 | Start gear |
| 3 | 2 | Pre-torque reduction duration, little-endian |
| 5 | 2 | Torque reduction duration, little-endian |
| 7 | 1 | Torque reduction limit |
| 8 | 2 | Dead-center offset, little-endian |
| 10 | 2 | Dead-center maximum wait, little-endian |
| 12 | 2 | Group torque reduction duration, little-endian |
| 14 | 1 | Multi-shift steps |
| 15 | 2 | Multi-shift wait duration, little-endian |

Selecting an AutoDownShift gear enables AutoDownShift and writes the selected
gear to both target gear and start gear. The native implementation first reads
the complete value and preserves all other bytes before writing it back.
Enabling or disabling AutoDownShift changes only value offset 0 and likewise
preserves the remaining 137 bytes.

**Confirmed (hardware):** The Parameter Data characteristic exposes write,
write-without-response, and notify properties (`28`), but not read. A direct
CoreBluetooth read fails with `Reading is not permitted.`

**Confirmed (hardware):** Parameter responses are delivered by notification.
With notifications enabled before the write, table 111 returned the valid frame
`FE AF 08 00 B4 3A 82 6F 00 00 00 F6 FF FF FF`. Its payload decodes as table ID
`111` followed by signed value `-10`, with no table data.

**Confirmed (bundle):** Gear initialization authenticates at level 5 before
reading EOL, shift, and BLE parameter tables. The authentication exchange uses
the Diagnostics Authentication characteristic, notifications, a 16-byte
challenge, and a 17-byte response before reporting the granted level.

**Confirmed (hardware):** The short table response and value `-10` occurred
before authentication. The same read succeeded after level-5 authentication.
Authentication dependence is therefore confirmed for this Gear, but the named
semantic meaning of error value `-10` remains unknown.

## Hardware Validation Log

- 2026-09-03: Gear `3X3GEAR112411700373` advertised with company identifier
    `3222`, connected successfully in approximately one second, and exposed 12
    GATT characteristics. The expected Diagnostics service included TIF, Parameter
    Data, Gateway to MCU, Authentication, and Log characteristics.
- 2026-09-03: Parameter Data properties were `28` (write,
    write-without-response, notify). Direct read after request
    `FE AF 05 00 B8 F2 02 6F 00 00 00 01` failed locally with
    `Reading is not permitted`; no response frame was captured in that test.
- 2026-09-03: After changing the native transport to subscribe before writing,
    the same request received
    `FE AF 08 00 B4 3A 82 6F 00 00 00 F6 FF FF FF`. CRC `0x3AB4` is valid;
    command `0x82` is the read response; the payload is table ID `111` and signed
    result `-10`. The official bundle authenticates at level 5 before this read.
- 2026-09-03: Native Diagnostics authentication was hardware-confirmed. The Gear
    returned a 16-byte challenge, accepted the AES-128-ECB response, and granted
    level 5. The following table-111 read returned a valid 146-byte payload:
    4-byte table ID, 4-byte zero result/metadata field, and 138 settings bytes.
    The observed settings reported AutoDownShift enabled with target gear 4.
- 2026-09-03: Manual up/down commands were hardware-confirmed. Position command
    9 reported gears 4 through 7 after shifts; because shift command 13 is a
    one-way write, clients must explicitly read position after the mechanism has
    settled to refresh displayed state.

**Confirmed (bundle):** The web calibration UI does not use a fixed post-shift
delay. It sends up/down through Gateway to MCU, updates `currentGear` from an
unsolicited `gearchanged` message, and schedules `getGearState()` after one
second as a fallback while the shift remains busy. The native app currently uses
TIF command 13 and therefore polls position immediately after a shift, stopping
when the reported gear changes and timing out after the same one-second window.

- 2026-09-03: Adaptive native position refresh was hardware-confirmed across 13
    consecutive shifts from gear 4 up to 9 and down to 1. Twelve shifts reported
    the new gear on the first read, 160–250 ms after the shift write completed.
    One shift still reported the old gear at 190 ms and reported the new gear on
    the second poll at 461 ms. There were no errors or one-second refresh
    timeouts.
- 2026-09-05: One-second idle polling while connected to Gear was
    hardware-confirmed. Shifts initiated by the physical Trigger were reflected
    correctly in the app UI without a manual refresh.
- 2026-09-05: Native app-assisted Trigger pairing was hardware-confirmed. The
    app kept Gear connected, authenticated the Trigger, observed Gear table 106
    until it reported the Trigger MAC, and disconnected the temporary Trigger
    session. Physical Trigger shifts then operated the Gear. The successful
    build enabled the MCU BLE bridge with command 32 during Gear initialization;
    that command was not independently isolated as the sole cause.
- 2026-09-05: A user-requested shift overlapped an idle position poll and
    CoreBluetooth rejected the second write as already pending. TIF transactions
    are now serialized for their complete notification-write-response lifetime,
    so shifts wait for an active position read to finish.
- 2026-09-03: Writing AutoDownShift target gear 5 was accepted by the Gear. The
    native app first read and preserved all 138 settings bytes, then sent command
    1 with AutoDownShift enabled, target gear 5, and start gear 5. The Gear
    returned a valid command `0x81` acknowledgement for table 111 with result 0.
    A later reconnect read target gear 5, confirming persistence. Subsequent
    target writes to gears 7, 4, and 2 also returned result 0; reconnects read
    target gear 2 successfully.
- 2026-09-03: AutoDownShift disable and enable writes each used a
    read-preserve-write sequence and received command `0x81`, table 111,
    result-0 acknowledgements. The final enabled state persisted across later
    reconnects. Persistence of the intermediate disabled state was not tested.
- 2026-09-03: Trigger `TSW001` with firmware `T00.32.04_3x3` connected after one
    timed-out attempt and exposed 72 GATT characteristics. Standard reads
    returned serial `HSTT00000000DF`, software version `T00.32.04_3x3`, and
    Battery Level `96%`. It exposed TRP Authentication and Shift services but no
    Gear Diagnostics service, so Trigger TIF battery and table-113 behavior were
    not exercised.
- 2026-09-03: Authenticated Gear firmware `1.8.6` returned the complete
    137-byte BLE parameter table 106 with paired Trigger MAC
    `D2:B4:7F:B8:0A:25`. The native unpair operation preserved the table, zeroed
    MAC bytes 0-5, set address type byte 7 to 0, and received a result-0 write
    acknowledgement. Readback, a subsequent reconnect, and a Gear reboot all
    returned a zero MAC, confirming that unpairing persisted.

For every test, add an entry with:

| Field | Required value |
| --- | --- |
| Date | Test date |
| Device type | Gear or Trigger |
| Device identifier | Non-secret label or CoreBluetooth UUID |
| Firmware | Application and bootloader versions |
| Operation | Read/write/notify and command name |
| Request | Complete frame as hexadecimal bytes |
| Response | Complete frame as hexadecimal bytes |
| Result | Parsed value and comparison with the official tool |

## Update Rules

When new protocol behavior is found:

1. Add the raw evidence before documenting an interpretation.
2. Mark whether it is bundle-confirmed, hardware-confirmed, inferred, or unknown.
3. Record the tested device type and firmware version.
4. Add or update a Swift test using captured bytes whenever framing or parsing changes.
5. Do not document passwords, authentication hashes, device secrets, or firmware binaries here.