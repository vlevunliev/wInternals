program fcd;
{ ---------------------------------------------------------
  fcd - Norton Change Directory (NCD) клонинг за Шило.
  Пълноекранно дърво на папките; стрелки навигация; speed search;
  Enter = cd към избраната папка, Esc = отказ.

  Кеш: ако <корен>\tree.tmp съществува -> зарежда се моментално;
  иначе се сканира и записва (като TREEINFO.NCD едно време).

  Употреба: fcd [корен] [/rescan] [/nocache]
    корен      стартова папка (по подразбиране текущата)
    /rescan    пресканирай, игнорирай кеша
    /nocache   не записвай tree.tmp

  Изход при Enter: избраният път се печата на stdout (за fcd.cmd wrapper)
  и се записва в %TEMP%\fcd.dir (за Шило хъба). Exit 0 = избор, 1 = отказ.

  cd трик (standalone) чрез fcd.cmd:
    @echo off
    fcd.exe %*
    if errorlevel 1 goto :eof
    set /p _d=<"%TEMP%\fcd.dir"
    cd /d "%_d%"
  --------------------------------------------------------- }
{$mode objfpc}{$H+}
{$codepage UTF8}
{$APPTYPE CONSOLE}

uses
  Windows, SysUtils, uScreen, uInput, win_primitive, Misc;

type
  TNode = record
    Path : UnicodeString;
    Name : UnicodeString;
    Depth: Integer;
  end;

var
  Nodes  : array of TNode;
  ParentIdx : array of Integer;   { индекс на родителя, -1 за корена }
  IsLast    : array of Boolean;   { последно дете сред братята си? }
  NC     : Integer = 0;
  Root   : UnicodeString;
  DoCache: Boolean = True;
  ReScan : Boolean = False;
  ScanActive : Boolean = False;   { рисувай ли прогрес при сканиране }
  RerootReq  : UnicodeString = '';{ F2 избра нов корен }

procedure AddNode(const APath, AName: UnicodeString; ADepth: Integer);
begin
  if NC >= Length(Nodes) then SetLength(Nodes, (NC + 64) * 2);
  Nodes[NC].Path  := APath;
  Nodes[NC].Name  := AName;
  Nodes[NC].Depth := ADepth;
  Inc(NC);
end;

{ прогрес при сканиране }
procedure DrawScan;
var
  bx, by, bw: Integer;
  s: UnicodeString;
begin
  if not ScanActive then Exit;
  bw := 40;
  bx := (ScrW - bw) div 2;
  by := ScrH div 2 - 1;
  FillRect(bx, by, bx + bw, by + 2, ' ', Attr(clWhite, clBlue));
  Box(bx, by, bx + bw, by + 2, Attr(clWhite, clBlue), True);
  s := 'Четене на данни… ' + UnicodeString(IntToStr(NC)) + ' папки';
  PutStr(bx + 2, by + 1, s, Attr(clYellow, clBlue));
  Flush;
end;

{ DFS pre-order callback за WalkTree - само папки; редът на добавяне Е редът за показване }
function ScanCB(const FullPath, Name: UnicodeString; Attr: DWORD;
  Size: Int64; Depth: Integer; Ctx: Pointer): TWalkAction;
begin
  if (Attr and FILE_ATTRIBUTE_DIRECTORY) = 0 then Exit(waSkip);       { само папки }
  if (Attr and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then Exit(waSkip);  { junction НЕ се обхожда (loop safety) }
  AddNode(FullPath, Name, Depth + 1);      { WalkTree брои от 0; коренът е на 0, децата на 1 }
  if (NC and $1FF) = 0 then DrawScan;      { обнови на всеки 512 папки }
  Result := waRecurse;
end;

procedure BuildTree;
begin
  NC := 0;
  SetLength(Nodes, 256);
  AddNode(Root, Root, 0);
  WalkTree(Root, @ScanCB, nil);
end;

function CacheFile: UnicodeString;
begin
  if (Length(Root) > 0) and (Root[Length(Root)] = '\') then
    Result := Root + 'tree.tmp'
  else
    Result := Root + '\tree.tmp';
end;

procedure SaveCache;
var
  f: THandle;
  i, written: Integer;
  line: RawByteString;
  wr: DWORD;
begin
  f := CreateFileW(PWideChar(LP(CacheFile)), GENERIC_WRITE, 0, nil,
                   CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL or FILE_ATTRIBUTE_HIDDEN, 0);
  if f = INVALID_HANDLE_VALUE then Exit;
  for i := 0 to NC - 1 do
  begin
    line := UTF8Encode(UnicodeString(IntToStr(Nodes[i].Depth)) + #9 +
                       Nodes[i].Path + #9 + Nodes[i].Name + #13#10);
    WriteFile(f, PAnsiChar(line)^, Length(line), wr, nil);
  end;
  CloseHandle(f);
end;

function LoadCache: Boolean;
var
  f: THandle;
  sz, got: DWORD;
  raw: RawByteString;
  u, line: UnicodeString;
  i, start, t1, t2: Integer;
begin
  Result := False;
  f := CreateFileW(PWideChar(LP(CacheFile)), GENERIC_READ, FILE_SHARE_READ,
                   nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if f = INVALID_HANDLE_VALUE then Exit;
  sz := GetFileSize(f, nil);
  if sz = $FFFFFFFF then sz := 0;
  SetLength(raw, sz);
  got := 0;
  if sz > 0 then ReadFile(f, raw[1], sz, got, nil);
  CloseHandle(f);
  SetLength(raw, got);
  u := UTF8Decode(raw);
  if u = '' then Exit;

  NC := 0;
  SetLength(Nodes, 256);
  start := 1;
  for i := 1 to Length(u) + 1 do
    if (i > Length(u)) or (u[i] = #10) then
    begin
      line := Copy(u, start, i - start);
      if (Length(line) > 0) and (line[Length(line)] = #13) then
        SetLength(line, Length(line) - 1);
      start := i + 1;
      if line = '' then Continue;
      t1 := Pos(#9, line);
      if t1 = 0 then Continue;
      t2 := Pos(#9, Copy(line, t1 + 1, MaxInt));
      if t2 = 0 then Continue;
      t2 := t1 + t2;
      AddNode(Copy(line, t1 + 1, t2 - t1 - 1),
              Copy(line, t2 + 1, MaxInt),
              StrToIntDef(string(Copy(line, 1, t1 - 1)), 0));
    end;
  Result := NC > 0;
end;

{ пресмята ParentIdx + IsLast за рисуване на клончетата (O(N)) }
procedure ComputeMeta;
var
  i, d, dd, maxD: Integer;
  lastAt: array of Integer;
begin
  SetLength(ParentIdx, NC);
  SetLength(IsLast, NC);
  maxD := 0;
  for i := 0 to NC - 1 do
    if Nodes[i].Depth > maxD then maxD := Nodes[i].Depth;
  SetLength(lastAt, maxD + 2);
  for i := 0 to maxD + 1 do lastAt[i] := -1;

  for i := 0 to NC - 1 do
  begin
    d := Nodes[i].Depth;
    if d > 0 then ParentIdx[i] := lastAt[d - 1] else ParentIdx[i] := -1;
    IsLast[i] := True;
    if lastAt[d] >= 0 then IsLast[lastAt[d]] := False;  { предишният брат вече не е последен }
    lastAt[d] := i;
    for dd := d + 1 to maxD do lastAt[dd] := -1;         { по-дълбоките нямат вече братя }
  end;
end;

{ ---------- бързи папки (F2) ---------- }
function EnvVar(const Name: UnicodeString): UnicodeString;
var
  buf: array[0..1023] of WideChar;
  n: DWORD;
begin
  n := GetEnvironmentVariableW(PWideChar(Name), @buf[0], 1024);
  if (n = 0) or (n >= 1024) then Result := '' else Result := buf;
end;

function DirEx(const P: UnicodeString): Boolean;
var a: DWORD;
begin
  if P = '' then Exit(False);
  a := GetFileAttributesW(PWideChar(P));
  Result := (a <> INVALID_FILE_ATTRIBUTES) and
            ((a and FILE_ATTRIBUTE_DIRECTORY) <> 0);
end;

{ меню с макро-папките; връща избран път или '' }
function QuickMenu: UnicodeString;
const
  MAXQ = 16;
var
  labels, paths: array[0..MAXQ-1] of UnicodeString;
  cnt, i, sel, bx, by, bw, bh: Integer;
  up: UnicodeString;
  E: TKeyEvent;
  a, sa: Word;
  s: UnicodeString;

  procedure Put(const lbl, p: UnicodeString);
  begin
    if (cnt < MAXQ) and DirEx(p) then
    begin labels[cnt] := lbl; paths[cnt] := p; Inc(cnt); end;
  end;

begin
  Result := '';
  cnt := 0;
  up := EnvVar('USERPROFILE');
  Put('Потребител',          up);
  Put('Работен плот',        up + '\Desktop');
  Put('Документи',           up + '\Documents');
  Put('Изтегляния',          up + '\Downloads');
  Put('AppData (Roaming)',   EnvVar('APPDATA'));
  Put('AppData (Local)',     EnvVar('LOCALAPPDATA'));
  Put('Temp',                EnvVar('TEMP'));
  Put('ProgramData',         EnvVar('PROGRAMDATA'));
  Put('Program Files',       EnvVar('PROGRAMFILES'));
  Put('Program Files (x86)', EnvVar('ProgramFiles(x86)'));
  Put('Windows',             EnvVar('WINDIR'));
  Put('System32',            EnvVar('WINDIR') + '\System32');
  Put('Публични',            EnvVar('PUBLIC'));
  if cnt = 0 then Exit;

  sel := 0;
  bw := 46;
  bh := cnt + 2;
  repeat
    bx := (ScrW - bw) div 2;
    by := (ScrH - bh) div 2;
    a  := Attr(clWhite, clBlue);
    sa := Attr(clBlack, clCyan);
    FillRect(bx, by, bx + bw, by + bh, ' ', a);
    Box(bx, by, bx + bw, by + bh, a, True);
    PutStr(bx + 2, by, ' Бързи папки ', Attr(clYellow, clBlue));
    for i := 0 to cnt - 1 do
    begin
      s := ' ' + labels[i];
      while Length(s) < bw - 1 do s := s + ' ';
      if Length(s) > bw - 1 then s := Copy(s, 1, bw - 1);
      if i = sel then PutStr(bx + 1, by + 1 + i, s, sa)
                 else PutStr(bx + 1, by + 1 + i, s, a);
    end;
    Flush;
    ReadKey(E);
    case E.Kind of
      kkSpecial:
        case E.Code of
          kUp:    if sel > 0 then Dec(sel) else sel := cnt - 1;
          kDown:  if sel < cnt - 1 then Inc(sel) else sel := 0;
          kHome:  sel := 0;
          kEnd:   sel := cnt - 1;
          kEnter: begin Result := paths[sel]; Exit; end;
          kEsc:   Exit;
        end;
      kkResize: ScrSync;
    end;
  until False;
end;

{ ---------- интерактивен режим ---------- }
function Pick: UnicodeString;
var
  cursor, top, i, row, innerW, innerH, x1, y1, x2, y2, baseDepth: Integer;
  E: TKeyEvent;
  a, sel, fa: Word;
  s, search: UnicodeString;

  procedure Clamp;
  begin
    if cursor < 0 then cursor := 0;
    if cursor >= NC then cursor := NC - 1;
    if cursor < top then top := cursor;
    if cursor >= top + innerH then top := cursor - innerH + 1;
    if top < 0 then top := 0;
  end;

  procedure SearchNext(const q: UnicodeString);
  var k, j: Integer;
  begin
    if q = '' then Exit;
    for k := 1 to NC do
    begin
      j := (cursor + k) mod NC;
      if Copy(WideUpperCase(Nodes[j].Name), 1, Length(q)) = WideUpperCase(q) then
      begin cursor := j; Exit; end;
    end;
  end;

  { префикс с клончета: │ за предшественик с още братя, │├└─ за възела }
  function BranchPrefix(idx: Integer): UnicodeString;
  var
    reld, lvl, p: Integer;
    anc: array of Boolean;
  begin
    reld := Nodes[idx].Depth - baseDepth;
    if reld <= 0 then Exit('');
    SetLength(anc, reld + 1);
    p := ParentIdx[idx];
    lvl := reld - 1;
    while (lvl >= 1) and (p >= 0) do
    begin anc[lvl] := IsLast[p]; p := ParentIdx[p]; Dec(lvl); end;
    Result := '';
    for lvl := 1 to reld - 1 do
      if anc[lvl] then Result := Result + '   '        { предшественикът е последен -> празно }
      else             Result := Result + #$2502'  ';   { │ }
    if IsLast[idx] then Result := Result + #$2514#$2500' '   { └─ }
    else                Result := Result + #$251C#$2500' '; { ├─ }
  end;

begin
  Result := '';
  cursor := 0; top := 0; search := '';
  baseDepth := Nodes[0].Depth;

  repeat
    x1 := 1; y1 := 0; x2 := ScrW - 2; y2 := ScrH - 1;
    innerW := x2 - x1 - 1;
    innerH := y2 - y1 - 1;
    if innerH < 1 then innerH := 1;
    Clamp;

    a   := Attr(clLtGray, clBlue);
    sel := Attr(clBlack,  clCyan);
    fa  := Attr(clBlack,  clCyan);

    FillRect(x1, y1, x2, y2, ' ', a);
    Box(x1, y1, x2, y2, Attr(clWhite, clBlue), True);
    s := ' NCD — избери папка ';
    PutStr(x1 + 2, y1, s, Attr(clYellow, clBlue));

    for row := 0 to innerH - 1 do
    begin
      i := top + row;
      if i >= NC then Break;
      if Nodes[i].Depth = baseDepth then
        s := Nodes[i].Path                 { коренът показва пълния път }
      else
        s := BranchPrefix(i) + Nodes[i].Name;
      if Length(s) > innerW then s := Copy(s, 1, innerW - 1) + '…';
      while Length(s) < innerW do s := s + ' ';
      if i = cursor then PutStr(x1 + 1, y1 + 1 + row, s, sel)
                     else PutStr(x1 + 1, y1 + 1 + row, s, a);
    end;

    { долен ред: search buffer + подсказка }
    if search <> '' then s := ' търсене: ' + search + ' '
    else s := ' стрелки · Enter=cd · F2=бързи папки · Esc=отказ · пиши=търси ';
    if Length(s) > innerW then s := Copy(s, 1, innerW);
    PutStr(x1 + 2, y2, s, fa);
    Flush;

    ReadKey(E);
    case E.Kind of
      kkSpecial:
        case E.Code of
          kUp:    begin Dec(cursor); search := ''; end;
          kDown:  begin Inc(cursor); search := ''; end;
          kPgUp:  begin Dec(cursor, innerH); search := ''; end;
          kPgDn:  begin Inc(cursor, innerH); search := ''; end;
          kHome:  begin cursor := 0; search := ''; end;
          kEnd:   begin cursor := NC - 1; search := ''; end;
          kRight: { към първото дете }
            begin
              search := '';
              if (cursor + 1 < NC) and
                 (Nodes[cursor + 1].Depth = Nodes[cursor].Depth + 1) then
                Inc(cursor);
            end;
          kLeft:  { към родителя }
            begin
              search := '';
              i := cursor - 1;
              while (i >= 0) and (Nodes[i].Depth >= Nodes[cursor].Depth) do Dec(i);
              if i >= 0 then cursor := i;
            end;
          kBack:
            if search <> '' then
            begin
              SetLength(search, Length(search) - 1);
              SearchNext(search);
            end;
          kEnter: begin Result := Nodes[cursor].Path; Exit; end;
          kEsc:   begin Result := ''; Exit; end;
          kF2:
            begin
              search := '';
              s := QuickMenu;
              if s <> '' then begin RerootReq := s; Result := ''; Exit; end;
            end;
        end;
      kkChar:
        begin
          search := search + E.Ch;
          SearchNext(search);
        end;
      kkResize: ScrSync;
    end;
  until False;
end;

{ ---------- изход ---------- }
procedure EmitChoice(const P: UnicodeString);
var
  hOut, f: THandle;
  u: RawByteString;
  wr: DWORD;
  tmp: array[0..MAX_PATH] of WideChar;
  tmpPath: UnicodeString;
begin
  { 1) stdout (за fcd.cmd wrapper) - UTF-8 байтове в потока }
  u := UTF8Encode(P + #13#10);
  hOut := GetStdHandle(STD_OUTPUT_HANDLE);
  WriteFile(hOut, PAnsiChar(u)^, Length(u), wr, nil);

  { 2) %TEMP%\fcd.dir (за Шило хъба) }
  GetTempPathW(MAX_PATH, @tmp[0]);
  tmpPath := UnicodeString(tmp) + 'fcd.dir';
  f := CreateFileW(PWideChar(tmpPath), GENERIC_WRITE, 0, nil,
                   CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if f <> INVALID_HANDLE_VALUE then
  begin
    u := UTF8Encode(P);
    WriteFile(f, PAnsiChar(u)^, Length(u), wr, nil);
    CloseHandle(f);
  end;
end;

var
  i: Integer;
  s: string;
  chosen: UnicodeString;
begin
  Root := '';
  for i := 1 to ParamCount do
  begin
    s := ParamStr(i);
    if SameText(s, '/rescan') then ReScan := True
    else if SameText(s, '/nocache') then DoCache := False
    else if (Length(s) > 0) and (s[1] <> '/') and (Root = '') then
      Root := UnicodeString(s);
  end;
  if Root = '' then Root := UnicodeString(GetCurrentDir);
  Root := ExpandFileName(Root);
  StripTrailingSep(Root);

  { конзолата се вдига ПРЕДИ сканирането, за да рисуваме прогрес }
  if not ScrInit then
  begin
    { няма конзола: тихо сканирай и ехо на корена }
    if ReScan or not LoadCache then BuildTree;
    Writeln(string(Root));
    Halt(1);
  end;
  ShowCursor(False);

  chosen := '';
  repeat
    if ReScan or not LoadCache then
    begin
      ScanActive := True;
      DrawScan;
      BuildTree;
      ScanActive := False;
      if DoCache then SaveCache;
    end;
    if NC = 0 then AddNode(Root, Root, 0);
    ComputeMeta;

    RerootReq := '';
    chosen := Pick;

    if RerootReq <> '' then
    begin
      Root := RerootReq;
      StripTrailingSep(Root);
      ReScan := False;      { за новия корен опитай кеш, иначе сканирай }
      Continue;
    end;
    Break;
  until False;

  ScrDone;

  if chosen <> '' then
  begin
    EmitChoice(chosen);
    Halt(0);
  end
  else
    Halt(1);
end.
