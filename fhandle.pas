program fhandle;
{ Кой процес държи заключен файл/папка. Изброява всички handle-и в системата
  (NtQuerySystemInformation), дублира ги, и за тип File сравнява името с целта.
  Иска admin (PROCESS_DUP_HANDLE на чужди процеси).
  Употреба: fhandle <път>
    показва PID, процес, handle стойност и обектното име - подай ги на fclose. }
{$mode objfpc}{$H+}
{$codepage UTF8}

uses
  Windows, SysUtils, misc;

type
  NTSTATUS = LongInt;

const
  SystemExtendedHandleInformation = 64;
  ObjectNameInformation = 1;
  ObjectTypeInformation = 2;
  STATUS_INFO_LENGTH_MISMATCH = NTSTATUS($C0000004);
  HANG_ACCESS = $0012019F;                 // handle-и, на които заявката за име зависва
  PROC_QUERY_LIMITED = $1000;

type
  UNICODE_STRING = record Len, MaximumLength: Word; Buffer: PWideChar; end;
  PUNICODE_STRING = ^UNICODE_STRING;

  SYSTEM_HANDLE_EX = record
    ObjectPtr: PtrUInt;
    UniqueProcessId: PtrUInt;
    HandleValue: PtrUInt;
    GrantedAccess: ULONG;
    CreatorBackTraceIndex: Word;
    ObjectTypeIndex: Word;
    HandleAttributes: ULONG;
    Reserved: ULONG;
  end;
  PSYSTEM_HANDLE_EX = ^SYSTEM_HANDLE_EX;

function NtQuerySystemInformation(SystemInformationClass: ULONG;
  SystemInformation: Pointer; SystemInformationLength: ULONG;
  ReturnLength: PULONG): NTSTATUS; stdcall; external 'ntdll.dll';
function NtQueryObject(Handle: HANDLE; ObjectInformationClass: ULONG;
  ObjectInformation: Pointer; ObjectInformationLength: ULONG;
  ReturnLength: PULONG): NTSTATUS; stdcall; external 'ntdll.dll';
function MyQueryFullProcessImageName(hProcess: HANDLE; dwFlags: DWORD;
  lpExeName: PWideChar; lpdwSize: PDWORD): BOOL;
  stdcall; external 'kernel32' name 'QueryFullProcessImageNameW';



function ObjType(h: HANDLE): UnicodeString;
var buf: array[0..1023] of Byte; rl: ULONG; us: PUNICODE_STRING;
begin
  Result := '';
  if NtQueryObject(h, ObjectTypeInformation, @buf, SizeOf(buf), @rl) = 0 then
  begin
    us := @buf;
    if (us^.Buffer <> nil) and (us^.Len > 0) then SetString(Result, us^.Buffer, us^.Len div 2);
  end;
end;

function ObjName(h: HANDLE): UnicodeString;
var buf: array[0..2047] of Byte; rl: ULONG; us: PUNICODE_STRING;
begin
  Result := '';
  if NtQueryObject(h, ObjectNameInformation, @buf, SizeOf(buf), @rl) = 0 then
  begin
    us := @buf;
    if (us^.Buffer <> nil) and (us^.Len > 0) then SetString(Result, us^.Buffer, us^.Len div 2);
  end;
end;

// PID -> име (lazy, с кеш)
var
  pnPid: array of DWORD;
  pnName: array of UnicodeString;
  pnCnt: Integer = 0;

function ProcName(pid: DWORD): UnicodeString;
var i: Integer; h: HANDLE; buf: array[0..MAX_PATH] of WideChar; sz: DWORD; nm: UnicodeString;
begin
  for i := 0 to pnCnt - 1 do if pnPid[i] = pid then Exit(pnName[i]);
  nm := '?';
  h := OpenProcess(PROC_QUERY_LIMITED, False, pid);
  if h <> 0 then
  begin
    sz := MAX_PATH;
    if MyQueryFullProcessImageName(h, 0, @buf[0], @sz) then
      nm := BaseName(PWideChar(@buf[0]));
    CloseHandle(h);
  end;
  if pnCnt >= System.Length(pnPid) then
  begin SetLength(pnPid, (pnCnt + 16) * 2); SetLength(pnName, (pnCnt + 16) * 2); end;
  pnPid[pnCnt] := pid; pnName[pnCnt] := nm; Inc(pnCnt);
  Result := nm;
end;

// кеш на отворени process handle-и за дублиране
var
  cachePid: array of DWORD;
  cacheH: array of HANDLE;
  cacheCnt: Integer = 0;

function ProcHandle(pid: DWORD): HANDLE;
var i: Integer; h: HANDLE;
begin
  for i := 0 to cacheCnt - 1 do if cachePid[i] = pid then Exit(cacheH[i]);
  h := OpenProcess(PROCESS_DUP_HANDLE, False, pid);
  if cacheCnt >= System.Length(cachePid) then
  begin SetLength(cachePid, (cacheCnt + 16) * 2); SetLength(cacheH, (cacheCnt + 16) * 2); end;
  cachePid[cacheCnt] := pid; cacheH[cacheCnt] := h; Inc(cacheCnt);
  Result := h;
end;

var
  i: Integer;
  targetPath, targetNt, drive, objn: UnicodeString;
  devBuf: array[0..MAX_PATH] of WideChar;
  buf: Pointer; bufLen, rl: ULONG;
  status: NTSTATUS;
  count, k: PtrUInt;
  ent: PSYSTEM_HANDLE_EX;
  base: PByte;
  ph, dup: HANDLE;
  found: Integer;
begin
  ConInit;
  if ParamCount < 1 then begin ConLn('Употреба: fhandle <път>'); Halt(1); end;
  targetPath := UnicodeString(ExpandFileName(ParamStr(1)));
  drive := Copy(targetPath, 1, 2);
  if QueryDosDeviceW(PWideChar(drive), @devBuf[0], MAX_PATH) = 0 then
  begin ConLn('QueryDosDevice грешка за ' + drive); Halt(1); end;
  targetNt := UnicodeString(PWideChar(@devBuf[0])) + Copy(targetPath, 3, MaxInt);

  bufLen := 1 shl 20; buf := GetMem(bufLen);
  repeat
    status := NtQuerySystemInformation(SystemExtendedHandleInformation, buf, bufLen, @rl);
    if status = STATUS_INFO_LENGTH_MISMATCH then
    begin FreeMem(buf); bufLen := bufLen * 2; buf := GetMem(bufLen); end;
  until status <> STATUS_INFO_LENGTH_MISMATCH;
  if status <> 0 then begin ConLn('NtQuerySystemInformation грешка.'); Halt(2); end;

  count := PPtrUInt(buf)^;                        // NumberOfHandles
  base := PByte(buf) + 2 * SizeOf(PtrUInt);       // прескочи count + reserved

  ConLn('Търся handle-и за: ' + targetNt);
  ConLn('');
  found := 0;

  for k := 0 to count - 1 do
  begin
    ent := PSYSTEM_HANDLE_EX(base + k * SizeOf(SYSTEM_HANDLE_EX));
    if ent^.GrantedAccess = HANG_ACCESS then Continue;
    ph := ProcHandle(DWORD(ent^.UniqueProcessId));
    if ph = 0 then Continue;
    if not DuplicateHandle(ph, HANDLE(ent^.HandleValue), GetCurrentProcess, @dup,
         0, False, DUPLICATE_SAME_ACCESS) then Continue;
    try
      if ObjType(dup) = 'File' then
      begin
        objn := ObjName(dup);
        if (objn <> '') and ((WideCompareText(objn, targetNt) = 0) or
           (Copy(WideLowerCase(objn), 1, System.Length(targetNt) + 1) =
            WideLowerCase(targetNt) + '\')) then
        begin
          ConLn(Format('PID %d  %s  handle 0x%x',
            [DWORD(ent^.UniqueProcessId), string(ProcName(DWORD(ent^.UniqueProcessId))),
             ent^.HandleValue]));
          ConLn('    ' + objn);
          Inc(found);
        end;
      end;
    finally
      CloseHandle(dup);
    end;
  end;

  for i := 0 to cacheCnt - 1 do if cacheH[i] <> 0 then CloseHandle(cacheH[i]);

  ConLn('');
  if found = 0 then ConLn('Никой не държи този път отворен (или handle-ите са пропуснати като зависващи).')
  else ConLn(UnicodeString(IntToStr(found)) + ' handle(а). Отключи с: fclose <PID> <handle>');
end.
