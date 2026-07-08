program fdel;
{ Бързо рекурсивно триене на дърво в стил "rd /s", но паралелно.
  Бързо изброяване (FindFirstFileEx + LARGE_FETCH), пул нишки за файловете,
  папките се махат bottom-up накрая. Long-path (\\?\) aware.

  Употреба: fdel <път> [/MT[:N]] [/Q] [/F]
    /MT[:N]  - N нишки за триене на файлове (по подразбиране 8)
    /Q       - тихо (без резюме)
    /F       - позволи триене на корен на диск (по подразбиране забранено)

  Безопасност:
    - reparse point (junction/symlink) НЕ се обхожда - маха се самият линк,
      не съдържанието на целта
    - read-only/hidden/system атрибути се чистят преди триене
    - отказва да трие корен на диск без /F
}
{$mode objfpc}{$H+}

uses
  Windows, SysUtils, Classes, Misc, Win_Primitive;


var
  Files: array of UnicodeString;
  FileCount: Integer = 0;
  Dirs: array of UnicodeString;      // pre-order: родител преди деца
  DirCount: Integer = 0;
  NextJob: LongInt = 0;              // атомарен курсор за работниците
  DelFiles: LongInt = 0;
  DelDirs: LongInt = 0;
  ErrCount: LongInt = 0;
  ThreadCount: Integer = 8;
  Quiet: Boolean = False;
  ForceRoot: Boolean = False;
  Target: UnicodeString;

procedure AddFile(const P: UnicodeString);
begin
  if FileCount >= Length(Files) then
    SetLength(Files, (FileCount + 16) * 2);
  Files[FileCount] := P;
  Inc(FileCount);
end;

procedure AddDir(const P: UnicodeString);
begin
  if DirCount >= Length(Dirs) then
    SetLength(Dirs, (DirCount + 16) * 2);
  Dirs[DirCount] := P;
  Inc(DirCount);
end;

// изчисти атрибути които спират триенето (read-only/hidden/system)
procedure ClearAttrs(const P: UnicodeString);
begin
  SetFileAttributesW(PWideChar(LP(P)), FILE_ATTRIBUTE_NORMAL);
end;

function DelCB(const FullPath, Name: UnicodeString; Attr: DWORD;
  Size: Int64; Depth: Integer; Ctx: Pointer): TWalkAction;
begin
  // reparse: НЕ обхождай - махни самия линк, не целта
  if (Attr and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then
  begin
    if (Attr and FILE_ATTRIBUTE_DIRECTORY) <> 0 then AddDir(FullPath)  // RemoveDirectoryW маха junction-а
    else AddFile(FullPath);                                           // DeleteFileW маха symlink-а
    Exit(waSkip);
  end;
  if (Attr and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
  begin
    AddDir(FullPath);   // pre-order: родителят преди децата
    Exit(waRecurse);
  end;
  AddFile(FullPath);
  Result := waSkip;
end;

type
  TWorker = class(TThread)
    procedure Execute; override;
  end;

procedure TWorker.Execute;
var
  i: LongInt;
begin
  repeat
    i := InterlockedIncrement(NextJob) - 1;
    if i >= FileCount then Break;
    if DeleteFileW(PWideChar(LP(Files[i]))) then
      InterlockedIncrement(DelFiles)
    else
    begin
      // втори опит след чистене на атрибути
      ClearAttrs(Files[i]);
      if DeleteFileW(PWideChar(LP(Files[i]))) then
        InterlockedIncrement(DelFiles)
      else
        InterlockedIncrement(ErrCount);
    end;
  until False;
end;

function IsDriveRoot(const P: UnicodeString): Boolean;
begin
  // "C:" или "C:\" ; също гол UNC share root \\srv\share
  Result := ((Length(P) <= 3) and (Length(P) >= 2) and (P[2] = ':'));
end;

var
  i: Integer;
  s: string;
  attr: DWORD;
  workers: array of TWorker;
  t0: QWord;
  positional: array of UnicodeString;
  np, ti: Integer;
begin
  ConInit;
  if ParamCount < 1 then
  begin
    ConLn('Usage: fdel <path> [<path2> ...] [/MT[:N]] [/Q] [/F]');
    Halt(1);
  end;

  // раздели позиционни (пътища) от опции
  SetLength(positional, ParamCount);
  np := 0;
  for i := 1 to ParamCount do
  begin
    s := ParamStr(i);
    if (Length(s) > 0) and (s[1] = '/') then
    begin
      if SameText(Copy(s, 1, 3), '/MT') then
      begin
        ThreadCount := 8;
        if (Length(s) > 3) and (s[4] = ':') then
          ThreadCount := StrToIntDef(string(Copy(s, 5, MaxInt)), 8);
        if ThreadCount < 1 then ThreadCount := 1;
      end
      else if SameText(s, '/Q') then Quiet := True
      else if SameText(s, '/F') then ForceRoot := True;
    end
    else
    begin
      positional[np] := UnicodeString(s);
      Inc(np);
    end;
  end;

  if np = 0 then
  begin
    ConLn('Usage: fdel <path> [<path2> ...] [/MT[:N]] [/Q] [/F]');
    Halt(1);
  end;

  t0 := GetTickCount64;

  // 1) изброяване на всички цели (файлове -> job-ове, папки -> Dirs списък)
  for ti := 0 to np - 1 do
  begin
    Target := ExpandFileName(positional[ti]);
    StripTrailingSep(Target);

    attr := GetFileAttributesW(PWideChar(LP(Target)));
    if attr = INVALID_FILE_ATTRIBUTES then
    begin
      ConLn('fdel: no such path: ' + Target);
      InterlockedIncrement(ErrCount);
      Continue;
    end;
    if IsDriveRoot(Target) and not ForceRoot then
    begin
      ConLn('fdel: refusing to delete drive root without /F: ' + Target);
      InterlockedIncrement(ErrCount);
      Continue;
    end;

    if (attr and FILE_ATTRIBUTE_DIRECTORY) = 0 then
      AddFile(Target)         // единичен файл/симлинк -> job
    else
    begin
      AddDir(Target);              // корена - pre-order, преди децата
      WalkTree(Target, @DelCB, nil);
    end;
  end;

  // 2) паралелно триене на всички файлове (един пул)
  NextJob := 0;
  if FileCount > 0 then
  begin
    SetLength(workers, ThreadCount);
    for i := 0 to ThreadCount - 1 do
      workers[i] := TWorker.Create(False);
    for i := 0 to ThreadCount - 1 do
    begin
      workers[i].WaitFor;
      workers[i].Free;
    end;
  end;

  // 3) папки bottom-up (обратен ред на pre-order = деца преди родители)
  for i := DirCount - 1 downto 0 do
  begin
    if RemoveDirectoryW(PWideChar(LP(Dirs[i]))) then
      InterlockedIncrement(DelDirs)
    else
    begin
      ClearAttrs(Dirs[i]);
      if RemoveDirectoryW(PWideChar(LP(Dirs[i]))) then
        InterlockedIncrement(DelDirs)
      else
        InterlockedIncrement(ErrCount);
    end;
  end;

  if not Quiet then
    ConLn('Deleted: ' + UnicodeString(IntToStr(DelFiles)) + ' files, ' +
         UnicodeString(IntToStr(DelDirs)) + ' dirs, errors: ' +
         UnicodeString(IntToStr(ErrCount)) + ', time: ' +
         UnicodeString(IntToStr(Integer(GetTickCount64 - t0))) + ' ms, threads: ' +
         UnicodeString(IntToStr(ThreadCount)));

  if ErrCount > 0 then Halt(2);
end.
