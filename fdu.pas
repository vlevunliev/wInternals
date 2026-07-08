program fdu;
{ Disk usage по WizTree метода - чете директно $MFT на NTFS вместо да обхожда
  дървото. Един последователен прочит на MFT-а -> размерът на всеки файл наведнъж,
  без нито един CreateFile. Затова е порядъци по-бързо от du/tree/Explorer.
  Иска admin (volume handle).
  Употреба: fdu [C] [/n N]
    C    - буква на дял (по подразбиране C)
    /n N - брой редове в класациите (по подразбиране 30) }
{$mode objfpc}{$H+}
{$codepage UTF8}

uses
  Windows, SysUtils, misc, win_primitive, ntmft;

const
  MASK48 = QWord($0000FFFFFFFFFFFF);
  CHUNK  = 1 shl 20;                       // 1 MB прочит на стъпка



{ ---- глобални масиви, индексирани по номер на MFT запис -------------------- }
var
  parents: array of LongWord;
  sizes:   array of Int64;
  fTotal:  array of Int64;       // рекурсивен сбор за папки
  names:   array of UnicodeString;
  isDir:   array of Boolean;
  inUse:   array of Boolean;
  recsTotal: LongWord;
  volumeBytes: Int64;
  DriveLetter: WideChar = 'C';

procedure ParseRecord(rec: PByte; idx: LongWord; recSize, sectorSize: DWORD);
var
  flags: Word; baseRef: QWord; ao: Word; ap: PByte;
  atype, alen, valLen: DWORD; nonRes, nameLen: Byte;
  fn: PByte; pRef: QWord; fnLen, ns: Byte; valOff: Word;
  total: Int64; nameSet: Boolean; bestNS: Integer;
begin
  inUse[idx] := False;
  if PDWORD(rec)^ <> $454C4946 then Exit;        // "FILE"
  ApplyFixup(rec, sectorSize);
  flags := PWord(rec + $16)^;
  if (flags and 1) = 0 then Exit;                // не е в употреба
  baseRef := PQWord(rec + $20)^ and MASK48;
  if baseRef <> 0 then Exit;                      // extension запис -> пропусни

  inUse[idx] := True;
  isDir[idx] := (flags and 2) <> 0;
  total := 0; nameSet := False; bestNS := -1;
  parents[idx] := idx;                            // ще се презапише от $FILE_NAME

  ao := PWord(rec + $14)^;
  ap := rec + ao;
  while (PtrUInt(ap) + 8 <= PtrUInt(rec) + recSize) do
  begin
    atype := PDWORD(ap)^;
    if atype = $FFFFFFFF then Break;
    alen := PDWORD(ap + 4)^;
    if (alen = 0) or (PtrUInt(ap) + alen > PtrUInt(rec) + recSize) then Break;
    nonRes  := PByte(ap + 8)^;
    nameLen := PByte(ap + 9)^;

    case atype of
      $30:                                        // $FILE_NAME (винаги resident)
        begin
          valOff := PWord(ap + $14)^;
          fn := ap + valOff;
          pRef  := PQWord(fn)^ and MASK48;
          fnLen := PByte(fn + $40)^;
          ns    := PByte(fn + $41)^;
          // предпочитай Win32 име пред DOS (8.3)
          if (not nameSet) or ((bestNS = 2) and (ns <> 2)) then
          begin
            SetString(names[idx], PWideChar(fn + $42), fnLen);
            bestNS := ns; nameSet := True;
          end;
          parents[idx] := LongWord(pRef);
        end;
      $80:                                        // $DATA
        begin
          if nonRes = 0 then
          begin
            valLen := PDWORD(ap + $10)^;
            total := total + valLen;
          end
          else
            total := total + PInt64(ap + $28)^;   // allocated size (на диска)
        end;
    end;
    Inc(ap, alen);
  end;

  if (idx = 8) or (total > volumeBytes) then total := 0;   // $BadClus / sparse фантоми
  sizes[idx] := total;
end;

{ ---- top-N колектор -------------------------------------------------------- }
type
  TTop = record idx: LongWord; val: Int64; end;
var
  topN: Integer = 30;

procedure TopInsert(var arr: array of TTop; cnt: Integer; idx: LongWord; val: Int64);
var j: Integer;
begin
  if val <= arr[cnt - 1].val then Exit;
  j := cnt - 1;
  while (j > 0) and (arr[j - 1].val < val) do
  begin
    arr[j] := arr[j - 1]; Dec(j);
  end;
  arr[j].idx := idx; arr[j].val := val;
end;

function BuildPath(idx: LongWord): UnicodeString;
var parts: array of UnicodeString; n, k: Integer; cur: LongWord;
begin
  if idx = 5 then Exit(UnicodeString(DriveLetter) + ':\');
  SetLength(parts, 0); n := 0; cur := idx;
  while (cur <> 5) and (cur < recsTotal) and (n < 256) do
  begin
    SetLength(parts, n + 1); parts[n] := names[cur]; Inc(n);
    cur := parents[cur];
  end;
  Result := UnicodeString(DriveLetter) + ':';
  for k := n - 1 downto 0 do Result := Result + '\' + parts[k];
end;

var
  i: Integer;
  s, volPath: UnicodeString;
  h: HANDLE;
  vb: array[0..1023] of Byte;
  ret: DWORD;
  bytesPerSector, bytesPerCluster, recSize: DWORD;
  mftValidLen, mftStartLcn, totalClusters, freeClusters: Int64;
  rec0: PByte;
  runs: TRunArray;
  buf: PByte;
  globalIdx: LongWord;
  r, ridx: Integer;
  pos, runBytes, runDisk: Int64;
  thisChunk: DWORD;
  nrec: Integer;
  fsize: Int64;
  fr: LongWord; depth: Integer;
  topDirs, topFiles: array of TTop;
  t0: QWord;
begin
  ConInit;
  for i := 1 to ParamCount do
  begin
    s := UnicodeString(ParamStr(i));
    if SameText(string(s), '/n') and (i < ParamCount) then
      topN := StrToIntDef(ParamStr(i+1), 30)
    else if (System.Length(s) = 1) and (s[1] in ['A'..'Z','a'..'z']) then
      DriveLetter := UpCase(WideChar(s[1]));
  end;

  volPath := '\\.\' + DriveLetter + ':';
  h := CreateFileW(PWideChar(volPath), GENERIC_READ,
         FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
  if h = INVALID_HANDLE_VALUE then
  begin
    ConLn('Не мога да отворя ' + volPath + ' (грешка ' +
          UnicodeString(IntToStr(GetLastError)) + '). Трябва admin.');
    Halt(1);
  end;

  if not DeviceIoControl(h, FSCTL_GET_NTFS_VOLUME_DATA, nil, 0, @vb, SizeOf(vb),
       ret, nil) then
  begin
    ConLn('GET_NTFS_VOLUME_DATA грешка ' + UnicodeString(IntToStr(GetLastError)) +
          ' (дялът NTFS ли е?).');
    CloseHandle(h); Halt(2);
  end;

  totalClusters   := PInt64(@vb[$10])^;
  freeClusters    := PInt64(@vb[$18])^;
  bytesPerSector  := PDWORD(@vb[$28])^;
  bytesPerCluster := PDWORD(@vb[$2C])^;
  recSize         := PDWORD(@vb[$30])^;
  mftValidLen     := PInt64(@vb[$38])^;
  mftStartLcn     := PInt64(@vb[$40])^;

  recsTotal := LongWord(mftValidLen div recSize);
  volumeBytes := totalClusters * bytesPerCluster;
  ConLn('Дял ' + UnicodeString(DriveLetter) + ': | клъстер ' +
        UnicodeString(IntToStr(bytesPerCluster)) + ' B | MFT записи ~' +
        UnicodeString(IntToStr(recsTotal)) + ' | зает ' +
        HumanSize((totalClusters - freeClusters) * bytesPerCluster) + ' от ' +
        HumanSize(totalClusters * bytesPerCluster));

  t0 := GetTickCount64;

  // запис 0 = $MFT; от неговите data runs научаваме къде е целият MFT
  rec0 := GetMem(recSize);
  if not ReadAt(h, mftStartLcn * bytesPerCluster, rec0, recSize) then
  begin
    ConLn('Не успях да прочета MFT запис 0.'); CloseHandle(h); Halt(3);
  end;
  runs := DecodeMftRuns(rec0, recSize);
  FreeMem(rec0);
  if System.Length(runs) = 0 then
  begin
    ConLn('Не намерих data runs за $MFT.'); CloseHandle(h); Halt(4);
  end;

  SetLength(parents, recsTotal);
  SetLength(sizes,   recsTotal);
  SetLength(fTotal,  recsTotal);
  SetLength(names,   recsTotal);
  SetLength(isDir,   recsTotal);
  SetLength(inUse,   recsTotal);

  // стрийм през MFT в реда на data run-овете -> индексът расте линейно
  buf := GetMem(CHUNK);
  globalIdx := 0;
  for r := 0 to System.Length(runs) - 1 do
  begin
    runBytes := runs[r].count * bytesPerCluster;
    runDisk  := runs[r].lcn   * bytesPerCluster;
    pos := 0;
    while (pos < runBytes) and (globalIdx < recsTotal) do
    begin
      if runBytes - pos < CHUNK then thisChunk := runBytes - pos
      else thisChunk := CHUNK;
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
  FreeMem(buf);
  CloseHandle(h);

  // агрегация: всеки файл добавя размера си към всичките си предци
  for globalIdx := 0 to recsTotal - 1 do
  begin
    if (not inUse[globalIdx]) or isDir[globalIdx] then Continue;
    fsize := sizes[globalIdx];
    if fsize <= 0 then Continue;
    fr := parents[globalIdx]; depth := 0;
    while (fr < recsTotal) and (depth < 256) do
    begin
      fTotal[fr] := fTotal[fr] + fsize;
      if fr = 5 then Break;
      fr := parents[fr]; Inc(depth);
    end;
  end;

  // класации
  SetLength(topDirs, topN);
  SetLength(topFiles, topN);
  for i := 0 to topN - 1 do begin topDirs[i].val := -1; topFiles[i].val := -1; end;

  for globalIdx := 0 to recsTotal - 1 do
  begin
    if not inUse[globalIdx] then Continue;
    if isDir[globalIdx] then
      TopInsert(topDirs, topN, globalIdx, fTotal[globalIdx])
    else
      TopInsert(topFiles, topN, globalIdx, sizes[globalIdx]);
  end;

  ConLn('');
  ConLn('=== Най-големи папки (рекурсивно) ===');
  for i := 0 to topN - 1 do
    if topDirs[i].val > 0 then
      ConLn(HumanSize(topDirs[i].val) + '  ' + BuildPath(topDirs[i].idx));

  ConLn('');
  ConLn('=== Най-големи файлове ===');
  for i := 0 to topN - 1 do
    if topFiles[i].val > 0 then
      ConLn(HumanSize(topFiles[i].val) + '  ' + BuildPath(topFiles[i].idx));

  ConLn('');
  ConLn('Сканирани ' + UnicodeString(IntToStr(recsTotal)) + ' записа за ' +
        UnicodeString(IntToStr(GetTickCount64 - t0)) + ' ms.');
end.
