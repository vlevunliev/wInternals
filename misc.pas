unit Misc;

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils, Windows, Win_Primitive;

type
  TWalkAction = (waRecurse, waSkip, waStop);
  // Callback за WalkTree. Извиква се за ВСЕКИ запис (файл или папка).
  // За папка: върни waRecurse за да слезеш вътре, waSkip да я прескочиш.
  // waStop прекратява цялото обхождане. За файл върнатата стойност е без значение.
  TWalkFunc = function(const FullPath, Name: UnicodeString; Attr: DWORD;
                       Size: Int64; Depth: Integer; Ctx: Pointer): TWalkAction;

Const
  // USN_REASON_* флагове
  R_DATA_OVERWRITE = $00000001;
  R_DATA_EXTEND    = $00000002;
  R_DATA_TRUNCATE  = $00000004;
  R_FILE_CREATE    = $00000100;
  R_FILE_DELETE    = $00000200;
  R_EA_CHANGE      = $00000400;
  R_SECURITY       = $00000800;
  R_RENAME_OLD     = $00001000;
  R_RENAME_NEW     = $00002000;
  R_BASIC_INFO     = $00008000;
  R_HARDLINK       = $00010000;
  R_REPARSE        = $00100000;
  R_STREAM         = $00200000;
  R_CLOSE          = $80000000;


var hOut: HANDLE;
    ConRedir: Boolean;

procedure ConInit;
procedure ConOut(const S: UnicodeString);
procedure ConLn(const S: UnicodeString);
function Lo(const s: UnicodeString): UnicodeString;
function HumanSize(b: Int64): UnicodeString;
function FtToStr(const ts: Int64): UnicodeString;
function ReasonStr(r: DWORD): UnicodeString;
function LP(const P: UnicodeString): UnicodeString;
function FtStr(ft: Int64): UnicodeString;
function IsRound(ft: Int64): Boolean;
function BaseName(const P: UnicodeString): UnicodeString;
procedure StripTrailingSep(var S: UnicodeString);
function PathIsDir(const P: UnicodeString): Boolean;
// Рекурсивно обхождане на дърво, pre-order (папката се подава ПРЕДИ децата ѝ).
// Reparse точките идат като обикновени записи — callback-ът решава (обикновено
// waSkip, за да не се влиза в junction). Връща False, ако е спряно с waStop.
function WalkTree(const Root: UnicodeString; CB: TWalkFunc; Ctx: Pointer;
  Depth: Integer = 0): Boolean;


implementation

procedure ConInit;
var mode: DWORD;
begin
  hOut := GetStdHandle(STD_OUTPUT_HANDLE);
  ConRedir := not GetConsoleMode(hOut, mode);
end;

procedure ConOut(const S: UnicodeString);
var written: DWORD; u: UTF8String;
begin
  if System.Length(S) = 0 then Exit;
  if not ConRedir then WriteConsoleW(hOut, PWideChar(S), System.Length(S), written, nil)
  else
    begin
      u := UTF8Encode(S);
      WriteFile(hOut, u[1], System.Length(u), written, nil);
    end;
end;

procedure ConLn(const S: UnicodeString);
begin
  ConOut(S + #13#10);
end;


function Lo(const s: UnicodeString): UnicodeString;
begin
  Result := UnicodeString(WideLowerCase(s));
end;


function HumanSize(b: Int64): UnicodeString;
begin
  if b >= Int64(1) shl 30 then
    Result := UnicodeString(Format('%8.2f GB', [b / (Int64(1) shl 30)]))
  else if b >= 1 shl 20 then
    Result := UnicodeString(Format('%8.2f MB', [b / (1 shl 20)]))
  else if b >= 1 shl 10 then
    Result := UnicodeString(Format('%8.2f KB', [b / (1 shl 10)]))
  else
    Result := UnicodeString(Format('%8d B ', [b]));
end;


function FtToStr(const ts: Int64): UnicodeString;
var ftSrc, ftLoc: TFileTime; st: TSystemTime;
begin
  Move(ts, ftSrc, 8);
  if FileTimeToLocalFileTime(ftSrc, ftLoc) and FileTimeToSystemTime(ftLoc, st) then
    Result := UnicodeString(Format('%.4d-%.2d-%.2d %.2d:%.2d:%.2d',
      [st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond]))
  else
    Result := '????-??-?? ??:??:??';
end;


function ReasonStr(r: DWORD): UnicodeString;
begin
  Result := '';
  if (r and R_FILE_CREATE)    <> 0 then Result := Result + 'CREATE ';
  if (r and R_FILE_DELETE)    <> 0 then Result := Result + 'DELETE ';
  if (r and R_RENAME_OLD)     <> 0 then Result := Result + 'RENAME_OLD ';
  if (r and R_RENAME_NEW)     <> 0 then Result := Result + 'RENAME_NEW ';
  if (r and R_DATA_OVERWRITE) <> 0 then Result := Result + 'OVERWRITE ';
  if (r and R_DATA_EXTEND)    <> 0 then Result := Result + 'EXTEND ';
  if (r and R_DATA_TRUNCATE)  <> 0 then Result := Result + 'TRUNCATE ';
  if (r and R_SECURITY)       <> 0 then Result := Result + 'SECURITY ';
  if (r and R_BASIC_INFO)     <> 0 then Result := Result + 'BASICINFO ';
  if (r and R_HARDLINK)       <> 0 then Result := Result + 'HARDLINK ';
  if (r and R_REPARSE)        <> 0 then Result := Result + 'REPARSE ';
  if (r and R_STREAM)         <> 0 then Result := Result + 'STREAM ';
  if (r and R_CLOSE)          <> 0 then Result := Result + 'CLOSE ';
  if Result = '' then Result := UnicodeString('0x' + IntToHex(r, 8) + ' ');
end;

// \\?\ префикс за дълги пътища
function LP(const P: UnicodeString): UnicodeString;
begin
  if (System.Length(P) >= 2) and (P[2] = ':') then
    Result := '\\?\' + P
  else if Copy(P, 1, 2) = '\\' then
    Result := '\\?\UNC\' + Copy(P, 3, MaxInt)
  else
    Result := P;
end;

function FtStr(ft: Int64): UnicodeString;
var ftSrc, ftLoc: TFileTime;
    st: TSystemTime;
    frac: Int64;
begin
  if ft = 0 then Exit('-');
  Move(ft, ftSrc, 8);
  if FileTimeToLocalFileTime(ftSrc, ftLoc) and FileTimeToSystemTime(ftLoc, st) then
  begin
    frac := ft mod 10000000;
    Result := UnicodeString(Format('%.4d-%.2d-%.2d %.2d:%.2d:%.2d.%.7d',
      [st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, frac]));
  end
  else Result := '?';
end;


function IsRound(ft: Int64): Boolean;
begin
  Result := (ft <> 0) and ((ft mod 10000000) = 0);
end;

// последният компонент на пътя (без крайни разделители)
function BaseName(const P: UnicodeString): UnicodeString;
var
  q: UnicodeString;
  i: Integer;
begin
  q := P;
  while (Length(q) > 0) and (q[Length(q)] = '\') do SetLength(q, Length(q) - 1);
  i := Length(q);
  while (i > 0) and (q[i] <> '\') do Dec(i);
  Result := Copy(q, i + 1, MaxInt);
end;


procedure StripTrailingSep(var S: UnicodeString);
begin
  while (Length(S) > 3) and (S[Length(S)] = '\') do
    SetLength(S, Length(S) - 1);
end;


function PathIsDir(const P: UnicodeString): Boolean;
var
  a: DWORD;
begin
  a := GetFileAttributesW(PWideChar(LP(P)));
  Result := (a <> INVALID_FILE_ATTRIBUTES) and ((a and FILE_ATTRIBUTE_DIRECTORY) <> 0);
end;

function WalkTree(const Root: UnicodeString; CB: TWalkFunc; Ctx: Pointer;
  Depth: Integer): Boolean;
var
  h: HANDLE;
  fd: TWin32FindDataW;
  nm, full: UnicodeString;
  attr: DWORD;
  sz: Int64;
  act: TWalkAction;
begin
  Result := True;
  h := FindFirstFileExW(PWideChar(LP(Root + '\*')), FindExInfoBasic, @fd,
         FindExSearchNameMatch, nil, FIND_FIRST_EX_LARGE_FETCH);
  if h = INVALID_HANDLE_VALUE then Exit;
  try
    repeat
      nm := PWideChar(@fd.cFileName[0]);
      if (nm = '.') or (nm = '..') then Continue;
      attr := fd.dwFileAttributes;
      full := Root + '\' + nm;
      sz   := (Int64(fd.nFileSizeHigh) shl 32) or fd.nFileSizeLow;
      act  := CB(full, nm, attr, sz, Depth, Ctx);
      if act = waStop then Exit(False);
      if (act = waRecurse) and ((attr and FILE_ATTRIBUTE_DIRECTORY) <> 0) then
        if not WalkTree(full, CB, Ctx, Depth + 1) then Exit(False);
    until not FindNextFileW(h, fd);
  finally
    Windows.FindClose(h);
  end;
end;

end.

