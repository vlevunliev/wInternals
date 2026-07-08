program forphan;
{ Намира orphaned файлове в C:\Windows\Installer - кеширани .msi/.msp, на които
  вече никой инсталиран продукт или patch не реферира. Същата логика като
  PatchCleaner: питаме Installer API-то за LocalPackage на всеки продукт и patch,
  и каквото в папката не е в списъка - е сирак. Иска admin.
  Употреба: forphan [/move ПАПКА] [/del]
    (без флаг) - само докладва, нищо не пипа (dry-run)
    /move D    - мести сираците в папка D (обратимо - препоръчително)
    /del       - изтрива сираците (необратимо!)

  Внимание: легаси Installer API-то покрива machine + текущ потребител. Преди
  /del провери списъка. /move е безопасният вариант - после или ги връщаш,
  или ги изтриваш, ако нищо не се е счупило. }
{$mode objfpc}{$H+}
{$codepage UTF8}

uses
  Windows, SysUtils, Classes, Misc;

const
  ERROR_NO_MORE_ITEMS = 259;

function MsiEnumProductsA(iProductIndex: DWORD; lpProductBuf: PAnsiChar): UINT;
  stdcall; external 'msi.dll';
function MsiGetProductInfoA(szProduct, szProperty: PAnsiChar;
  lpValueBuf: PAnsiChar; pcchValueBuf: PDWORD): UINT; stdcall; external 'msi.dll';
function MsiEnumPatchesA(szProduct: PAnsiChar; iPatchIndex: DWORD;
  lpPatchBuf, lpTransformsBuf: PAnsiChar; pcchTransformsBuf: PDWORD): UINT;
  stdcall; external 'msi.dll';
function MsiGetPatchInfoA(szPatch, szAttribute: PAnsiChar;
  lpValueBuf: PAnsiChar; pcchValueBuf: PDWORD): UINT; stdcall; external 'msi.dll';


// LocalPackage на продукт (кеширан .msi)
function ProductLP(p: PAnsiChar): string;
var buf: array[0..1023] of AnsiChar; cch: DWORD;
begin
  cch := SizeOf(buf);
  if MsiGetProductInfoA(p, 'LocalPackage', @buf[0], @cch) = ERROR_SUCCESS then
    SetString(Result, PAnsiChar(@buf[0]), cch)
  else Result := '';
end;

// LocalPackage на patch (кеширан .msp)
function PatchLP(p: PAnsiChar): string;
var buf: array[0..1023] of AnsiChar; cch: DWORD;
begin
  cch := SizeOf(buf);
  if MsiGetPatchInfoA(p, 'LocalPackage', @buf[0], @cch) = ERROR_SUCCESS then
    SetString(Result, PAnsiChar(@buf[0]), cch)
  else Result := '';
end;

var
  refs: TStringList;
  MoveDir: string = '';
  DoDel: Boolean = False;

procedure CollectReferenced;
var
  i, j: DWORD;
  r, pr: UINT;
  prod: array[0..38] of AnsiChar;
  patch: array[0..38] of AnsiChar;
  trans: array[0..1023] of AnsiChar;
  tcch: DWORD;
  lp: string;
begin
  i := 0;
  while True do
  begin
    r := MsiEnumProductsA(i, @prod[0]);
    if r <> ERROR_SUCCESS then Break;        // вкл. NO_MORE_ITEMS
    lp := ProductLP(@prod[0]);
    if lp <> '' then refs.Add(LowerCase(ExtractFileName(lp)));

    j := 0;
    while True do
    begin
      tcch := SizeOf(trans);
      pr := MsiEnumPatchesA(@prod[0], j, @patch[0], @trans[0], @tcch);
      if pr <> ERROR_SUCCESS then Break;
      lp := PatchLP(@patch[0]);
      if lp <> '' then refs.Add(LowerCase(ExtractFileName(lp)));
      Inc(j);
    end;
    Inc(i);
  end;
end;

var
  winDir: array[0..MAX_PATH] of AnsiChar;
  instDir: string;
  h: HANDLE;
  fd: TWin32FindDataA;
  i: Integer;
  name, ext, full, dst: string;
  fsize: Int64;
  allCnt, refCnt, orphCnt: Integer;
  allSz, refSz, orphSz: Int64;
  idx: Integer;
  isOrphan: Boolean;
begin
  ConInit;
  i := 1;
  while i <= ParamCount do
  begin
    if SameText(ParamStr(i), '/move') and (i < ParamCount) then
    begin
      MoveDir := ParamStr(i+1); Inc(i);
    end
    else if SameText(ParamStr(i), '/del') then DoDel := True;
    Inc(i);
  end;

  GetWindowsDirectoryA(@winDir[0], MAX_PATH);
  instDir := string(PAnsiChar(@winDir[0])) + '\Installer';

  refs := TStringList.Create;
  refs.Sorted := True;
  refs.Duplicates := dupIgnore;
  try
    CollectReferenced;
    ConLn('Реферирани пакети: ' + UnicodeString(IntToStr(refs.Count)));
    ConLn('Папка: ' + UnicodeString(instDir));
    ConLn('');

    if MoveDir <> '' then CreateDirectoryA(PAnsiChar(MoveDir), nil);

    allCnt := 0; refCnt := 0; orphCnt := 0;
    allSz := 0; refSz := 0; orphSz := 0;

    h := FindFirstFileA(PAnsiChar(instDir + '\*'), fd);
    if h = INVALID_HANDLE_VALUE then
    begin
      ConLn('Не мога да чета папката (грешка ' +
            UnicodeString(IntToStr(GetLastError)) + '). Трябва admin.');
      Halt(1);
    end;
    try
      repeat
        if (fd.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then Continue;
        name := string(PAnsiChar(@fd.cFileName[0]));
        ext := LowerCase(ExtractFileExt(name));
        if (ext <> '.msi') and (ext <> '.msp') then Continue;

        fsize := (Int64(fd.nFileSizeHigh) shl 32) or fd.nFileSizeLow;
        Inc(allCnt); allSz := allSz + fsize;

        isOrphan := not refs.Find(LowerCase(name), idx);
        if isOrphan then
        begin
          Inc(orphCnt); orphSz := orphSz + fsize;
          full := instDir + '\' + name;
          ConLn('  СИРАК ' + HumanSize(fsize) + '  ' + UnicodeString(name));
          if MoveDir <> '' then
          begin
            dst := MoveDir + '\' + name;
            if not MoveFileA(PAnsiChar(full), PAnsiChar(dst)) then
              ConLn('        (не успях да преместя, грешка ' +
                    UnicodeString(IntToStr(GetLastError)) + ')');
          end
          else if DoDel then
            if not DeleteFileA(PAnsiChar(full)) then
              ConLn('        (не успях да изтрия, грешка ' +
                    UnicodeString(IntToStr(GetLastError)) + ')');
        end
        else
        begin
          Inc(refCnt); refSz := refSz + fsize;
        end;
      until not FindNextFileA(h, fd);
    finally
      Windows.FindClose(h);
    end;

    ConLn('');
    ConLn('Общо в папката: ' + UnicodeString(IntToStr(allCnt)) + ' файла, ' + HumanSize(allSz));
    ConLn('  реферирани:   ' + UnicodeString(IntToStr(refCnt)) + ' файла, ' + HumanSize(refSz));
    ConLn('  СИРАЦИ:       ' + UnicodeString(IntToStr(orphCnt)) + ' файла, ' + HumanSize(orphSz));
    ConLn('');
    if (MoveDir = '') and (not DoDel) then
      ConLn('Само доклад. За действие: /move <папка> (обратимо) или /del (необратимо).')
    else if MoveDir <> '' then
      ConLn('Преместени в: ' + UnicodeString(MoveDir))
    else
      ConLn('Изтрити.');
  finally
    refs.Free;
  end;
end.
