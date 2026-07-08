program freg;
{ Намира скрити registry ключове и стойности - имена с вграден \0 или control
  chars. Win32 regedit стъпва на null-terminated стрингове и е сляп за тях;
  ние минаваме през Nt* фамилията с counted UNICODE_STRING и ги виждаме всичките.
  Класическият malware трик (Poweliks). Чист ntdll.
  Употреба: freg [корен] [/all]
    корен  - HKLM\... | HKU\... | native \Registry\... (по подразбиране HKLM\SOFTWARE)
    /all   - покажи всичко, не само скритото }
{$mode objfpc}{$H+}
{$codepage UTF8}

uses
  Windows, SysUtils, Misc, Win_Primitive;

type
  KEY_BASIC_INFORMATION = record
    LastWriteTime: Int64;
    TitleIndex: ULONG;
    NameLength: ULONG;            // в байтове
    Name: array[0..0] of WideChar;
  end;
  PKEY_BASIC_INFORMATION = ^KEY_BASIC_INFORMATION;

  KEY_VALUE_BASIC_INFORMATION = record
    TitleIndex: ULONG;
    DataType: ULONG;
    NameLength: ULONG;
    Name: array[0..0] of WideChar;
  end;
  PKEY_VALUE_BASIC_INFORMATION = ^KEY_VALUE_BASIC_INFORMATION;

const
  KEY_ENUMERATE_SUB_KEYS   = $0008;
  KEY_QUERY_VALUE          = $0001;
  KeyBasicInformation      = 0;
  KeyValueBasicInformation = 0;

function NtOpenKey(out KeyHandle: HANDLE; DesiredAccess: ACCESS_MASK;
  ObjectAttributes: POBJECT_ATTRIBUTES): NTSTATUS;
  stdcall; external 'ntdll.dll';

function NtEnumerateKey(KeyHandle: HANDLE; Index: ULONG; KeyInformationClass: ULONG;
  KeyInformation: Pointer; Length: ULONG; out ResultLength: ULONG): NTSTATUS;
  stdcall; external 'ntdll.dll';

function NtEnumerateValueKey(KeyHandle: HANDLE; Index: ULONG;
  KeyValueInformationClass: ULONG; KeyValueInformation: Pointer; Length: ULONG;
  out ResultLength: ULONG): NTSTATUS;
  stdcall; external 'ntdll.dll';


var
  ShowAll: Boolean = False;
  HiddenCount: Integer = 0;

// Скрито = съдържа знак под 32 (вкл. \0) - точно това regedit не може да покаже
function IsHidden(const S: UnicodeString): Boolean;
var i: Integer;
begin
  for i := 1 to System.Length(S) do
    if Ord(S[i]) < 32 then Exit(True);
  Result := False;
end;

// Escape за визуализация: control chars -> \xNN
function Esc(const S: UnicodeString): UnicodeString;
var i: Integer;
begin
  Result := '';
  for i := 1 to System.Length(S) do
    if Ord(S[i]) < 32 then
      Result := Result + UnicodeString(Format('\x%.2x', [Ord(S[i])]))
    else
      Result := Result + S[i];
end;

function OpenKey(Root: HANDLE; const Name: UnicodeString; out H: HANDLE): NTSTATUS;
var
  us: UNICODE_STRING;
  oa: OBJECT_ATTRIBUTES;
begin
  us.Buffer        := PWideChar(Name);          // counted - пази вградените \0
  us.Len           := System.Length(Name) * SizeOf(WideChar);
  us.MaximumLength := us.Len;
  FillChar(oa, SizeOf(oa), 0);
  oa.Length        := SizeOf(oa);
  oa.RootDirectory := Root;
  oa.ObjectName    := @us;
  oa.Attributes    := OBJ_CASE_INSENSITIVE;
  Result := NtOpenKey(H, KEY_ENUMERATE_SUB_KEYS or KEY_QUERY_VALUE, @oa);
end;

procedure Walk(H: HANDLE; const Prefix: UnicodeString);
var
  buf: array[0..2047] of Byte;
  rl, idx: ULONG;
  status: NTSTATUS;
  ki: PKEY_BASIC_INFORMATION;
  vi: PKEY_VALUE_BASIC_INFORMATION;
  nm, full: UnicodeString;
  childH: HANDLE;
  hid: Boolean;
begin
  // стойности
  idx := 0;
  repeat
    status := NtEnumerateValueKey(H, idx, KeyValueBasicInformation, @buf,
                SizeOf(buf), rl);
    if status <> STATUS_SUCCESS then Break;
    vi := @buf;
    SetString(nm, PWideChar(@vi^.Name[0]), vi^.NameLength div SizeOf(WideChar));
    hid := IsHidden(nm);
    if hid or ShowAll then
    begin
      full := Prefix + ' :: [value] ' + Esc(nm);
      if hid then begin ConLn('  СКРИТА ' + full); Inc(HiddenCount); end
      else ConLn('         ' + full);
    end;
    Inc(idx);
  until False;

  // подключове
  idx := 0;
  repeat
    status := NtEnumerateKey(H, idx, KeyBasicInformation, @buf, SizeOf(buf), rl);
    if status <> STATUS_SUCCESS then Break;
    ki := @buf;
    SetString(nm, PWideChar(@ki^.Name[0]), ki^.NameLength div SizeOf(WideChar));
    hid := IsHidden(nm);
    full := Prefix + '\' + Esc(nm);
    if hid then begin ConLn('  СКРИТ  ' + full); Inc(HiddenCount); end
    else if ShowAll then ConLn('         ' + full);

    // влизаме навътре - counted име пази \0, затова стигаме там където regedit не може
    if OpenKey(H, nm, childH) = STATUS_SUCCESS then
    begin
      Walk(childH, full);
      NtClose(childH);
    end;
    Inc(idx);
  until False;
end;

// HKLM\... / HKU\... -> native \Registry\... път
function Normalize(const P: UnicodeString): UnicodeString;
var up: UnicodeString;
begin
  up := UnicodeString(UpperCase(string(P)));
  if (Copy(up,1,5) = 'HKLM\') then Result := '\Registry\Machine\' + Copy(P,6,MaxInt)
  else if (Copy(up,1,4) = 'HKU\') then Result := '\Registry\User\' + Copy(P,5,MaxInt)
  else if up = 'HKLM' then Result := '\Registry\Machine'
  else if up = 'HKU' then Result := '\Registry\User'
  else Result := P;  // приема и суров native път
end;

var
  i: Integer;
  s, rootPath: UnicodeString;
  rootH: HANDLE;
  st: NTSTATUS;
begin
  ConInit;
  rootPath := 'HKLM\SOFTWARE';
  for i := 1 to ParamCount do
  begin
    s := UnicodeString(ParamStr(i));
    if SameText(string(s), '/all') then ShowAll := True
    else rootPath := s;
  end;
  rootPath := Normalize(rootPath);

  st := OpenKey(0, rootPath, rootH);
  if st <> STATUS_SUCCESS then
  begin
    ConLn('Не мога да отворя "' + rootPath + '" (NTSTATUS=0x' +
          UnicodeString(IntToHex(st, 8)) + '). Опитай като admin.');
    Halt(1);
  end;

  ConLn('Корен: ' + rootPath);
  Walk(rootH, rootPath);
  NtClose(rootH);

  ConLn('');
  if HiddenCount = 0 then ConLn('Нищо скрито намерено.')
  else ConLn(UnicodeString(IntToStr(HiddenCount)) + ' скрити имена намерени.');
end.
