# Canon UFR II LT job format (MF4700 series)

Reverse-engineered from Canon's own macOS driver (*MF Printer Driver & Utilities
for Mac V10.11.13*, `CNPZBMF4700ZB.ppd`, filter `xdclfilter`) by running it
unmodified on test pages and diffing its output. `rastertoufr2lt` reproduces
that output **byte for byte**. `make test` checks 16 reference jobs: blank, solid,
text and graphics, full-page noise, multi-page, 8 paper sizes, 1200×600 dpi, and
copies. Only the timestamp, the total-size field and Canon's empty flush packets
differ, by design.

The device identifies itself as `Canon MF4700 Series /P` (SNMP sysDescr), with
interpreter `UFRII` (Printer-MIB prtInterpreterLangFamily). Canon's internal name for
this PDL is "BDL". In Japan the same engine speaks CARPS2.

## 1. Transport

Raw TCP port 9100 (LPD on 515 also works). The printer never replies on the
data connection. Empty connections are ignored, with no blank pages.

## 2. CPCA framing

The whole job is a sequence of CPCA packets, each with a 20-byte header:

| off | size | value |
|----:|-----:|-------|
| 0 | 2 | `CD CA` magic |
| 2 | 1 | `10` (version) |
| 3 | 1 | kind: `00` control, `02` data |
| 4 | 2 | opcode, big-endian |
| 6 | 2 | `00 01` |
| 8 | 2 | payload length, big-endian |
| 10 | 2 | `FF FF` |
| 12 | 8 | zero |

Opcodes form a Job ⊃ Binder ⊃ Document hierarchy:

| op | meaning | payload |
|----|---------|---------|
| `6B` | job start | TLV list, below |
| `12` | set job attribute | attr id (u16) + value |
| `13` | job end | `00` |
| `14` | binder start | `00 00 00 00` |
| `15` | set binder attribute | attr id + value |
| `16` | binder end | — |
| `17` | document start | `00 00 00 00` |
| `18` | set document attribute | attr id + value |
| `19` | document end | — |
| `1A` | data | kind `02`: `01` + PDL bytes; kind `00` with payload `01` = end of data |

### Packet sequence (Canon's driver, A4, 1 copy)

```
6B  job start (TLV)
12  07D7 0001                       job copies = 1
14  00000000                        binder start
15  08B3 02
15  082B <str ≤32>                  job name
15  07D7 <u16 copies>               copies (uncollated)
15  07D8 0F
15  07D9 17 00000000
15  084A 04
15  07DA 00
15  08A5 FEFEFFFE 00×8 03
17  00000000                        document start
18  002E 83 0000
18  08B5 02
18  086E 010B 0000
18  07ED 03 FE 00 <paper> 00×8 03   paper: media type, source (FE = auto), 00, size (table below)
18  07D7 0001
18  07DF 01
18  07E0 04
18  07E1 00000000
18  003A 08 <u16 xdpi> <u16 ydpi>    resolution: 600×600 or 1200×600
18  0972 00                         01 00 01 = barcode mode, 01 00 03 = white-gap mode
18  0971 <mode>                     "reduce blurring/smudging": 0=Off … 2=Standard … 4
1A* data packets (PDL)
1A  01 (kind 00)                    end of data
19                                  document end
15  0113 <u32 impressions>          pages × copies
16                                  binder end
12  0113 <u32 impressions>
12  07D6 <u32 total job bytes>      size of the whole stream, including this packet and the next
13  00                              job end
```

Collated multi-copy jobs are sent by Canon's driver as N complete jobs.
Uncollated copies use `07D7`. Toner-save produces no attribute: it is applied in
rendering.

The first byte of `07ED` is the media type, which the printer matches against its
sources' paper settings: Plain `03` (the default), Plain L `0A`, Recycled `0B`,
Color `0C`, Heavy 1 `1A`, Envelope `06`. With Canon's "select by paper source" mode
(not offered for this model) it is `FE`. The second byte is the paper source; the
MF4700 driver always sends `FE`, automatic. The printer then feeds from the manual
slot whenever it senses a sheet there. If that slot's guides are not snug
against the paper, the printer reports a paper size mismatch, even for an A4 job
with A4 loaded.

### Job start TLV (`6B`)

`u16 count`, then `count` entries of `u16 id, u16 len, value`:

| id | value |
|----|-------|
| `00F0` | `01` |
| `0130` | `03 00 00` |
| `0004` | string: job name (max 32 bytes) |
| `0117` | string: document name (max 255 bytes) |
| `0006` | string: user's full name (omitted when unknown, count drops by 1) |
| `000D` | `04` |
| `0118` | 64 bytes: 16-byte driver id `8BF23A27 2E1E44D4 B21F5732 97D793AB` (a constant in Canon's `libcoral.dylib`), 16 zero bytes, then the host name twice in 16-byte NUL-padded fields (max 15 chars) |
| `000C` | `32` |
| `0009` | timestamp (UTC): `u32 (year<<20 \| month<<16 \| day<<11 \| weekday<<8)`, `u8 hour`, `u8 minute`, `u16 second×1000+ms` |

Strings are `u16 charset (0004 = ISO-8859-1 MIBenum), u8 length, bytes`. Canon
converts to Windows-1252 and replaces anything unmappable with `?`.

## 3. Data packets

Each data packet payload is `01` followed by at most 4075 PDL bytes, so a packet
is at most 4096 bytes. Canon flushes a packet group at these points: session + paper
+ first page header; each band (the first band of a page also carries "begin
image"); end page; end session. Bands larger than 4075 bytes continue in further
packets. Canon's writer also emits empty (`01`-only) packets on internal flushes;
they carry nothing.

## 4. Page description language

A compact tagged binary stream:

* `00–7F` at top level: **operator**.
* `C0–FF`: **attribute tag**, followed by either
  * an immediate value `00–7F`, or
  * a type byte `80–BF` plus value bytes. Bit 5 = signed, bits 2–3 = element size
    (1, 2, 4 bytes), bits 0–1 = element count − 1. Seen: `80` u8, `84` u16,
    `85` u16×2, `A0` s8, `A1` s8×2, `A4` s16, `A5` s16×2, `A8` s32.
* `9C`/`9D`/`9E`: **data block** with a 1/2/4-byte big-endian length.

Operators take the attributes that follow them:

| op | meaning | attributes (as Canon writes them) |
|----|---------|-------------|
| `01` | begin session | `C1 85 1000 1081`, `C2 00`, `D8 84 0258` (600), `DD 80 C8`, `F0 84 0800` |
| `02` | begin paper group | `C3 <paper>`, `C5 00`, `C6 00` (custom size: `C3 7F` + `F1 81 ww hh`) |
| `51` | — | `F2 00` |
| `03` | begin page | `E7 85 <w> <h>` page bitmap size, `DE 80 00`, `C8 00`, `CA A1 00 00`, `CB 00` |
| `61` | begin image | `E6 80 <m>` horizontal multiplier (1 = 600 dpi, 2 = 1200 dpi), `E5 00` |
| `62` | band | `E3 85 <w> <lines>`, `E8 A1/A5 <x> <y>` band origin, `E1 05` (JBIG), `D7 <len>`, then data block |
| `13` | end page | — |
| `12` | end paper group | — |
| `11` | end session | — |

A job is `01 02 51 03 61 62… 13 [03 61 62… 13]… 12 11`. Size and length
attributes always use the smallest signed type that fits (`E8 A1 00 00` for the
first band, `A5` afterwards; `D7 A0/A4/A8`; blocks `9C/9D/9E`).

### Bands: JBIG1

Each page is a 1-bit image (1 = black), width `w × m`, height `h`, cut into
**256-line bands**. Each band is an **independent** JBIG1 (ITU-T T.82) encoding:

* BIH: `DL=0 D=0 P=1`, `L0=128`, `MX=0 MY=0`, order `00`, options `48`
  (`LRLTWO | TPBON`).
* The first band of a page carries the 20-byte BIH, with `YD` = page height.
  Other bands carry only stripe data.
* Each band's last stripe ends with **SDRST** (`FF 03`) instead of SDNORM.

Stock jbigkit (`jbg_enc_options(.., 0, JBG_LRLTWO|JBG_TPBON, 128, 0, 0)`, one
encoder per band, final `FF 02` patched to `FF 03`) is bit-identical to Canon.

## 5. Paper sizes

| PPD name | PWG | CPCA `07ED` | PDL `C3` | bitmap @600 dpi |
|---|---|---|---|---|
| A4 | iso_a4_210x297mm | 02 | 00 | 4958 × 7016 |
| Letter | na_letter_8.5x11in | 0D | 64 | 5100 × 6600 |
| Legal | na_legal_8.5x14in | 0C | 66 | 5100 × 8400 |
| A5 | iso_a5_148x210mm | 03 | 02 | 3499 × 4958 |
| B5 (JIS) | jis_b5_182x257mm | 07 | 0B | 4299 × 6074 |
| Executive | na_executive_7.25x10.5in | 0A | 65 | 4350 × 6300 |
| Statement | na_invoice_5.5x8.5in | 3C | 6B | 3300 × 5100 |
| Postcard | jpn_hagaki_100x148mm | 0E | 14 | 2358 × 3499 |
| Reply postcard | jpn_oufuku_148x200mm | 0F | 15 | 3499 × 4724 |
| 4-on-1 postcard | 200x297mm | 37 | 16 | 4724 × 7016 |
| Env. Nagagata 3 | jpn_chou3_120x235mm | C1 | 22 | 2833 × 5550 |
| Env. Yougata-Naga 3 | 120x235mm | D5 | 28 | 2833 × 5550 |
| Env. Monarch | na_monarch_3.875x7.5in | 17 | 24 | 2316 × 4491 |
| Env. #10 | na_number-10_4.125x9.5in | 16 | 23 | 2483 × 5691 |
| Env. DL | iso_dl_110x220mm | 18 | 27 | 2599 × 5199 |
| Env. C5 | iso_c5_162x229mm | 15 | 25 | 3824 × 5408 |
| Index card | na_index-3x5_3x5in | 40 | 73 | 1800 × 3000 |
| Oficio | 216x318mm | 3E | 71 | 5100 × 7508 |
| Brazil Oficio | 216x356mm | CC | 60 | 5100 × 8383 |
| Mexico Oficio | 216x341mm | D2 | 62 | 5100 × 8058 |
| Gov. Letter | 203x267mm | D0 | 5A | 4791 × 6308 |
| Gov. Legal | na_govt-legal_8x13in | D1 | 5C | 4791 × 7791 |
| 16K | 195x270mm | D4 | 78 | 4608 × 6374 |
| Foolscap | na_foolscap_8.5x13in | 3D | 70 | 5100 × 7791 |
| Australian Foolscap | 206x337mm | CA | 63 | 4866 × 7958 |

Hardware margins are 5 mm on every side, but the bitmap covers the full sheet.

## 6. Halftoning (Canon's, for reference)

Canon screens gray with a 45° clustered dot, 8-pixel period (~106 lpi at
600 dpi, two dots per 8×8 tile). Its tone curve compensates strongly for dot gain:

| input gray (ink) | 10% | 25% | 50% | 75% | 90% |
|---|---|---|---|---|---|
| dot coverage | 3.9% | 7.0% | 19.5% | 46.9% | 75.0% |

`rastertoufr2lt` uses the same screen geometry and curve.

## Appendix: MFNP Notify (SCAN → Computer)

Taken from Canon's MF Toolbox for Mac (`Canon MF Scan Agent`, `ProtocolMFNP`
in ProtocolModule.framework). The packets use the 16-byte MFNP header
(`MFNP`, 0x02, command 0x32, status, sequence, session, payload length).
All integers are big-endian.

Request payload:

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | type: 0 inquire, 1 register, 2 polling, 3 update, 4 cancel, 5 polling ack |
| 2 | 2 | 0 |
| 4 | 4 | timestamp from the register reply (0 for inquire/register) |
| 8 | 64 | computer name, **8-bit**, NUL padded (Canon: `gethostname()`) |
| 72 | 4 | interrupt data length (0) |
| 76 | 4 | application info length |
| 80 | n | application info |

* Polling sends the local time `YYYYMMDDhhmmss` as 16 bytes of application info.
* Register sends the name shown on the panel (UTF-8, 193 bytes), a u16 button
  count, and per button u8 key id, u8 colour mode (1 black & white, 3 gray,
  4 colour, 5 colour document) and 121 bytes of UTF-8 name (8 characters, then a
  comment).
* Canon sends inquire then register, polls every 4 s (6 s after throttling or an
  event), and acks events with type 5.

Reply payload: u16 0, u16 status (0 ok, 1 rejected: register again, 2 info,
3 throttling, 0x8000 event), u32 timestamp, u32 interrupt data length, u32 event
id, u8 key id, u32 application info length. On the MF4700 series the key id is
the panel's scan type: 1 Color Scan, 2 B&W Scan, 3 Custom 1, 4 Custom 2.

The job details that open a scan session (UDP 0x10, Canon's SessionStart) are u32
retry count, u32 timestamp, then 8-bit computer name [64], user name [64] and
document name [256]. SANE's pixma backend writes these strings, and the Notify
computer name, as UTF-16BE. The MF reads the first byte as NUL, so the panel
shows an empty name.

