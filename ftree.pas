program ftree;
{ Истинско дърво - показва ВСИЧКО, нула скрито покрито. За разлика от вградения
  tree: показва hidden + system и слиза в тях; reparse точки (junction/symlink)
  ги маркира и резолвва target-а вместо да рекурсира (loop safety); long-path safe.
  Употреба: ftree [път] [/f] [/d N]
    път  - корен (по подразбиране текущата папка)
    /f   - включи и файловете (по подразбиране само папки)
    /d N - максимална дълбочина
  Флагове до името: [H]idden [S]ystem [L]reparse [E]ncrypted }
{$mode objfpc}{$H+}
{$codepage UTF8}

uses
  Windows, SysUtils, misc, win_primitive;


type
  TEntry = record
    name: UnicodeString;
    attr: DWORD;
  end;

  TCollect = record
    Entries: array of TEntry;
    N: Integer;
  end;
  PCollect = ^TCollect;

function AttrFlags(a: DWORD): UnicodeString;
var s: UnicodeString;
begin
  s := '';
  if (a and FILE_ATTRIBUTE_HIDDEN)         <> 0 then s := s + 'H';
  if (a and FILE_ATTRIBUTE_SYSTEM)         <> 0 then s := s + 'S';
  if (a and FILE_ATTRIBUTE_REPARSE_POINT)  <> 0 then s := s + 'L';
  if (a and FILE_ATTRIBUTE_ENCRYPTED)      <> 0 then s := s + 'E';
  if s <> '' then Result := '  [' + s + ']' else Result := '';
end;

// Резолвва target-а на junction/symlink през FSCTL_GET_REPARSE_POINT
function ReparseTarget(const FullPath: UnicodeString): UnicodeString;
var
  h: HANDLE;
  buf: array[0..16383] of Byte;
  ret: DWORD;
  tag: DWORD;
  base: Integer;
  prOff, prLen, subOff, subLen: Word;
begin
  Result := '';
  h := CreateFileW(PWideChar(FullPath), 0,
         FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
         OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT, 0);
  if h = INVALID_HANDLE_VALUE then Exit;
  try
    if not DeviceIoControl(h, FSCTL_GET_REPARSE_POINT, nil, 0, @buf, SizeOf(buf),
         ret, nil) then Exit;
    tag := PDWORD(@buf[0])^;
    if tag = IO_REPARSE_TAG_MOUNT_POINT then base := 16        // няма Flags поле
    else if tag = IO_REPARSE_TAG_SYMLINK then base := 20       // + Flags DWORD
    else Exit;
    // четирите WORD-а започват на offset 8; offset-ите са спрямо PathBuffer
    subOff := PWord(@buf[8])^;
    subLen := PWord(@buf[10])^;
    prOff  := PWord(@buf[12])^;
    prLen  := PWord(@buf[14])^;
    if prLen > 0 then
      SetString(Result, PWideChar(@buf[base + prOff]), prLen div SizeOf(WideChar))
    else if subLen > 0 then
      SetString(Result, PWideChar(@buf[base + subOff]), subLen div SizeOf(WideChar));
  finally
    CloseHandle(h);
  end;
end;

procedure Sort(var e: array of TEntry; n: Integer);
  function Less(const a, b: TEntry): Boolean;
  var ad, bd: Boolean;
  begin
    ad := (a.attr and FILE_ATTRIBUTE_DIRECTORY) <> 0;
    bd := (b.attr and FILE_ATTRIBUTE_DIRECTORY) <> 0;
    if ad <> bd then Exit(ad);                      // папките първи
    Result := CompareText(string(a.name), string(b.name)) < 0;
  end;
var i, j: Integer; tmp: TEntry;
begin
  for i := 1 to n - 1 do
  begin
    tmp := e[i]; j := i - 1;
    while (j >= 0) and Less(tmp, e[j]) do
    begin
      e[j+1] := e[j];
      Dec(j);
    end;
    e[j+1] := tmp;
  end;
end;

var
  ShowFiles: Boolean = False;
  MaxDepth: Integer = 0;
  DirCount: Integer = 0;
  FileCount: Integer = 0;

// Callback за WalkTree: събира едно ниво в масив (без рекурсия - тя е ръчна долу)
function CollectCB(const FullPath, Name: UnicodeString; Attr: DWORD;
  Size: Int64; Depth: Integer; Ctx: Pointer): TWalkAction;
var c: PCollect;
begin
  c := PCollect(Ctx);
  if (not ShowFiles) and ((Attr and FILE_ATTRIBUTE_DIRECTORY) = 0) then Exit(waSkip);
  if c^.N >= System.Length(c^.Entries) then SetLength(c^.Entries, (c^.N + 8) * 2);
  c^.Entries[c^.N].name := Name;
  c^.Entries[c^.N].attr := Attr;
  Inc(c^.N);
  Result := waSkip;
end;

procedure Walk(const dir, prefix: UnicodeString; depth: Integer);
var
  col: TCollect;
  n, i: Integer;
  conn, childPrefix, line, target: UnicodeString;
  isDir, isReparse, isLast: Boolean;
begin
  if (MaxDepth > 0) and (depth > MaxDepth) then Exit;

  col.N := 0; SetLength(col.Entries, 32);
  WalkTree(dir, @CollectCB, @col);          // изброй едно ниво (рекурсията е ръчна)
  n := col.N;

  Sort(col.Entries, n);

  for i := 0 to n - 1 do
  begin
    isLast    := (i = n - 1);
    isDir     := (col.Entries[i].attr and FILE_ATTRIBUTE_DIRECTORY) <> 0;
    isReparse := (col.Entries[i].attr and FILE_ATTRIBUTE_REPARSE_POINT) <> 0;

    if isLast then conn := '└── ' else conn := '├── ';
    line := prefix + conn + col.Entries[i].name + AttrFlags(col.Entries[i].attr);

    if isReparse then
    begin
      target := ReparseTarget(LP(dir + '\' + col.Entries[i].name));
      if target <> '' then line := line + ' → ' + target;
    end;
    ConLn(line);

    if isDir then Inc(DirCount) else Inc(FileCount);

    // рекурсия само в истински папки, НЕ в reparse точки (loop safety)
    if isDir and (not isReparse) then
    begin
      if isLast then childPrefix := prefix + '    '
      else childPrefix := prefix + '│   ';
      Walk(dir + '\' + col.Entries[i].name, childPrefix, depth + 1);
    end;
  end;
end;

var
  i: Integer;
  s, root: UnicodeString;
begin
  ConInit;
  root := UnicodeString(GetCurrentDir);
  i := 1;
  while i <= ParamCount do
  begin
    s := UnicodeString(ParamStr(i));
    if SameText(string(s), '/f') then ShowFiles := True
    else if SameText(string(s), '/d') and (i < ParamCount) then
    begin
      MaxDepth := StrToIntDef(ParamStr(i+1), 0); Inc(i);
    end
    else
      root := UnicodeString(ExpandFileName(ParamStr(i)));
    Inc(i);
  end;

  StripTrailingSep(root);

  ConLn(root);
  Walk(root, '', 1);
  ConLn('');
  ConLn(UnicodeString(IntToStr(DirCount)) + ' папки, ' +
        UnicodeString(IntToStr(FileCount)) + ' файла.');
end.
