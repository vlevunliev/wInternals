program fcopy;
{ Рекурсивно копиране на дърво в стил robocopy /MT.
  Бързо изброяване (FindFirstFileEx + LARGE_FETCH), CopyFileEx (ODX),
  опционален пул нишки и unbuffered режим за големи файлове.
  Употреба: fcopy <източник> <цел> [/MT[:N]] [/NB]
    /MT[:N]  - N нишки (по подразбиране 8); за HDD ползвай 1
    /NB      - COPY_FILE_NO_BUFFERING (за големи файлове, >неск. стотин MB)
}
{$mode objfpc}{$H+}

uses
  Windows, SysUtils, classes, misc, win_primitive;


type
  TCopyJob = record
    Src, Dst: UnicodeString;
    Size: Int64;
  end;

  TCopyCtx = record
    SrcRoot, DstRoot: UnicodeString;
  end;
  PCopyCtx = ^TCopyCtx;

  TWorker = class(TThread)
    procedure Execute; override;
  end;

var
  Jobs: array of TCopyJob;
  JobCount: Integer = 0;
  NextJob: LongInt = 0;         // атомарен курсор за работниците
  NoBuffering: Boolean = False;
  ThreadCount: Integer = 1;
  TotalBytes: Int64 = 0;
  CopiedFiles: LongInt = 0;
  ErrCount: LongInt = 0;
  SrcRoot, DstRoot: UnicodeString;



procedure AddJob(const ASrc, ADst: UnicodeString; ASize: Int64);
begin
  if JobCount >= Length(Jobs) then
    SetLength(Jobs, (JobCount + 16) * 2);
  Jobs[JobCount].Src  := ASrc;
  Jobs[JobCount].Dst  := ADst;
  Jobs[JobCount].Size := ASize;
  Inc(JobCount);
end;



function CopyCB(const FullPath, Name: UnicodeString; Attr: DWORD;
  Size: Int64; Depth: Integer; Ctx: Pointer): TWalkAction;
var c: PCopyCtx; dst: UnicodeString;
begin
  if (Attr and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then Exit(waSkip);  // не влизай в junction
  c := PCopyCtx(Ctx);
  dst := c^.DstRoot + Copy(FullPath, System.Length(c^.SrcRoot) + 1, MaxInt);
  if (Attr and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
  begin
    CreateDirectoryW(PWideChar(LP(dst)), nil);
    Exit(waRecurse);
  end;
  AddJob(FullPath, dst, Size);
  Result := waSkip;
end;

procedure TWorker.Execute;
var
  i: LongInt;
  flags: DWORD;
  ret : LongWord;
begin
  flags := 0;
  if NoBuffering then flags := COPY_FILE_NO_BUFFERING;
  repeat
    i := InterlockedIncrement(NextJob) - 1;   // вземи следващия индекс
    if i >= JobCount then Break;
    ret:=CopyFileExW(PWideChar(LP(Jobs[i].Src)), PWideChar(LP(Jobs[i].Dst)), nil, nil, nil, flags);
    if Boolean(ret) then
    begin
      InterLockedExchangeAdd64(TotalBytes, Jobs[i].Size);
      InterlockedIncrement(CopiedFiles);
    end
    else
      InterlockedIncrement(ErrCount);
  until False;
end;

var
  i, nSrc: Integer;
  s: UnicodeString;
  workers: array of TWorker;
  t0: QWord;
  positional: array of UnicodeString;
  np: Integer;
  src: UnicodeString;
  ctx: TCopyCtx;
begin
  if ParamCount < 2 then
  begin
    Writeln('Usage: fcopy <src> [<src2> ...] <dst> [/MT[:N]] [/NB]');
    Halt(1);
  end;

  // раздели позиционни (пътища) от опции (/...)
  SetLength(positional, ParamCount);
  np := 0;
  for i := 1 to ParamCount do
  begin
    s := UnicodeString(ParamStr(i));
    if (Length(s) > 0) and (s[1] = '/') then
    begin
      if SameText(string(Copy(s, 1, 3)), '/MT') then
      begin
        ThreadCount := 8;
        if (Length(s) > 3) and (s[4] = ':') then
          ThreadCount := StrToIntDef(string(Copy(s, 5, MaxInt)), 8);
        if ThreadCount < 1 then ThreadCount := 1;
      end
      else if SameText(string(s), '/NB') then
        NoBuffering := True;
    end
    else
    begin
      positional[np] := s;
      Inc(np);
    end;
  end;

  if np < 2 then
  begin
    Writeln('Usage: fcopy <src> [<src2> ...] <dst> [/MT[:N]] [/NB]');
    Halt(1);
  end;

  // последният позиционен = цел, останалите = източници
  DstRoot := ExpandFileName(positional[np - 1]);
  StripTrailingSep(DstRoot);
  nSrc := np - 1;

  t0 := GetTickCount64;

  // 1) изброяване + създаване на директориите за всеки източник
  for i := 0 to nSrc - 1 do
  begin
    src := ExpandFileName(positional[i]);
    StripTrailingSep(src);
    if PathIsDir(src) then
    begin
      // копирай папката КАТО поддиректория на целта: dst\ИмеНаПапката\...
      ctx.SrcRoot := src;
      ctx.DstRoot := DstRoot + '\' + BaseName(src);
      CreateDirectoryW(PWideChar(LP(ctx.DstRoot)), nil);   // корен-целта
      WalkTree(src, @CopyCB, @ctx);
    end
    else if PathIsDir(DstRoot) then
      AddJob(src, DstRoot + '\' + BaseName(src), 0)
    else
      // единствен източник + несъществуваща цел -> целта е име на файл
      AddJob(src, DstRoot, 0);
  end;

  // 2) паралелно копиране (един пул за всички job-ове)
  NextJob := 0;
  SetLength(workers, ThreadCount);
  for i := 0 to ThreadCount - 1 do
    workers[i] := TWorker.Create(False);
  for i := 0 to ThreadCount - 1 do
  begin
    workers[i].WaitFor;
    workers[i].Free;
  end;

  Writeln(Format('Copied: %d files, %d MB, errors: %d, time: %d ms, threads: %d',
    [CopiedFiles, TotalBytes div (1024 * 1024), ErrCount,
     Integer(GetTickCount64 - t0), ThreadCount]));

  if ErrCount > 0 then Halt(2);
end.
