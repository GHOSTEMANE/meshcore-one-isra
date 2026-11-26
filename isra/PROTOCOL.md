# isra companion protocol extensions (revision 2)

Shared by the firmware fork (MeshCore Solo + isra, "isra4") and the app fork
(MeshCore One + isra, "MC1 isra"). The same file is kept in both repositories:
`docs/isra-protocol.md` in the firmware, `isra/PROTOCOL.md` in the app. Any change
here bumps the revision and lands in both.

Rules for everything below:

- One private opcode, **0xE1** (`CMD_ISRA`), with a sub-op byte. Stock firmware
  answers `RESP_CODE_ERR` + `ERR_CODE_UNSUPPORTED_CMD` (1): the app then keeps every
  isra feature off and behaves exactly like upstream MeshCore One.
- Replies and pushes from the firmware use the code **0xE1** too, followed by the
  sub-op byte (Solo does the same with 0x7D / 0x7E). The firmware sends a 0xE1
  frame, or any frame listed under "only after the cap", **only to a host that
  set the matching cap on that link**. A stock app never sees them.
- Little-endian integers. Latitude/longitude are degrees x 1e6 (as cmd 14).
- Caps are kept **per link** (BLE, USB). On BLE they are cleared only when the
  link disconnects: apps send `CMD_APP_START` and `CMD_DEVICE_QUERY` again
  mid-session (after settings writes, refreshes), so neither clears them. USB has no
  disconnect event: there `CMD_APP_START` clears them (a new session starts), so a
  host on a non-BLE link sends HELLO again after every `CMD_APP_START`.

## 0xE1 / 0x00  HELLO (host caps <-> firmware caps)

Host -> firmware:

```
[0] 0xE1
[1] 0x00
[2..5] host caps (u32)
         bit 0  SENT_MSGS   the host understands SENT_DM / SENT_CHANNEL / SENT_STATUS (section 3)
         bit 1  PHONE_POS   the host answers position requests (section 2)
         others 0
```

Firmware -> host (reply):

```
[0] 0xE1
[1] 0x00
[2..5] firmware caps (u32), same bits: what this firmware can do
[6]    protocol revision (2)
[7]    device state flags (u8)
         bit 0  phone_loc setting ("Phone pos") is on
         bit 1  GPS master is on
         bit 2  GPS duty cycle (GPS pwr) is on
```

The app sends HELLO after `CMD_APP_START` on every connection, before its first
`CMD_SYNC_NEXT_MESSAGE`. The caps in effect are `host & firmware`.

## 1. (reserved)

## 2. Phone position for telemetry

### 0xE1 / 0x01  PHONE_POS  (host -> firmware)

```
[0] 0xE1
[1] 0x01
[2..5]   lat  (i32, deg x 1e6)
[6..9]   lon  (i32, deg x 1e6)
[10..13] alt  (i32, millimetres above mean sea level)
[14]     flags (u8)  bit 0 = altitude valid
[15..16] horizontal accuracy (u16, metres; 0xFFFF = unknown)
[17..18] age of the fix when sent (u16, seconds)
```

Reply: `RESP_CODE_OK`, or `RESP_CODE_ERR` with
- `ERR_CODE_BAD_STATE` (4): "Phone pos" off, GPS master off, or the GPS duty cycle off
  (the phone position only replaces a sleeping GPS);
- `ERR_CODE_ILLEGAL_ARG` (6): 0,0, out of range, accuracy worse than 1000 m, or
  age over 600 s.

Firmware rules:
- RAM only. Never written to flash, never to `sensors.node_lat/lon`, never in an
  advert, SELF_INFO or anything but the telemetry answer.
- Stored with its fix time = now - age.
- Valid for the same window as a GPS fix: 2 x GPS interval + 2 min (32 min at 15 min).
  After the BLE link drops: one GPS cycle + 1 min from the fix time, and the GPS
  wakes at once; a GPS fix then wins as the newer one.
- While a valid phone position exists and the link is up, the GPS does not wake
  on its schedule (as isra3).
- Telemetry answers the newer of the valid GPS fix and the valid phone position,
  with altitude only if valid (else 0). Permissions are the usual ones
  (`telemetry.loc` and the contact's location bit).
- Accepted from any link (it is harmless: RAM only, telemetry only).

### 0xE1 / 0x10  POSITION REQUEST  (firmware -> host, push; only after cap PHONE_POS)

```
[0] 0xE1
[1] 0x10
```

The firmware pushes it on the BLE link of a host with the cap when all hold:
"Phone pos" on, GPS master on, GPS duty cycle on, and either no valid phone
position or its age >= one GPS interval. At most once per 60 s. Also once right
after a HELLO that sets the cap. The notification wakes a suspended iOS app
(bluetooth-central), which answers with PHONE_POS (or nothing, if it has no fix;
the position then expires and the GPS takes over).

## 3. Messages sent from the device (spec: protocolo-mensagens-do-aparelho.md)

Revision 2 moves the three frames under 0xE1, so they can never collide with
response codes upstream MeshCore allocates later (30, 31, 32 are its next free
ones). Each frame is the draft's frame 30 / 31 / 32 with its first byte replaced by
the two bytes `0xE1, sub-op`; every later offset moves by one:

```
0xE1 / 0x20  SENT_DM       (draft frame 30)
[0] 0xE1 [1] 0x20
[2] status (0 sent / awaiting ack, 1 delivered, 2 retrying, 3 failed)
[3] attempt (0-3)   [4] reserved 0
[5..10]  recipient pubkey prefix (6)
[11]     path_len used, or 0xFF
[12]     txt_type
[13..16] sender timestamp (u32)
[17..]   text (UTF-8)

0xE1 / 0x21  SENT_CHANNEL  (draft frame 31)
[0] 0xE1 [1] 0x21
[2..4]   reserved 0
[5]      channel index
[6]      path_len (0xFF)
[7]      txt_type
[8..11]  sender timestamp (u32)
[12..]   text (UTF-8), the body only, without "name: "

0xE1 / 0x22  SENT_STATUS   (draft frame 32)
[0] 0xE1 [1] 0x22
[2..7]   recipient pubkey prefix (6)
[8..11]  sender timestamp (u32)
[12]     status: 1 delivered, 2 retrying, 3 failed
[13]     attempt (0-3)
[14..17] round trip ms (delivered), else 0
```

They are delivered through the offline queue (`PUSH_CODE_MSG_WAITING` ->
`CMD_SYNC_NEXT_MESSAGE`) like any queued message. Changes from the draft:

- The cap is bit 0 of HELLO (not a separate command 67).
- While a SENT_DM is still in the queue, a status change rewrites its bytes
  [2] and [3] instead of queuing a SENT_STATUS.
- The firmware queues SENT_DM / SENT_CHANNEL always. At `CMD_SYNC_NEXT_MESSAGE`,
  for a host without the cap, they are converted to the ordinary received frame
  (16 / 17 when the host's `app_target_ver` >= 3, else 7 / 8) with the
  " · enviada pelo Wio" tag (the isra2 mirror), and a SENT_STATUS is skipped.
- Queue pressure: when the queue is full, the oldest device-sent entry
  (SENT_DM / SENT_CHANNEL / SENT_STATUS) is evicted first, then the oldest channel
  message; a SENT_STATUS never evicts anything (it is dropped instead).
- Device-sent DMs use `getCurrentTimeUnique()`.
- Live: when a device-sent DM is acked and a host with the cap is connected, the
  firmware also pushes `PUSH_CODE_SEND_CONFIRMED` (0x82) with the ack code and
  round trip, as for host-sent DMs. Device-sent DMs are not added to
  `expected_ack_table` (the UI already matches their acks).

## Versioning

- Firmware caps and the revision come from HELLO; the app gates each feature on its
  bit, never on a version string.
- A new field is only appended; a changed meaning needs a new revision.
