program fshim;
{ Парсер за ShimCache (AppCompatCache) - артефактът, в който Windows тихо
  записва кои екзета е виждала, а никъде не го показва. Формат Win10/11 ("10ts").
  Блобът е REG_BINARY в SYSTEM hive-а -> иска admin.
  Употреба: fshim [/path X]
    /path X - запиши суровия блоб във файл X за офлайн анализ

  ВАЖНО: на Win10 това НЕ е доказателство за изпълнение, а че файлът е бил
  видян/наличен. Времето е last-modified на файла ($STANDARD_INFORMATION),
  не време на стартиране. Стойността се записва на shutdown - на свежо
  стартирана машина блобът отразява предишната сесия. }
{$mode objfpc}{$H+}
{$codepage UTF8}

uses
  Windows, SysUtils, misc;

const
  HKLM_SUBKEY = 'SYSTEM\CurrentControlSet\Control\Session Manager\AppCompatCache';
  VAL_NAME    = 'AppCompatCache';


// чете REG_BINARY блоба; връща nil при неуспех
function ReadBlob(out Size: DWORD): PByte;
var
  hk: HKEY;
  typ, sz: DWORD;
  r: LongInt;
begin
  Result := nil; Size := 0;
  r := RegOpenKeyExW(HKEY_LOCAL_MACHINE, PWideChar(UnicodeString(HKLM_SUBKEY)),
         0, KEY_QUERY_VALUE, hk);
  if r <> ERROR_SUCCESS then
  begin
    ConLn('RegOpenKeyEx грешка ' + UnicodeString(IntToStr(r)) +
          ' (5 = достъп отказан -> трябва admin).');
    Exit;
  end;
  try
    sz := 0;
    if RegQueryValueExW(hk, PWideChar(UnicodeString(VAL_NAME)), nil, @typ, nil,
         @sz) <> ERROR_SUCCESS then Exit;
    Result := GetMem(sz);
    if RegQueryValueExW(hk, PWideChar(UnicodeString(VAL_NAME)), nil, @typ,
         Result, @sz) <> ERROR_SUCCESS then
    begin
      FreeMem(Result); Result := nil; Exit;
    end;
    Size := sz;
  finally
    RegCloseKey(hk);
  end;
end;

function IsMagic(p: PByte): Boolean;   // "10ts"
begin
  Result := (p[0] = Ord('1')) and (p[1] = Ord('0')) and
            (p[2] = Ord('t')) and (p[3] = Ord('s'));
end;

var
  Count: Integer = 0;

// Win10/11 запис:
//  +0  "10ts"            (4)
//  +4  unknown           (4)
//  +8  CacheEntrySize    (4)  - байтове след това поле
//  +12 PathSize          (2)
//  +14 Path              (PathSize, UTF-16)
//      LastModified      (8, FILETIME)
//      DataSize          (4)
//      Data              (DataSize)
procedure Parse(blob: PByte; len: DWORD);
var
  pos, first: DWORD;
  entrySize, dataSize: DWORD;
  pathSize: Word;
  ft: Int64;
  path: UnicodeString;
begin
  if len < 4 then Exit;

  first := PDWORD(blob)^;                 // offset към първия запис (обикн. 0x30/0x34)
  if (first <> $30) and (first <> $34) then
  begin
    // fallback: сканирай за първото "10ts"
    first := 0;
    while (first + 4 <= len) and (not IsMagic(blob + first)) do Inc(first);
    if first + 4 > len then
    begin
      ConLn('Не намерих "10ts" сигнатура - вероятно по-стар формат от Win8.1.');
      Exit;
    end;
  end;

  pos := first;
  while pos + 14 <= len do
  begin
    if not IsMagic(blob + pos) then Break;

    entrySize := PDWORD(blob + pos + 8)^;
    pathSize  := PWord(blob + pos + 12)^;

    // bound-check преди да четем името и времето
    if (pos + 14 + pathSize + 8 > len) or (entrySize = 0) or
       (pos + 12 + entrySize > len) then Break;

    SetString(path, PWideChar(blob + pos + 14), pathSize div SizeOf(WideChar));
    ft := PInt64(blob + pos + 14 + pathSize)^;

    Inc(Count);
    ConLn(UnicodeString(Format('%4d  ', [Count])) + FtToStr(ft) + '  ' + path);

    // dataSize е след FILETIME-а; следващ запис = pos + 12 + entrySize
    dataSize := PDWORD(blob + pos + 14 + pathSize + 8)^;
    if dataSize = 0 then ;                 // само за яснота - не се ползва за стъпка

    pos := pos + 12 + entrySize;
  end;
end;

var
  i: Integer;
  s, dumpPath: UnicodeString;
  blob: PByte;
  sz: DWORD;
  fs: THandle;
  wr: DWORD;
begin
  ConInit;
  dumpPath := '';
  for i := 1 to ParamCount do
  begin
    s := UnicodeString(ParamStr(i));
    if SameText(string(s), '/path') and (i < ParamCount) then
      dumpPath := UnicodeString(ParamStr(i+1));
  end;

  blob := ReadBlob(sz);
  if blob = nil then Halt(1);

  try
    ConLn('AppCompatCache блоб: ' + UnicodeString(IntToStr(sz)) + ' байта');
    ConLn('  #   Last-Modified (file)   Path');
    ConLn('----  -------------------   ----');
    Parse(blob, sz);
    ConLn('');
    ConLn(UnicodeString(IntToStr(Count)) + ' записа. (видян/наличен, НЕ е изпълнение)');

    if dumpPath <> '' then
    begin
      fs := CreateFileW(PWideChar(dumpPath), GENERIC_WRITE, 0, nil, CREATE_ALWAYS, 0, 0);
      if fs <> INVALID_HANDLE_VALUE then
      begin
        WriteFile(fs, blob^, sz, wr, nil);
        CloseHandle(fs);
        ConLn('Суров блоб записан в ' + dumpPath);
      end;
    end;
  finally
    FreeMem(blob);
  end;
end.
