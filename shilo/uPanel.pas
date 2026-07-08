unit uPanel;
{ ---------------------------------------------------------
  uPanel - двупанелен файлов списък за Шило хъба.
  FindFirstFileW четене, колони, курсор, скрол, маркиране.
  --------------------------------------------------------- }
{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  Windows, SysUtils, uScreen;

type
  TStrArr = array of UnicodeString;

  TFileEntry = record
    Name     : UnicodeString;
    Size     : Int64;
    IsDir    : Boolean;
    IsUp     : Boolean;      { ".." }
    Marked   : Boolean;
    Attr     : DWORD;
  end;

  TPanel = class
  private
    FEntries : array of TFileEntry;
    FCount   : Integer;
    FCursor  : Integer;
    FTop     : Integer;
    procedure Add(const E: TFileEntry);
    procedure SortEntries;
    function  RowsVisible: Integer;
    procedure ClampScroll;
  public
    Dir      : UnicodeString;      { текуща папка, завършва с '\' }
    X1,Y1,X2,Y2 : Integer;         { граници на панела }
    Active   : Boolean;
    constructor Create;
    procedure SetBounds(AX1,AY1,AX2,AY2: Integer);
    procedure ReadDir(const APath: UnicodeString);
    procedure Reload;
    procedure Draw;
    procedure MoveCursor(Delta: Integer);
    procedure CursorHome;
    procedure CursorEnd;
    procedure Enter;                { влиза в папка / нагоре }
    procedure ToggleMark;           { маркира и слиза надолу }
    function  CurName: UnicodeString;
    function  CurFull: UnicodeString;
    function  CurIsDir: Boolean;
    function  MarkedCount: Integer;
    { връща маркираните (или текущия ако няма маркирани) като
      кавичкирани пълни пътища, разделени с интервал }
    function  MarkedList: UnicodeString;
    { маркираните (или текущия ако няма) като пълни пътища, без кавички }
    function  MarkedPaths: TStrArr;
  end;

implementation

const
  clFrame  = 0;  { задават се в Draw според Active }

constructor TPanel.Create;
begin
  inherited Create;
  Dir := '';
  FCount := 0;
  FCursor := 0;
  FTop := 0;
  Active := False;
end;

procedure TPanel.SetBounds(AX1,AY1,AX2,AY2: Integer);
begin
  X1 := AX1; Y1 := AY1; X2 := AX2; Y2 := AY2;
end;

function TPanel.RowsVisible: Integer;
begin
  Result := (Y2 - Y1) - 1;          { рамка горе/долу }
  if Result < 1 then Result := 1;
end;

procedure TPanel.Add(const E: TFileEntry);
begin
  if FCount > High(FEntries) then
    SetLength(FEntries, (FCount + 1) * 2);
  FEntries[FCount] := E;
  Inc(FCount);
end;

procedure TPanel.SortEntries;
var
  i, j: Integer;
  t: TFileEntry;
  function Less(const A, B: TFileEntry): Boolean;
  begin
    if A.IsUp <> B.IsUp then Exit(A.IsUp);
    if A.IsDir <> B.IsDir then Exit(A.IsDir);
    Less := WideCompareText(A.Name, B.Name) < 0;
  end;
begin
  { прост insertion sort - директориите нагоре, после по име }
  for i := 1 to FCount - 1 do
  begin
    t := FEntries[i];
    j := i - 1;
    while (j >= 0) and Less(t, FEntries[j]) do
    begin
      FEntries[j+1] := FEntries[j];
      Dec(j);
    end;
    FEntries[j+1] := t;
  end;
end;

procedure TPanel.ReadDir(const APath: UnicodeString);
var
  fd: TWin32FindDataW;
  h: THandle;
  E: TFileEntry;
  nm: UnicodeString;
  full, mask: UnicodeString;
  buf: array[0..MAX_PATH] of WideChar;
  fp: PWideChar;
  n: DWORD;
begin
  { нормализирай към абсолютен път със завършващ '\' }
  full := APath;
  n := GetFullPathNameW(PWideChar(full), MAX_PATH, @buf[0], fp);
  if (n > 0) and (n <= MAX_PATH) then
    full := buf;
  if (Length(full) = 0) then full := 'C:\';
  if full[Length(full)] <> '\' then full := full + '\';
  Dir := full;

  FCount := 0;
  SetLength(FEntries, 64);

  { ".." освен в корена }
  if Length(full) > 3 then
  begin
    E.Name := '..'; E.Size := 0; E.IsDir := True; E.IsUp := True;
    E.Marked := False; E.Attr := FILE_ATTRIBUTE_DIRECTORY;
    Add(E);
  end;

  mask := full + '*';
  h := FindFirstFileW(PWideChar(mask), fd);
  if h <> INVALID_HANDLE_VALUE then
  try
    repeat
      nm := fd.cFileName;
      if (nm = '.') or (nm = '..') then Continue;
      E.Name   := nm;
      E.Attr   := fd.dwFileAttributes;
      E.IsDir  := (fd.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0;
      E.IsUp   := False;
      E.Marked := False;
      E.Size   := (Int64(fd.nFileSizeHigh) shl 32) or fd.nFileSizeLow;
      Add(E);
    until not FindNextFileW(h, fd);
  finally
    Windows.FindClose(h);
  end;

  SortEntries;
  FCursor := 0;
  FTop := 0;
end;

procedure TPanel.Reload;
var
  keep: UnicodeString;
begin
  keep := CurName;
  ReadDir(Dir);
end;

procedure TPanel.ClampScroll;
var
  rv: Integer;
begin
  rv := RowsVisible;
  if FCursor < 0 then FCursor := 0;
  if FCursor >= FCount then FCursor := FCount - 1;
  if FCursor < 0 then FCursor := 0;
  if FCursor < FTop then FTop := FCursor;
  if FCursor >= FTop + rv then FTop := FCursor - rv + 1;
  if FTop < 0 then FTop := 0;
end;

function FmtSize(S: Int64; IsDir: Boolean): UnicodeString;
begin
  if IsDir then Exit('   <DIR>');
  if S < 1000000 then
    Result := UnicodeString(Format('%8d', [S]))
  else if S < Int64(1000000000) then
    Result := UnicodeString(Format('%6dK', [S div 1024]))
  else
    Result := UnicodeString(Format('%6dM', [S div (1024*1024)]));
end;

procedure TPanel.Draw;
var
  fr, hd, sel, mk, nrm: Word;
  rv, i, row, y, innerW: Integer;
  E: TFileEntry;
  s, nm, sz: UnicodeString;
  a: Word;
begin
  ClampScroll;
  if Active then
  begin
    fr  := Attr(clWhite,  clBlack);
    hd  := Attr(clBlack,  clCyan);
  end
  else
  begin
    fr  := Attr(clLtGray, clBlack);
    hd  := Attr(clLtGray, clBlue);
  end;
  nrm := Attr(clLtGray, clBlack);
  sel := Attr(clBlack,  clCyan);
  mk  := Attr(clYellow, clBlack);

  FillRect(X1+1, Y1+1, X2-1, Y2-1, ' ', nrm);
  Box(X1, Y1, X2, Y2, fr, Active);

  innerW := X2 - X1 - 1;

  { заглавие: текущата папка, отрязана отдясно }
  s := Dir;
  if Length(s) > innerW - 2 then
    s := '…' + Copy(s, Length(s) - (innerW - 4), innerW);
  PutStr(X1 + 2, Y1, ' ' + s + ' ', hd);

  rv := RowsVisible;
  for row := 0 to rv - 1 do
  begin
    i := FTop + row;
    if i >= FCount then Break;
    E := FEntries[i];
    y := Y1 + 1 + row;

    if E.IsDir then nm := '[' + E.Name + ']' else nm := E.Name;
    sz := FmtSize(E.Size, E.IsDir);

    { име отляво (отрязано), размер отдясно }
    if Length(nm) > innerW - 10 then nm := Copy(nm, 1, innerW - 11) + '…';
    s := nm;
    while Length(s) < innerW - 9 do s := s + ' ';
    s := s + ' ' + sz;
    if Length(s) > innerW then s := Copy(s, 1, innerW);
    while Length(s) < innerW do s := s + ' ';

    if (i = FCursor) and Active then a := sel
    else if E.Marked then a := mk
    else a := nrm;

    PutStr(X1 + 1, y, s, a);
  end;

  { долен ред: брой/маркирани — строим ръчно, без AnsiString път }
  s := ' ' + UnicodeString(IntToStr(FCount)) + ' обекта';
  if MarkedCount > 0 then
    s := s + ', ' + UnicodeString(IntToStr(MarkedCount)) + ' марк. '
  else
    s := s + ' ';
  PutStr(X1 + 2, Y2, s, fr);
end;

procedure TPanel.MoveCursor(Delta: Integer);
begin
  FCursor := FCursor + Delta;
  if FCursor < 0 then FCursor := 0;
  if FCursor >= FCount then FCursor := FCount - 1;
  ClampScroll;
end;

procedure TPanel.CursorHome;
begin FCursor := 0; ClampScroll; end;

procedure TPanel.CursorEnd;
begin FCursor := FCount - 1; ClampScroll; end;

procedure TPanel.Enter;
var
  nm: UnicodeString;
  p: Integer;
begin
  if FCount = 0 then Exit;
  if not FEntries[FCursor].IsDir then Exit;
  if FEntries[FCursor].IsUp then
  begin
    { нагоре: махни последния компонент }
    nm := Copy(Dir, 1, Length(Dir) - 1);   { без крайния '\' }
    p := Length(nm);
    while (p > 0) and (nm[p] <> '\') do Dec(p);
    if p > 0 then nm := Copy(nm, 1, p) else nm := Dir;
    ReadDir(nm);
  end
  else
    ReadDir(Dir + FEntries[FCursor].Name);
end;

procedure TPanel.ToggleMark;
begin
  if FCount = 0 then Exit;
  if FEntries[FCursor].IsUp then begin MoveCursor(1); Exit; end;
  FEntries[FCursor].Marked := not FEntries[FCursor].Marked;
  MoveCursor(1);
end;

function TPanel.CurName: UnicodeString;
begin
  if (FCount = 0) or (FCursor < 0) or (FCursor >= FCount) then Exit('');
  Result := FEntries[FCursor].Name;
end;

function TPanel.CurFull: UnicodeString;
begin
  if CurName = '' then Exit('');
  if FEntries[FCursor].IsUp then Result := Dir
  else Result := Dir + FEntries[FCursor].Name;
end;

function TPanel.CurIsDir: Boolean;
begin
  if (FCount = 0) then Exit(False);
  Result := FEntries[FCursor].IsDir;
end;

function TPanel.MarkedCount: Integer;
var i: Integer;
begin
  Result := 0;
  for i := 0 to FCount - 1 do
    if FEntries[i].Marked then Inc(Result);
end;

function TPanel.MarkedList: UnicodeString;
var
  i: Integer;
begin
  Result := '';
  if MarkedCount = 0 then
  begin
    if CurName <> '' then Result := '"' + CurFull + '"';
    Exit;
  end;
  for i := 0 to FCount - 1 do
    if FEntries[i].Marked then
    begin
      if Result <> '' then Result := Result + ' ';
      Result := Result + '"' + Dir + FEntries[i].Name + '"';
    end;
end;

function TPanel.MarkedPaths: TStrArr;
var
  i, n: Integer;
begin
  Result := nil;
  if MarkedCount = 0 then
  begin
    if (CurName <> '') and not FEntries[FCursor].IsUp then
    begin
      SetLength(Result, 1);
      Result[0] := CurFull;
    end;
    Exit;
  end;
  SetLength(Result, MarkedCount);
  n := 0;
  for i := 0 to FCount - 1 do
    if FEntries[i].Marked then
    begin
      Result[n] := Dir + FEntries[i].Name;
      Inc(n);
    end;
end;

end.
