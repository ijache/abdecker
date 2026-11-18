{ SPDX-License-Identifier: MIT
  Copyright (c) 2026 Ingo Jache }

unit sock_delphi;

{ abdecker - the few socket and system calls of the HTTP server (http),
  as plain functions. Berkeley sockets, blocking, IPv4 only.
  This one: Delphi (builds Windows only), Winsock 2.
  Interface identical to sock_fpc: change both together. }

interface

type
  TSock = NativeUInt;

const
  NoSock = High(NativeUInt);   // = INVALID_SOCKET (Winsock), -1 (FPC)

{ Once before the first socket call (Winsock start-up; on Unix: ignore
  SIGPIPE, so a client that closes early cannot end the process). }
procedure SockStartup;
{ Listening socket on an IPv4 address ('localhost' and '' = 127.0.0.1).
  False with a readable reason in Err. }
function SockListen(const Host: string; Port: Integer; out s: TSock; out Err: string): Boolean;
{ Waits for a connection; NoSock on error. Remote: the client's address. }
function SockAccept(l: TSock; out Remote: string): TSock;
{ recv/send: bytes transferred, 0 = closed by the peer, < 0 = error or timeout }
function SockRecv(s: TSock; var Buf; Len: Integer): Integer;
function SockSend(s: TSock; const Buf; Len: Integer): Integer;
procedure SockSetRecvTimeout(s: TSock; Ms: Int64);
procedure SockSetSendTimeout(s: TSock; Ms: Int64);
{ Closes the sending direction only (the client sees the end of the answer) }
procedure SockShutdownSend(s: TSock);
procedure SockClose(s: TSock);

{ Milliseconds since an arbitrary start, monotonic }
function Ticks: UInt64;
{ Number of logical processors }
function CpuCount: Integer;

implementation

uses
  System.SysUtils, System.Classes, Winapi.Windows, Winapi.Winsock2;

procedure SockStartup;
var
  data: TWSAData;
begin
  WSAStartup($0202, data);
end;

function LastError: Integer;
begin
  result := WSAGetLastError;
end;

function SockListen(const Host: string; Port: Integer; out s: TSock; out Err: string): Boolean;
var
  a: AnsiString;
  addr: TSockAddrIn;
begin
  result := false;
  s := NoSock;
  a := AnsiString(Host);
  if (a = '') or SameText(Host, 'localhost') then a := '127.0.0.1';
  FillChar(addr, SizeOf(addr), 0);
  addr.sin_family := AF_INET;
  addr.sin_port := htons(Port);
  addr.sin_addr.S_addr := inet_addr(MarshaledAString(a));
  if addr.sin_addr.S_addr = INADDR_NONE then begin
    Err := 'invalid address "' + Host + '" (IPv4 expected, e.g. 127.0.0.1 or 0.0.0.0)';
    exit;
  end;

  s := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if s = NoSock then begin
    Err := 'cannot create socket (error ' + IntToStr(LastError) + ')';
    exit;
  end;

  if bind(s, PSockAddr(@addr)^, SizeOf(addr)) <> 0 then begin
    Err := 'cannot listen on ' + Host + ':' + IntToStr(Port) + ' (in use? error ' + IntToStr(LastError) + ')';
    SockClose(s);
    exit;
  end;

  if listen(s, 128) <> 0 then begin
    Err := 'cannot listen (error ' + IntToStr(LastError) + ')';
    SockClose(s);
    exit;
  end;

  result := true;
end;

function SockAccept(l: TSock; out Remote: string): TSock;
var
  addr: TSockAddrIn;
  len: Integer;
  p: PByte;
begin
  len := SizeOf(addr);
  FillChar(addr, SizeOf(addr), 0);
  result := accept(l, PSockAddr(@addr), @len);
  p := @addr.sin_addr;
  Remote := Format('%d.%d.%d.%d', [p[0], p[1], p[2], p[3]]);
end;

function SockRecv(s: TSock; var Buf; Len: Integer): Integer;
begin
  result := recv(s, Buf, Len, 0);
end;

function SockSend(s: TSock; const Buf; Len: Integer): Integer;
begin
  result := send(s, Buf, Len, 0);
end;

procedure SetTimeout(s: TSock; Opt: Integer; Ms: Int64);
var
  v: DWORD;
begin
  if Ms < 1 then Ms := 1;
  v := Ms;   // Winsock: milliseconds as DWORD
  setsockopt(s, SOL_SOCKET, Opt, MarshaledAString(@v), SizeOf(v));
end;

procedure SockSetRecvTimeout(s: TSock; Ms: Int64);
begin
  SetTimeout(s, SO_RCVTIMEO, Ms);
end;

procedure SockSetSendTimeout(s: TSock; Ms: Int64);
begin
  SetTimeout(s, SO_SNDTIMEO, Ms);
end;

procedure SockShutdownSend(s: TSock);
begin
  shutdown(s, SD_SEND);
end;

procedure SockClose(s: TSock);
begin
  closesocket(s);
end;

function Ticks: UInt64;
begin
  result := GetTickCount64;
end;

function CpuCount: Integer;
begin
  result := TThread.ProcessorCount;
end;

end.
