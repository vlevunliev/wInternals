program trpad;
{ ---------------------------------------------------------
  TinyRetroPad - Pascal port of Dave Plummer's trpad.asm
  (Dave's Tiny Editor / Tiny App lineage, Apache 2.0)
  Pure Win32 API, no LCL, no external units beyond RTL.
  fpc -Twin32 -WG trpad.pas   (или -Twin64)
  --------------------------------------------------------- }
{$mode objfpc}{$H-}
{$APPTYPE GUI}

{ =====================  FEATURE MENU  =====================
  Разкоментирай за да включиш опционалните екстри
  (еквивалент на FEAT_* switch-овете в asm-а).           }
{ $DEFINE FEAT_LINENUMBERS}
{ $DEFINE FEAT_DARKMODE}
{ ========================================================== }

uses
  Windows;

function ShellExecuteA(hWnd: HWND; lpOperation, lpFile, lpParameters,
  lpDirectory: PAnsiChar; nShowCmd: LongInt): HINST; stdcall;
  external 'shell32.dll' name 'ShellExecuteA';

{ ---- commdlg: липсва в FPC Windows unit-а, декларираме си го ---- }
type
  TOpenFilenameA = record
    lStructSize: DWORD;
    hwndOwner: HWND;
    hInstance: HINST;
    lpstrFilter: PAnsiChar;
    lpstrCustomFilter: PAnsiChar;
    nMaxCustFilter: DWORD;
    nFilterIndex: DWORD;
    lpstrFile: PAnsiChar;
    nMaxFile: DWORD;
    lpstrFileTitle: PAnsiChar;
    nMaxFileTitle: DWORD;
    lpstrInitialDir: PAnsiChar;
    lpstrTitle: PAnsiChar;
    Flags: DWORD;
    nFileOffset: Word;
    nFileExtension: Word;
    lpstrDefExt: PAnsiChar;
    lCustData: LPARAM;
    lpfnHook: Pointer;
    lpTemplateName: PAnsiChar;
    pvReserved: Pointer;
    dwReserved: DWORD;
    FlagsEx: DWORD;
  end;

  TChooseFontW = record
    lStructSize: DWORD;
    hwndOwner: HWND;
    hDC: HDC;
    lpLogFont: Pointer;               // ^LOGFONTW
    iPointSize: LongInt;
    Flags: DWORD;
    rgbColors: COLORREF;
    lCustData: LPARAM;
    lpfnHook: Pointer;
    lpTemplateName: PWideChar;
    hInstance: HINST;
    lpszStyle: PWideChar;
    nFontType: Word;
    wPad: Word;                       // ___MISSING_ALIGNMENT__
    nSizeMin: LongInt;
    nSizeMax: LongInt;
  end;

  TFindReplaceA = record
    lStructSize: DWORD;
    hwndOwner: HWND;
    hInstance: HINST;
    Flags: DWORD;
    lpstrFindWhat: PAnsiChar;
    lpstrReplaceWith: PAnsiChar;
    wFindWhatLen: Word;
    wReplaceWithLen: Word;
    lCustData: LPARAM;
    lpfnHook: Pointer;
    lpTemplateName: PAnsiChar;
  end;

  TPrintDlgA = record
    lStructSize: DWORD;
    hwndOwner: HWND;
    hDevMode: HGLOBAL;
    hDevNames: HGLOBAL;
    hDC: HDC;
    Flags: DWORD;
    nFromPage: Word;
    nToPage: Word;
    nMinPage: Word;
    nMaxPage: Word;
    nCopies: Word;
    hInstance: HINST;
    lCustData: LPARAM;
    lpfnPrintHook: Pointer;
    lpfnSetupHook: Pointer;
    lpPrintTemplateName: PAnsiChar;
    lpSetupTemplateName: PAnsiChar;
    hPrintTemplate: HGLOBAL;
    hSetupTemplate: HGLOBAL;
  end;

  TPageSetupDlgA = record
    lStructSize: DWORD;
    hwndOwner: HWND;
    hDevMode: HGLOBAL;
    hDevNames: HGLOBAL;
    Flags: DWORD;
    ptPaperSize: TPoint;
    rtMinMargin: TRect;
    rtMargin: TRect;
    hInstance: HINST;
    lCustData: LPARAM;
    lpfnPageSetupHook: Pointer;
    lpfnPagePaintHook: Pointer;
    lpPageSetupTemplateName: PAnsiChar;
    hPageSetupTemplate: HGLOBAL;
  end;

function GetOpenFileNameA(lpofn: Pointer): BOOL; stdcall;
  external 'comdlg32.dll' name 'GetOpenFileNameA';
function GetSaveFileNameA(lpofn: Pointer): BOOL; stdcall;
  external 'comdlg32.dll' name 'GetSaveFileNameA';
function ChooseFontW(lpcf: Pointer): BOOL; stdcall;
  external 'comdlg32.dll' name 'ChooseFontW';
function FindTextA(lpfr: Pointer): HWND; stdcall;
  external 'comdlg32.dll' name 'FindTextA';
function ReplaceTextA(lpfr: Pointer): HWND; stdcall;
  external 'comdlg32.dll' name 'ReplaceTextA';
function PrintDlgA(lppd: Pointer): BOOL; stdcall;
  external 'comdlg32.dll' name 'PrintDlgA';
function PageSetupDlgA(lppsd: Pointer): BOOL; stdcall;
  external 'comdlg32.dll' name 'PageSetupDlgA';

const
  WindowWidth  = 800;
  WindowHeight = 640;
  SBHEIGHT     = 20;               // status bar height, px
  MAX_CMD_PATH = 128;
  MAX_TITLE    = 128;
  IDC_GOEDIT   = 1000;             // Go To dialog edit field

  // Rich Edit (не са в Windows unit-а)
  EM_EXGETSEL        = WM_USER + 52;
  EM_EXLIMITTEXT     = WM_USER + 53;
  EM_EXLINEFROMCHAR  = WM_USER + 54;
  EM_EXSETSEL        = WM_USER + 55;
  EM_FORMATRANGE     = WM_USER + 57;
  EM_SETBKGNDCOLOR   = WM_USER + 67;
  EM_SETCHARFORMAT   = WM_USER + 68;
  EM_SETEVENTMASK    = WM_USER + 69;
  EM_SETTARGETDEVICE = WM_USER + 72;
  EM_FINDTEXTEXA     = WM_USER + 79;

  SCF_ALL         = $00000004;
  ENM_CHANGE      = $00000001;
  ENM_UPDATE      = $00000002;
  ENM_SCROLL      = $00000004;
  ENM_MOUSEEVENTS = $00020000;
  ENM_SELCHANGE   = $00080000;
  EN_MSGFILTER    = $0700;
  EN_SELCHANGE    = $0702;
  CFM_BOLD        = $00000001;
  CFM_ITALIC      = $00000002;
  CFM_SIZE        = DWORD($80000000);
  CFM_FACE        = $20000000;
  CFM_COLOR       = $40000000;
  CFE_BOLD        = $00000001;
  CFE_ITALIC      = $00000002;
  CFE_AUTOCOLOR   = $40000000;

  // command IDs (WM_COMMAND / WM_SYSCOMMAND)
  IDM_SAVE           = $E100;
  IDM_FILE_NEW       = $E200;
  IDM_FILE_EXIT      = $E201;
  IDM_FILE_OPEN      = $E202;
  IDM_FILE_SAVEAS    = $E203;
  IDM_FILE_PRINT     = $E204;
  IDM_FILE_PAGESETUP = $E205;
  IDM_EDIT_UNDO      = $E210;
  IDM_EDIT_CUT       = $E211;
  IDM_EDIT_COPY      = $E212;
  IDM_EDIT_PASTE     = $E213;
  IDM_EDIT_DELETE    = $E214;
  IDM_EDIT_SELALL    = $E215;
  IDM_EDIT_TIME      = $E216;
  IDM_EDIT_FIND      = $E217;
  IDM_EDIT_FINDNEXT  = $E218;
  IDM_EDIT_REPLACE   = $E219;
  IDM_EDIT_GOTO      = $E21A;
  IDM_FMT_WRAP       = $E220;
  IDM_FMT_FONT       = $E221;
  IDM_VIEW_STATUS    = $E230;
  IDM_HELP_ABOUT     = $E240;
  IDM_HELP_VIEWHELP  = $E241;

{$IFDEF FEAT_LINENUMBERS}
  LN_MARGIN_W      = 44;           // gutter width, px
  LN_PAD           = 6;            // left padding of numbers
  IDM_VIEW_LINENUM = $E231;
{$ENDIF}
{$IFDEF FEAT_DARKMODE}
  DARK_BG       = $001E1E1E;       // 00BBGGRR
  DARK_FG       = $00DCDCDC;
  IDM_VIEW_DARK = $E232;
{$ENDIF}

  ClassName : PAnsiChar = '.';           // saves bytes, seems to work :)
  RichDll   : PAnsiChar = 'Msftedit';
  EditClass : PAnsiChar = 'RICHEDIT50W';
  AppTail   : PAnsiChar = ' - TinyRetroPad';
  AboutCap  : PAnsiChar = 'TinyRetroPad';
  AboutText : PAnsiChar = 'TinyRetroPad - tiny notepad-style editor';
  SaveAsk   : PAnsiChar = 'Save changes?';
  FileFilter: PAnsiChar = 'All Files'#0'*.*'#0#0;
  HelpUrl   : PAnsiChar = 'https://github.com/davepl';
  DocName   : PAnsiChar = 'TinyRetroPad';

type
  TCharRange = packed record
    cpMin, cpMax: LongInt;
  end;

  TFindTextExA = record
    chrg: TCharRange;
    lpstrText: PAnsiChar;
    chrgText: TCharRange;
  end;

  TFormatRange = record
    hdc, hdcTarget: HDC;
    rc, rcPage: TRect;
    chrg: TCharRange;
  end;

  TCharFormatW = packed record
    cbSize: DWORD;
    dwMask: DWORD;
    dwEffects: DWORD;
    yHeight: LongInt;
    yOffset: LongInt;
    crTextColor: COLORREF;
    bCharSet: Byte;
    bPitchAndFamily: Byte;
    szFaceName: array[0..LF_FACESIZE-1] of WideChar;
    wPad: Word;                    // -> 92 bytes, като richedit.h
  end;

  // NMHDR + начало на MSGFILTER (за WM_NOTIFY)
  TMsgFilterRec = record
    hwndFrom: HWND;
    idFrom: UINT_PTR;
    code: UINT;
    msg: UINT;
    wp: WPARAM;
    lp: LPARAM;
  end;
  PMsgFilterRec = ^TMsgFilterRec;

  // in-memory Go To dialog template (без font block, компактен)
  TGoToTmpl = packed record
    style: DWORD;
    exStyle: DWORD;
    cdit: Word;
    x, y, cx, cy: SmallInt;
    menu, cls: Word;
    title: array[0..5] of WideChar;
    pad1: Word;                          // ALIGN 4
    it1Style: DWORD;                     // edit field
    it1Ex: DWORD;
    it1x, it1y, it1cx, it1cy: SmallInt;
    it1Id: Word;
    it1ClsFF, it1ClsAtom: Word;          // 0FFFFh,0081h = Edit atom
    it1Title: Word;
    it1Data: Word;
    pad2: Word;                          // ALIGN 4
    it2Style: DWORD;                     // OK button
    it2Ex: DWORD;
    it2x, it2y, it2cx, it2cy: SmallInt;
    it2Id: Word;
    it2ClsFF, it2ClsAtom: Word;          // 0FFFFh,0080h = Button atom
    it2Title: array[0..2] of WideChar;
    it2Data: Word;
  end;

const
  GoToTmpl: TGoToTmpl = (
    style: DS_MODALFRAME or WS_POPUP or WS_CAPTION or WS_SYSMENU;
    exStyle: 0;
    cdit: 2;
    x: 0; y: 0; cx: 150; cy: 46;
    menu: 0; cls: 0;
    title: ('G','o',' ','T','o',#0);
    pad1: 0;
    it1Style: WS_CHILD or WS_VISIBLE or WS_BORDER or ES_NUMBER or WS_TABSTOP;
    it1Ex: 0;
    it1x: 7; it1y: 7; it1cx: 136; it1cy: 12;
    it1Id: IDC_GOEDIT;
    it1ClsFF: $FFFF; it1ClsAtom: $0081;
    it1Title: 0;
    it1Data: 0;
    pad2: 0;
    it2Style: WS_CHILD or WS_VISIBLE or BS_DEFPUSHBUTTON or WS_TABSTOP;
    it2Ex: 0;
    it2x: 50; it2y: 26; it2cx: 50; it2cy: 14;
    it2Id: IDOK;
    it2ClsFF: $FFFF; it2ClsAtom: $0080;
    it2Title: ('O','K',#0);
    it2Data: 0
  );

var
  hInstApp    : HINST = 0;
  hMain    : HWND  = 0;
  hEdit    : HWND  = 0;
  hStatus  : HWND  = 0;
  hFindDlg : HWND  = 0;               // modeless Find/Replace
  uFindMsg : UINT  = 0;               // registered FINDMSGSTRING
  fDirty   : LongBool = False;
  fWrap    : LongBool = True;
  fStatus  : LongBool = True;
{$IFDEF FEAT_LINENUMBERS}
  fLineNum : LongBool = False;
{$ENDIF}
{$IFDEF FEAT_DARKMODE}
  fDark    : LongBool = False;
{$ENDIF}
  CmdFile  : array[0..MAX_CMD_PATH-1] of AnsiChar;
  TitleBuf : array[0..MAX_TITLE-1] of AnsiChar;
  FindWhat : array[0..127] of AnsiChar;
  ReplaceWith: array[0..127] of AnsiChar;
  fr       : TFindReplaceA;           // shared find/replace request
  RichFont : TCharFormatW;            // default face: Courier

function EdMsg(m: UINT; w: WPARAM; l: LPARAM): LRESULT; inline;
begin
  Result := SendMessageA(hEdit, m, w, l);
end;

{ ---- title bar: file name (+ tail), от CmdFile или Untitled ---- }
procedure BuildTitle;
var
  p, base: PAnsiChar;
  d: PAnsiChar;
begin
  d := @TitleBuf[0];
  if CmdFile[0] = #0 then
    p := PAnsiChar('Untitled')
  else
  begin
    p := @CmdFile[0];
    base := p;
    while p^ <> #0 do                 // strip path -> filename tail
    begin
      if p^ = '\' then base := p + 1;
      Inc(p);
    end;
    p := base;
  end;
  while p^ <> #0 do begin d^ := p^; Inc(d); Inc(p); end;
  p := AppTail;
  while p^ <> #0 do begin d^ := p^; Inc(d); Inc(p); end;
  d^ := #0;
  // TODO по оригинала: '*' при dirty е обявено в коментара, но не е реализирано
end;

procedure ApplyTitle;
begin
  BuildTitle;
  SetWindowTextA(hMain, @TitleBuf[0]);
end;

{ ---- команден ред: първи аргумент -> CmdFile (quoted/bare) ---- }
procedure ParseStartupFile;
var
  s, d: PAnsiChar;
  n: Integer;
begin
  CmdFile[0] := #0;
  s := GetCommandLineA;
  if s = nil then Exit;

  if s^ = '"' then
  begin                               // skip quoted exe path
    Inc(s);
    while (s^ <> #0) and (s^ <> '"') do Inc(s);
    if s^ = '"' then Inc(s);
  end
  else                                // skip bare exe path
    while (s^ <> #0) and (s^ <> ' ') and (s^ <> #9) do Inc(s);

  while (s^ = ' ') or (s^ = #9) do Inc(s);
  if s^ = #0 then Exit;

  d := @CmdFile[0];
  n := MAX_CMD_PATH - 1;
  if s^ = '"' then
  begin
    Inc(s);
    while (s^ <> #0) and (s^ <> '"') and (n > 0) do
    begin d^ := s^; Inc(d); Inc(s); Dec(n); end;
  end
  else
    while (s^ <> #0) and (s^ <> ' ') and (s^ <> #9) and (n > 0) do
    begin d^ := s^; Inc(d); Inc(s); Dec(n); end;
  d^ := #0;
end;

{ ---- file dialogs -> CmdFile ---- }
function PickOpenFile: Boolean;
var
  ofn: TOpenFilenameA;
begin
  FillChar(ofn, SizeOf(ofn), 0);
  CmdFile[0] := #0;
  ofn.lStructSize := SizeOf(ofn);
  ofn.hwndOwner   := hMain;
  ofn.lpstrFilter := FileFilter;
  ofn.lpstrFile   := @CmdFile[0];
  ofn.nMaxFile    := MAX_CMD_PATH;
  ofn.Flags       := OFN_FILEMUSTEXIST or OFN_PATHMUSTEXIST or OFN_HIDEREADONLY;
  Result := GetOpenFileNameA(@ofn);
end;

function PickSaveFile: Boolean;
var
  ofn: TOpenFilenameA;
begin
  FillChar(ofn, SizeOf(ofn), 0);
  ofn.lStructSize := SizeOf(ofn);
  ofn.hwndOwner   := hMain;
  ofn.lpstrFilter := FileFilter;
  ofn.lpstrFile   := @CmdFile[0];
  ofn.nMaxFile    := MAX_CMD_PATH;
  ofn.Flags       := OFN_PATHMUSTEXIST or OFN_HIDEREADONLY or OFN_OVERWRITEPROMPT;
  Result := GetSaveFileNameA(@ofn);
end;

{ ---- load / save ---- }
procedure LoadStartupFile;
var
  hFile: THandle;
  size, got: DWORD;
  buf: PAnsiChar;
begin
  hFile := CreateFileA(@CmdFile[0], GENERIC_READ, FILE_SHARE_READ, nil,
                       OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if hFile = INVALID_HANDLE_VALUE then Exit;
  size := GetFileSize(hFile, nil);
  if size <> $FFFFFFFF then
  begin
    GetMem(buf, size + 1);
    got := 0;
    if ReadFile(hFile, buf^, size, got, nil) then
    begin
      buf[got] := #0;
      SetWindowTextA(hEdit, buf);
      EdMsg(EM_SETCHARFORMAT, SCF_ALL, LPARAM(@RichFont));
    end;
    FreeMem(buf);
  end;
  CloseHandle(hFile);
end;

procedure SaveFile;
var
  hFile: THandle;
  len, written: DWORD;
  buf: PAnsiChar;
begin
  len := EdMsg(WM_GETTEXTLENGTH, 0, 0);
  GetMem(buf, len + 1);
  // забележка: RichEdit може да върне по-малко от GETTEXTLENGTH,
  // затова пишем реално копираното (asm-ът пишеше len - латентен бъг)
  len := SendMessageA(hEdit, WM_GETTEXT, len + 1, LPARAM(buf));
  hFile := CreateFileA(@CmdFile[0], GENERIC_WRITE, 0, nil,
                       CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if hFile <> INVALID_HANDLE_VALUE then
  begin
    written := 0;
    WriteFile(hFile, buf^, len, written, nil);
    CloseHandle(hFile);
    fDirty := False;
    ApplyTitle;
  end;
  FreeMem(buf);
end;

{ ---- dirty prompt: True = продължи, False = cancel ---- }
function MaybeSaveChanges: Boolean;
begin
  Result := True;
  if not fDirty then Exit;
  case MessageBoxA(hMain, SaveAsk, AboutCap,
                   MB_YESNOCANCEL or MB_ICONQUESTION) of
    IDCANCEL: Exit(False);
    IDNO:     Exit(True);
  end;
  if CmdFile[0] = #0 then
    if not PickSaveFile then Exit(False);
  SaveFile;
end;

procedure NewFile;
begin
  CmdFile[0] := #0;
  SetWindowTextA(hEdit, '');
  fDirty := False;
  ApplyTitle;
end;

{ ---- Edit > Time/Date: вмъква локални дата и час при курсора ---- }
procedure InsertTimeDate;
var
  st: TSystemTime;
  db, tb: array[0..31] of AnsiChar;
begin
  GetLocalTime(@st);
  GetDateFormatA(LOCALE_USER_DEFAULT, DATE_SHORTDATE, @st, nil, @db[0], 32);
  GetTimeFormatA(LOCALE_USER_DEFAULT, 0, @st, nil, @tb[0], 32);
  EdMsg(EM_REPLACESEL, WPARAM(True), LPARAM(@db[0]));
  EdMsg(EM_REPLACESEL, WPARAM(True), LPARAM(PAnsiChar(' ')));
  EdMsg(EM_REPLACESEL, WPARAM(True), LPARAM(@tb[0]));
end;

{ ---- Format > Word Wrap ---- }
procedure ToggleWrap;
begin
  if fWrap then
  begin
    fWrap := False;                   // много широк target = без wrap
    EdMsg(EM_SETTARGETDEVICE, 0, LPARAM(LongInt(-1)));
  end
  else
  begin
    fWrap := True;                    // 0 = wrap към ширината на прозореца
    EdMsg(EM_SETTARGETDEVICE, 0, 0);
  end;
end;

{ ---- Format > Font: common dialog -> EM_SETCHARFORMAT ---- }
procedure ChooseFontDlg;
var
  lf: LOGFONTW;
  cf: TChooseFontW;
  fmt: TCharFormatW;
  fx: DWORD;
begin
  FillChar(cf, SizeOf(cf), 0);
  FillChar(lf, SizeOf(lf), 0);
  cf.lStructSize := SizeOf(cf);
  cf.hwndOwner   := hMain;
  cf.lpLogFont   := @lf;
  cf.Flags       := CF_SCREENFONTS or CF_EFFECTS;
  if not ChooseFontW(@cf) then Exit;

  FillChar(fmt, SizeOf(fmt), 0);
  fmt.cbSize := SizeOf(fmt);
  fmt.dwMask := CFM_FACE or CFM_SIZE or CFM_BOLD or CFM_ITALIC;
  fx := 0;
  if lf.lfWeight >= 700 then fx := fx or CFE_BOLD;
  if lf.lfItalic <> 0   then fx := fx or CFE_ITALIC;
  fmt.dwEffects := fx;
  fmt.yHeight := cf.iPointSize * 2;   // twips = 1/10 pt * 2
  Move(lf.lfFaceName, fmt.szFaceName, SizeOf(lf.lfFaceName));
  EdMsg(EM_SETCHARFORMAT, SCF_ALL, LPARAM(@fmt));
end;

{ ---- Find / Replace ---- }
procedure InitFR;
begin
  FillChar(fr, SizeOf(fr), 0);
  fr.lStructSize      := SizeOf(fr);
  fr.hwndOwner        := hMain;
  fr.lpstrFindWhat    := @FindWhat[0];
  fr.wFindWhatLen     := 128;
  fr.lpstrReplaceWith := @ReplaceWith[0];
  fr.wReplaceWithLen  := 128;
  fr.Flags            := FR_DOWN;
end;

function DoFindNext: Boolean;
var
  cr: TCharRange;
  ft: TFindTextExA;
  fl: DWORD;
begin
  Result := False;
  EdMsg(EM_EXGETSEL, 0, LPARAM(@cr));
  ft.chrg.cpMin := cr.cpMax;          // от края на селекцията надолу
  ft.chrg.cpMax := -1;
  ft.lpstrText  := @FindWhat[0];
  fl := (fr.Flags and FR_MATCHCASE) or FR_DOWN;
  if EdMsg(EM_FINDTEXTEXA, fl, LPARAM(@ft)) = -1 then Exit;
  EdMsg(EM_EXSETSEL, 0, LPARAM(@ft.chrgText));
  EdMsg(EM_SCROLLCARET, 0, 0);
  Result := True;
end;

procedure DoReplaceOne;
begin
  EdMsg(EM_REPLACESEL, WPARAM(True), LPARAM(@ReplaceWith[0]));
  DoFindNext;
end;

procedure DoReplaceAll;
var
  cr: TCharRange;
begin
  cr.cpMin := 0; cr.cpMax := 0;       // от началото
  EdMsg(EM_EXSETSEL, 0, LPARAM(@cr));
  while DoFindNext do
    EdMsg(EM_REPLACESEL, WPARAM(True), LPARAM(@ReplaceWith[0]));
end;

procedure OnFindReplaceMsg;
begin
  if (fr.Flags and FR_DIALOGTERM) <> 0 then begin hFindDlg := 0; Exit; end;
  if (fr.Flags and FR_REPLACEALL) <> 0 then begin DoReplaceAll; Exit; end;
  if (fr.Flags and FR_REPLACE)    <> 0 then begin DoReplaceOne; Exit; end;
  DoFindNext;
end;

{ ---- File > Print: common dialog + EM_FORMATRANGE ---- }
procedure PrintDoc;
var
  pd: TPrintDlgA;
  di: DOCINFOA;
  fmt: TFormatRange;
  txtLen, next: LongInt;
  dc: HDC;
begin
  FillChar(pd, SizeOf(pd), 0);
  pd.lStructSize := SizeOf(pd);
  pd.hwndOwner   := hMain;
  pd.Flags       := PD_RETURNDC or PD_NOPAGENUMS or PD_NOSELECTION;
  if not PrintDlgA(@pd) then Exit;
  dc := pd.hDC;

  FillChar(di, SizeOf(di), 0);
  di.cbSize      := SizeOf(di);
  di.lpszDocName := DocName;
  StartDocA(dc, @di);

  FillChar(fmt, SizeOf(fmt), 0);
  fmt.hdc := dc;
  fmt.hdcTarget := dc;
  // страница в twips: RES * 1440 / LOGPIXELS
  fmt.rc.Right      := MulDiv(GetDeviceCaps(dc, HORZRES), 1440,
                              GetDeviceCaps(dc, LOGPIXELSX));
  fmt.rcPage.Right  := fmt.rc.Right;
  fmt.rc.Bottom     := MulDiv(GetDeviceCaps(dc, VERTRES), 1440,
                              GetDeviceCaps(dc, LOGPIXELSY));
  fmt.rcPage.Bottom := fmt.rc.Bottom;

  txtLen := EdMsg(WM_GETTEXTLENGTH, 0, 0);
  fmt.chrg.cpMin := 0;
  fmt.chrg.cpMax := txtLen;

  repeat
    StartPage(dc);
    next := EdMsg(EM_FORMATRANGE, WPARAM(True), LPARAM(@fmt));
    fmt.chrg.cpMin := next;
    EndPage(dc);
    if next <= 0 then Break;          // предпазител срещу зацикляне
  until next >= txtLen;

  EdMsg(EM_FORMATRANGE, 0, 0);        // flush formatting cache
  EndDoc(dc);
  DeleteDC(dc);
end;

procedure PageSetup;
var
  psd: TPageSetupDlgA;
begin
  FillChar(psd, SizeOf(psd), 0);
  psd.lStructSize := SizeOf(psd);
  psd.hwndOwner   := hMain;
  PageSetupDlgA(@psd);
end;

{ ---- status bar: '  Ln %d, Col %d' от позицията на курсора ---- }
procedure UpdateStatus;
var
  cr: TCharRange;
  li, ln, col: LongInt;
  a, b: string[15];
  s: string[63];
begin
  if not fStatus then Exit;
  EdMsg(EM_EXGETSEL, 0, LPARAM(@cr));
  li  := EdMsg(EM_EXLINEFROMCHAR, 0, cr.cpMax);
  ln  := li + 1;
  col := cr.cpMax - EdMsg(EM_LINEINDEX, li, 0) + 1;
  Str(ln, a);
  Str(col, b);
  s := '  Ln ' + a + ', Col ' + b + #0;
  SetWindowTextA(hStatus, @s[1]);
end;

{ ---- пре-layout на edit/status по client размера ---- }
procedure RelayoutClient;
var
  rc: TRect;
begin
  GetClientRect(hMain, @rc);
  SendMessageA(hMain, WM_SIZE, 0,
               MakeLong(rc.Right and $FFFF, rc.Bottom and $FFFF));
end;

{$IFDEF FEAT_LINENUMBERS}
procedure LnInvalidate(hW: HWND);
var
  rc: TRect;
begin
  if not fLineNum then Exit;
  rc.Left := 0; rc.Top := 0; rc.Right := LN_MARGIN_W; rc.Bottom := $7FFF;
  InvalidateRect(hW, @rc, False);
end;
{$ENDIF}

{ ---- Go To dialog ---- }
function GoToProc(hDlg: HWND; uMsg: UINT; wParam: WPARAM;
                  lParam: LPARAM): LRESULT; stdcall;
var
  trans: WINBOOL;
begin
  Result := 1;
  case uMsg of
    WM_INITDIALOG: Exit;
    WM_COMMAND:
      case LOWORD(wParam) of
        IDOK:     begin
                    EndDialog(hDlg,
                      GetDlgItemInt(hDlg, IDC_GOEDIT, trans, False));
                    Exit;
                  end;
        IDCANCEL: begin EndDialog(hDlg, 0); Exit; end;
      end;
  end;
  Result := 0;
end;

procedure GoToDlg;
var
  line, idx: LongInt;
  cr: TCharRange;
begin
  line := DialogBoxIndirectParam(hInstApp, @GoToTmpl, hMain,
                                  DLGPROC(@GoToProc), 0);
  if line = 0 then Exit;              // cancel/невалидно
  idx := EdMsg(EM_LINEINDEX, line - 1, 0);
  if idx = -1 then Exit;
  cr.cpMin := idx; cr.cpMax := idx;
  EdMsg(EM_EXSETSEL, 0, LPARAM(@cr));
  EdMsg(EM_SCROLLCARET, 0, 0);
  SetFocus(hEdit);
end;

{ ---- menus ---- }
procedure AppendEnabled(hMenu: HMENU; uID: UINT; pText: PAnsiChar);
begin
  AppendMenuA(hMenu, MF_STRING, uID, pText);
end;

procedure AppendSep(hMenu: HMENU);
begin
  AppendMenuA(hMenu, MF_SEPARATOR, 0, nil);
end;

procedure ShowContextMenu(hWndOwner: HWND);
var
  hCtx: HMENU;
  mp: DWORD;
begin
  hCtx := CreatePopupMenu;
  AppendEnabled(hCtx, IDM_EDIT_UNDO,   '&Undo');
  AppendSep(hCtx);
  AppendEnabled(hCtx, IDM_EDIT_CUT,    'Cu&t');
  AppendEnabled(hCtx, IDM_EDIT_COPY,   '&Copy');
  AppendEnabled(hCtx, IDM_EDIT_PASTE,  '&Paste');
  AppendEnabled(hCtx, IDM_EDIT_DELETE, 'De&lete');
  AppendSep(hCtx);
  AppendEnabled(hCtx, IDM_EDIT_SELALL, 'Select &All');
  mp := GetMessagePos;
  TrackPopupMenu(hCtx, 0, SmallInt(LOWORD(mp)), SmallInt(HIWORD(mp)),
                 0, hWndOwner, nil);
  DestroyMenu(hCtx);
end;

procedure CreateNotepadMenus(hWnd: HWND);
var
  hBar, hPop: HMENU;
begin
  hBar := CreateMenu;
  if hBar = 0 then Exit;

  // File
  hPop := CreatePopupMenu;
  AppendEnabled(hPop, IDM_FILE_NEW,       '&New');
  AppendEnabled(hPop, IDM_FILE_OPEN,      '&Open...');
  AppendEnabled(hPop, IDM_SAVE,           '&Save');
  AppendEnabled(hPop, IDM_FILE_SAVEAS,    'Save &As...');
  AppendSep(hPop);
  AppendEnabled(hPop, IDM_FILE_PAGESETUP, 'Page Set&up...');
  AppendEnabled(hPop, IDM_FILE_PRINT,     '&Print...');
  AppendSep(hPop);
  AppendEnabled(hPop, IDM_FILE_EXIT,      'E&xit');
  AppendMenuA(hBar, MF_POPUP or MF_STRING, hPop, '&File');

  // Edit
  hPop := CreatePopupMenu;
  AppendEnabled(hPop, IDM_EDIT_UNDO,     '&Undo');
  AppendSep(hPop);
  AppendEnabled(hPop, IDM_EDIT_CUT,      'Cu&t');
  AppendEnabled(hPop, IDM_EDIT_COPY,     '&Copy');
  AppendEnabled(hPop, IDM_EDIT_PASTE,    '&Paste');
  AppendEnabled(hPop, IDM_EDIT_DELETE,   'De&lete');
  AppendSep(hPop);
  AppendEnabled(hPop, IDM_EDIT_FIND,     '&Find...');
  AppendEnabled(hPop, IDM_EDIT_FINDNEXT, 'Find &Next');
  AppendEnabled(hPop, IDM_EDIT_REPLACE,  '&Replace...');
  AppendEnabled(hPop, IDM_EDIT_GOTO,     '&Go To...');
  AppendSep(hPop);
  AppendEnabled(hPop, IDM_EDIT_SELALL,   'Select &All');
  AppendEnabled(hPop, IDM_EDIT_TIME,     'Time/&Date');
  AppendMenuA(hBar, MF_POPUP or MF_STRING, hPop, '&Edit');

  // Format
  hPop := CreatePopupMenu;
  AppendEnabled(hPop, IDM_FMT_WRAP, '&Word Wrap');
  AppendEnabled(hPop, IDM_FMT_FONT, '&Font...');
  AppendMenuA(hBar, MF_POPUP or MF_STRING, hPop, 'F&ormat');

  // View
  hPop := CreatePopupMenu;
  AppendEnabled(hPop, IDM_VIEW_STATUS, '&Status Bar');
{$IFDEF FEAT_LINENUMBERS}
  AppendEnabled(hPop, IDM_VIEW_LINENUM, 'Line &Numbers');
{$ENDIF}
{$IFDEF FEAT_DARKMODE}
  AppendEnabled(hPop, IDM_VIEW_DARK, 'Dark &Mode');
{$ENDIF}
  AppendMenuA(hBar, MF_POPUP or MF_STRING, hPop, '&View');

  // Help
  hPop := CreatePopupMenu;
  AppendEnabled(hPop, IDM_HELP_VIEWHELP, '&View Help');
  AppendSep(hPop);
  AppendEnabled(hPop, IDM_HELP_ABOUT,    '&About TinyRetroPad');
  AppendMenuA(hBar, MF_POPUP or MF_STRING, hPop, '&Help');

  SetMenu(hWnd, hBar);
end;

{$IFDEF FEAT_DARKMODE}
procedure CmdViewDark;
var
  dfmt: TCharFormatW;
  chk: UINT;
begin
  fDark := not fDark;
  FillChar(dfmt, SizeOf(dfmt), 0);
  dfmt.cbSize := SizeOf(dfmt);
  dfmt.dwMask := CFM_COLOR;
  if fDark then
  begin
    EdMsg(EM_SETBKGNDCOLOR, 0, DARK_BG);       // wParam 0 = даден цвят
    dfmt.crTextColor := DARK_FG;
  end
  else
  begin
    EdMsg(EM_SETBKGNDCOLOR, 1, 0);             // wParam 1 = system цвят
    dfmt.dwEffects := CFE_AUTOCOLOR;
  end;
  EdMsg(EM_SETCHARFORMAT, SCF_ALL, LPARAM(@dfmt));
  chk := MF_BYCOMMAND;
  if fDark then chk := chk or MF_CHECKED;
  CheckMenuItem(GetMenu(hMain), IDM_VIEW_DARK, chk);
end;
{$ENDIF}

{ ---- window procedure ---- }
function MainWndProc(hWnd: HWND; uMsg: UINT; wParam: WPARAM;
                 lParam: LPARAM): LRESULT; stdcall;
var
  w, h, cmd: Integer;
  pf: PMsgFilterRec;
{$IFDEF FEAT_LINENUMBERS}
  ps: TPaintStruct;
  rc: TRect;
  pt: TPoint;
  dc: HDC;
  li, total, ci: LongInt;
  nbuf: string[15];
  gx: Integer;
{$ENDIF}
begin
  Result := 0;

{$IFDEF FEAT_LINENUMBERS}
  if (uMsg = WM_PAINT) and fLineNum then
  begin
    dc := BeginPaint(hWnd, @ps);
    GetClientRect(hWnd, @rc);
    rc.Right := LN_MARGIN_W;                   // strip = {0,0,MARGIN,clientH}
    FillRect(dc, rc, GetSysColorBrush(COLOR_BTNFACE));
    SetBkMode(dc, TRANSPARENT);
    li := EdMsg(EM_GETFIRSTVISIBLELINE, 0, 0);
    total := EdMsg(EM_GETLINECOUNT, 0, 0);
    while li < total do
    begin
      ci := EdMsg(EM_LINEINDEX, li, 0);
      EdMsg(EM_POSFROMCHAR, PtrUInt(@pt), ci);  // pt.y = line top, client px
      if pt.Y > rc.Bottom then Break;
      Str(li + 1, nbuf);
      TextOutA(dc, LN_PAD, pt.Y, @nbuf[1], Length(nbuf));
      Inc(li);
    end;
    EndPaint(hWnd, @ps);
    Exit;
  end;
{$ENDIF}

  case uMsg of
    WM_CREATE:
      begin
        // EDIT control (RICHEDIT50W); размер 0,0 - WM_SIZE ще го нагласи
        hEdit := CreateWindowExA(0, EditClass, nil,
                   WS_CHILD or WS_VISIBLE or WS_BORDER or ES_LEFT or
                   ES_MULTILINE or ES_AUTOVSCROLL or WS_VSCROLL,
                   0, 0, 0, 0, hWnd, 0, 0, nil);
        // event mask за EN_CHANGE/EN_SELCHANGE/mouse (context menu)
        EdMsg(EM_SETEVENTMASK, 0,
              ENM_CHANGE or ENM_MOUSEEVENTS or ENM_SELCHANGE
              {$IFDEF FEAT_LINENUMBERS} or ENM_SCROLL or ENM_UPDATE {$ENDIF});
        // вдигни лимита за редактиране
        EdMsg(EM_EXLIMITTEXT, 0, $7FFFFFFE);
        // Save в системното меню
        AppendMenuA(GetSystemMenu(hWnd, False), MF_STRING, IDM_SAVE, 'Save');
        CreateNotepadMenus(hWnd);
        // status bar pane
        hStatus := CreateWindowExA(WS_EX_STATICEDGE, 'STATIC', '',
                     WS_CHILD or WS_VISIBLE, 0, 0, 0, 0, hWnd, 0, 0, nil);
        UpdateStatus;
      end;

    WM_SYSCOMMAND:
      begin
        if wParam = IDM_SAVE then SaveFile
        else Result := DefWindowProcA(hWnd, uMsg, wParam, lParam);
      end;

    WM_COMMAND:
      begin
        if HIWORD(wParam) = EN_CHANGE then
        begin
          if not fDirty then begin fDirty := True; ApplyTitle; end;
          Exit;
        end;
{$IFDEF FEAT_LINENUMBERS}
        if (HIWORD(wParam) = EN_VSCROLL) or (HIWORD(wParam) = EN_UPDATE) then
        begin LnInvalidate(hWnd); Exit; end;
{$ENDIF}
        cmd := LOWORD(wParam);
        case cmd of
          IDM_FILE_NEW:
            if MaybeSaveChanges then NewFile;
          IDM_FILE_OPEN:
            if MaybeSaveChanges and PickOpenFile then
            begin
              LoadStartupFile;
              fDirty := False;
              ApplyTitle;
            end;
          IDM_SAVE:
            if CmdFile[0] = #0 then
            begin if PickSaveFile then SaveFile; end
            else SaveFile;
          IDM_FILE_SAVEAS:
            if PickSaveFile then SaveFile;
          IDM_FILE_PRINT:     PrintDoc;
          IDM_FILE_PAGESETUP: PageSetup;
          IDM_FILE_EXIT:
            if MaybeSaveChanges then DestroyWindow(hWnd);
          IDM_EDIT_UNDO:   EdMsg(WM_UNDO, 0, 0);
          IDM_EDIT_CUT:    EdMsg(WM_CUT, 0, 0);
          IDM_EDIT_COPY:   EdMsg(WM_COPY, 0, 0);
          IDM_EDIT_PASTE:  EdMsg(WM_PASTE, 0, 0);
          IDM_EDIT_DELETE: EdMsg(WM_CLEAR, 0, 0);
          IDM_EDIT_SELALL:
            begin
              SetFocus(hEdit);
              EdMsg(EM_SETSEL, 0, -1);
            end;
          IDM_EDIT_TIME:
            begin
              SetFocus(hEdit);
              InsertTimeDate;
            end;
          IDM_EDIT_FIND:
            begin
              InitFR;
              hFindDlg := FindTextA(@fr);
            end;
          IDM_EDIT_FINDNEXT: DoFindNext;
          IDM_EDIT_REPLACE:
            begin
              InitFR;
              hFindDlg := ReplaceTextA(@fr);
            end;
          IDM_EDIT_GOTO:  GoToDlg;
          IDM_FMT_WRAP:   ToggleWrap;
          IDM_FMT_FONT:   ChooseFontDlg;
          IDM_VIEW_STATUS:
            begin
              fStatus := not fStatus;
              if fStatus then ShowWindow(hStatus, SW_SHOW)
              else ShowWindow(hStatus, SW_HIDE);
              RelayoutClient;
              UpdateStatus;
            end;
{$IFDEF FEAT_LINENUMBERS}
          IDM_VIEW_LINENUM:
            begin
              fLineNum := not fLineNum;
              RelayoutClient;
              LnInvalidate(hWnd);
            end;
{$ENDIF}
{$IFDEF FEAT_DARKMODE}
          IDM_VIEW_DARK: CmdViewDark;
{$ENDIF}
          IDM_HELP_ABOUT:
            MessageBoxA(hWnd, AboutText, AboutCap,
                        MB_OK or MB_ICONINFORMATION);
          IDM_HELP_VIEWHELP:
            ShellExecuteA(0, 'open', HelpUrl, nil, nil, SW_SHOWNORMAL);
        end;
      end;

    WM_NOTIFY:
      begin
        pf := PMsgFilterRec(lParam);
        if pf^.code = EN_SELCHANGE then
          UpdateStatus
        else if (pf^.code = EN_MSGFILTER) and (pf^.msg = WM_RBUTTONUP) then
        begin
          ShowContextMenu(hWnd);
          Exit(1);
        end;
      end;

    WM_SIZE:
      begin
        w := LOWORD(lParam);
        h := HIWORD(lParam);
        if fStatus then
        begin
          Dec(h, SBHEIGHT);
          SetWindowPos(hStatus, 0, 0, h, w, SBHEIGHT, SWP_NOZORDER);
        end;
{$IFDEF FEAT_LINENUMBERS}
        gx := 0;
        if fLineNum then begin gx := LN_MARGIN_W; Dec(w, LN_MARGIN_W); end;
        SetWindowPos(hEdit, 0, gx, 0, w, h, SWP_NOZORDER);
        LnInvalidate(hWnd);
{$ELSE}
        SetWindowPos(hEdit, 0, 0, 0, w, h, SWP_NOZORDER);
{$ENDIF}
      end;

    WM_DESTROY:
      PostQuitMessage(0);

  else
    if (uFindMsg <> 0) and (uMsg = uFindMsg) then
      OnFindReplaceMsg                // FINDMSGSTRING нотификация
    else
      Result := DefWindowProcA(hWnd, uMsg, wParam, lParam);
  end;
end;

{ ---- Notepad-style accelerators, които EDIT-ът не покрива ---- }
function CheckAppAccel(const msg: TMsg): Boolean;
var
  cmd: UINT;
begin
  Result := False;
  if msg.message <> WM_KEYDOWN then Exit;
  cmd := 0;
  case msg.wParam of
    VK_F3: cmd := IDM_EDIT_FINDNEXT;
    VK_F5: cmd := IDM_EDIT_TIME;
  else
    if (GetKeyState(VK_CONTROL) and $8000) = 0 then Exit;
    case msg.wParam of
      Ord('N'): cmd := IDM_FILE_NEW;
      Ord('O'): cmd := IDM_FILE_OPEN;
      Ord('S'): if (GetKeyState(VK_SHIFT) and $8000) <> 0 then
                  cmd := IDM_FILE_SAVEAS
                else
                  cmd := IDM_SAVE;
      Ord('P'): cmd := IDM_FILE_PRINT;
      Ord('F'): cmd := IDM_EDIT_FIND;
      Ord('H'): cmd := IDM_EDIT_REPLACE;
      Ord('G'): cmd := IDM_EDIT_GOTO;
    else
      Exit;
    end;
  end;
  SendMessageA(hMain, WM_COMMAND, cmd, 0);
  Result := True;
end;

const
  CourierW: array[0..7] of WideChar = ('C','o','u','r','i','e','r',#0);

var
  wc: TWndClassA;
  msg: TMsg;

begin
  hInstApp := GetModuleHandleA(nil);
  LoadLibraryA(RichDll);                       // модерният Rich Edit
  uFindMsg := RegisterWindowMessageA('commdlg_FindReplace');

  // default Rich Edit font: Courier only
  FillChar(RichFont, SizeOf(RichFont), 0);
  RichFont.cbSize := SizeOf(RichFont);
  RichFont.dwMask := CFM_FACE;
  Move(CourierW, RichFont.szFaceName, SizeOf(CourierW));

  FillChar(wc, SizeOf(wc), 0);                 // останалото нулирано, като в asm-а
  wc.lpfnWndProc   := @MainWndProc;
  wc.hInstance     := hInstApp;
  wc.lpszClassName := ClassName;
  RegisterClassA(@wc);

  ParseStartupFile;

  hMain := CreateWindowExA(0, ClassName, ClassName,
             WS_OVERLAPPEDWINDOW or WS_VISIBLE,
             CW_USEDEFAULT, CW_USEDEFAULT, WindowWidth, WindowHeight,
             0, 0, hInstApp, nil);
  if hMain = 0 then ExitProcess(0);

  LoadStartupFile;
  fDirty := False;
  ApplyTitle;

  while GetMessageA(@msg, 0, 0, 0) do
  begin
    // активният modeless Find/Replace си обработва клавишите
    if (hFindDlg <> 0) and IsDialogMessageA(hFindDlg, @msg) then Continue;
    if CheckAppAccel(msg) then Continue;
    TranslateMessage(msg);
    DispatchMessageA(msg);
  end;

  ExitProcess(msg.wParam);
end.
