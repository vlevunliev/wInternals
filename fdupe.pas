program fdupe;
{ Намира дублирани файлове. MFT сканът ги групира по размер (бързо), после
  хешва само файловете с еднакъв размер (BCrypt SHA-256, нула OpenSSL) за да
  потвърди истинските дубли. Показва пропиляното място. Иска admin.
  Употреба: fdupe [/d X] [/min N]
    /d X   - буква на дял (по подразбиране C)
    /min N - минимален размер в MB (по подразбиране 4) }
{$mode objfpc}{$H+}
{$codepage UTF8}

uses
  Windows, SysUtils, misc, win_primitive, ntmft;

const
  MASK48 = QWord($0000FFFFFFFFFFFF);
  CHUNK  = 1 shl 20;


var
  parents: array of LongWord;
  sizes:   array of Int64;
  names:   array of UnicodeString;
  isDir:   array of Boolean;
  inUse:   array of Boolean;
  recsTotal: LongWord;
  volumeBytes: Int64;
  DriveLetter: WideChar = 'C';

procedure ParseRecord(rec: PByte; idx: LongWord; recSize, sectorSize: DWORD);
var flags: Word; baseRef: QWord; ao: Word; ap: PByte; atype, alen, valLen: DWORD;
    nonRes, nameLen: Byte; fn: PByte; pRef: QWord; fnLen, ns: Byte; valOff: Word;
    total: Int64; nameSet: Boolean; bestNS: Integer;
begin
  inUse[idx] := False;
  if PDWORD(rec)^ <> $454C4946 then Exit;
  ApplyFixup(rec, sectorSize);
  flags := PWord(rec + $16)^;
  if (flags and 1) = 0 then Exit;
  baseRef := PQWord(rec + $20)^ and MASK48;
  if baseRef <> 0 then Exit;
  inUse[idx] := True; isDir[idx] := (flags and 2) <> 0;
  total := 0; nameSet := False; bestNS := -1; parents[idx] := idx;
  ao := PWord(rec + $14)^; ap := rec + ao;
  while (PtrUInt(ap) + 8 <= PtrUInt(rec) + recSize) do
  begin
    atype := PDWORD(ap)^;
    if atype = $FFFFFFFF then Break;
    alen := PDWORD(ap + 4)^;
    if (alen = 0) or (PtrUInt(ap) + alen > PtrUInt(rec) + recSize) then Break;
    nonRes := PByte(ap + 8)^; nameLen := PByte(ap + 9)^;
    case atype of
      $30:
        begin
          valOff := PWord(ap + $14)^; fn := ap + valOff;
          pRef := PQWord(fn)^ and MASK48; fnLen := PByte(fn + $40)^; ns := PByte(fn + $41)^;
          if (not nameSet) or ((bestNS = 2) and (ns <> 2)) then
          begin
            SetString(names[idx], PWideChar(fn + $42), fnLen); bestNS := ns; nameSet := True;
          end;
          parents[idx] := LongWord(pRef);
        end;
      $80:
        if nonRes = 0 then begin valLen := PDWORD(ap + $10)^; total := total + valLen; end
        else total := total + PInt64(ap + $28)^;
    end;
    Inc(ap, alen);
  end;
  if (idx < 16) or (total > volumeBytes) then total := 0;   // метаданни / sparse
  sizes[idx] := total;
end;

function BuildPath(idx: LongWord): UnicodeString;
var parts: array of UnicodeString; n, k: Integer; cur: LongWord;
begin
  if idx = 5 then Exit(UnicodeString(DriveLetter) + ':\');
  SetLength(parts, 0); n := 0; cur := idx;
  while (cur <> 5) and (cur < recsTotal) and (n < 256) do
  begin
    SetLength(parts, n + 1); parts[n] := names[cur]; Inc(n); cur := parents[cur];
  end;
  Result := UnicodeString(DriveLetter) + ':';
  for k := n - 1 downto 0 do Result := Result + '\' + parts[k];
end;

{ ---- BCrypt SHA-256 -------------------------------------------------------- }
type TSHA256 = array[0..31] of Byte;
var hAlg: Pointer; objLen: ULONG;

procedure HashInit;
var cb: ULONG;
begin
  BCryptOpenAlgorithmProvider(hAlg, 'SHA256', nil, 0);
  BCryptGetProperty(hAlg, 'ObjectLength', @objLen, SizeOf(objLen), cb, 0);
end;

function HashFile(const path: UnicodeString; out dig: TSHA256): Boolean;
var h: HANDLE; hHash, ho, buf: Pointer; rd: DWORD;
begin
  Result := False;
  h := CreateFileW(PWideChar(path), GENERIC_READ,
         FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
         OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, 0);
  if h = INVALID_HANDLE_VALUE then Exit;
  ho := GetMem(objLen); buf := GetMem(CHUNK);
  if BCryptCreateHash(hAlg, hHash, ho, objLen, nil, 0, 0) = 0 then
  begin
    while ReadFile(h, buf^, CHUNK, rd, nil) and (rd > 0) do
      BCryptHashData(hHash, buf, rd, 0);
    Result := BCryptFinishHash(hHash, @dig[0], 32, 0) = 0;
    BCryptDestroyHash(hHash);
  end;
  FreeMem(ho); FreeMem(buf); CloseHandle(h);
end;

function SameDig(const a, b: TSHA256): Boolean;
var i: Integer;
begin
  for i := 0 to 31 do if a[i] <> b[i] then Exit(False);
  Result := True;
end;
{ --------------------------------------------------------------------------- }

// Безопасно: преименува копието настрани, прави hardlink, и чак при успех трие
// временното. При провал връща оригинала непокътнат - нищо не се губи.
function ReplaceCopyWithLink(const target, keep: UnicodeString): Boolean;
var tmp: UnicodeString;
begin
  Result := False;
  tmp := target + '.fduptmp';
  if not MoveFileW(PWideChar(target), PWideChar(tmp)) then Exit;
  if MyCreateHardLink(PWideChar(target), PWideChar(keep), nil) then
  begin
    DeleteFileW(PWideChar(tmp));            // успех -> махни старото копие
    Result := True;
  end
  else
    MoveFileW(PWideChar(tmp), PWideChar(target));   // провал -> върни оригинала
end;

// quicksort на индекси по sizes[] намаляващо
procedure QSort(var a: array of LongWord; lo, hi: Integer);
var
  i, j: Integer;
  piv: Int64;
  t: LongWord;
begin
  i := lo; j := hi; piv := sizes[a[(lo + hi) div 2]];
  repeat
    while sizes[a[i]] > piv do Inc(i);
    while sizes[a[j]] < piv do Dec(j);
    if i <= j then
    begin
      t := a[i];
      a[i] := a[j];
      a[j] := t;
      Inc(i);
      Dec(j);
    end;
  until i > j;
  if lo < j then QSort(a, lo, j);
  if i < hi then QSort(a, i, hi);
end;

var
  i: Integer;
  s: UnicodeString;
  minMB: Integer = 4;
  DoLink: Boolean = False;
  minBytes: Int64;
  h: HANDLE;
  vb: array[0..1023] of Byte;
  ret: DWORD;
  bytesPerSector, bytesPerCluster, recSize: DWORD;
  mftValidLen, mftStartLcn, totalClusters: Int64;
  rec0: PByte; runs: TRunArray; buf: PByte;
  globalIdx: LongWord; r, ridx: Integer;
  pos, runBytes, runDisk: Int64; thisChunk: DWORD; nrec: Integer;
  cand: array of LongWord; nc: Integer;
  gi, gj, a, b: Integer;
  digs: array of TSHA256; ok: array of Boolean;
  used: array of Boolean;
  groupShown: Boolean;
  wasted: Int64; dupGroups: Integer;
  reclaimed: Int64; linkErr: Integer;
  pathA, pathB: UnicodeString;
  t0: QWord;
begin
  ConInit; HashInit;
  i := 1;
  while i <= ParamCount do
  begin
    s := UnicodeString(ParamStr(i));
    if SameText(string(s), '/d') and (i < ParamCount) then begin DriveLetter := UpCase(WideChar(UnicodeString(ParamStr(i+1))[1])); Inc(i); end
    else if SameText(string(s), '/min') and (i < ParamCount) then begin minMB := StrToIntDef(ParamStr(i+1), 4); Inc(i); end
    else if SameText(string(s), '/link') then DoLink := True;
    Inc(i);
  end;
  minBytes := Int64(minMB) * (1 shl 20);

  h := CreateFileW(PWideChar('\\.\' + DriveLetter + ':'), GENERIC_READ,
         FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
  if h = INVALID_HANDLE_VALUE then begin ConLn('Трябва admin.'); Halt(1); end;
  if not DeviceIoControl(h, FSCTL_GET_NTFS_VOLUME_DATA, nil, 0, @vb, SizeOf(vb), ret, nil) then
  begin ConLn('GET_NTFS_VOLUME_DATA грешка.'); CloseHandle(h); Halt(2); end;

  totalClusters   := PInt64(@vb[$10])^;
  bytesPerSector  := PDWORD(@vb[$28])^;
  bytesPerCluster := PDWORD(@vb[$2C])^;
  recSize         := PDWORD(@vb[$30])^;
  mftValidLen     := PInt64(@vb[$38])^;
  mftStartLcn     := PInt64(@vb[$40])^;
  recsTotal := LongWord(mftValidLen div recSize);
  volumeBytes := totalClusters * bytesPerCluster;

  t0 := GetTickCount64;
  rec0 := GetMem(recSize);
  if not ReadAt(h, mftStartLcn * bytesPerCluster, rec0, recSize) then
  begin ConLn('Не прочетох MFT запис 0.'); CloseHandle(h); Halt(3); end;
  runs := DecodeMftRuns(rec0, recSize); FreeMem(rec0);

  SetLength(parents, recsTotal); SetLength(sizes, recsTotal);
  SetLength(names, recsTotal); SetLength(isDir, recsTotal); SetLength(inUse, recsTotal);

  buf := GetMem(CHUNK); globalIdx := 0;
  for r := 0 to System.Length(runs) - 1 do
  begin
    runBytes := runs[r].count * bytesPerCluster; runDisk := runs[r].lcn * bytesPerCluster; pos := 0;
    while (pos < runBytes) and (globalIdx < recsTotal) do
    begin
      if runBytes - pos < CHUNK then thisChunk := runBytes - pos else thisChunk := CHUNK;
      if not ReadAt(h, runDisk + pos, buf, thisChunk) then Break;
      nrec := thisChunk div recSize;
      for ridx := 0 to nrec - 1 do
      begin
        if globalIdx >= recsTotal then Break;
        ParseRecord(buf + ridx * recSize, globalIdx, recSize, bytesPerSector);
        Inc(globalIdx);
      end;
      Inc(pos, thisChunk);
    end;
  end;
  FreeMem(buf); CloseHandle(h);

  // кандидати: файлове >= minBytes
  SetLength(cand, 0); nc := 0;
  for globalIdx := 0 to recsTotal - 1 do
    if inUse[globalIdx] and (not isDir[globalIdx]) and (sizes[globalIdx] >= minBytes) then
    begin SetLength(cand, nc + 1); cand[nc] := globalIdx; Inc(nc); end;

  if nc > 1 then QSort(cand, 0, nc - 1);

  ConLn('Кандидати (>= ' + UnicodeString(IntToStr(minMB)) + ' MB): ' +
        UnicodeString(IntToStr(nc)) + '. Хеширам групите с еднакъв размер...');
  if DoLink then
    ConLn('РЕЖИМ /link: дублите се заменят с hardlink. Безопасно за read-only/' +
          'executables; за файлове, които редактираш - пипаш едно, пипаш всички.');
  ConLn('');

  wasted := 0; dupGroups := 0; reclaimed := 0; linkErr := 0;
  gi := 0;
  while gi < nc do
  begin
    gj := gi;
    while (gj < nc) and (sizes[cand[gj]] = sizes[cand[gi]]) do Inc(gj);
    if gj - gi >= 2 then     // >=2 файла с еднакъв размер -> хешвай
    begin
      SetLength(digs, gj - gi); SetLength(ok, gj - gi); SetLength(used, gj - gi);
      for a := 0 to (gj - gi) - 1 do
      begin
        ok[a] := HashFile(BuildPath(cand[gi + a]), digs[a]); used[a] := False;
      end;
      for a := 0 to (gj - gi) - 1 do
      begin
        if used[a] or (not ok[a]) then Continue;
        groupShown := False;
        pathA := BuildPath(cand[gi + a]);
        for b := a + 1 to (gj - gi) - 1 do
          if (not used[b]) and ok[b] and SameDig(digs[a], digs[b]) then
          begin
            if not groupShown then
            begin
              Inc(dupGroups);
              ConLn('--- ' + HumanSize(sizes[cand[gi + a]]) + ' x идентични ---');
              ConLn('  ' + pathA + '  [пазя]');
              groupShown := True; used[a] := True;
            end;
            pathB := BuildPath(cand[gi + b]);
            used[b] := True;
            wasted := wasted + sizes[cand[gi + a]];
            if DoLink then
            begin
              if ReplaceCopyWithLink(pathB, pathA) then
              begin
                reclaimed := reclaimed + sizes[cand[gi + a]];
                ConLn('  ' + pathB + '  -> hardlink (+' + HumanSize(sizes[cand[gi + a]]) + ')');
              end
              else
              begin
                Inc(linkErr);
                ConLn('  ' + pathB + '  -> ВНИМАНИЕ: не успях, оставено непокътнато');
              end;
            end
            else
              ConLn('  ' + pathB);
          end;
      end;
    end;
    gi := gj;
  end;

  ConLn('');
  ConLn(UnicodeString(IntToStr(dupGroups)) + ' групи дубли, пропиляно място: ' +
        HumanSize(wasted) + ' за ' + UnicodeString(IntToStr(GetTickCount64 - t0)) + ' ms.');
  if DoLink then
  begin
    ConLn('Освободено чрез hardlink: ' + HumanSize(reclaimed));
    if linkErr > 0 then ConLn('Неуспешни замени: ' + UnicodeString(IntToStr(linkErr)));
  end;
end.
