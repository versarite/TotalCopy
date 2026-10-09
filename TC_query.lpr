program TC_query;

{ Helper for Total Commander: asks the running TC (in the background, no window)
  for the path and the name of the item under the cursor - regardless of any
  selection - puts "path\filename" on the Windows clipboard and exits immediately.

  Usage:  TC_query.exe [-s] [-d] [-b] [-x program]
            -s         = silent (no beep)
            -d         = debug: write TC's answers to TC_query.log next to the exe
            -b         = both panels: left item and right item (two lines on the clipboard)
            -x program = don't use the clipboard, start "program" with the file
                         (with -b: with both files, e.g. -b -x WinMergeU.exe)
                         -x must be the last option; no quotes needed, even
                         with spaces: -x C:\Program Files\WinMerge\WinMergeU.exe
  Exit codes: 0 = ok, 1 = TC not running, 2 = no path from TC,
              3 = clipboard error, 4 = another instance is running,
              5 = watchdog (took too long), 6 = no file name (only path used),
              7 = program from -x could not be started,
              8 = file inside an archive could not be unpacked
  Files inside ZIP archives: with -x they are unpacked to %TEMP%\TC_query
  first (cleaned up on the next -x run). Other archive types are not supported. }

{$mode objfpc}{$H+}
{$apptype GUI}   // no console window

uses
  Windows, Messages, SysUtils, Classes, ShellApi, Zipper;

{$R *.res}               // project resources: main icon TC_query.ico (icon index 0)
{$R TC_query_icons.res}  // extra button icons: 1 = compare (two clipboards),
                         //   2 = open (-x), 3 = diff (two pages, alternative for -b -x)

const
  TC_REQUEST_W = Ord('G') + 256 * Ord('W');  // ask for UTF-16 answers
  REPLY_TIMEOUT_MS = 1000;
  HWND_MSG_ONLY = HWND(-3);                   // = HWND_MESSAGE
  WATCHDOG_MS = 3000;                         // hard limit for talking to TC
  WATCHDOG_UNZIP_MS = 120000;                 // more time while unpacking from a ZIP

var
  GHiddenWnd: HWND = 0;
  GReply: UnicodeString = '';
  GGotReply: Boolean = False;
  GDebug: Boolean = False;
  GDeadline: QWord = 0;                       // watchdog kills the process after this

procedure DebugLog(const S: string);
var
  F: TextFile;
  FN: string;
begin
  if not GDebug then Exit;
  FN := ChangeFileExt(ParamStr(0), '.log');
  AssignFile(F, FN);
  {$I-}
  if FileExists(FN) then Append(F) else Rewrite(F);
  {$I+}
  if IOResult <> 0 then Exit;
  WriteLn(F, FormatDateTime('hh:nn:ss.zzz', Now), '  ', S);
  CloseFile(F);
end;

// Safety net: whatever happens, the process is gone after GDeadline
function WatchdogThread(P: Pointer): PtrInt;
begin
  repeat
    Sleep(100);
  until GetTickCount64 > GDeadline;
  ExitProcess(5);
  Result := 0;
end;

// Receives TC's answer. TC sends it back with WM_COPYDATA to the window
// handle we passed in wParam, usually while our SendMessage is still running.
function ReceiverWndProc(Wnd: HWND; Msg: UINT; WP: WPARAM; LP: LPARAM): LRESULT; stdcall;
var
  CDS: PCopyDataStruct;
  A: AnsiString;
begin
  if Msg = WM_COPYDATA then
  begin
    CDS := PCopyDataStruct(LP);
    // Any answer from TC starts with 'R'; 'RW' = UTF-16, otherwise ANSI
    if (CDS <> nil) and ((CDS^.dwData and $FF) = Ord('R')) then
    begin
      if (CDS^.dwData shr 8) = Ord('W') then
      begin
        SetLength(GReply, CDS^.cbData div SizeOf(WideChar));
        if Length(GReply) > 0 then
          Move(CDS^.lpData^, GReply[1], Length(GReply) * SizeOf(WideChar));
      end
      else
      begin
        SetLength(A, CDS^.cbData);
        if Length(A) > 0 then
          Move(CDS^.lpData^, A[1], Length(A));
        GReply := UnicodeString(A);
      end;
      // cut at the first #0
      if Pos(#0, GReply) > 0 then
        SetLength(GReply, Pos(#0, GReply) - 1);
      GGotReply := True;
      Result := 1;
      Exit;
    end;
  end;
  Result := DefWindowProcW(Wnd, Msg, WP, LP);
end;

function CreateReceiverWindow: HWND;
const
  ClassName: PWideChar = 'TCQueryReceiverClass';
var
  WC: TWndClassW;
begin
  Result := 0;
  FillChar(WC, SizeOf(WC), 0);
  WC.lpfnWndProc := @ReceiverWndProc;
  WC.hInstance := HInstance;
  WC.lpszClassName := ClassName;
  if RegisterClassW(WC) = 0 then
    Exit;
  // Message-only window: never visible, never in the taskbar
  Result := CreateWindowExW(0, ClassName, 'TCQueryReceiver', 0,
    0, 0, 0, 0, HWND_MSG_ONLY, 0, HInstance, nil);
end;

// Sends one query (e.g. 'SP', 'SN') and waits briefly for the answer.
function QueryTC(TCWnd: HWND; const Cmd: AnsiString): UnicodeString;
var
  CDS: TCopyDataStruct;
  Buf: AnsiString;
  StartTick: QWord;
  Msg: TMsg;
begin
  GReply := '';
  GGotReply := False;

  // The command itself is a plain ANSI string, even when asking for UTF-16 answers
  Buf := Cmd + #0;
  CDS.dwData := TC_REQUEST_W;
  CDS.cbData := Length(Buf);
  CDS.lpData := PAnsiChar(Buf);

  SendMessageW(TCWnd, WM_COPYDATA, WPARAM(GHiddenWnd), LPARAM(@CDS));

  // Normally the reply has already arrived; if not, pump messages a little while
  StartTick := GetTickCount64;
  while (not GGotReply) and (GetTickCount64 - StartTick < REPLY_TIMEOUT_MS) do
  begin
    while PeekMessageW(Msg, 0, 0, 0, PM_REMOVE) do
    begin
      TranslateMessage(Msg);
      DispatchMessageW(Msg);
    end;
    if not GGotReply then
      Sleep(5);
  end;

  Result := Trim(GReply);
  if GGotReply then
    DebugLog(Cmd + ' -> "' + UTF8Encode(Result) + '"')
  else
    DebugLog(Cmd + ' -> no reply');
end;

// First non-empty answer from a list of queries
function QueryFirst(TCWnd: HWND; const Cmds: array of AnsiString): UnicodeString;
var
  I: Integer;
begin
  Result := '';
  for I := Low(Cmds) to High(Cmds) do
  begin
    Result := QueryTC(TCWnd, Cmds[I]);
    if Result <> '' then
      Exit;
  end;
end;

// Puts Unicode text on the clipboard with plain Win32 calls
function SetClipboardTextW(const S: UnicodeString): Boolean;
var
  H: HGLOBAL;
  P: Pointer;
  Size: PtrUInt;
  Tries: Integer;
begin
  Result := False;
  Size := (Length(S) + 1) * SizeOf(WideChar);
  H := GlobalAlloc(GMEM_MOVEABLE, Size);
  if H = 0 then Exit;
  P := GlobalLock(H);
  Move(PWideChar(S)^, P^, Size);
  GlobalUnlock(H);

  // Another program may hold the clipboard for a moment - retry briefly
  for Tries := 1 to 20 do
  begin
    if OpenClipboard(GHiddenWnd) then
    begin
      EmptyClipboard;
      Result := SetClipboardData(CF_UNICODETEXT, H) <> 0;
      CloseClipboard;
      Break;
    end;
    Sleep(10);
  end;

  if not Result then
    GlobalFree(H);   // only free it if the clipboard did not take ownership
end;

// Builds "path\name" from TC's answers.
// Returns 0 = ok, 2 = no path, 6 = no name (Full is then just the folder)
function GetItem(TCWnd: HWND; const PathCmds, NameCmds: array of AnsiString;
  out Full: UnicodeString): Integer;
var
  Path, Name, Dir: UnicodeString;
begin
  Result := 0;
  Full := '';
  Path := QueryFirst(TCWnd, PathCmds);
  if Path = '' then
    Exit(2);
  Name := QueryFirst(TCWnd, NameCmds);

  if Path[Length(Path)] <> '\' then
    Path := Path + '\';

  if (Name = '') or (Name = '..') then
  begin
    Full := Path;                          // nothing usable under the cursor
    if Name = '' then
      Result := 6;
  end
  else if ((Length(Name) > 2) and (Name[2] = ':')) or (Copy(Name, 1, 2) = '\\') then
    Full := Name                           // TC already returned a full path
  else
  begin
    // Inside archives TC returns the name relative to the archive root
    // ("sub\file.txt") while the path already ends with "sub\".
    // Don't add that folder part twice.
    Dir := ExtractFilePath(Name);          // "sub\" or ''
    if (Dir <> '') and (Length(Path) >= Length(Dir)) and
       SameText(Copy(Path, Length(Path) - Length(Dir) + 1, Length(Dir)), Dir) then
      Full := Path + Copy(Name, Length(Dir) + 1, MaxInt)
    else
      Full := Path + Name;
  end;
end;

// Quotes one argument. A trailing backslash is doubled, otherwise "C:\dir\"
// would be read as an escaped quote by most programs.
function QuoteArg(const S: UnicodeString): UnicodeString;
begin
  if (S <> '') and (S[Length(S)] = '\') then
    Result := '"' + S + '\"'
  else
    Result := '"' + S + '"';
end;

// Starts Prog with the given (already quoted) parameters
function RunProgram(const Prog, Params: UnicodeString): Boolean;
begin
  DebugLog('Run: ' + UTF8Encode(Prog) + ' ' + UTF8Encode(Params));
  Result := ShellExecuteW(0, nil, PWideChar(Prog), PWideChar(Params),
    nil, SW_SHOWNORMAL) > 32;
end;

{ ---------- Files inside ZIP archives ----------
  Inside a ZIP, TC reports a "virtual" path like C:\x\archive.zip\sub\file.txt.
  That file does not exist on disk, so for -x we unpack it to
  %TEMP%\TC_query\<Tag>\ and pass the unpacked copy instead. }

function PathExistsW(const P: UnicodeString; out IsDir: Boolean): Boolean;
var
  Attr: DWORD;
begin
  Attr := GetFileAttributesW(PWideChar(P));
  Result := Attr <> INVALID_FILE_ATTRIBUTES;
  IsDir := Result and ((Attr and FILE_ATTRIBUTE_DIRECTORY) <> 0);
end;

// Splits C:\x\a.zip\sub\f.txt into Archive = C:\x\a.zip and Inner = sub\f.txt.
// Returns False if the path exists on disk (= not inside an archive).
function SplitArchivePath(const Full: UnicodeString;
  out Archive, Inner: UnicodeString): Boolean;
var
  P: UnicodeString;
  I: Integer;
  IsDir: Boolean;
begin
  Result := False;
  Archive := '';
  Inner := '';
  P := Full;
  while (Length(P) > 3) and (P[Length(P)] = '\') do
    SetLength(P, Length(P) - 1);
  if PathExistsW(P, IsDir) then
    Exit;                                  // a normal file or folder

  for I := 4 to Length(P) do
    if P[I] = '\' then
      if PathExistsW(Copy(P, 1, I - 1), IsDir) and not IsDir then
      begin
        Archive := Copy(P, 1, I - 1);      // first part that is a FILE
        Inner := Copy(P, I + 1, MaxInt);
        Exit(True);
      end;
end;

// Deletes a folder tree (errors ignored - files may still be open in a diff tool)
procedure DeleteTree(const Dir: string);
var
  SR: TSearchRec;
begin
  if FindFirst(Dir + '\*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      if (SR.Attr and faDirectory) <> 0 then
        DeleteTree(Dir + '\' + SR.Name)
      else
        DeleteFile(Dir + '\' + SR.Name);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
  RemoveDir(Dir);
end;

function TempBaseDir: string;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'TC_query';
end;

// If Path points into a ZIP: unpack it and replace Path with the path of the copy.
// Returns 0 = nothing to do or ok, 8 = could not unpack (Path unchanged).
function ResolveArchivePath(var Path: UnicodeString; const Tag: string): Integer;
var
  Full, Resolved: UnicodeString;
  ArchiveW, InnerW: UnicodeString;
  Inner, InnerZ: UTF8String;
  OutDir, EntryName: string;
  UnZ: TUnZipper;
  Names: TStringList;
  I: Integer;
  IsDir: Boolean;
begin
  Result := 0;
  Full := Path;
  if not SplitArchivePath(Full, ArchiveW, InnerW) then
    Exit;

  Inner := UTF8Encode(InnerW);
  while (Inner <> '') and (Inner[Length(Inner)] = '\') do
    SetLength(Inner, Length(Inner) - 1);
  InnerZ := StringReplace(Inner, '\', '/', [rfReplaceAll]);  // ZIP uses "/"
  OutDir := TempBaseDir + '\' + Tag;
  DebugLog('Archive: ' + UTF8Encode(ArchiveW) + '  entry: ' + Inner);

  GDeadline := GetTickCount64 + WATCHDOG_UNZIP_MS;   // unpacking may take a while
  ForceDirectories(OutDir);

  UnZ := TUnZipper.Create;
  Names := TStringList.Create;
  try
    try
      UnZ.FileName := UTF8Encode(ArchiveW);
      UnZ.OutputPath := OutDir;
      UnZ.Examine;
      for I := 0 to UnZ.Entries.Count - 1 do
      begin
        // some older ZIPs store "\" instead of "/"
        EntryName := StringReplace(UnZ.Entries[I].ArchiveFileName, '\', '/', [rfReplaceAll]);
        // the file itself, or everything below it if it is a folder
        if SameText(EntryName, InnerZ) or
           SameText(Copy(EntryName, 1, Length(InnerZ) + 1), InnerZ + '/') then
          Names.Add(UnZ.Entries[I].ArchiveFileName);
      end;
      if Names.Count = 0 then
      begin
        DebugLog('Entry not found in archive');
        Exit(8);
      end;
      UnZ.UnZipFiles(Names);
    except
      on E: Exception do
      begin
        DebugLog('Unzip error: ' + E.Message);
        Exit(8);
      end;
    end;
  finally
    Names.Free;
    UnZ.Free;
  end;

  // built as UnicodeString so non-ASCII names survive
  while (InnerW <> '') and (InnerW[Length(InnerW)] = '\') do
    SetLength(InnerW, Length(InnerW) - 1);
  Resolved := UnicodeString(OutDir) + '\' + InnerW;
  if not PathExistsW(Resolved, IsDir) then
  begin
    DebugLog('Unpacked file missing: ' + UTF8Encode(Resolved));
    Exit(8);
  end;
  DebugLog('Unpacked to: ' + UTF8Encode(Resolved));
  Path := Resolved;
end;

var
  TCWnd: HWND;
  Mutex: THandle;
  ThreadID: TThreadID;
  Side: UnicodeString;
  FullName, LeftName, RightName, Params: UnicodeString;
  RunProg: UnicodeString = '';
  Silent: Boolean = False;
  BothPanels: Boolean = False;
  ExitCode_: Integer = 0;
  R: Integer;
  I: Integer;
begin
  // Let all RTL file functions (FileExists, TFileStream in the unzipper, ...)
  // treat strings as UTF-8, so names with umlauts etc. work
  DefaultFileSystemCodePage := CP_UTF8;
  DefaultRTLFileSystemCodePage := CP_UTF8;

  I := 1;
  while I <= ParamCount do
  begin
    if SameText(ParamStr(I), '-s') then Silent := True
    else if SameText(ParamStr(I), '-d') then GDebug := True
    else if SameText(ParamStr(I), '-b') then BothPanels := True
    else if SameText(ParamStr(I), '-x') then
    begin
      // Everything after -x is the program, so paths with spaces need no quotes
      // (-x therefore has to be the last option)
      Inc(I);
      while I <= ParamCount do
      begin
        if RunProg <> '' then RunProg := RunProg + ' ';
        RunProg := RunProg + UnicodeString(ParamStr(I));
        Inc(I);
      end;
    end;
    Inc(I);
  end;

  // Only one instance at a time (e.g. hotkey pressed twice quickly)
  Mutex := CreateMutex(nil, True, 'Local\TC_query_single_instance');
  if (Mutex = 0) or (GetLastError = ERROR_ALREADY_EXISTS) then
    Halt(4);

  // Guarantees the program terminates, even if TC never answers
  GDeadline := GetTickCount64 + WATCHDOG_MS;
  BeginThread(@WatchdogThread, nil, ThreadID);

  TCWnd := FindWindow('TTOTAL_CMD', nil);
  if TCWnd = 0 then
  begin
    DebugLog('Total Commander not found');
    Halt(1);
  end;

  GHiddenWnd := CreateReceiverWindow;
  if GHiddenWnd = 0 then
    Halt(2);

  if BothPanels then
  begin
    // -b: item under the cursor in the left AND the right panel
    R := GetItem(TCWnd, ['LP'], ['LN'], LeftName);
    if R = 2 then begin DestroyWindow(GHiddenWnd); Halt(2); end;
    ExitCode_ := R;
    R := GetItem(TCWnd, ['RP'], ['RN'], RightName);
    if R = 2 then begin DestroyWindow(GHiddenWnd); Halt(2); end;
    if R <> 0 then ExitCode_ := R;

    FullName := LeftName + #13#10 + RightName;          // for the clipboard
  end
  else
  begin
    // Which panel is active: 'L' or 'R'
    Side := UpperCase(QueryTC(TCWnd, 'A'));
    if (Side <> 'L') and (Side <> 'R') then
      Side := '';

    // Try the different spellings TC versions understand
    if Side <> '' then
      R := GetItem(TCWnd, ['SP', 'AP', AnsiString(Side) + 'P'],
                          ['SN', 'AN', AnsiString(Side) + 'N'], FullName)
    else
      R := GetItem(TCWnd, ['SP', 'AP'], ['SN', 'AN'], FullName);
    if R = 2 then begin DestroyWindow(GHiddenWnd); Halt(2); end;
    ExitCode_ := R;
  end;

  if RunProg <> '' then
  begin
    // -x: start the program with the file(s), clipboard stays untouched.
    // Items inside a ZIP are unpacked to %TEMP%\TC_query first.
    DeleteTree(TempBaseDir);               // leftovers from the last run
    if BothPanels then
    begin
      if ResolveArchivePath(LeftName, 'L') <> 0 then ExitCode_ := 8;
      if ResolveArchivePath(RightName, 'R') <> 0 then ExitCode_ := 8;
      Params := QuoteArg(LeftName) + ' ' + QuoteArg(RightName);
    end
    else
    begin
      if ResolveArchivePath(FullName, 'A') <> 0 then ExitCode_ := 8;
      Params := QuoteArg(FullName);
    end;

    if ExitCode_ <> 8 then
      if not RunProgram(RunProg, Params) then
        ExitCode_ := 7;
  end
  else
  begin
    DebugLog('Clipboard: "' + UTF8Encode(FullName) + '"');
    if not SetClipboardTextW(FullName) then
      ExitCode_ := 3;
  end;
  DestroyWindow(GHiddenWnd);

  // MessageBeep plays asynchronously in the system, so we can exit right away
  if (not Silent) and (ExitCode_ = 0) then
    MessageBeep(MB_ICONASTERISK);

  Halt(ExitCode_);
end.
