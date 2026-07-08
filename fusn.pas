program fusn;
{ Tail на NTFS USN журнала - всяка промяна на файл, която NTFS логва, а нищо
  не ти показва. Volume handle + FSCTL_QUERY/READ_USN_JOURNAL. Иска admin.
  Употреба: fusn [C] [/tail] [/n N]
    C      - буква на дял (по подразбиране C)
    /tail  - следи на живо само новите събития (като tail -f); без него
             изхвърля целия текущ журнал и излиза
    /n N   - спри след N записа }
{$mode objfpc}{$H+}
{$codepage UTF8}

uses
  Windows, SysUtils, misc, win_primitive;

const
  BUFSIZE                 = 64 * 1024;

var
  Letter: WideChar = 'C';
  Tail: Boolean = False;
  Limit: Integer = 0;        // 0 = без лимит
  Shown: Integer = 0;

procedure ProcessBuffer(buf: PByte; br: DWORD);
var
  recPtr: PByte;
  rec: PUSN_RECORD_V2;
  name: UnicodeString;
  isDir: Boolean;
begin
  recPtr := buf + 8;                          // първите 8 байта = следващ USN
  while PtrUInt(recPtr) < PtrUInt(buf) + br do
  begin
    rec := PUSN_RECORD_V2(recPtr);
    if rec^.RecordLength = 0 then Break;
    SetString(name, PWideChar(recPtr + rec^.FileNameOffset), rec^.FileNameLength div SizeOf(WideChar));
    isDir := (rec^.FileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0;
    ConLn(FtToStr(rec^.TimeStamp) + '  ' + ReasonStr(rec^.Reason) + UnicodeString(BoolToStr(isDir, '<DIR> ', '')) + name);
    Inc(Shown);
    if (Limit > 0) and (Shown >= Limit) then Exit;
    Inc(recPtr, rec^.RecordLength);
  end;
end;

var
  i: Integer;
  s, volPath: UnicodeString;
  h: HANDLE;
  jd: USN_JOURNAL_DATA;
  rd: READ_USN_JOURNAL_DATA;
  buf: Pointer;
  br: DWORD;
  startUsn, nextUsn: Int64;
begin
  ConInit;
  for i := 1 to ParamCount do
  begin
    s := UnicodeString(ParamStr(i));
    if SameText(string(s), '/tail') then Tail := True
    else if SameText(string(s), '/n') and (i < ParamCount) then
      Limit := StrToIntDef(ParamStr(i+1), 0)
    else if (System.Length(s) = 1) and (s[1] in ['A'..'Z','a'..'z']) then
      Letter := UpCase(WideChar(s[1]));
  end;

  volPath := '\\.\' + Letter + ':';
  h := CreateFileW(PWideChar(volPath), GENERIC_READ,
         FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
  if h = INVALID_HANDLE_VALUE then
  begin
    ConLn('Не мога да отворя ' + volPath +' (грешка ' + UnicodeString(IntToStr(GetLastError)) +'). Трябва admin cmd.');
    Halt(1);
  end;

  FillChar(jd, SizeOf(jd), 0);
  if not DeviceIoControl(h, FSCTL_QUERY_USN_JOURNAL, nil, 0, @jd, SizeOf(jd), br, nil) then
  begin
    ConLn('USN журналът не е активен (грешка ' + UnicodeString(IntToStr(GetLastError)) + ').');
    ConLn('Активирай го: fsutil usn createjournal m=33554432 a=8388608 ' + UnicodeString(Letter) + ':');
    CloseHandle(h);
    Halt(2);
  end;

  // tail = само новите; иначе целия наличен журнал
  if Tail then startUsn := jd.NextUsn
          else startUsn := jd.FirstUsn;

  buf := GetMem(BUFSIZE);
  try
    repeat
      FillChar(rd, SizeOf(rd), 0);
      rd.StartUsn       := startUsn;
      rd.ReasonMask     := $FFFFFFFF;
      rd.Timeout        := 0;
      rd.BytesToWaitFor := Ord(Tail);     // tail -> блокира докато дойде ново
      rd.UsnJournalID   := jd.UsnJournalID;

      if not DeviceIoControl(h, FSCTL_READ_USN_JOURNAL, @rd, SizeOf(rd),buf, BUFSIZE, br, nil) then
      begin
        ConLn('READ грешка ' + UnicodeString(IntToStr(GetLastError)));
        Break;
      end;

      nextUsn := PInt64(buf)^;
      if br > 8 then ProcessBuffer(PByte(buf), br);

      if (Limit > 0) and (Shown >= Limit) then Break;

      // без tail: br<=8 значи няма повече записи -> край
      if (not Tail) and (br <= 8) then Break;

      startUsn := nextUsn;
    until False;
  finally
    FreeMem(buf);
    CloseHandle(h);
  end;

  if not Tail then
    ConLn(#13#10 + UnicodeString(IntToStr(Shown)) + ' записа.');
end.
