unit Win_Primitive;

{$mode ObjFPC}{$H+}

interface

uses
  windows;


type

  // ---- NT native (споделено от fobj, freg) --------------------------------
  NTSTATUS = LongInt;

  UNICODE_STRING = record
    Len: Word;              // дължина в БАЙТОВЕ, не в знаци
    MaximumLength: Word;
    Buffer: PWideChar;
  end;
  PUNICODE_STRING = ^UNICODE_STRING;

  OBJECT_ATTRIBUTES = record
    Length: ULONG;
    RootDirectory: HANDLE;
    ObjectName: PUNICODE_STRING;
    Attributes: ULONG;
    SecurityDescriptor: Pointer;
    SecurityQualityOfService: Pointer;
  end;
  POBJECT_ATTRIBUTES = ^OBJECT_ATTRIBUTES;

  WIN32_FIND_STREAM_DATA = record
      StreamSize: Int64;
      cStreamName: array[0..MAX_PATH + 35] of WideChar;
  end;

  USN_JOURNAL_DATA = record
    UsnJournalID: UInt64;
    FirstUsn: Int64;
    NextUsn: Int64;
    LowestValidUsn: Int64;
    MaxUsn: Int64;
    MaximumSize: UInt64;
    AllocationDelta: UInt64;
  end;

  READ_USN_JOURNAL_DATA = record
    StartUsn: Int64;
    ReasonMask: DWORD;
    ReturnOnlyOnClose: DWORD;
    Timeout: UInt64;
    BytesToWaitFor: UInt64;
    UsnJournalID: UInt64;
  end;

  USN_RECORD_V2 = record
    RecordLength: DWORD;
    MajorVersion: Word;
    MinorVersion: Word;
    FileReferenceNumber: UInt64;
    ParentFileReferenceNumber: UInt64;
    Usn: Int64;
    TimeStamp: Int64;
    Reason: DWORD;
    SourceInfo: DWORD;
    SecurityId: DWORD;
    FileAttributes: DWORD;
    FileNameLength: Word;
    FileNameOffset: Word;
    FileName: array[0..0] of WideChar;
  end;
  PUSN_RECORD_V2 = ^USN_RECORD_V2;

  WINTRUST_FILE_INFO = record
    cbStruct: DWORD;
    pcwszFilePath: PWideChar;
    hFile: HANDLE;
    pgKnownSubject: Pointer;
  end;
  WINTRUST_DATA = record
    cbStruct: DWORD;
    pPolicyCallbackData: Pointer;
    pSIPClientData: Pointer;
    dwUIChoice: DWORD;
    fdwRevocationChecks: DWORD;
    dwUnionChoice: DWORD;
    pFile: Pointer;
    dwStateAction: DWORD;
    hWVTStateData: HANDLE;
    pwszURLReference: PWideChar;
    dwProvFlags: DWORD;
    dwUIContext: DWORD;
  end;


const
  // ---- NT native --------------------------------------------------------
  OBJ_CASE_INSENSITIVE   = $00000040;
  STATUS_SUCCESS         = NTSTATUS($00000000);
  STATUS_MORE_ENTRIES    = NTSTATUS($00000105);
  STATUS_NO_MORE_ENTRIES = NTSTATUS($8000001A);

  FSCTL_QUERY_USN_JOURNAL = $000900F4;
  FSCTL_READ_USN_JOURNAL  = $000900BB;
  FSCTL_GET_NTFS_VOLUME_DATA = $00090064;

  FIND_FIRST_EX_LARGE_FETCH = $00000002;
  FSCTL_GET_REPARSE_POINT    = $000900A8;
  IO_REPARSE_TAG_MOUNT_POINT = $A0000003;
  IO_REPARSE_TAG_SYMLINK     = $A000000C;
  FILE_FLAG_OPEN_REPARSE_POINT = $00200000;   // FPC Windows unit не я дефинира
  FSCTL_GET_NTFS_FILE_RECORD = $00090068;
  COPY_FILE_NO_BUFFERING    = $00001000;

  FindExInfoBasic           = 1;
  FindExSearchNameMatch     = 0;
  FindStreamInfoStandard    = 0;

  WTD_UI_NONE              = 2;
  WTD_REVOKE_NONE          = 0;
  WTD_CHOICE_FILE          = 1;
  WTD_STATEACTION_VERIFY   = 1;
  WTD_STATEACTION_CLOSE    = 2;

  CERT_QUERY_OBJECT_FILE                    = 1;
  CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED_EMBED = $400;
  CERT_QUERY_FORMAT_FLAG_BINARY             = 2;
  CMSG_SIGNER_CERT_INFO_PARAM               = 7;
  CERT_FIND_SUBJECT_CERT                    = $000B0000;
  CERT_NAME_SIMPLE_DISPLAY_TYPE             = 4;
  CERT_NAME_ISSUER_FLAG                     = 1;

  WINTRUST_ACTION_GENERIC_VERIFY_V2: TGUID = '{00AAC56B-CD44-11D0-8CC2-00C04FC295EE}';



function SetFilePointerEx(hFile: HANDLE; liDistanceToMove: Int64; lpNewFilePointer: PInt64; dwMoveMethod: DWORD): BOOL; stdcall; external 'kernel32';

function BCryptOpenAlgorithmProvider(out phAlgorithm: Pointer; pszAlgId, pszImpl: PWideChar; dwFlags: ULONG): LongInt; stdcall; external 'bcrypt.dll';
function BCryptGetProperty(hObject: Pointer; pszProperty: PWideChar; pbOutput: Pointer; cbOutput: ULONG; out pcbResult: ULONG; dwFlags: ULONG): LongInt; stdcall; external 'bcrypt.dll';
function BCryptCreateHash(hAlgorithm: Pointer; out phHash: Pointer; pbHashObject: Pointer; cbHashObject: ULONG; pbSecret: Pointer; cbSecret: ULONG; dwFlags: ULONG): LongInt; stdcall; external 'bcrypt.dll';
function BCryptHashData(hHash: Pointer; pbInput: Pointer; cbInput: ULONG; dwFlags: ULONG): LongInt; stdcall; external 'bcrypt.dll';
function BCryptFinishHash(hHash: Pointer; pbOutput: Pointer; cbOutput: ULONG; dwFlags: ULONG): LongInt; stdcall; external 'bcrypt.dll';
function BCryptDestroyHash(hHash: Pointer): LongInt; stdcall; external 'bcrypt.dll';


function MyCreateHardLink(lpFileName, lpExistingFileName: PWideChar;  lpSec: Pointer): BOOL; stdcall; external 'kernel32' name 'CreateHardLinkW';

function FindFirstFileExW(lpFileName: LPCWSTR; fInfoLevelId: DWORD; lpFindFileData: Pointer; fSearchOp: DWORD; lpSearchFilter: Pointer; dwAdditionalFlags: DWORD): HANDLE; stdcall; external 'kernel32';
function FindFirstStreamW(lpFileName: LPCWSTR; InfoLevel: DWORD; lpFindStreamData: Pointer; dwFlags: DWORD): HANDLE; stdcall; external 'kernel32';
function FindNextStreamW(hFindStream: HANDLE; lpFindStreamData: Pointer): BOOL; stdcall; external 'kernel32';


function WinVerifyTrust(hwnd: HWND; pgActionID: PGUID; pWVTData: Pointer): LongInt; stdcall; external 'wintrust.dll';
function CryptQueryObject(dwObjectType: DWORD; pvObject: Pointer;
  dwExpectedContentTypeFlags, dwExpectedFormatTypeFlags, dwFlags: DWORD;
  pdwMsgAndCertEncodingType, pdwContentType, pdwFormatType, phCertStore,
  phMsg, ppvContext: Pointer): BOOL; stdcall; external 'crypt32.dll';
function CryptMsgGetParam(hCryptMsg: Pointer; dwParamType, dwIndex: DWORD; pvData: Pointer; pcbData: PDWORD): BOOL; stdcall; external 'crypt32.dll';
function CertFindCertificateInStore(hCertStore: Pointer;
  dwCertEncodingType, dwFindFlags, dwFindType: DWORD; pvFindPara,
  pPrevCertContext: Pointer): Pointer; stdcall; external 'crypt32.dll';
function CertGetNameStringW(pCertContext: Pointer; dwType, dwFlags: DWORD;
  pvTypePara: Pointer; pszNameString: PWideChar; cchNameString: DWORD): DWORD;
  stdcall; external 'crypt32.dll';
function CertFreeCertificateContext(pCertContext: Pointer): BOOL; stdcall; external 'crypt32.dll';
function CertCloseStore(hCertStore: Pointer; dwFlags: DWORD): BOOL; stdcall; external 'crypt32.dll';
function CryptMsgClose(hCryptMsg: Pointer): BOOL; stdcall; external 'crypt32.dll';


function WofSetFileDataLocation(FileHandle: HANDLE; Provider: ULONG;
  ExternalFileInfo: Pointer; Length: ULONG): HRESULT; stdcall; external 'WofUtil.dll';

function MyGetCompressedFileSize(lpFileName: LPCWSTR; lpFileSizeHigh: LPDWORD): DWORD;
  stdcall; external 'kernel32' name 'GetCompressedFileSizeW';

// ---- NT native (ntdll) ----------------------------------------------------
function NtClose(Handle: HANDLE): NTSTATUS; stdcall; external 'ntdll.dll';

implementation

end.

