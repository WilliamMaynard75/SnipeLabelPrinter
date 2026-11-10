# Snipe-IT Label Printer

A small macOS app that prints Snipe-IT asset label PDFs to a Brother PT-P700 over USB,
without going through the macOS print system or Brother's drivers.

## What it does

- Search Snipe-IT by asset name or tag and click a result to fetch its label, or press Return
  for an exact match. Scanning a label's QR code, or a comma-separated list, works too.
  Labels come from Snipe-IT's own label API, so they use the template configured there.
- Or drag in Snipe-IT label PDFs (or click **Add…**). Multi-page PDFs become one label per page.
- Each PDF is rendered at 600 dpi, cropped to its content, scaled to the 128-dot print head
  (24 mm tape) and converted to 1-bit black and white. The preview shows exactly what will print.
- All queued labels print as one strip, so the printer's ~2 cm lead-in is only fed once.
  Copies, the gap between labels, and a dashed cut line are adjustable.
- "Blank tape at end" (default 20 mm) adds blank tape after the last label to match the lead-in,
  so the label is centered on the cut piece, the same as Brother's Windows software.

## Requirements

- macOS 14 or later
- Brother PT-P700 on USB with Editor Lite mode **off** (green PLite light off)
- For fetching from Snipe-IT: a personal API key (Snipe-IT → your name → Manage API Keys),
  from an account that can view assets. Paste it in the app's Settings (⌘,); it's stored in the Keychain.

## Build

```sh
./make-app.sh        # builds "Snipe-IT Label Printer.app" in this folder
```

Or open `Package.swift` in Xcode and run.

## Command-line modes

```sh
SnipeLabelPrinter --render label.pdf out.png   # save the 1-bit image that would print
SnipeLabelPrinter --status                     # show the printer's status
SnipeLabelPrinter --print a.pdf b.pdf          # print labels as one job
SnipeLabelPrinter --tag 90167 out.png          # fetch a label from Snipe-IT by tag or name
```

## Credits

- USB code (`Sources/CLibUSB`) is libusb (LGPL-2.1), as bundled in David Phillip Oster's macOS port
  of [ptouch-print](https://github.com/clarkewd/ptouch-print/).
- The printer command sequence follows Dominic Radermacher's ptouch-print.
