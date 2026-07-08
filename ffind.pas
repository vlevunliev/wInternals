program ffind;
{ Моментално търсене на файл по име през директно четене на $MFT.
  Everything-класа: реди порядъци по-бързо от dir /s или where, защото минава
  целия MFT в един последователен прочит вместо да обхожда дървото. Иска admin.
  Употреба: ffind <текст> [/d X]
    <текст> - подниз от името (case-insensitive)
    /d X    - буква на дял (по подразбиране C) }
{$mode objfpc}{$H+}
{$codepage UTF8}

uses
  Windows, SysUtils, Misc, Win_Primitive, ntmft;

const
  MASK48 = QWord($0000FFFFFFFFFFFF);
  CHUNK  = 1 shl 20;

var
  parents: array of LongWord;
  names:   array of UnicodeString;
  inUse:   array of Boolean;
  recsTotal: LongWord;
  DriveLetter: WideChar = 'C';
  i: Integer;
  s, pattern, pat: UnicodeString;
  h: HANDLE;
  vb: array[0..1023] of Byte;
  ret: DWORD;
  bytesPerSector, bytesPerCluster, recSize: DWORD;
  mftValidLen, mftStartLcn: Int64;
  rec0, buf: PByte;
  runs: TRunArray;
  globalIdx: LongWord;
  r, ridx: Integer;
  pos, runBytes, runDisk: Int64;
  thisChunk: DWORD;
  nrec: Integer;
  found: Integer;
  t0: QWord;


procedure ParseRecord(rec: PByte; idx: LongWord; recSize, sectorSize: DWORD);
var
    flags: Word;
    baseRef: QWord;
    ao: Word;
    ap: PByte;
    atype, alen: DWORD;
    fn: PByte;
    pRef: QWord;
    fnLen, ns: Byte;
    valOff: Word;
    nameSet: Boolean;
    bestNS: Integer;
begin
  inUse[idx] := False;
  if PDWORD(rec)^ <> $454C4946 then Exit;          // "FILE"
  ApplyFixup(rec, sectorSize);
  flags := PWord(rec + $16)^;
  if (flags and 1) = 0 then Exit;
  baseRef := PQWord(rec + $20)^ and MASK48;
  if baseRef <> 0 then Exit;
  inUse[idx] := True;
  parents[idx] := idx; nameSet := False; bestNS := -1;
  ao := PWord(rec + $14)^; ap := rec + ao;
  while (PtrUInt(ap) + 8 <= PtrUInt(rec) + recSize) do
  begin
    atype := PDWORD(ap)^;
    if atype = $FFFFFFFF then Break;
    alen := PDWORD(ap + 4)^;
    if (alen = 0) or (PtrUInt(ap) + alen > PtrUInt(rec) + recSize) then Break;
    if atype = $30 then
    begin
      valOff := PWord(ap + $14)^; fn := ap + valOff;
      pRef := PQWord(fn)^ and MASK48;
      fnLen := PByte(fn + $40)^; ns := PByte(fn + $41)^;
      if (not nameSet) or ((bestNS = 2) and (ns <> 2)) then
      begin
        SetString(names[idx], PWideChar(fn + $42), fnLen);
        bestNS := ns; nameSet := True;
      end;
      parents[idx] := LongWord(pRef);
    end;
    Inc(ap, alen);
  end;
end;

function BuildPath(idx: LongWord): UnicodeString;
var
    parts: array of UnicodeString;
    n, k: Integer; cur: LongWord;
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


begin
  ConInit;
  pattern := '';
  i := 1;
  while i <= ParamCount do
  begin
    s := UnicodeString(ParamStr(i));
    if SameText(string(s), '/d') and (i < ParamCount) then
    begin
      DriveLetter := UpCase(WideChar(UnicodeString(ParamStr(i+1))[1])); Inc(i);
    end
    else if pattern = '' then pattern := s;
    Inc(i);
  end;
  if pattern = '' then begin ConLn('Употреба: ffind <текст> [/d X]'); Halt(1); end;
  pat := Lo(pattern);

  h := CreateFileW(PWideChar('\\.\' + DriveLetter + ':'), GENERIC_READ,FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
  if h = INVALID_HANDLE_VALUE then
  begin
    ConLn('Не мога да отворя тома (трябва admin).');
    Halt(1);
  end;

  if not DeviceIoControl(h, FSCTL_GET_NTFS_VOLUME_DATA, nil, 0, @vb, SizeOf(vb), ret, nil) then
  begin
    ConLn('GET_NTFS_VOLUME_DATA грешка.');
    CloseHandle(h);
    Halt(2);
  end;

  bytesPerSector  := PDWORD(@vb[$28])^;
  bytesPerCluster := PDWORD(@vb[$2C])^;
  recSize         := PDWORD(@vb[$30])^;
  mftValidLen     := PInt64(@vb[$38])^;
  mftStartLcn     := PInt64(@vb[$40])^;
  recsTotal := LongWord(mftValidLen div recSize);

  t0 := GetTickCount64;
  rec0 := GetMem(recSize);

  if not ReadAt(h, mftStartLcn * bytesPerCluster, rec0, recSize) then
  begin
    ConLn('Не прочетох MFT запис 0.');
    CloseHandle(h);
    Halt(3);
  end;
  runs := DecodeMftRuns(rec0, recSize); FreeMem(rec0);

  SetLength(parents, recsTotal);
  SetLength(names, recsTotal);
  SetLength(inUse, recsTotal);

  buf := GetMem(CHUNK);
  globalIdx := 0;

  for r := 0 to System.Length(runs) - 1 do
  begin
    runBytes := runs[r].count * bytesPerCluster;
    runDisk  := runs[r].lcn * bytesPerCluster;
    pos := 0;
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

  found := 0;
  for globalIdx := 0 to recsTotal - 1 do
    if inUse[globalIdx] and (System.Pos(pat, Lo(names[globalIdx])) > 0) then
    begin
      ConLn(BuildPath(globalIdx)); Inc(found);
    end;

  ConLn('');
  ConLn(UnicodeString(IntToStr(found)) + ' съвпадения за "' + pattern + '" за ' +
        UnicodeString(IntToStr(GetTickCount64 - t0)) + ' ms.');
end.
