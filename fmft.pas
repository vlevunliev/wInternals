program fmft;
{ Суров dump на MFT записа на файл + timestomp детекция. Взима записа директно
  през FSCTL_GET_NTFS_FILE_RECORD по неговия file reference number - не сканира
  целия MFT. Иска admin (volume handle).
  Употреба: fmft <път_до_файл>

  Timestomp: SetFileTime и анти-форензичните инструменти пипат само
  $STANDARD_INFORMATION времената; $FILE_NAME пази реалното време на създаване/
  преименуване. Разминаване (особено $SI преди $FN, или закръглени $SI) = флаг. }
{$mode objfpc}{$H+}
{$codepage UTF8}

uses
  Windows, SysUtils, misc, win_primitive,ntmft;

function AttrName(t: DWORD): UnicodeString;
begin
  case t of
    $10: Result := '$STANDARD_INFORMATION';
    $20: Result := '$ATTRIBUTE_LIST';
    $30: Result := '$FILE_NAME';
    $40: Result := '$OBJECT_ID';
    $50: Result := '$SECURITY_DESCRIPTOR';
    $60: Result := '$VOLUME_NAME';
    $70: Result := '$VOLUME_INFORMATION';
    $80: Result := '$DATA';
    $90: Result := '$INDEX_ROOT';
    $A0: Result := '$INDEX_ALLOCATION';
    $B0: Result := '$BITMAP';
    $C0: Result := '$REPARSE_POINT';
    $D0: Result := '$EA_INFORMATION';
    $E0: Result := '$EA';
    $100: Result := '$LOGGED_UTILITY_STREAM';
  else Result := '0x' + UnicodeString(IntToHex(t, 2));
  end;
end;

var
  i: Integer;
  path, volPath, attrs, dataDesc, fnName: UnicodeString;
  drive: WideChar;
  hf, hv: HANDLE;
  bhfi: TByHandleFileInformation;
  frn: Int64;
  inBuf: Int64;
  outBuf: array[0..4095] of Byte;
  ret, recLen: DWORD;
  rec, ap, v: PByte;
  recNum: LongWord; seq, linkCnt, flags, ao: Word;
  atype, alen, valLen: DWORD; nonRes, nameLen, ns: Byte; nameOff, valOff: Word;
  siC, siM, siA, siR: Int64;     // $SI Created/Modified/Accessed/mftChanged
  fnC, fnM, fnA, fnR: Int64;     // $FN
  haveSI, haveFN: Boolean;
  adsName: UnicodeString;
  warned: Boolean;
begin
  ConInit;
  if ParamCount < 1 then begin ConLn('Употреба: fmft <път_до_файл>'); Halt(1); end;
  path := UnicodeString(ExpandFileName(ParamStr(1)));

  // FRN на файла
  hf := CreateFileW(PWideChar(path), 0,
         FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
         OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0);
  if hf = INVALID_HANDLE_VALUE then
  begin ConLn('Не мога да отворя файла (грешка ' + UnicodeString(IntToStr(GetLastError)) + ').'); Halt(1); end;
  if not GetFileInformationByHandle(hf, bhfi) then
  begin ConLn('GetFileInformationByHandle грешка.'); CloseHandle(hf); Halt(1); end;
  frn := (Int64(bhfi.nFileIndexHigh) shl 32) or bhfi.nFileIndexLow;
  CloseHandle(hf);

  drive := UpCase(WideChar(path[1]));
  volPath := '\\.\' + drive + ':';
  hv := CreateFileW(PWideChar(volPath), GENERIC_READ,
          FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
  if hv = INVALID_HANDLE_VALUE then
  begin ConLn('Не мога да отворя тома (трябва admin).'); Halt(1); end;

  inBuf := frn;
  if not DeviceIoControl(hv, FSCTL_GET_NTFS_FILE_RECORD, @inBuf, SizeOf(inBuf),
       @outBuf, SizeOf(outBuf), ret, nil) then
  begin ConLn('FSCTL_GET_NTFS_FILE_RECORD грешка ' + UnicodeString(IntToStr(GetLastError)) + '.'); CloseHandle(hv); Halt(2); end;
  CloseHandle(hv);

  recLen := PDWORD(@outBuf[8])^;
  rec := @outBuf[12];
  if PDWORD(rec)^ <> $454C4946 then
  begin ConLn('Записът не е "FILE" - повреден или празен.'); Halt(3); end;
  ApplyFixup(rec, 512);

  seq     := PWord(rec + $10)^;
  linkCnt := PWord(rec + $12)^;
  ao      := PWord(rec + $14)^;
  flags   := PWord(rec + $16)^;
  recNum  := PDWORD(rec + $2C)^;

  ConLn('Файл: ' + path);
  ConLn('MFT запис: ' + UnicodeString(IntToStr(recNum)) +
        '  (FRN ' + UnicodeString(IntToStr(frn and $0000FFFFFFFFFFFF)) +
        ', seq ' + UnicodeString(IntToStr(seq)) + ')');
  if (flags and 2) <> 0 then
    ConLn('Hardlinks: ' + UnicodeString(IntToStr(linkCnt)) + '   [DIR]')
  else
    ConLn('Hardlinks: ' + UnicodeString(IntToStr(linkCnt)) + '   [FILE]');

  haveSI := False; haveFN := False; attrs := ''; dataDesc := '';
  siC := 0; siM := 0; siA := 0; siR := 0; fnC := 0; fnM := 0; fnA := 0; fnR := 0;
  fnName := '';

  ap := rec + ao;
  while (PtrUInt(ap) + 8 <= PtrUInt(rec) + recLen) do
  begin
    atype := PDWORD(ap)^;
    if atype = $FFFFFFFF then Break;
    alen := PDWORD(ap + 4)^;
    if (alen = 0) or (PtrUInt(ap) + alen > PtrUInt(rec) + recLen) then Break;
    nonRes := PByte(ap + 8)^; nameLen := PByte(ap + 9)^; nameOff := PWord(ap + $0A)^;
    valOff := PWord(ap + $14)^;
    if attrs <> '' then attrs := attrs + ', ';
    attrs := attrs + AttrName(atype);

    case atype of
      $10:
        begin
          v := ap + valOff;
          siC := PInt64(v)^; siM := PInt64(v + 8)^; siR := PInt64(v + 16)^; siA := PInt64(v + 24)^;
          haveSI := True;
        end;
      $30:
        begin
          v := ap + valOff; ns := PByte(v + $41)^;
          if (not haveFN) or (ns <> 2) then
          begin
            fnC := PInt64(v + 8)^; fnM := PInt64(v + 16)^; fnR := PInt64(v + 24)^; fnA := PInt64(v + 32)^;
            SetString(fnName, PWideChar(v + $42), PByte(v + $40)^);
            haveFN := True;
          end;
        end;
      $80:
        if nameLen = 0 then
        begin
          if nonRes = 0 then
            dataDesc := UnicodeString(IntToStr(PDWORD(ap + $10)^)) + ' B (resident)'
          else
            dataDesc := UnicodeString(IntToStr(PInt64(ap + $28)^)) + ' B (non-resident, allocated)';
        end
        else
        begin
          SetString(adsName, PWideChar(ap + nameOff), nameLen);
          if nonRes = 0 then
            ConLn('  ADS :' + adsName + '  ' + UnicodeString(IntToStr(PDWORD(ap + $10)^)) + ' B')
          else
            ConLn('  ADS :' + adsName + '  ' + UnicodeString(IntToStr(PInt64(ap + $28)^)) + ' B');
        end;
    end;
    Inc(ap, alen);
  end;

  ConLn('Атрибути: ' + attrs);
  ConLn('');

  if haveSI then
  begin
    ConLn('$STANDARD_INFORMATION:');
    ConLn('  Created:    ' + FtStr(siC));
    ConLn('  Modified:   ' + FtStr(siM));
    ConLn('  Accessed:   ' + FtStr(siA));
    ConLn('  MFTChanged: ' + FtStr(siR));
  end;
  if haveFN then
  begin
    ConLn('$FILE_NAME (' + fnName + '):');
    ConLn('  Created:    ' + FtStr(fnC));
    ConLn('  Modified:   ' + FtStr(fnM));
    ConLn('  Accessed:   ' + FtStr(fnA));
    ConLn('  MFTChanged: ' + FtStr(fnR));
  end;
  if dataDesc <> '' then ConLn('$DATA: ' + dataDesc);

  ConLn('');
  ConLn('Timestomp анализ:');
  warned := False;
  if haveSI and haveFN and (fnC <> 0) and (siC < fnC) then
  begin ConLn('  [!] $SI Created предхожда $FN Created - класически timestomp.'); warned := True; end;
  if haveSI and haveFN and (fnM <> 0) and (siM < fnM) then
  begin ConLn('  [!] $SI Modified предхожда $FN - времето е бутнато назад.'); warned := True; end;
  if haveSI and (IsRound(siC) or IsRound(siM)) then
  begin ConLn('  [!] $SI времена закръглени до цяла секунда - типично за инструмент.'); warned := True; end;
  if haveSI and (siM <> 0) and (siC <> 0) and (siM < siC) then
  begin ConLn('  [!] $SI Modified преди Created - аномалия.'); warned := True; end;
  if not warned then ConLn('  Няма явни признаци.');
end.
