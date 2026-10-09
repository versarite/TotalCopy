# TotalCopy
## Educational project - written with Claude/Opus5.5 support

TotalCopy is a small Windows helper for [Total Commander](https://www.ghisler.com/).
It retrieves the full path and file name of the item under the cursor in Total
Commander's active panel, or the items under the cursors in both panels, and
either copies the result to the clipboard or launches an external comparison
tool with the file path(s).
I found it useful to have a button in TC that sends files under the cursor 
in BOTH panels for comparison to WinMerge , even if they are located inside zip 
archives.TC has an internal function to copy path/name strings to the clipboard, 
but not for both panels at the same time. 

## Features

- Copy the full path and file name of the item under the cursor in the active panel.
- Optionally retrieve items from both the left and right panels.
- Launch an external program such as [WinMerge](https://winmerge.org/) with the file path(s).
- Supports files inside ZIP archives in comparison mode by extracting the relevant
  item(s) to a temporary directory.
- Handles Unicode paths and file names.
- Runs without opening a console window.

## Requirements

- Microsoft Windows.
- Total Commander must be running.
- For comparison mode, an external program such as WinMerge.

## Usage

Run `TC_query.exe` from Total Commander, typically by configuring it as a user
command or button.

### Copy a path to the clipboard

Run with no arguments. TotalCopy places the full path and file name of the item
under the cursor in the active panel on the clipboard. This is similar to Total
Commander's built-in **Copy names with path to clipboard** command.

### Launch a comparison tool

Use `-b -x` followed by the full path to the comparison program. With `-b`, the
program receives two arguments: the full paths of the items under the cursors in
the left and right panels.

Example:

```text
TC_query.exe -b -x C:\Program Files\WinMerge\WinMergeU.exe
```

The `-x` option must be last. Everything after `-x` is treated as the comparison
program path, so quotes around a path containing spaces are not required. In
comparison mode, TotalCopy launches the program and leaves the clipboard
unchanged.

Without `-b`, `-x` launches the specified program with the item under the cursor
in the active panel as its single argument.

### Options

| Option | Description |
| --- | --- |
| *(none)* | Copy the full path and file name of the item under the cursor in the active panel to the clipboard. |
| `-b` | Use the items under the cursors in both panels. Without `-x`, copies the two paths on separate lines. With `-x`, passes both paths as arguments to the external program. |
| `-x <program path>` | Launch the specified program with the path argument(s) instead of writing to the clipboard. Must be the final option. |
| `-s` | Suppress the success beep. |
| `-d` | Write diagnostic information to a `.log` file beside the executable. |

### ZIP archive handling

When `-x` is used with an item inside a ZIP archive, TotalCopy extracts the relevant
item to `%TEMP%\TC_query` and passes the extracted path to the comparison program.
Temporary files from a previous run are cleaned up at the next comparison-mode run.
Other archive formats are not supported by this feature.

## Building from source

1. Install [Lazarus](https://www.lazarus-ide.org/) and Free Pascal for Windows.
2. Open `TC_query.lpi` in Lazarus.
3. Build the project for the Windows 64-bit target (`x86_64-win64`) to match the
   supplied executable.

The project uses `TC_query.lpr` as its program source and includes resource files
and icon assets. The `.res` resource files are retained because the source refers
to them directly. Build output and Lazarus session files are excluded from the
repository.

The original project identifier (`TC_query`) is retained in the source/project
filenames to avoid unnecessary project and resource renaming.

## Exit codes

| Code | Meaning |
| ---: | --- |
| `0` | Success |
| `1` | Total Commander is not running |
| `2` | No path received from Total Commander |
| `3` | Clipboard error |
| `4` | Another instance is already running |
| `5` | Watchdog timeout |
| `6` | No usable file name was returned; the folder path may have been used |
| `7` | The program specified by `-x` could not be started |
| `8` | An item inside a ZIP archive could not be extracted |

## License

TotalCopy is distributed under the GNU General Public License, version 3.
See [`LICENSE`](LICENSE) for the complete license text.

##  Copyright (C) 2026 [DL1BWA/KD1AEV]

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
  See the GNU General Public License for more details.

