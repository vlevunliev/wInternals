program shilo;
{ ---------------------------------------------------------
  shilo - Шило хъб: двупанелен MC-style лаунчър за Шило тулчетата.
  Суров Win32 console API, нула DLL извън kernel32/user32.
  Всички файлови операции се делегират на тулчетата през F2 менюто.

    fpc -Twin32 -O2 shilo.pas     (или -Twin64)

  Файлове до exe-то:
    shilo.menu  - потребителското меню (MC-съвместимо)
    shilo.ini   - [shilo] Editor=trpad.exe
  --------------------------------------------------------- }
{$mode objfpc}{$H+}
{$codepage UTF8}
{$APPTYPE CONSOLE}

uses
  Windows, SysUtils, uScreen, uInput, uPanel, uMenu, uViewer;

var
  Left, Right : TPanel;
  Active      : TPanel;
  MenuFile    : UnicodeString;
  EditorCmd   : UnicodeString = 'trpad.exe';
  Running     : Boolean = True;

function ExeDir: UnicodeString;
var
  buf: array[0..MAX_PATH] of WideChar;
  n, i: DWORD;
begin
  n := GetModuleFileNameW(0, @buf[0], MAX_PATH);
  Result := Copy(UnicodeString(buf), 1, n);
  i := Length(Result);
  while (i > 0) and (Result[i] <> '\') do Dec(i);
  Result := Copy(Result, 1, i);       { с крайния '\' }
end;

procedure ReadIni;
var
  f: TextFile;
  raw: RawByteString;
  line, key, val: UnicodeString;
  p: Integer;
begin
  {$I-}
  AssignFile(f, ExeDir + 'shilo.ini');
  Reset(f);
  {$I+}
  if IOResult <> 0 then Exit;
  while not Eof(f) do
  begin
    ReadLn(f, raw);
    line := Trim(UTF8Decode(raw));
    if (line = '') or (line[1] = '[') or (line[1] = ';') or (line[1] = '#') then
      Continue;
    p := Pos('=', line);
    if p = 0 then Continue;
    key := LowerCase(Trim(Copy(line, 1, p - 1)));
    val := Trim(Copy(line, p + 1, Length(line)));
    if key = 'editor' then EditorCmd := val;
  end;
  CloseFile(f);
end;

procedure Layout;
var
  mid, py2: Integer;
begin
  mid := ScrW div 2;
  py2 := ScrH - 2;                    { последният ред = F-бар }
  Left.SetBounds(0, 0, mid - 1, py2);
  Right.SetBounds(mid, 0, ScrW - 1, py2);
end;

procedure DrawFBar;
type
  TSlot = record n: UnicodeString; lbl: UnicodeString; end;
const
  Slots: array[0..8] of TSlot = (
    (n: '1'; lbl: 'Помощ'),
    (n: '2'; lbl: 'Меню'),
    (n: '3'; lbl: 'Преглед'),
    (n: '4'; lbl: 'Ред'),
    (n: '5'; lbl: 'Копирай'),
    (n: '7'; lbl: 'Папка'),
    (n: '8'; lbl: 'Изтрий'),
    (n: '9'; lbl: 'Дърво'),
    (n: '10'; lbl: 'Изход'));
var
  y, i, x: Integer;
  na, la: Word;
begin
  y := ScrH - 1;
  na := Attr(clWhite,  clBlack);   { номерът }
  la := Attr(clBlack,  clCyan);    { етикетът }
  FillRect(0, y, ScrW - 1, y, ' ', la);
  x := 0;
  for i := 0 to High(Slots) do
  begin
    PutStr(x, y, Slots[i].n, na);
    Inc(x, Length(Slots[i].n));
    PutStr(x, y, Slots[i].lbl + ' ', la);
    Inc(x, Length(Slots[i].lbl) + 1);
  end;
end;

procedure Redraw;
begin
  ScrClear(Attr(clLtGray, clBlack));
  Left.Draw;
  Right.Draw;
  DrawFBar;
  Flush;
end;

procedure SwitchPanel;
begin
  Active.Active := False;
  if Active = Left then Active := Right else Active := Left;
  Active.Active := True;
end;

function OtherPanel: TPanel;
begin
  if Active = Left then Result := Right else Result := Left;
end;

procedure DoEdit;
begin
  if Active.CurName = '' then Exit;
  if Active.CurIsDir then Exit;
  RunCommand('@"' + EditorCmd + '" "' + Active.CurFull + '"');
end;

procedure DoView;
begin
  if Active.CurName = '' then Exit;
  if Active.CurIsDir then Exit;
  if LowerCase(ExtractFileExt(string(Active.CurFull))) = '.pdf' then
    RunCommand('@tinyPDFViewer "' + Active.CurFull + '"')
  else
    ViewText(Active.CurFull);
end;

function QuoteList(const items: TStrArr): UnicodeString;
var i: Integer;
begin
  Result := '';
  for i := 0 to High(items) do
  begin
    if Result <> '' then Result := Result + ' ';
    Result := Result + '"' + items[i] + '"';
  end;
end;

procedure DoCopy;
var
  items: TStrArr;
  dst: UnicodeString;
begin
  items := Active.MarkedPaths;
  if Length(items) = 0 then Exit;
  dst := OtherPanel.Dir;
  if not Confirm('Копиране',
       'Копирай ' + UnicodeString(IntToStr(Length(items))) +
       ' обекта в ' + dst + ' ?') then Exit;
  { всички източници + целта в едно извикване }
  RunSilent('fcopy ' + QuoteList(items) + ' "' + dst + '" /MT');
  Left.Reload; Right.Reload;
end;

procedure DoDelete;
var
  items: TStrArr;
begin
  items := Active.MarkedPaths;
  if Length(items) = 0 then Exit;
  if not Confirm('ИЗТРИВАНЕ',
       'Изтрий БЕЗВЪЗВРАТНО ' + UnicodeString(IntToStr(Length(items))) +
       ' обекта ?') then Exit;
  { всички цели в едно извикване }
  RunSilent('fdel ' + QuoteList(items) + ' /Q /MT');
  Left.Reload; Right.Reload;
end;

procedure DoMkDir;
var
  name: UnicodeString;
begin
  name := '';
  if not InputBox('Нова папка', 'Име:', name) then Exit;
  if Trim(name) = '' then Exit;
  CreateDirectoryW(PWideChar(Active.Dir + name), nil);
  Left.Reload; Right.Reload;
end;

procedure DoNCD;
var
  chosen: UnicodeString;
  drive: UnicodeString;
begin
  { пусни fcd върху корена на активния диск, реална конзола }
  drive := Copy(Active.Dir, 1, 2) + '\';       { напр. C:\ }
  RunConsoleTUI('fcd "' + drive + '"');
  chosen := ReadFcdDir;
  if chosen <> '' then Active.ReadDir(chosen);
end;

procedure DoHelp;
var
  h: TStrArr;
begin
  SetLength(h, 16);
  h[0]  := 'Шило хъб — клавиши';
  h[1]  := '';
  h[2]  := '  Tab           смяна на активен панел';
  h[3]  := '  стрелки       курсор';
  h[4]  := '  PgUp/PgDn     страница';
  h[5]  := '  Home/End      начало/край';
  h[6]  := '  Enter         влизане в папка / нагоре';
  h[7]  := '  Ins           маркирай и слез';
  h[8]  := '';
  h[9]  := '  F1  Помощ      F2  Меню (шило тула)';
  h[10] := '  F3  Преглед    F4  Редактор (trpad)';
  h[11] := '  F5  Копирай    F7  Нова папка';
  h[12] := '  F8  Изтрий     F10 Изход';
  h[13] := '';
  h[14] := '  F2 отваря пълното меню с всички инструменти';
  h[15] := '  (fmft, fads, fcert, fhandle, fdu, fdupe ...)';
  ShowText('Помощ', h);
end;

procedure HandleKey(const E: TKeyEvent);
begin
  case E.Kind of
    kkResize:
      begin ScrSync; Layout; end;

    kkSpecial:
      case E.Code of
        kTab:   SwitchPanel;
        kUp:    Active.MoveCursor(-1);
        kDown:  Active.MoveCursor(1);
        kPgUp:  Active.MoveCursor(-(ScrH div 2));
        kPgDn:  Active.MoveCursor(ScrH div 2);
        kHome:  Active.CursorHome;
        kEnd:   Active.CursorEnd;
        kIns:   Active.ToggleMark;
        kEnter: if Active.CurIsDir then Active.Enter;
        kF1:    DoHelp;
        kF2:    begin RunUserMenu(MenuFile, Active, OtherPanel);
                      Left.Reload; Right.Reload; end;
        kF3:    DoView;
        kF4:    DoEdit;
        kF5:    DoCopy;
        kF7:    DoMkDir;
        kF8:    DoDelete;
        kF9:    DoNCD;
        kF10:   Running := False;
        kEsc:   Running := False;
      end;

    kkChar:
      if E.Ch = 'q' then Running := False;
  end;
end;

var
  E: TKeyEvent;
  startDir: UnicodeString;
  otherOf : TPanel;
begin
  if not ScrInit then
  begin
    Writeln('Не мога да инициализирам конзолата.');
    Halt(1);
  end;
  ShowCursor(False);

  MenuFile := ExeDir + 'shilo.menu';
  ReadIni;

  startDir := UnicodeString(GetCurrentDir);
  Left  := TPanel.Create;
  Right := TPanel.Create;
  Layout;
  Left.ReadDir(startDir);
  Right.ReadDir(startDir);
  Active := Left;
  Left.Active := True;

  Redraw;
  while Running do
  begin
    ReadKey(E);
    HandleKey(E);
    if Running then Redraw;
  end;

  Left.Free;
  Right.Free;
  ScrDone;
end.
