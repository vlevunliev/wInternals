program fcompact;
{ Bulk WOF прозрачна компресия на папка - механизмът зад compact /compactos.
  Данните се пазят компресирани, четат се прозрачно. За статични файлове
  (executables, .lib, билд изходи) LZX свива 50-70%. Освобождава място без
  да трие нищо. Иска admin за по-голямата част от системните папки.
  Употреба: fcompact <папка> [/lzx|/x4|/x8|/x16] [/min N]
    /lzx        - LZX, най-добра компресия (по подразбиране); бавно
    /x4/x8/x16  - XPRESS 4K/8K/16K - по-бързо, по-малка компресия
    /min N      - пропусни файлове под N KB (по подразбиране 8)

  Бележка: WOF е прозрачна и идеална за статични файлове. Запис във файла
  връща компресията (файлът се разпъва обратно). Не я ползвай за активно
  редактирани файлове. Декомпресия: compact /u /s <папка>. }
{$mode objfpc}{$H+}
{$codepage UTF8}

uses
  Windows, SysUtils, misc, win_primitive;

const
  WOF_PROVIDER_FILE         = 2;

  // FILE_PROVIDER_COMPRESSION_*
  ALG_XPRESS4K  = 0;
  ALG_LZX       = 1;
  ALG_XPRESS8K  = 2;
  ALG_XPRESS16K = 3;


type
  FILE_PROVIDER_EXTERNAL_INFO_V1 = record
    Version, Algorithm, Flags: ULONG;
  end;


function CompressedSize(const path: UnicodeString): Int64;
var lo, hi: DWORD;
begin
  hi := 0;
  lo := MyGetCompressedFileSize(PWideChar(path), @hi);
  if lo = $FFFFFFFF then Exit(0);
  Result := (Int64(hi) shl 32) or lo;
end;

function CompressFile(const path: UnicodeString; algo: ULONG): Boolean;
var h: HANDLE; info: FILE_PROVIDER_EXTERNAL_INFO_V1;
begin
  Result := False;
  h := CreateFileW(PWideChar(path), GENERIC_READ or GENERIC_WRITE,
         FILE_SHARE_READ, nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0);
  if h = INVALID_HANDLE_VALUE then Exit;
  info.Version := 1; info.Algorithm := algo; info.Flags := 0;
  Result := WofSetFileDataLocation(h, WOF_PROVIDER_FILE, @info, SizeOf(info)) = S_OK;
  CloseHandle(h);
end;

var
  Algo: ULONG = ALG_LZX;
  MinKB: Integer = 8;
  MinBytes: Int64;
  DoneCnt, FailCnt, SkipCnt: Integer;
  TotBefore, TotAfter: Int64;

function CompactCB(const FullPath, Name: UnicodeString; Attr: DWORD;
  Size: Int64; Depth: Integer; Ctx: Pointer): TWalkAction;
var before, after: Int64;
begin
  if (Attr and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then Exit(waSkip);  // не следвай junction
  if (Attr and FILE_ATTRIBUTE_DIRECTORY) <> 0 then Exit(waRecurse);
  // файл:
  if Size < MinBytes then begin Inc(SkipCnt); Exit(waSkip); end;
  before := CompressedSize(LP(FullPath));
  if CompressFile(LP(FullPath), Algo) then
  begin
    after := CompressedSize(LP(FullPath));
    Inc(DoneCnt);
    TotBefore := TotBefore + before;
    TotAfter  := TotAfter + after;
  end
  else
    Inc(FailCnt);
  Result := waSkip;
end;

var
  i: Integer;
  s, root, algName: UnicodeString;
  t0: QWord;
begin
  ConInit;
  root := '';
  i := 1;
  while i <= ParamCount do
  begin
    s := UnicodeString(ParamStr(i));
    if SameText(string(s), '/lzx') then Algo := ALG_LZX
    else if SameText(string(s), '/x4') then Algo := ALG_XPRESS4K
    else if SameText(string(s), '/x8') then Algo := ALG_XPRESS8K
    else if SameText(string(s), '/x16') then Algo := ALG_XPRESS16K
    else if SameText(string(s), '/min') and (i < ParamCount) then begin MinKB := StrToIntDef(ParamStr(i+1), 8); Inc(i); end
    else if (System.Length(s) > 0) and (s[1] <> '/') then root := UnicodeString(ExpandFileName(ParamStr(i)));
    Inc(i);
  end;
  if root = '' then begin ConLn('Употреба: fcompact <папка> [/lzx|/x4|/x8|/x16] [/min N]'); Halt(1); end;
  StripTrailingSep(root);
  MinBytes := Int64(MinKB) * 1024;

  case Algo of
    ALG_LZX: algName := 'LZX';
    ALG_XPRESS4K: algName := 'XPRESS4K';
    ALG_XPRESS8K: algName := 'XPRESS8K';
    ALG_XPRESS16K: algName := 'XPRESS16K';
  end;

  ConLn('Компресирам ' + root + ' с ' + algName + ' (>= ' + UnicodeString(IntToStr(MinKB)) + ' KB)...');
  DoneCnt := 0;
  FailCnt := 0;
  SkipCnt := 0;
  TotBefore := 0;
  TotAfter := 0;
  t0 := GetTickCount64;
  WalkTree(root, @CompactCB, nil);

  ConLn('');
  ConLn('Компресирани: ' + UnicodeString(IntToStr(DoneCnt)) + ' файла');
  ConLn('  преди:  ' + HumanSize(TotBefore));
  ConLn('  след:   ' + HumanSize(TotAfter));
  if TotBefore > 0 then
    ConLn('  спестено: ' + HumanSize(TotBefore - TotAfter) +
          UnicodeString(Format(' (%.1f%%)', [(TotBefore - TotAfter) * 100 / TotBefore])));
  ConLn('Пропуснати (малки): ' + UnicodeString(IntToStr(SkipCnt)) +
        ', неуспешни (заети/права): ' + UnicodeString(IntToStr(FailCnt)));
  ConLn('Време: ' + UnicodeString(IntToStr(GetTickCount64 - t0)) + ' ms.');
end.
