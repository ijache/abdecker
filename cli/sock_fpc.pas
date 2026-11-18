{ SPDX-License-Identifier: MIT
  Copyright (c) 2026 Ingo Jache }

unit sock_fpc;

{ abdecker - the few socket and system calls of the HTTP server (http),
  as plain functions. Berkeley sockets, blocking, IPv4 only.
  This one: FPC, every platform, unit Sockets (on Windows a wrapper around
  Winsock).
  Interface identical to sock_delphi: change both together. }

{$MODE DELPHI}
{$H+}

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
  {$IFDEF UNIX} BaseUnix, {$ENDIF}
  SysUtils, Sockets;

procedure SockStartup;
begin
  {$IFDEF UNIX}
  // a client that closes early must not end the process with SIGPIPE
  FpSignal(SIGPIPE, SignalHandler(SIG_IGN));
  {$ENDIF}
end;

function SockListen(const Host: string; Port: Integer; out s: TSock; out Err: string): Boolean;
var
  a: string;
  addr: TInetSockAddr;
  h: PtrInt;
begin
  result := false;
  s := NoSock;
  a := Host;
  if (a = '') or SameText(Host, 'localhost') then a := '127.0.0.1';
  FillChar(addr, SizeOf(addr), 0);
  addr.sin_family := AF_INET;
  addr.sin_port := htons(Port);
  addr.sin_addr := StrToNetAddr(a);
  if (addr.sin_addr.s_addr = 0) and (a <> '0.0.0.0') then begin
    Err := 'invalid address "' + Host + '" (IPv4 expected, e.g. 127.0.0.1 or 0.0.0.0)';
    exit;
  end;

  h := fpSocket(AF_INET, SOCK_STREAM, 0);
  if h < 0 then begin
    Err := 'cannot create socket (error ' + IntToStr(SocketError) + ')';
    exit;
  end;

  s := TSock(h);

  if fpBind(h, @addr, SizeOf(addr)) <> 0 then begin
    Err := 'cannot listen on ' + Host + ':' + IntToStr(Port) + ' (in use? error ' + IntToStr(SocketError) + ')';
    SockClose(s);
    exit;
  end;

  if fpListen(h, 128) <> 0 then begin
    Err := 'cannot listen (error ' + IntToStr(SocketError) + ')';
    SockClose(s);
    exit;
  end;

  result := true;
end;

function SockAccept(l: TSock; out Remote: string): TSock;
var
  addr: TInetSockAddr;
  len: TSockLen;
  h: PtrInt;
  p: PByte;
begin
  len := SizeOf(addr);
  FillChar(addr, SizeOf(addr), 0);
  h := fpAccept(PtrInt(l), @addr, @len);
  if h < 0 then begin
    result := NoSock;
  end else begin
    result := TSock(h);
  end;

  p := @addr.sin_addr;
  Remote := Format('%d.%d.%d.%d', [p[0], p[1], p[2], p[3]]);
end;

function SockRecv(s: TSock; var Buf; Len: Integer): Integer;
begin
  result := fpRecv(PtrInt(s), @Buf, Len, 0);
end;

function SockSend(s: TSock; const Buf; Len: Integer): Integer;
begin
  result := fpSend(PtrInt(s), @Buf, Len, 0);
end;

procedure SetTimeout(s: TSock; Opt: Integer; Ms: Int64);
{$IFDEF UNIX}
var
  tv: TTimeVal;
begin
  if Ms < 1 then Ms := 1;
  tv.tv_sec := Ms div 1000;      // Unix: struct timeval
  tv.tv_usec := (Ms mod 1000) * 1000;
  fpSetSockOpt(PtrInt(s), SOL_SOCKET, Opt, @tv, SizeOf(tv));
end;
{$ELSE}
var
  v: LongWord;
begin
  if Ms < 1 then Ms := 1;
  v := Ms;                       // Windows: milliseconds as DWORD
  fpSetSockOpt(PtrInt(s), SOL_SOCKET, Opt, @v, SizeOf(v));
end;
{$ENDIF}

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
  fpShutdown(PtrInt(s), 1);   // SHUT_WR
end;

procedure SockClose(s: TSock);
begin
  CloseSocket(PtrInt(s));
end;

function Ticks: UInt64;
begin
  result := GetTickCount64;
end;

function CpuCount: Integer;
begin
  result := GetCPUCount;
end;

end.
