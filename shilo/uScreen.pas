unit uScreen;
{ ---------------------------------------------------------
  uScreen - конзолен фреймбуфер за Шило хъба (MC-style TUI)
  Суров Win32 console API, WriteConsoleOutputW двоен буфер.
  Нула DLL извън kernel32. Wide (UTF-16) навсякъде.
  --------------------------------------------------------- }
{$mode objfpc}{$H+}

interface

uses
  Windows;

type
  { нормализирани цветове - същите като конзолните атрибути,
    но с четими имена; фон = hi nibble, текст = lo nibble }
  TScrColor = Word;

const
  clBlack   = 0;  clBlue    = 1;  clGreen   = 2;  clCyan    = 3;
  clRed     = 4;  clMagenta = 5;  clBrown   = 6;  clLtGray  = 7;
  clDkGray  = 8;  clLtBlue  = 9;  clLtGreen = 10; clLtCyan  = 11;
  clLtRed   = 12; clLtMag   = 13; clYellow  = 14; clWhite   = 15;

function Attr(FG, BG: TScrColor): Word; inline;

{ инициализация / край; ScrInit връща false ако няма конзола }
function  ScrInit: Boolean;
procedure ScrDone;

{ текущ размер на буфера, обновява се от ScrInit / ScrSync }
var
  ScrW: Integer = 80;
  ScrH: Integer = 25;

{ рисуване в back буфера (0-базирани координати) }
procedure ScrClear(A: Word);
procedure PutCh(X, Y: Integer; Ch: WideChar; A: Word);
procedure PutStr(X, Y: Integer; const S: UnicodeString; A: Word);
procedure FillRect(X1, Y1, X2, Y2: Integer; Ch: WideChar; A: Word);
procedure HLine(X, Y, Len: Integer; A: Word; Dbl: Boolean = False);
procedure VLine(X, Y, Len: Integer; A: Word; Dbl: Boolean = False);
procedure Box(X1, Y1, X2, Y2: Integer; A: Word; Dbl: Boolean = False);

{ прехвърля back буфера на екрана (само при разлика от front) }
procedure Flush;

{ re-чете размера на прозореца; realloc при промяна; форсира пълно преначертаване }
procedure ScrSync;

{ отстъпва конзолата на дъщерен процес и я връща обратно }
procedure ScrSuspend;
procedure ScrResume;

{ хардуерен курсор }
procedure ShowCursor(Vis: Boolean);
procedure GotoXY(X, Y: Integer);

implementation

var
  hOut, hIn : THandle;
  Back, Front : array of TCharInfo;
  Inited : Boolean = False;
  SavedMode : DWORD = 0;
  SavedCP : UINT = 0;

function Attr(FG, BG: TScrColor): Word; inline;
begin
  Attr := Word((BG shl 4) or (FG and $0F));
end;

function Idx(X, Y: Integer): Integer; inline;
begin
  Idx := Y * ScrW + X;
end;

function InBuf(X, Y: Integer): Boolean; inline;
begin
  InBuf := (X >= 0) and (X < ScrW) and (Y >= 0) and (Y < ScrH);
end;

procedure Alloc;
begin
  SetLength(Back,  ScrW * ScrH);
  SetLength(Front, ScrW * ScrH);
end;

function ScrInit: Boolean;
var
  csbi: TConsoleScreenBufferInfo;
begin
  Result := False;
  hOut := GetStdHandle(STD_OUTPUT_HANDLE);
  hIn  := GetStdHandle(STD_INPUT_HANDLE);
  if (hOut = INVALID_HANDLE_VALUE) or (hIn = INVALID_HANDLE_VALUE) then Exit;
  if not GetConsoleScreenBufferInfo(hOut, csbi) then Exit;

  ScrW := csbi.srWindow.Right  - csbi.srWindow.Left + 1;
  ScrH := csbi.srWindow.Bottom - csbi.srWindow.Top  + 1;
  if (ScrW <= 0) or (ScrH <= 0) then Exit;

  { входният режим: без line/echo, с window/mouse събития }
  GetConsoleMode(hIn, @SavedMode);
  SetConsoleMode(hIn, ENABLE_WINDOW_INPUT or ENABLE_MOUSE_INPUT
                      or ENABLE_EXTENDED_FLAGS);
  SavedCP := GetConsoleOutputCP;
  SetConsoleOutputCP(CP_UTF8);

  Alloc;
  Inited := True;
  ScrClear(Attr(clLtGray, clBlack));
  { front нулиран с невъзможен атрибут -> първият Flush рисува всичко }
  FillChar(Front[0], Length(Front) * SizeOf(TCharInfo), $FF);
  Result := True;
end;

procedure ScrDone;
begin
  if not Inited then Exit;
  ShowCursor(True);
  if SavedMode <> 0 then SetConsoleMode(hIn, SavedMode);
  if SavedCP  <> 0 then SetConsoleOutputCP(SavedCP);
  SetLength(Back, 0);
  SetLength(Front, 0);
  Inited := False;
end;

procedure ScrClear(A: Word);
var
  i: Integer;
begin
  for i := 0 to High(Back) do
  begin
    Back[i].UnicodeChar := WideChar(' ');
    Back[i].Attributes  := A;
  end;
end;

procedure PutCh(X, Y: Integer; Ch: WideChar; A: Word);
var
  i: Integer;
begin
  if not InBuf(X, Y) then Exit;
  i := Idx(X, Y);
  Back[i].UnicodeChar := Ch;
  Back[i].Attributes  := A;
end;

procedure PutStr(X, Y: Integer; const S: UnicodeString; A: Word);
var
  k, cx: Integer;
begin
  if (Y < 0) or (Y >= ScrH) then Exit;
  cx := X;
  for k := 1 to Length(S) do
  begin
    if cx >= ScrW then Break;
    if cx >= 0 then
    begin
      Back[Idx(cx, Y)].UnicodeChar := S[k];
      Back[Idx(cx, Y)].Attributes  := A;
    end;
    Inc(cx);
  end;
end;

procedure FillRect(X1, Y1, X2, Y2: Integer; Ch: WideChar; A: Word);
var
  x, y: Integer;
begin
  for y := Y1 to Y2 do
    for x := X1 to X2 do
      PutCh(x, y, Ch, A);
end;

const
  { single, double: горен-ляв, горен-десен, долен-ляв, долен-десен, хор, верт }
  BoxS: array[0..5] of WideChar = (#$250C, #$2510, #$2514, #$2518, #$2500, #$2502);
  BoxD: array[0..5] of WideChar = (#$2554, #$2557, #$255A, #$255D, #$2550, #$2551);

procedure HLine(X, Y, Len: Integer; A: Word; Dbl: Boolean);
var
  i: Integer; c: WideChar;
begin
  if Dbl then c := BoxD[4] else c := BoxS[4];
  for i := 0 to Len - 1 do PutCh(X + i, Y, c, A);
end;

procedure VLine(X, Y, Len: Integer; A: Word; Dbl: Boolean);
var
  i: Integer; c: WideChar;
begin
  if Dbl then c := BoxD[5] else c := BoxS[5];
  for i := 0 to Len - 1 do PutCh(X, Y + i, c, A);
end;

procedure Box(X1, Y1, X2, Y2: Integer; A: Word; Dbl: Boolean);
var
  b: ^WideChar;
begin
  if Dbl then b := @BoxD[0] else b := @BoxS[0];
  HLine(X1 + 1, Y1, X2 - X1 - 1, A, Dbl);
  HLine(X1 + 1, Y2, X2 - X1 - 1, A, Dbl);
  VLine(X1, Y1 + 1, Y2 - Y1 - 1, A, Dbl);
  VLine(X2, Y1 + 1, Y2 - Y1 - 1, A, Dbl);
  PutCh(X1, Y1, b[0], A);
  PutCh(X2, Y1, b[1], A);
  PutCh(X1, Y2, b[2], A);
  PutCh(X2, Y2, b[3], A);
end;

procedure Flush;
var
  bufSize, bufCoord: TCoord;
  region: TSmallRect;
  y, x, i, x0, x1: Integer;
  rowChanged: Boolean;
begin
  if not Inited then Exit;
  { ред по ред: пиши само променените редове, минимизирайки WriteConsoleOutputW }
  bufSize.X := ScrW;
  bufSize.Y := 1;
  bufCoord.X := 0;
  bufCoord.Y := 0;
  for y := 0 to ScrH - 1 do
  begin
    rowChanged := False;
    x0 := y * ScrW;
    for x := 0 to ScrW - 1 do
    begin
      i := x0 + x;
      if (Back[i].UnicodeChar <> Front[i].UnicodeChar) or
         (Back[i].Attributes  <> Front[i].Attributes) then
      begin
        rowChanged := True;
        Break;
      end;
    end;
    if not rowChanged then Continue;

    region.Left   := 0;
    region.Top    := y;
    region.Right  := ScrW - 1;
    region.Bottom := y;
    WriteConsoleOutputW(hOut, @Back[x0], bufSize, bufCoord, region);
    { синхронизирай front за този ред }
    for x := 0 to ScrW - 1 do
    begin
      x1 := x0 + x;
      Front[x1] := Back[x1];
    end;
  end;
end;

procedure ForceRedraw;
begin
  if Length(Front) > 0 then
    FillChar(Front[0], Length(Front) * SizeOf(TCharInfo), $FF);
end;

procedure ScrSync;
var
  csbi: TConsoleScreenBufferInfo;
  nW, nH: Integer;
begin
  if not Inited then Exit;
  if not GetConsoleScreenBufferInfo(hOut, csbi) then Exit;
  nW := csbi.srWindow.Right  - csbi.srWindow.Left + 1;
  nH := csbi.srWindow.Bottom - csbi.srWindow.Top  + 1;
  if (nW > 0) and (nH > 0) and ((nW <> ScrW) or (nH <> ScrH)) then
  begin
    ScrW := nW;
    ScrH := nH;
    Alloc;
    ScrClear(Attr(clLtGray, clBlack));
  end;
  ForceRedraw;
end;

procedure ScrSuspend;
begin
  if not Inited then Exit;
  if SavedMode <> 0 then SetConsoleMode(hIn, SavedMode);
  { CP остава UTF-8: дъщерните тула са WriteConsoleW (без значение),
    а нашите кирилски съобщения се рендерят коректно }
  ShowCursor(True);
  GotoXY(0, 0);
end;

procedure ScrResume;
begin
  if not Inited then Exit;
  SetConsoleMode(hIn, ENABLE_WINDOW_INPUT or ENABLE_MOUSE_INPUT
                      or ENABLE_EXTENDED_FLAGS);
  SetConsoleOutputCP(CP_UTF8);
  ShowCursor(False);
  ScrSync;
end;

procedure ShowCursor(Vis: Boolean);
var
  ci: TConsoleCursorInfo;
begin
  if not Inited then Exit;
  GetConsoleCursorInfo(hOut, ci);
  ci.bVisible := Vis;
  SetConsoleCursorInfo(hOut, ci);
end;

procedure GotoXY(X, Y: Integer);
var
  c: TCoord;
begin
  if not Inited then Exit;
  c.X := X;
  c.Y := Y;
  SetConsoleCursorPosition(hOut, c);
end;

end.
