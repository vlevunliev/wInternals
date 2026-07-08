program fcert;
{ Authenticode инспектор за EXE/DLL/MSI. Показва дали е подписан, дали подписът
  е валиден, и кой го е подписал. WinVerifyTrust за статуса + CryptQueryObject/
  CertGetNameString за подписалия. Без мрежова revocation проверка (offline).
  Употреба: fcert <файл> }
{$mode objfpc}{$H+}
{$codepage UTF8}

uses
  Windows, SysUtils, misc, win_primitive;


var
  path, signer, issuer, verdict: UnicodeString;
  st: LongInt;

function VerifyFile(const path: UnicodeString): LongInt;
var fi: WINTRUST_FILE_INFO; wd: WINTRUST_DATA; g: TGUID;
begin
  FillChar(fi, SizeOf(fi), 0);
  fi.cbStruct := SizeOf(fi);
  fi.pcwszFilePath := PWideChar(path);
  FillChar(wd, SizeOf(wd), 0);
  wd.cbStruct := SizeOf(wd);
  wd.dwUIChoice := WTD_UI_NONE;
  wd.fdwRevocationChecks := WTD_REVOKE_NONE;
  wd.dwUnionChoice := WTD_CHOICE_FILE;
  wd.pFile := @fi;
  wd.dwStateAction := WTD_STATEACTION_VERIFY;
  g := WINTRUST_ACTION_GENERIC_VERIFY_V2;
  Result := WinVerifyTrust(0, @g, @wd);
  wd.dwStateAction := WTD_STATEACTION_CLOSE;
  WinVerifyTrust(0, @g, @wd);
end;

procedure GetSigner(const path: UnicodeString; out signer, issuer: UnicodeString);
var
  enc, ct, ft, cb: DWORD;
  hStore, hMsg, pCert, signerBuf: Pointer;
  nameBuf: array[0..255] of WideChar;
begin
  signer := '';
  issuer := '';
  hStore := nil;
  hMsg := nil;
  if not CryptQueryObject(CERT_QUERY_OBJECT_FILE, PWideChar(path),
       CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED_EMBED, CERT_QUERY_FORMAT_FLAG_BINARY,
       0, @enc, @ct, @ft, @hStore, @hMsg, nil) then Exit;
  cb := 0;
  CryptMsgGetParam(hMsg, CMSG_SIGNER_CERT_INFO_PARAM, 0, nil, @cb);
  if cb > 0 then
  begin
    signerBuf := GetMem(cb);
    if CryptMsgGetParam(hMsg, CMSG_SIGNER_CERT_INFO_PARAM, 0, signerBuf, @cb) then
    begin
      pCert := CertFindCertificateInStore(hStore, enc, 0, CERT_FIND_SUBJECT_CERT, signerBuf, nil);
      if pCert <> nil then
      begin
        if CertGetNameStringW(pCert, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, nil, @nameBuf[0], 256) > 1 then signer := PWideChar(@nameBuf[0]);
        if CertGetNameStringW(pCert, CERT_NAME_SIMPLE_DISPLAY_TYPE, CERT_NAME_ISSUER_FLAG, nil, @nameBuf[0], 256) > 1 then issuer := PWideChar(@nameBuf[0]);
        CertFreeCertificateContext(pCert);
      end;
    end;
    FreeMem(signerBuf);
  end;
  if hMsg <> nil then CryptMsgClose(hMsg);
  if hStore <> nil then CertCloseStore(hStore, 0);
end;

begin
  ConInit;
  if ParamCount < 1 then
  begin
    ConLn('Употреба: fcert <файл>');
    Halt(1);
  end;
  path := UnicodeString(ExpandFileName(ParamStr(1)));

  ConLn('Файл: ' + path);

  st := VerifyFile(path);
  case DWORD(st) of
    $00000000: verdict := 'ВАЛИДЕН - доверен подпис';
    $800B0100: verdict := 'НЕПОДПИСАН';
    $80096010: verdict := 'НЕВАЛИДЕН - файлът е променен след подписване';
    $800B0101: verdict := 'подписан, но сертификатът е ИЗТЕКЪЛ';
    $800B010C: verdict := 'подписан, но сертификатът е ОТНЕТ';
    $800B0109: verdict := 'подписан, но root-ът НЕ е доверен (self-signed / чужд CA)';
    $800B0111: verdict := 'ИЗРИЧНО недоверен';
    $80092026: verdict := 'подписът е блокиран от политика';
  else
    verdict := 'друго (0x' + UnicodeString(IntToHex(DWORD(st), 8)) + ')';
  end;
  ConLn('Подпис: ' + verdict);

  if DWORD(st) <> $800B0100 then              // ако изобщо има подпис
  begin
    GetSigner(path, signer, issuer);
    if signer <> '' then ConLn('Подписал: ' + signer);
    if issuer <> '' then ConLn('Издател:  ' + issuer);
  end;
end.
