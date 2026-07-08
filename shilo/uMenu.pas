unit uMenu;
{ ---------------------------------------------------------
  uMenu - MC-съвместим потребителски меню двигател за Шило.

  Формат на .menu файла:
    # коментар
    = <условие>          (по избор, важи за следващия запис)
    X  Заглавие          (X = hotkey в колона 0)
    <TAB>команда %f      (командни редове, с водещ интервал/TAB)

  Условия:  f <glob> | d | t r|d , комбинирани с & и |
  Макроси:  %f %d %p %s %t %F %D %{подкана} %%
  --------------------------------------------------------- }
{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  Windows, SysUtils, uScreen, uInput, uPanel, uViewer;

{ отваря менюто; Active/Other дават контекста за %-макросите.
  MenuPath е пълният път до .menu файла. }
procedure RunUserMenu(const MenuPath: UnicodeString; Active, Other: TPanel);

{ пуска една команда (вече substituted) и чака; връща конзолата после }
procedure RunCommand(const Cmd: UnicodeString);

{ прост InputBox; връща False при Esc }
function InputBox(const Title, Prompt: UnicodeString;
                  var Value: UnicodeString): Boolean;

{ Да/Не диалог; Enter/y = Да, Esc/n = Не }
function Confirm(const Title, Text: UnicodeString): Boolean;

{ пуска команда БЕЗ overlay (за цикли/тихи операции); чака края }
procedure RunSilent(const Cmd: UnicodeString);

{ показва текстов файл в overlay (F3 Преглед) }
procedure ViewText(const Path: UnicodeString);

{ пуска вложен конзолен TUI (fcd) на реалната конзола, чака, връща екрана }
procedure RunConsoleTUI(const Cmd: UnicodeString);

{ чете избраната от fcd папка от %TEMP%\fcd.dir; '' ако няма }
function ReadFcdDir: UnicodeString;

implementation

type
  TMenuItem = record
    Hotkey : WideChar;
    Title  : UnicodeString;
    Cmd    : array of UnicodeString;
    Cond   : UnicodeString;       { празно = винаги }
  end;

{ ---------- glob match (*, ?), case-insensitive ---------- }
function GlobMatch(const Pat, S: UnicodeString): Boolean;
var
  p, si, star, mark: Integer;
  P2, S2: UnicodeString;
begin
  P2 := WideUpperCase(Pat);
  S2 := WideUpperCase(S);
  p := 1; si := 1; star := 0; mark := 0;
  while si <= Length(S2) do
  begin
    if (p <= Length(P2)) and ((P2[p] = '?') or (P2[p] = S2[si])) then
    begin Inc(p); Inc(si); end
    else if (p <= Length(P2)) and (P2[p] = '*') then
    begin star := p; mark := si; Inc(p); end
    else if star <> 0 then
    begin p := star + 1; Inc(mark); si := mark; end
    else Exit(False);
  end;
  while (p <= Length(P2)) and (P2[p] = '*') do Inc(p);
  Result := p > Length(P2);
end;

{ ---------- оценка на едно условие ---------- }
function EvalAtom(const A: UnicodeString; Active: TPanel): Boolean;
var
  s: UnicodeString;
  arg: UnicodeString;
  sp: Integer;
begin
  s := Trim(A);
  if s = '' then Exit(True);
  sp := Pos(' ', s);
  if sp > 0 then arg := Trim(Copy(s, sp + 1, Length(s))) else arg := '';
  case LowerCase(Copy(s, 1, 1))[1] of
    'f': Result := GlobMatch(arg, Active.CurName);       { файлово име по glob }
    'd': Result := Active.CurIsDir;                       { текущият е папка }
    't': begin                                            { тип: r=файл d=папка }
           if arg = 'd' then Result := Active.CurIsDir
           else Result := not Active.CurIsDir;
         end;
  else
    Result := True;
  end;
end;

function EvalCond(const C: UnicodeString; Active: TPanel): Boolean;
var
  i, start: Integer;
  atom: UnicodeString;
  op: WideChar;
  acc: Boolean;
begin
  if Trim(C) = '' then Exit(True);
  { ляво-към-дясно, & и | с еднакъв приоритет (просто, като MC-скицата) }
  acc := True;
  op := '&';
  start := 1;
  i := 1;
  while i <= Length(C) + 1 do
  begin
    if (i > Length(C)) or (C[i] = '&') or (C[i] = '|') then
    begin
      atom := Copy(C, start, i - start);
      if op = '&' then acc := acc and EvalAtom(atom, Active)
                  else acc := acc or  EvalAtom(atom, Active);
      if i <= Length(C) then op := C[i];
      start := i + 1;
    end;
    Inc(i);
  end;
  Result := acc;
end;

{ ---------- парсване на .menu ---------- }
function LoadMenu(const Path: UnicodeString; out Items: array of TMenuItem;
                  Active: TPanel): Integer;
var
  f: TextFile;
  line, pend: UnicodeString;
  raw: RawByteString;
  n: Integer;
  cur: Integer;
begin
  n := 0;
  cur := -1;
  pend := '';
  Result := 0;
  {$I-}
  AssignFile(f, Path);
  Reset(f);
  {$I+}
  if IOResult <> 0 then Exit;
  while not Eof(f) do
  begin
    ReadLn(f, raw);
    { файлът е UTF-8; преобразувай }
    line := UTF8Decode(raw);
    if line = '' then Continue;
    if line[1] = '#' then Continue;

    if line[1] = '=' then
    begin
      pend := Trim(Copy(line, 2, Length(line)));
      Continue;
    end;

    if (line[1] = ' ') or (line[1] = #9) then
    begin
      { команден ред за текущия запис }
      if cur >= 0 then
      begin
        SetLength(Items[cur].Cmd, Length(Items[cur].Cmd) + 1);
        Items[cur].Cmd[High(Items[cur].Cmd)] := Trim(line);
      end;
      Continue;
    end;

    { нов запис: hotkey + заглавие }
    if n > High(Items) then Break;
    Items[n].Hotkey := line[1];
    Items[n].Title  := Trim(Copy(line, 2, Length(line)));
    Items[n].Cond   := pend;
    SetLength(Items[n].Cmd, 0);
    pend := '';
    cur := n;
    Inc(n);
  end;
  CloseFile(f);
  Result := n;
end;

{ ---------- %-substitution ---------- }
function Substitute(const Cmd: UnicodeString; Active, Other: TPanel): UnicodeString;
var
  i: Integer;
  c, c2: WideChar;
  prompt, val: UnicodeString;
  j: Integer;
begin
  Result := '';
  i := 1;
  while i <= Length(Cmd) do
  begin
    c := Cmd[i];
    if (c = '%') and (i < Length(Cmd)) then
    begin
      c2 := Cmd[i+1];
      case c2 of
        '%': begin Result := Result + '%'; Inc(i, 2); Continue; end;
        'f': begin Result := Result + '"' + Active.CurFull + '"'; Inc(i,2); Continue; end;
        'p': begin Result := Result + '"' + Active.CurFull + '"'; Inc(i,2); Continue; end;
        'd': begin Result := Result + '"' + Active.Dir + '"'; Inc(i,2); Continue; end;
        's','t': begin Result := Result + Active.MarkedList; Inc(i,2); Continue; end;
        'F': begin Result := Result + '"' + Other.CurFull + '"'; Inc(i,2); Continue; end;
        'D': begin Result := Result + '"' + Other.Dir + '"'; Inc(i,2); Continue; end;
        '{': begin
               { %{подкана} }
               j := i + 2;
               prompt := '';
               while (j <= Length(Cmd)) and (Cmd[j] <> '}') do
               begin prompt := prompt + Cmd[j]; Inc(j); end;
               val := '';
               if InputBox('Параметър', prompt, val) then
                 Result := Result + val;
               i := j + 1;
               Continue;
             end;
      end;
    end;
    Result := Result + c;
    Inc(i);
  end;
end;

{ ---------- изпълнение ---------- }
function HasShellMeta(const S: UnicodeString): Boolean;
var i: Integer;
begin
  Result := True;
  for i := 1 to Length(S) do
    if (S[i] = '|') or (S[i] = '<') or (S[i] = '>') or (S[i] = '&') then Exit;
  Result := False;
end;

procedure RunCommand(const Cmd: UnicodeString);
const
  CON_TEXTMODE = 1;   { CONSOLE_TEXTMODE_BUFFER }
var
  si: TStartupInfoW;
  pi: TProcessInformation;
  sa: TSecurityAttributes;
  cmdline: UnicodeString;
  buf: PWideChar;
  hBuf: THandle;
  bufW, bufH: Integer;
  sz, readAt, rowSize: TCoord;
  region: TSmallRect;
  csbi: TConsoleScreenBufferInfo;
  row: array of TCharInfo;
  Lines: array of UnicodeString;
  nLines, y, x, lastNonEmpty: Integer;
  s: UnicodeString;
  guiMode: Boolean;
  rawCmd: UnicodeString;
begin
  rawCmd := Trim(Cmd);
  if rawCmd = '' then Exit;

  { водещ '@' => GUI приложение: пусни без захват, чакай, върни панелите }
  guiMode := (rawCmd[1] = '@');
  if guiMode then
  begin
    rawCmd := Trim(Copy(rawCmd, 2, MaxInt));
    if rawCmd = '' then Exit;
    FillChar(si, SizeOf(si), 0);
    si.cb := SizeOf(si);
    FillChar(pi, SizeOf(pi), 0);
    buf := GetMem((Length(rawCmd) + 1) * SizeOf(WideChar));
    Move(PWideChar(rawCmd)^, buf^, (Length(rawCmd) + 1) * SizeOf(WideChar));
    if CreateProcessW(nil, buf, nil, nil, False, 0, nil, nil, si, pi) then
    begin
      WaitForSingleObject(pi.hProcess, INFINITE);
      CloseHandle(pi.hThread);
      CloseHandle(pi.hProcess);
    end;
    FreeMem(buf);
    Exit;
  end;

  if HasShellMeta(rawCmd) then
    cmdline := 'cmd.exe /c ' + rawCmd    { шел само при нужда (тръби/пренасочване) }
  else
    cmdline := rawCmd;                   { директен CreateProcess, нула cmd.exe }

  { "изпълнявам" индикатор, докато чакаме }
  Box(ScrW div 2 - 15, ScrH div 2 - 1, ScrW div 2 + 15, ScrH div 2 + 1,
      Attr(clWhite, clMagenta), True);
  PutStr(ScrW div 2 - 12, ScrH div 2, 'Изпълнявам…', Attr(clYellow, clMagenta));
  Flush;

  { off-screen console buffer за stdout на детето (WriteConsoleW пише тук) }
  bufW := ScrW; if bufW < 120 then bufW := 120;
  bufH := 2000;
  sa.nLength := SizeOf(sa);
  sa.lpSecurityDescriptor := nil;
  sa.bInheritHandle := True;
  hBuf := CreateConsoleScreenBuffer(GENERIC_READ or GENERIC_WRITE,
            FILE_SHARE_READ or FILE_SHARE_WRITE, sa, CON_TEXTMODE, nil);
  if hBuf <> INVALID_HANDLE_VALUE then
  begin
    sz.X := bufW; sz.Y := bufH;
    SetConsoleScreenBufferSize(hBuf, sz);
  end;

  FillChar(si, SizeOf(si), 0);
  si.cb := SizeOf(si);
  si.dwFlags := STARTF_USESTDHANDLES;
  si.hStdInput  := GetStdHandle(STD_INPUT_HANDLE);
  si.hStdOutput := hBuf;
  si.hStdError  := hBuf;
  FillChar(pi, SizeOf(pi), 0);

  buf := GetMem((Length(cmdline) + 1) * SizeOf(WideChar));
  Move(PWideChar(cmdline)^, buf^, (Length(cmdline) + 1) * SizeOf(WideChar));

  if CreateProcessW(nil, buf, nil, nil, True, 0, nil, nil, si, pi) then
  begin
    WaitForSingleObject(pi.hProcess, INFINITE);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);

    { прочети написаните редове от off-screen буфера }
    nLines := 0;
    if (hBuf <> INVALID_HANDLE_VALUE) and
       GetConsoleScreenBufferInfo(hBuf, csbi) then
    begin
      nLines := csbi.dwCursorPosition.Y + 1;
      if nLines > bufH then nLines := bufH;
      if nLines < 0 then nLines := 0;
    end;

    SetLength(row, bufW);
    SetLength(Lines, nLines);
    rowSize.X := bufW; rowSize.Y := 1;
    readAt.X := 0; readAt.Y := 0;
    lastNonEmpty := -1;
    for y := 0 to nLines - 1 do
    begin
      region.Left := 0; region.Top := y;
      region.Right := bufW - 1; region.Bottom := y;
      ReadConsoleOutputW(hBuf, @row[0], rowSize, readAt, region);
      SetLength(s, bufW);
      for x := 0 to bufW - 1 do s[x + 1] := WideChar(row[x].UnicodeChar);
      while (Length(s) > 0) and (s[Length(s)] = ' ') do
        SetLength(s, Length(s) - 1);
      Lines[y] := s;
      if s <> '' then lastNonEmpty := y;
    end;
    { отрежи крайните празни редове }
    if lastNonEmpty + 1 < nLines then SetLength(Lines, lastNonEmpty + 1);

    if hBuf <> INVALID_HANDLE_VALUE then CloseHandle(hBuf);
    FreeMem(buf);

    if Length(Lines) = 0 then
    begin
      SetLength(Lines, 1);
      Lines[0] := '(тулът не изведе нищо)';
    end;
    ShowText('Изход: ' + Cmd, Lines);
  end
  else
  begin
    if hBuf <> INVALID_HANDLE_VALUE then CloseHandle(hBuf);
    FreeMem(buf);
    SetLength(Lines, 1);
    Lines[0] := 'Не успях да пусна: ' + cmdline;
    ShowText('Грешка', Lines);
  end;
end;

procedure ExecItem(const It: TMenuItem; Active, Other: TPanel);
var
  i: Integer;
  batName, l: UnicodeString;
  tmp: array[0..MAX_PATH] of WideChar;
  bat: TextFile;
begin
  if Length(It.Cmd) = 0 then Exit;
  if Length(It.Cmd) = 1 then
  begin
    RunCommand(Substitute(It.Cmd[0], Active, Other));
    Exit;
  end;
  { многоредова команда -> временен .cmd }
  GetTempPathW(MAX_PATH, @tmp[0]);
  batName := UnicodeString(tmp) + 'shilo_menu.cmd';
  AssignFile(bat, batName);
  Rewrite(bat);
  WriteLn(bat, '@echo off');
  for i := 0 to High(It.Cmd) do
  begin
    l := Substitute(It.Cmd[i], Active, Other);
    WriteLn(bat, UTF8Encode(l));
  end;
  CloseFile(bat);
  RunCommand('cmd.exe /c "' + batName + '"');
  DeleteFileW(PWideChar(batName));
end;

{ ---------- меню UI ---------- }
procedure RunUserMenu(const MenuPath: UnicodeString; Active, Other: TPanel);
var
  Items: array[0..63] of TMenuItem;
  vis: array[0..63] of Integer;      { индекси на видимите }
  nAll, nVis, i, sel, mw, mh, mx, my, row: Integer;
  E: TKeyEvent;
  a, ah: Word;
  s: UnicodeString;
begin
  nAll := LoadMenu(MenuPath, Items, Active);
  if nAll = 0 then
  begin
    { няма меню файл - кажи го и излез }
    Box(ScrW div 2 - 20, ScrH div 2 - 1, ScrW div 2 + 20, ScrH div 2 + 1,
        Attr(clWhite, clRed), True);
    PutStr(ScrW div 2 - 18, ScrH div 2, 'Липсва ' + MenuPath, Attr(clWhite, clRed));
    Flush;
    ReadKey(E);
    Exit;
  end;

  nVis := 0;
  for i := 0 to nAll - 1 do
    if EvalCond(Items[i].Cond, Active) then
    begin vis[nVis] := i; Inc(nVis); end;
  if nVis = 0 then Exit;

  mw := 44;
  mh := nVis + 2;
  mx := (ScrW - mw) div 2;
  my := (ScrH - mh) div 2;
  sel := 0;

  repeat
    a  := Attr(clBlack, clCyan);
    ah := Attr(clBlack, clLtGray);
    FillRect(mx, my, mx + mw, my + mh, ' ', a);
    Box(mx, my, mx + mw, my + mh, Attr(clWhite, clCyan), True);
    PutStr(mx + 2, my, ' Меню на потребителя ', Attr(clYellow, clCyan));

    for row := 0 to nVis - 1 do
    begin
      i := vis[row];
      s := ' ' + Items[i].Hotkey + '  ' + Items[i].Title;
      while Length(s) < mw - 1 do s := s + ' ';
      if Length(s) > mw - 1 then s := Copy(s, 1, mw - 1);
      if row = sel then PutStr(mx + 1, my + 1 + row, s, ah)
                   else PutStr(mx + 1, my + 1 + row, s, a);
    end;
    Flush;

    ReadKey(E);
    if E.Kind = kkSpecial then
      case E.Code of
        kUp:    if sel > 0 then Dec(sel) else sel := nVis - 1;
        kDown:  if sel < nVis - 1 then Inc(sel) else sel := 0;
        kHome:  sel := 0;
        kEnd:   sel := nVis - 1;
        kEsc:   Exit;
        kEnter:
          begin
            ExecItem(Items[vis[sel]], Active, Other);
            Exit;
          end;
      end
    else if E.Kind = kkChar then
    begin
      { hotkey избор }
      for row := 0 to nVis - 1 do
        if WideUpperCase(Items[vis[row]].Hotkey) = WideUpperCase(E.Ch) then
        begin
          ExecItem(Items[vis[row]], Active, Other);
          Exit;
        end;
    end
    else if E.Kind = kkResize then
    begin
      ScrSync;
      mx := (ScrW - mw) div 2;
      my := (ScrH - mh) div 2;
    end;
  until False;
end;

{ ---------- InputBox ---------- }
function InputBox(const Title, Prompt: UnicodeString;
                  var Value: UnicodeString): Boolean;
var
  bw, bx, by, ix, iw: Integer;
  E: TKeyEvent;
  a, ia: Word;
  s: UnicodeString;
begin
  Result := False;
  bw := 50;
  bx := (ScrW - bw) div 2;
  by := ScrH div 2 - 1;
  ix := bx + 2;
  iw := bw - 4;

  repeat
    a  := Attr(clWhite, clBlue);
    ia := Attr(clYellow, clBlack);
    FillRect(bx, by, bx + bw, by + 4, ' ', a);
    Box(bx, by, bx + bw, by + 4, a, True);
    PutStr(bx + 2, by, ' ' + Title + ' ', Attr(clYellow, clBlue));
    PutStr(bx + 2, by + 1, Prompt, a);
    s := Value;
    if Length(s) > iw then s := Copy(s, Length(s) - iw + 1, iw);
    while Length(s) < iw do s := s + ' ';
    PutStr(ix, by + 2, s, ia);
    ShowCursor(True);
    GotoXY(ix + Length(Value), by + 2);
    Flush;

    ReadKey(E);
    case E.Kind of
      kkChar: Value := Value + E.Ch;
      kkSpecial:
        case E.Code of
          kBack: if Length(Value) > 0 then SetLength(Value, Length(Value) - 1);
          kEnter: begin Result := True; Break; end;
          kEsc:   begin Result := False; Break; end;
        end;
      kkResize:
        begin
          ScrSync;
          bx := (ScrW - bw) div 2;
          by := ScrH div 2 - 1;
          ix := bx + 2;
        end;
    end;
  until False;

  ShowCursor(False);
end;

{ ---------- Confirm (Да/Не) ---------- }
function Confirm(const Title, Text: UnicodeString): Boolean;
var
  bw, bx, by: Integer;
  E: TKeyEvent;
  a: Word;
  s: UnicodeString;
begin
  Result := False;
  bw := Length(Text) + 6;
  if bw < 32 then bw := 32;
  if bw > ScrW - 4 then bw := ScrW - 4;
  repeat
    bx := (ScrW - bw) div 2;
    by := ScrH div 2 - 2;
    a := Attr(clWhite, clRed);
    FillRect(bx, by, bx + bw, by + 4, ' ', a);
    Box(bx, by, bx + bw, by + 4, a, True);
    s := ' ' + Title + ' ';
    PutStr(bx + 2, by, s, Attr(clYellow, clRed));
    PutStr(bx + 3, by + 1, Text, a);
    PutStr(bx + 3, by + 3, 'Enter = Да     Esc = Не', Attr(clYellow, clRed));
    Flush;
    ReadKey(E);
    case E.Kind of
      kkSpecial:
        case E.Code of
          kEnter: begin Result := True;  Exit; end;
          kEsc:   begin Result := False; Exit; end;
        end;
      kkChar:
        case E.Ch of
          'y','Y','д','Д': begin Result := True;  Exit; end;
          'n','N','н','Н': begin Result := False; Exit; end;
        end;
      kkResize: ScrSync;
    end;
  until False;
end;

{ ---------- RunSilent (без overlay) ---------- }
procedure RunSilent(const Cmd: UnicodeString);
const
  CON_TEXTMODE = 1;
var
  si: TStartupInfoW;
  pi: TProcessInformation;
  sa: TSecurityAttributes;
  hBuf: THandle;
  buf: PWideChar;
  cmdline: UnicodeString;
begin
  if Trim(Cmd) = '' then Exit;
  if HasShellMeta(Cmd) then cmdline := 'cmd.exe /c ' + Cmd else cmdline := Cmd;

  { off-screen буфер, за да не splat-ва WriteConsoleW тулът; не го четем }
  sa.nLength := SizeOf(sa);
  sa.lpSecurityDescriptor := nil;
  sa.bInheritHandle := True;
  hBuf := CreateConsoleScreenBuffer(GENERIC_READ or GENERIC_WRITE,
            FILE_SHARE_READ or FILE_SHARE_WRITE, sa, CON_TEXTMODE, nil);

  FillChar(si, SizeOf(si), 0);
  si.cb := SizeOf(si);
  si.dwFlags := STARTF_USESTDHANDLES;
  si.hStdInput  := GetStdHandle(STD_INPUT_HANDLE);
  si.hStdOutput := hBuf;
  si.hStdError  := hBuf;
  FillChar(pi, SizeOf(pi), 0);

  buf := GetMem((Length(cmdline) + 1) * SizeOf(WideChar));
  Move(PWideChar(cmdline)^, buf^, (Length(cmdline) + 1) * SizeOf(WideChar));
  if CreateProcessW(nil, buf, nil, nil, True, 0, nil, nil, si, pi) then
  begin
    WaitForSingleObject(pi.hProcess, INFINITE);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
  end;
  FreeMem(buf);
  if hBuf <> INVALID_HANDLE_VALUE then CloseHandle(hBuf);
end;

{ ---------- ViewText (F3) ---------- }
procedure ViewText(const Path: UnicodeString);
var
  h: THandle;
  sz, got: DWORD;
  raw: RawByteString;
  u: UnicodeString;
  Lines: TStrArr;
  i, start, n: Integer;
  ch: WideChar;
begin
  h := CreateFileW(PWideChar(Path), GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE,
                   nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if h = INVALID_HANDLE_VALUE then
  begin
    SetLength(Lines, 1); Lines[0] := 'Не мога да отворя: ' + Path;
    ShowText('Грешка', Lines); Exit;
  end;
  sz := GetFileSize(h, nil);
  if sz = $FFFFFFFF then sz := 0;
  if sz > 4 * 1024 * 1024 then sz := 4 * 1024 * 1024;   { таван 4 MB }
  SetLength(raw, sz);
  got := 0;
  if sz > 0 then ReadFile(h, raw[1], sz, got, nil);
  CloseHandle(h);
  SetLength(raw, got);

  u := UTF8Decode(raw);
  if (u = '') and (got > 0) then u := UnicodeString(raw);   { fallback ANSI }

  { разбий на редове по #10, махни #13, непечатимите -> '.' }
  SetLength(Lines, 0);
  n := 0;
  start := 1;
  for i := 1 to Length(u) + 1 do
  begin
    if (i > Length(u)) or (u[i] = #10) then
    begin
      if n >= Length(Lines) then SetLength(Lines, (n + 64) * 2);
      Lines[n] := Copy(u, start, i - start);
      { махни завършващ #13 }
      if (Length(Lines[n]) > 0) and (Lines[n][Length(Lines[n])] = #13) then
        SetLength(Lines[n], Length(Lines[n]) - 1);
      { табове -> интервали, control -> '.' }
      for start := 1 to Length(Lines[n]) do
      begin
        ch := Lines[n][start];
        if ch = #9 then Lines[n][start] := ' '
        else if ch < #32 then Lines[n][start] := '.';
      end;
      Inc(n);
      start := i + 1;
    end;
  end;
  SetLength(Lines, n);
  if n = 0 then begin SetLength(Lines, 1); Lines[0] := '(празен файл)'; end;
  ShowText('Преглед: ' + Path, Lines);
end;

{ ---------- вложен конзолен TUI (fcd) ---------- }
procedure RunConsoleTUI(const Cmd: UnicodeString);
var
  si: TStartupInfoW;
  pi: TProcessInformation;
  buf: PWideChar;
begin
  if Trim(Cmd) = '' then Exit;
  FillChar(si, SizeOf(si), 0);
  si.cb := SizeOf(si);
  FillChar(pi, SizeOf(pi), 0);
  buf := GetMem((Length(Cmd) + 1) * SizeOf(WideChar));
  Move(PWideChar(Cmd)^, buf^, (Length(Cmd) + 1) * SizeOf(WideChar));
  { дели нашата конзола: детето рисува на реалния екран, ние сме блокирани }
  if CreateProcessW(nil, buf, nil, nil, True, 0, nil, nil, si, pi) then
  begin
    WaitForSingleObject(pi.hProcess, INFINITE);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
  end;
  FreeMem(buf);
  ScrSync;   { детето надраска екрана -> форсирай пълно преначертаване }
end;

function ReadFcdDir: UnicodeString;
var
  h: THandle;
  sz, got: DWORD;
  raw: RawByteString;
  tmp: array[0..MAX_PATH] of WideChar;
  p: UnicodeString;
begin
  Result := '';
  GetTempPathW(MAX_PATH, @tmp[0]);
  p := UnicodeString(tmp) + 'fcd.dir';
  h := CreateFileW(PWideChar(p), GENERIC_READ, FILE_SHARE_READ, nil,
                   OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if h = INVALID_HANDLE_VALUE then Exit;
  sz := GetFileSize(h, nil);
  if sz = $FFFFFFFF then sz := 0;
  if sz > 4096 then sz := 4096;
  SetLength(raw, sz);
  got := 0;
  if sz > 0 then ReadFile(h, raw[1], sz, got, nil);
  CloseHandle(h);
  SetLength(raw, got);
  Result := Trim(UTF8Decode(raw));
  { изтрий файла, за да не се преизползва застоял избор }
  DeleteFileW(PWideChar(p));
end;

end.
