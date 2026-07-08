unit ntmft;

{ Споделен MFT скенер за Шило - механиката, която fdu/ffind/fdupe повтаряха.
  Само чист прочит + парсене; tool-специфичното (какво се събира от всеки
  запис, реконструкция на пътища) остава в самите инструменти. }

{$mode ObjFPC}{$H+}

interface

uses
  Windows, Win_Primitive;

type
  TRun = record lcn, count: Int64; end;
  TRunArray = array of TRun;

// Raw прочит на offset байта от volume handle-а.
function ReadAt(h: HANDLE; offset: Int64; buf: Pointer; size: DWORD): Boolean;
// USA fixup: възстановява последните 2 байта на всеки сектор от MFT записа.
procedure ApplyFixup(rec: PByte; sectorSize: DWORD);
// Декодира data run-овете на първото неименувано non-resident $DATA в записа.
function DecodeMftRuns(rec: PByte; recSize: DWORD): TRunArray;

implementation

function ReadAt(h: HANDLE; offset: Int64; buf: Pointer; size: DWORD): Boolean;
var rd: DWORD;
begin
  Result := SetFilePointerEx(h, offset, nil, FILE_BEGIN) and
            ReadFile(h, buf^, size, rd, nil) and (rd = size);
end;

procedure ApplyFixup(rec: PByte; sectorSize: DWORD);
var usaOff, usaCnt: Word; i: Integer;
begin
  usaOff := PWord(rec + 4)^;
  usaCnt := PWord(rec + 6)^;
  if usaCnt < 2 then Exit;
  for i := 1 to usaCnt - 1 do
    PWord(rec + DWORD(i) * sectorSize - 2)^ := PWord(rec + usaOff + i * 2)^;
end;

function DecodeMftRuns(rec: PByte; recSize: DWORD): TRunArray;
var
  ao: Word; ap: PByte; atype, alen: DWORD;
  nonRes, nameLen: Byte; runOff: Word; p: PByte;
  hdr, lenSz, offSz: Byte; rl, ro, lcn: Int64; k, n: Integer;
begin
  Result := nil; n := 0;
  ao := PWord(rec + $14)^;
  ap := rec + ao;
  while (PtrUInt(ap) + 8 <= PtrUInt(rec) + recSize) do
  begin
    atype := PDWORD(ap)^;
    if atype = $FFFFFFFF then Break;
    alen := PDWORD(ap + 4)^;
    if alen = 0 then Break;
    nonRes  := PByte(ap + 8)^;
    nameLen := PByte(ap + 9)^;
    if (atype = $80) and (nonRes = 1) and (nameLen = 0) then
    begin
      runOff := PWord(ap + $20)^;
      p := ap + runOff;
      lcn := 0;
      while (PtrUInt(p) < PtrUInt(ap) + alen) and (p^ <> 0) do
      begin
        hdr := p^; Inc(p);
        lenSz := hdr and $0F;
        offSz := (hdr shr 4) and $0F;
        rl := 0;
        for k := 0 to lenSz - 1 do rl := rl or (Int64(p[k]) shl (8 * k));
        Inc(p, lenSz);
        ro := 0;
        for k := 0 to offSz - 1 do ro := ro or (Int64(p[k]) shl (8 * k));
        if (offSz > 0) and ((p[offSz - 1] and $80) <> 0) then    // знаково разширение
          ro := ro or (Int64(-1) shl (8 * offSz));
        Inc(p, offSz);
        lcn := lcn + ro;
        SetLength(Result, n + 1);
        Result[n].lcn := lcn; Result[n].count := rl; Inc(n);
      end;
      Exit;
    end;
    Inc(ap, alen);
  end;
end;

end.
