unit uViewer;
{ ---------------------------------------------------------
  uViewer - scrollable текстов overlay за Шило хъба.
  Показва прихванатия изход на тул върху рамка; клавиш затваря.
  --------------------------------------------------------- }
{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  SysUtils, uScreen, uInput;

procedure ShowText(const Title: UnicodeString; const Lines: array of UnicodeString);

implementation

procedure ShowText(const Title: UnicodeString; const Lines: array of UnicodeString);
var
  x1, y1, x2, y2, innerW, innerH: Integer;
  top, maxTop, i, row: Integer;
  n: Integer;
  E: TKeyEvent;
  a, ta, fa: Word;
  s: UnicodeString;
begin
  n := Length(Lines);
  top := 0;
  repeat
    x1 := 2; y1 := 1; x2 := ScrW - 3; y2 := ScrH - 2;
    innerW := x2 - x1 - 1;
    innerH := y2 - y1 - 1;
    if innerH < 1 then innerH := 1;
    maxTop := n - innerH;
    if maxTop < 0 then maxTop := 0;
    if top > maxTop then top := maxTop;
    if top < 0 then top := 0;

    a  := Attr(clWhite,  clBlue);
    ta := Attr(clYellow, clBlue);
    fa := Attr(clBlack,  clCyan);

    FillRect(x1, y1, x2, y2, ' ', a);
    Box(x1, y1, x2, y2, a, True);
    s := ' ' + Title + ' ';
    if Length(s) > innerW then s := Copy(s, 1, innerW);
    PutStr(x1 + 2, y1, s, ta);

    for row := 0 to innerH - 1 do
    begin
      i := top + row;
      if i >= n then Break;
      s := Lines[i];
      if Length(s) > innerW then s := Copy(s, 1, innerW);
      PutStr(x1 + 1, y1 + 1 + row, s, a);
    end;

    { долен ред: позиция + подсказка }
    s := ' ' + UnicodeString(IntToStr(top + 1)) + '-' +
         UnicodeString(IntToStr(top + innerH)) + ' / ' +
         UnicodeString(IntToStr(n)) +
         '   ↑↓ PgUp/PgDn скрол · Esc затвори ';
    if Length(s) > innerW then s := Copy(s, 1, innerW);
    PutStr(x1 + 2, y2, s, fa);
    Flush;

    ReadKey(E);
    case E.Kind of
      kkSpecial:
        case E.Code of
          kUp:    Dec(top);
          kDown:  Inc(top);
          kPgUp:  Dec(top, innerH);
          kPgDn:  Inc(top, innerH);
          kHome:  top := 0;
          kEnd:   top := maxTop;
          kEsc, kEnter: Break;
        end;
      kkChar:
        if (E.Ch = 'q') or (E.Ch = 'Q') then Break;
      kkResize:
        ScrSync;
    end;
  until False;
end;

end.
