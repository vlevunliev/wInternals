program fclose;
{ Затваря насила handle в чужд процес - дублира го с DUPLICATE_CLOSE_SOURCE,
  което затваря оригинала в притежателя. Иска admin.
  Употреба: fclose <PID> <handle>
    PID    - процес (от fhandle)
    handle - стойност на handle (напр. 0x4F8 или десетично)

  ОПАСНО: процесът-притежател не знае, че handle-ът му изчезва. Може да
  забие или да повреди данни. Ползвай само когато си наясно какво правиш -
  затваряне на файл, държан от заглушено приложение, а не системен handle. }
{$mode objfpc}{$H+}
{$codepage UTF8}

uses
  Windows, SysUtils, Misc;


function ParseNum(const s: string): Int64;
begin
  if (Length(s) > 2) and (LowerCase(Copy(s, 1, 2)) = '0x') then
    Result := StrToInt64Def('$' + Copy(s, 3, MaxInt), -1)
  else
    Result := StrToInt64Def(s, -1);
end;

var
  pid: Int64; hval: Int64;
  ph, dup: HANDLE;
begin
  ConInit;
  if ParamCount < 2 then begin ConLn('Употреба: fclose <PID> <handle>'); Halt(1); end;
  pid := ParseNum(ParamStr(1));
  hval := ParseNum(ParamStr(2));
  if (pid < 0) or (hval < 0) then begin ConLn('Невалиден PID или handle.'); Halt(1); end;

  ph := OpenProcess(PROCESS_DUP_HANDLE, False, DWORD(pid));
  if ph = 0 then
  begin ConLn('OpenProcess грешка ' + UnicodeString(IntToStr(GetLastError)) + ' (admin? процесът жив ли е?).'); Halt(2); end;

  if DuplicateHandle(ph, HANDLE(hval), GetCurrentProcess, @dup, 0, False,
       DUPLICATE_CLOSE_SOURCE) then
  begin
    CloseHandle(dup);
    ConLn(Format('Handle 0x%x в PID %d затворен.', [hval, pid]));
  end
  else
    ConLn('DuplicateHandle грешка ' + UnicodeString(IntToStr(GetLastError)) +
          ' (грешен handle или процесът го е затворил вече).');

  CloseHandle(ph);
end.
