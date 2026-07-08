program fobj;
{ Браузър за NT object namespace - дървото, което Explorer крие.
  \Device, \BaseNamedObjects, \GLOBAL??, \Sessions ... devices, sections,
  mutants, events, symbolic links. Чист ntdll, нула други зависимости.
  Употреба: fobj [път] [/r]
    път  - стартова директория в namespace-а (по подразбиране \)
    /r   - рекурсивно надолу }
{$mode objfpc}{$H+}
{$codepage UTF8}

uses
  Windows, SysUtils, Misc, Win_Primitive;

type
  OBJECT_DIRECTORY_INFORMATION = record
    Name: UNICODE_STRING;
    TypeName: UNICODE_STRING;
  end;
  POBJECT_DIRECTORY_INFORMATION = ^OBJECT_DIRECTORY_INFORMATION;

const
  DIRECTORY_QUERY        = $0001;
  DIRECTORY_TRAVERSE     = $0002;
  BUFSIZE                = 64 * 1024;

function NtOpenDirectoryObject(out DirectoryHandle: HANDLE;
  DesiredAccess: ACCESS_MASK; ObjectAttributes: POBJECT_ATTRIBUTES): NTSTATUS;
  stdcall; external 'ntdll.dll';

function NtQueryDirectoryObject(DirectoryHandle: HANDLE; Buffer: Pointer;
  Length: ULONG; ReturnSingleEntry: ByteBool; RestartScan: ByteBool;
  var Context: ULONG; ReturnLength: LPDWORD): NTSTATUS;
  stdcall; external 'ntdll.dll';


var
  Recursive: Boolean = False;
  DirCount: Integer = 0;
  ObjCount: Integer = 0;

function USToStr(const U: UNICODE_STRING): UnicodeString;
begin
  if (U.Buffer = nil) or (U.Len = 0) then
    Result := ''
  else
    SetString(Result, U.Buffer, U.Len div SizeOf(WideChar));
end;

procedure InitOA(out OA: OBJECT_ATTRIBUTES; Name: PUNICODE_STRING; Root: HANDLE);
begin
  FillChar(OA, SizeOf(OA), 0);
  OA.Length        := SizeOf(OA);
  OA.RootDirectory := Root;
  OA.ObjectName    := Name;
  OA.Attributes    := OBJ_CASE_INSENSITIVE;
end;

function OpenDir(Root: HANDLE; const Name: UnicodeString; out H: HANDLE): NTSTATUS;
var
  us: UNICODE_STRING;
  oa: OBJECT_ATTRIBUTES;
begin
  us.Buffer        := PWideChar(Name);
  us.Len           := System.Length(Name) * SizeOf(WideChar);
  us.MaximumLength := us.Len;
  InitOA(oa, @us, Root);
  Result := NtOpenDirectoryObject(H, DIRECTORY_QUERY or DIRECTORY_TRAVERSE, @oa);
end;

procedure Walk(H: HANDLE; const Prefix: UnicodeString; Depth: Integer);
var
  buf: Pointer;
  ctx, retLen: ULONG;
  status: NTSTATUS;
  restart: ByteBool;
  p: POBJECT_DIRECTORY_INFORMATION;
  nm, tp, indent: UnicodeString;
  childH: HANDLE;
  isDir: Boolean;
begin
  buf := GetMem(BUFSIZE);                       // собствен буфер за нивото
  try
    indent := UnicodeString(StringOfChar(' ', Depth * 2));
    ctx := 0;
    restart := ByteBool(True);
    repeat
      status := NtQueryDirectoryObject(H, buf, BUFSIZE, ByteBool(False),
                  restart, ctx, @retLen);
      restart := ByteBool(False);
      if status = STATUS_NO_MORE_ENTRIES then Break;
      if (status <> STATUS_SUCCESS) and (status <> STATUS_MORE_ENTRIES) then Break;

      p := POBJECT_DIRECTORY_INFORMATION(buf);
      while p^.Name.Buffer <> nil do
      begin
        nm := USToStr(p^.Name);
        tp := USToStr(p^.TypeName);
        isDir := (tp = 'Directory');
        Inc(ObjCount);
        if isDir then Inc(DirCount);

        ConLn(indent + nm + '  [' + tp + ']');

        if Recursive and isDir then
          if OpenDir(H, nm, childH) = STATUS_SUCCESS then
          begin
            Walk(childH, Prefix + '\' + nm, Depth + 1);
            NtClose(childH);
          end
          else
            ConLn(indent + '  <отказан достъп>');

        Inc(p);
      end;
    until status <> STATUS_MORE_ENTRIES;
  finally
    FreeMem(buf);
  end;
end;

var
  i: Integer;
  s, rootPath: UnicodeString;
  rootH: HANDLE;
  st: NTSTATUS;
begin
  ConInit;
  rootPath := '\';
  for i := 1 to ParamCount do
  begin
    s := UnicodeString(ParamStr(i));
    if SameText(string(s), '/r') then Recursive := True
    else rootPath := s;
  end;

  st := OpenDir(0, rootPath, rootH);
  if st <> STATUS_SUCCESS then
  begin
    ConLn('Не мога да отворя "' + rootPath + '" (NTSTATUS=0x' +
          UnicodeString(IntToHex(st, 8)) + '). Опитай като admin.');
    Halt(1);
  end;

  ConLn(rootPath);
  Walk(rootH, rootPath, 1);
  NtClose(rootH);

  ConLn('');
  ConLn(UnicodeString(IntToStr(ObjCount)) + ' обекта, от които ' +
        UnicodeString(IntToStr(DirCount)) + ' директории.');
end.
