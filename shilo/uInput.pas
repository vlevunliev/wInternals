unit uInput;
{ ---------------------------------------------------------
  uInput - нормализиран клавиатурен вход за Шило хъба.
  ReadConsoleInputW, блокиращо. Връща клавишни и resize събития.
  --------------------------------------------------------- }
{$mode objfpc}{$H+}

interface

uses
  Windows;

type
  TKeyKind = (kkNone, kkChar, kkSpecial, kkResize);

  TKeyEvent = record
    Kind : TKeyKind;
    Ch   : WideChar;   { за kkChar }
    Code : Word;       { за kkSpecial - една от k* константите }
    Ctrl, Alt, Shift : Boolean;
  end;

const
  kUp    = 1;  kDown  = 2;  kLeft  = 3;  kRight = 4;
  kPgUp  = 5;  kPgDn  = 6;  kHome  = 7;  kEnd   = 8;
  kIns   = 9;  kDel   = 10; kEnter = 11; kEsc   = 12;
  kTab   = 13; kBack  = 14;
  kF1    = 101; kF2 = 102; kF3 = 103; kF4  = 104; kF5  = 105; kF6 = 106;
  kF7    = 107; kF8 = 108; kF9 = 109; kF10 = 110; kF11 = 111; kF12 = 112;

{ блокира до значещо събитие (клавиш надолу или resize) }
procedure ReadKey(out E: TKeyEvent);

implementation

function MapVK(vk: Word; out code: Word): Boolean;
begin
  Result := True;
  case vk of
    VK_UP:     code := kUp;
    VK_DOWN:   code := kDown;
    VK_LEFT:   code := kLeft;
    VK_RIGHT:  code := kRight;
    VK_PRIOR:  code := kPgUp;
    VK_NEXT:   code := kPgDn;
    VK_HOME:   code := kHome;
    VK_END:    code := kEnd;
    VK_INSERT: code := kIns;
    VK_DELETE: code := kDel;
    VK_RETURN: code := kEnter;
    VK_ESCAPE: code := kEsc;
    VK_TAB:    code := kTab;
    VK_BACK:   code := kBack;
    VK_F1..VK_F12: code := kF1 + (vk - VK_F1);
  else
    Result := False;
  end;
end;

procedure ReadKey(out E: TKeyEvent);
var
  rec: TInputRecord;
  got: DWORD;
  hIn: THandle;
  cks: DWORD;
  code: Word;
  wc: WideChar;
begin
  E.Kind := kkNone;
  E.Ch := #0;
  E.Code := 0;
  E.Ctrl := False; E.Alt := False; E.Shift := False;
  hIn := GetStdHandle(STD_INPUT_HANDLE);

  repeat
    if not ReadConsoleInputW(hIn, rec, 1, got) then Exit;
    if got = 0 then Continue;

    case rec.EventType of
      WINDOW_BUFFER_SIZE_EVENT:
        begin
          E.Kind := kkResize;
          Exit;
        end;

      KEY_EVENT:
        begin
          if not rec.Event.KeyEvent.bKeyDown then Continue;
          cks := rec.Event.KeyEvent.dwControlKeyState;
          E.Ctrl  := (cks and (LEFT_CTRL_PRESSED or RIGHT_CTRL_PRESSED)) <> 0;
          E.Alt   := (cks and (LEFT_ALT_PRESSED  or RIGHT_ALT_PRESSED )) <> 0;
          E.Shift := (cks and SHIFT_PRESSED) <> 0;

          if MapVK(rec.Event.KeyEvent.wVirtualKeyCode, code) then
          begin
            E.Kind := kkSpecial;
            E.Code := code;
            Exit;
          end;

          wc := WideChar(rec.Event.KeyEvent.UnicodeChar);
          if wc >= #32 then
          begin
            E.Kind := kkChar;
            E.Ch := wc;
            Exit;
          end;
          { Ctrl+letter: UnicodeChar е 1..26 }
          if E.Ctrl and (Ord(wc) >= 1) and (Ord(wc) <= 26) then
          begin
            E.Kind := kkChar;
            E.Ch := WideChar(Ord('a') + Ord(wc) - 1);
            Exit;
          end;
        end;
    end;
  until False;
end;

end.
