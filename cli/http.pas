{ SPDX-License-Identifier: MIT
  Copyright (c) 2026 Ingo Jache }

unit http;

{ abdecker - minimal HTTP/1.1 server for "abdecker serve". Knows nothing
  about invoices: a handler turns a request record into a response record.

  Model:
  - Berkeley sockets, blocking calls, behind the small API of sock_delphi /
    sock_fpc (the platform differences live there, not here).
  - The accept loop (the calling thread) only accepts and queues the socket
    with its accept time. Queue full: 503 at once.
  - A pool of worker threads takes connections from the queue: read the
    request, call the handler, write the response, close. Queue behind a
    critical section, woken by an auto-reset event; a worker that sees more
    work after taking one wakes the next worker. No semaphores, no polling.
  - One deadline per request, counted from accept: expired in the queue ->
    503; reading -> SO_RCVTIMEO set to the remaining time before every recv,
    408 when it runs out; sending -> SO_SNDTIMEO (remaining, at least 5 s).
  - HTTP/1.1, "Connection: close", body only with Content-Length (411
    otherwise), no chunked uploads, "Expect: 100-continue" is answered.
  - Every exception while handling a connection becomes a 500 (if nothing was
    sent yet); the socket is always closed, a worker never dies. }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
{$IFDEF FPC}
  SysUtils, Classes, SyncObjs;
{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs;
{$ENDIF}

type
  THttpHeader = record
    Name, Value: string;
  end;
  THttpHeaders = array of THttpHeader;
  THttpStrings = array of string;

  THttpRequest = record
    Method: string;          // as sent, e.g. 'POST'
    Path: string;            // decoded, without the query
    Query: string;           // raw, without '?'
    Headers: THttpHeaders;
    Body: TBytes;
    RemoteAddr: string;
  end;

  THttpResponse = record
    Status: Integer;
    ContentType: string;
    Headers: THttpHeaders;   // additional headers
    Body: TBytes;
  end;

  { One part of a multipart/form-data body }
  THttpPart = record
    Name, FileName, ContentType: string;
    Data: TBytes;
  end;
  THttpParts = array of THttpPart;

  THttpHandler = procedure(const Req: THttpRequest; var Resp: THttpResponse);
  { Builds the response for an error found by the server itself
    (400, 408, 411, 413, 500, 503). Code: a stable identifier, e.g. 'HTTP-TOO-LARGE'. }
  THttpErrorFunc = procedure(Status: Integer; const Code, Text: string; var Resp: THttpResponse);

  THttpOptions = record
    Host: string;            // IPv4 address, 'localhost' = 127.0.0.1
    Port: Integer;
    MaxBody: Int64;          // bytes
    Workers: Integer;
    QueueSize: Integer;
    TimeoutMs: Integer;      // deadline per request, from accept
    Log: Boolean;            // one line per request on standard output
    Banner: string;          // printed once listening, if not empty
  end;

{ Listens and serves until the process ends. Returns only if the server
  cannot start (ErrorText says why). }
function HttpServe(const Opt: THttpOptions; Handler: THttpHandler; ErrorFunc: THttpErrorFunc;
  out ErrorText: string): Boolean;

function DefaultWorkers: Integer;
function StatusText(Code: Integer): string;
procedure AddHeader(var h: THttpHeaders; const Name, Value: string);
function HeaderValue(const h: THttpHeaders; const Name: string): string;
{ Value of a query parameter (percent-decoded, '+' = space) }
function QueryParam(const Query, Name: string; out Value: string): Boolean;
{ All parameters of a query string, decoded, as 'name=value' in their order }
function QueryPairs(const Query: string): THttpStrings;
{ Splits a multipart/form-data body. False if the request is not multipart
  or the body is malformed. }
function ParseMultipart(const Req: THttpRequest; out Parts: THttpParts): Boolean;

implementation

uses
  {$IFDEF FPC} sock_fpc {$ELSE} sock_delphi {$ENDIF};

{ UTF-8 bytes as string (Delphi: string is UTF-16; FPC: it holds UTF-8) }
function Utf8ToStr(const b: TBytes): string;
begin
{$IFDEF FPC}
  SetLength(result, Length(b));
  if Length(b) > 0 then Move(b[0], result[1], Length(b));
{$ELSE}
  result := TEncoding.UTF8.GetString(b);
{$ENDIF}
end;

const
  MaxHeaderBytes = 16384;
  MinSendTimeoutMs = 5000;

{ ===========================================================================
  Small helpers
  =========================================================================== }

function DefaultWorkers: Integer;
begin
  result := CpuCount;
  if result < 2 then result := 2;
end;

function StatusText(Code: Integer): string;
begin
  case Code of
    100: result := 'Continue';
    200: result := 'OK';
    400: result := 'Bad Request';
    404: result := 'Not Found';
    405: result := 'Method Not Allowed';
    408: result := 'Request Timeout';
    411: result := 'Length Required';
    413: result := 'Content Too Large';
    422: result := 'Unprocessable Content';
    500: result := 'Internal Server Error';
    503: result := 'Service Unavailable';
  else
    result := 'Status';
  end;
end;

procedure AddHeader(var h: THttpHeaders; const Name, Value: string);
begin
  SetLength(h, Length(h) + 1);
  h[High(h)].Name := Name;
  h[High(h)].Value := Value;
end;

function HeaderValue(const h: THttpHeaders; const Name: string): string;
var
  i: Integer;
begin
  for i := 0 to High(h) do begin
    if SameText(h[i].Name, Name) then exit(h[i].Value);
  end;

  result := '';
end;

function HexVal(c: Char): Integer;
begin
  case c of
    '0'..'9': result := Ord(c) - Ord('0');
    'a'..'f': result := Ord(c) - Ord('a') + 10;
    'A'..'F': result := Ord(c) - Ord('A') + 10;
  else
    result := -1;
  end;
end;

{ Percent-decoding to UTF-8 bytes, then to a string. Plus: '+' = space. }
function PercentDecode(const s: string; Plus: Boolean): string;
var
  b: TBytes;
  i, n, h1, h2: Integer;
begin
  SetLength(b, Length(s));
  n := 0;
  i := 1;
  while i <= Length(s) do begin
    if (s[i] = '%') and (i + 2 <= Length(s)) then begin
      h1 := HexVal(s[i + 1]);
      h2 := HexVal(s[i + 2]);
      if (h1 >= 0) and (h2 >= 0) then begin
        b[n] := h1 * 16 + h2;
        Inc(n);
        Inc(i, 3);
        continue;
      end;
    end;

    if Plus and (s[i] = '+') then begin
      b[n] := Ord(' ');
    end else begin
      b[n] := Ord(s[i]) and $FF;
    end;

    Inc(n);
    Inc(i);
  end;

  SetLength(b, n);
  result := Utf8ToStr(b);
end;

function QueryParam(const Query, Name: string; out Value: string): Boolean;
var
  rest, pair, k: string;
  p: Integer;
begin
  Value := '';
  rest := Query;
  while rest <> '' do begin
    p := Pos('&', rest);
    if p > 0 then begin
      pair := Copy(rest, 1, p - 1);
      Delete(rest, 1, p);
    end else begin
      pair := rest;
      rest := '';
    end;

    p := Pos('=', pair);
    if p > 0 then begin
      k := PercentDecode(Copy(pair, 1, p - 1), true);
    end else begin
      k := PercentDecode(pair, true);
    end;

    if k = Name then begin
      if p > 0 then Value := PercentDecode(Copy(pair, p + 1, MaxInt), true);
      exit(true);
    end;
  end;

  result := false;
end;

function QueryPairs(const Query: string): THttpStrings;
var
  rest, pair: string;
  p: Integer;
begin
  result := nil;
  rest := Query;

  while rest <> '' do begin
    p := Pos('&', rest);

    if p > 0 then begin
      pair := Copy(rest, 1, p - 1);
      Delete(rest, 1, p);
    end else begin
      pair := rest;
      rest := '';
    end;

    if pair = '' then continue;
    p := Pos('=', pair);
    SetLength(result, Length(result) + 1);

    if p > 0 then begin
      result[High(result)] := PercentDecode(Copy(pair, 1, p - 1), true) + '=' +
        PercentDecode(Copy(pair, p + 1, MaxInt), true);
    end else begin
      result[High(result)] := PercentDecode(pair, true) + '=';
    end;
  end;
end;

function FindBytes(const b: TBytes; const Pat: TBytes; From: Integer): Integer;
var
  i, last: Integer;
begin
  last := Length(b) - Length(Pat);

  for i := From to last do begin
    if (b[i] = Pat[0]) and CompareMem(@b[i], @Pat[0], Length(Pat)) then exit(i);
  end;

  result := -1;
end;

function AsciiOf(const b: TBytes; Start, Count: Integer): string;
var
  i: Integer;
begin
  SetLength(result, Count);

  for i := 0 to Count - 1 do begin
    result[i + 1] := Char(b[Start + i]);
  end;
end;

{ Parameter of a header value like 'form-data; name="pdf"; filename="a.pdf"' }
function HeaderParam(const v, Name: string): string;
var
  rest, seg, key: string;
  p: Integer;
begin
  result := '';
  key := LowerCase(Name) + '=';
  rest := v;
  while rest <> '' do begin
    p := Pos(';', rest);
    if p > 0 then begin
      seg := Trim(Copy(rest, 1, p - 1));
      Delete(rest, 1, p);
    end else begin
      seg := Trim(rest);
      rest := '';
    end;

    if Pos(key, LowerCase(seg)) = 1 then begin
      result := Trim(Copy(seg, Length(key) + 1, MaxInt));
      if (Length(result) >= 2) and (result[1] = '"') and (result[Length(result)] = '"') then begin
        result := Copy(result, 2, Length(result) - 2);
      end;

      exit;
    end;
  end;
end;

{ A string whose characters are bytes (as from AsciiOf), read as UTF-8 }
function BytesAsUtf8(const s: string): string;
var
  b: TBytes;
  i: Integer;
begin
  SetLength(b, Length(s));

  for i := 1 to Length(s) do begin
    b[i - 1] := Ord(s[i]) and $FF;
  end;

  result := Utf8ToStr(b);
end;

function ParseMultipart(const Req: THttpRequest; out Parts: THttpParts): Boolean;
var
  ct, boundary, line, hName, hValue: string;
  delim, crlf2: TBytes;
  p, hEnd, next, lineEnd, i, colon: Integer;
  part: THttpPart;
  headText: string;
begin
  result := false;
  Parts := nil;
  ct := HeaderValue(Req.Headers, 'Content-Type');
  if Pos('multipart/form-data', LowerCase(ct)) <> 1 then exit;
  boundary := HeaderParam(ct, 'boundary');
  if boundary = '' then exit;
  delim := TEncoding.ASCII.GetBytes('--' + boundary);
  crlf2 := TEncoding.ASCII.GetBytes(#13#10#13#10);
  p := FindBytes(Req.Body, delim, 0);
  if p < 0 then exit;
  delim := TEncoding.ASCII.GetBytes(#13#10'--' + boundary);
  p := p + Length(delim) - 2;   // after the first delimiter (it has no leading CRLF)

  repeat
    // "--" after a delimiter ends the body
    if (p + 1 < Length(Req.Body)) and (Req.Body[p] = Ord('-')) and (Req.Body[p + 1] = Ord('-')) then begin
      break;
    end;

    if (p + 1 >= Length(Req.Body)) or (Req.Body[p] <> 13) or (Req.Body[p + 1] <> 10) then exit;
    Inc(p, 2);
    hEnd := FindBytes(Req.Body, crlf2, p);
    if hEnd < 0 then exit;
    part := Default(THttpPart);
    headText := AsciiOf(Req.Body, p, hEnd - p) + #13#10;
    i := 1;
    while i <= Length(headText) do begin
      lineEnd := Pos(#13#10, Copy(headText, i, MaxInt));
      if lineEnd = 0 then break;
      line := Copy(headText, i, lineEnd - 1);
      Inc(i, lineEnd + 1);
      colon := Pos(':', line);
      if colon = 0 then continue;
      hName := Trim(Copy(line, 1, colon - 1));
      hValue := Trim(Copy(line, colon + 1, MaxInt));

      if SameText(hName, 'Content-Disposition') then begin
        part.Name := HeaderParam(hValue, 'name');
        // file names arrive as UTF-8 bytes
        part.FileName := BytesAsUtf8(HeaderParam(hValue, 'filename'));
      end else if SameText(hName, 'Content-Type') then part.ContentType := hValue;
    end;

    p := hEnd + 4;
    next := FindBytes(Req.Body, delim, p);
    if next < 0 then exit;
    part.Data := Copy(Req.Body, p, next - p);
    SetLength(Parts, Length(Parts) + 1);
    Parts[High(Parts)] := part;
    p := next + Length(delim);
  until false;

  result := true;
end;

{ ===========================================================================
  Server
  =========================================================================== }

type
  TConn = record
    Sock: TSock;
    Accepted: UInt64;   // Ticks at accept
    Remote: string;
  end;

  TServer = class
  public
    Opt: THttpOptions;
    Handler: THttpHandler;
    ErrorFunc: THttpErrorFunc;
    Lock: TCriticalSection;
    Wake: TEvent;
    LogLock: TCriticalSection;
    Queue: array of TConn;  // ring buffer
    Head, Count: Integer;
    constructor Create(const AOpt: THttpOptions; AHandler: THttpHandler; AErrorFunc: THttpErrorFunc);
    destructor Destroy; override;
    function Push(const c: TConn): Boolean;
    function Pop(out c: TConn; out More: Boolean): Boolean;
    procedure Handle(const c: TConn);
    procedure Log(const c: TConn; const Req: THttpRequest; Status: Integer; Bytes: Int64);
  end;

  TWorker = class(TThread)
  private
    FServer: TServer;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TServer);
  end;

constructor TServer.Create(const AOpt: THttpOptions; AHandler: THttpHandler; AErrorFunc: THttpErrorFunc);
begin
  inherited Create;
  Opt := AOpt;
  Handler := AHandler;
  ErrorFunc := AErrorFunc;
  Lock := TCriticalSection.Create;
  LogLock := TCriticalSection.Create;
  Wake := TEvent.Create(nil, false, false, '');   // auto-reset
  SetLength(Queue, Opt.QueueSize);
end;

destructor TServer.Destroy;
begin
  Wake.Free;
  LogLock.Free;
  Lock.Free;
  inherited;
end;

function TServer.Push(const c: TConn): Boolean;
begin
  Lock.Enter;

  try
    result := Count < Length(Queue);
    if result then begin
      Queue[(Head + Count) mod Length(Queue)] := c;
      Inc(Count);
    end;
  finally
    Lock.Leave;
  end;

  if result then begin
    Wake.SetEvent;
  end;
end;

function TServer.Pop(out c: TConn; out More: Boolean): Boolean;
begin
  Lock.Enter;

  try
    result := Count > 0;
    if result then begin
      c := Queue[Head];
      Queue[Head] := Default(TConn);
      Head := (Head + 1) mod Length(Queue);
      Dec(Count);
    end;

    More := Count > 0;
  finally
    Lock.Leave;
  end;
end;

procedure TServer.Log(const c: TConn; const Req: THttpRequest; Status: Integer; Bytes: Int64);
var
  m, p: string;
begin
  if not Opt.Log then exit;
  m := Req.Method;
  if m = '' then m := '-';
  p := Req.Path;
  if p = '' then p := '-';
  LogLock.Enter;

  try
    Writeln(FormatDateTime('yyyy-mm-dd hh:nn:ss', Now), ' ', c.Remote, ' ', m, ' ', p, ' ', Status, ' ',
      Ticks - c.Accepted, ' ms ', Bytes, ' bytes');
  finally
    LogLock.Leave;
  end;
end;

{ Sends all bytes; False if the peer is gone or the send timeout ran out }
function SendAll(s: TSock; const b: TBytes): Boolean;
var
  sent, n: Integer;
begin
  sent := 0;
  while sent < Length(b) do begin
    n := SockSend(s, b[sent], Length(b) - sent);
    if n <= 0 then exit(false);
    Inc(sent, n);
  end;

  result := true;
end;

function ResponseBytes(const Resp: THttpResponse): TBytes;
var
  h: string;
  i: Integer;
  head: TBytes;
begin
  h := 'HTTP/1.1 ' + IntToStr(Resp.Status) + ' ' + StatusText(Resp.Status) + #13#10;
  if Resp.ContentType <> '' then h := h + 'Content-Type: ' + Resp.ContentType + #13#10;
  h := h + 'Content-Length: ' + IntToStr(Length(Resp.Body)) + #13#10 + 'Connection: close'#13#10;

  for i := 0 to High(Resp.Headers) do begin
    h := h + Resp.Headers[i].Name + ': ' + Resp.Headers[i].Value + #13#10;
  end;

  h := h + #13#10;
  head := TEncoding.ASCII.GetBytes(h);
  result := Concat(head, Resp.Body);
end;

{ Rejects a connection without reading the request (queue full, expired):
  answer, close the sending side, drop what the client still sends for a
  moment, close. So the client sees the answer instead of "connection reset". }
procedure Reject(Server: TServer; const c: TConn; Status: Integer; const Code, Text: string);
var
  resp: THttpResponse;
  buf: array[0..4095] of Byte;
  stop: UInt64;
begin
  try
    resp := Default(THttpResponse);
    Server.ErrorFunc(Status, Code, Text, resp);
    resp.Status := Status;

    if Status = 503 then begin
      AddHeader(resp.Headers, 'Retry-After', '1');
    end;

    SockSetSendTimeout(c.Sock, 1000);
    SendAll(c.Sock, ResponseBytes(resp));
    SockShutdownSend(c.Sock);
    stop := Ticks + 200;
    SockSetRecvTimeout(c.Sock, 50);

    while (Ticks < stop) and (SockRecv(c.Sock, buf, SizeOf(buf)) > 0) do begin
      ;
    end;

    Server.Log(c, Default(THttpRequest), Status, Length(resp.Body));
  except
    // nothing more to do for this connection
  end;

  SockClose(c.Sock);
end;

type
  EHttpStatus = class(Exception)
  public
    Status: Integer;
    Code: string;
    constructor Create(AStatus: Integer; const ACode, AText: string);
  end;

constructor EHttpStatus.Create(AStatus: Integer; const ACode, AText: string);
begin
  inherited Create(AText);
  Status := AStatus;
  Code := ACode;
end;

{ Reads a request within the deadline. Raises EHttpStatus for 400/408/411/413.
  False if the client closed the connection before sending a request. }
function ReadRequest(Server: TServer; const c: TConn; out Req: THttpRequest): Boolean;
var
  buf: TBytes;
  chunk: array[0..65535] of Byte;
  used, n, hEnd, i, p, lineEnd: Integer;
  deadline: UInt64;
  head, line, target, te, cl, expect: string;
  len: Int64;
  lines: TStringList;

  function ReadSome: Integer;
  var
    left: Int64;
  begin
    left := Int64(deadline) - Int64(Ticks);
    if left <= 0 then begin
      raise EHttpStatus.Create(408, 'HTTP-TIMEOUT', 'The request was not received in time');
    end;

    SockSetRecvTimeout(c.Sock, left);
    result := SockRecv(c.Sock, chunk, SizeOf(chunk));
    if result < 0 then begin
      if Int64(deadline) - Int64(Ticks) <= 50 then begin
        raise EHttpStatus.Create(408, 'HTTP-TIMEOUT', 'The request was not received in time');
      end;

      result := 0;   // connection error: treat as closed
    end;
  end;

begin
  result := false;
  Req := Default(THttpRequest);
  Req.RemoteAddr := c.Remote;
  deadline := c.Accepted + UInt64(Server.Opt.TimeoutMs);
  SetLength(buf, 0);
  used := 0;
  hEnd := -1;

  // header
  repeat
    n := ReadSome;
    if n = 0 then begin
      if used = 0 then exit;
      raise EHttpStatus.Create(400, 'HTTP-BAD-REQUEST', 'Incomplete request');
    end;

    SetLength(buf, used + n);
    Move(chunk[0], buf[used], n);
    Inc(used, n);

    for i := 3 to used - 1 do begin
      if (buf[i] = 10) and (buf[i - 1] = 13) and (buf[i - 2] = 10) and (buf[i - 3] = 13) then begin
        hEnd := i + 1;
        break;
      end;
    end;

    if ((hEnd < 0) and (used > MaxHeaderBytes)) or (hEnd > MaxHeaderBytes) then begin
      raise EHttpStatus.Create(400, 'HTTP-BAD-REQUEST', 'Request header too large');
    end;
  until hEnd >= 0;

  head := AsciiOf(buf, 0, hEnd - 4);
  lines := TStringList.Create;

  try
    i := 1;
    while i <= Length(head) + 1 do begin
      lineEnd := Pos(#13#10, Copy(head, i, MaxInt));
      if lineEnd = 0 then begin
        lines.Add(Copy(head, i, MaxInt));
        break;
      end;

      lines.Add(Copy(head, i, lineEnd - 1));
      Inc(i, lineEnd + 1);
    end;
    // request line: METHOD SP target SP HTTP/1.x
    line := lines[0];
    p := Pos(' ', line);
    if p = 0 then begin
      raise EHttpStatus.Create(400, 'HTTP-BAD-REQUEST', 'Malformed request line');
    end;

    Req.Method := Copy(line, 1, p - 1);
    Delete(line, 1, p);
    p := Pos(' ', line);
    if (p = 0) or (Pos('HTTP/1.', Copy(line, p + 1, MaxInt)) <> 1) then begin
      raise EHttpStatus.Create(400, 'HTTP-BAD-REQUEST', 'Malformed request line');
    end;

    target := Copy(line, 1, p - 1);
    p := Pos('?', target);
    if p > 0 then begin
      Req.Query := Copy(target, p + 1, MaxInt);
      target := Copy(target, 1, p - 1);
    end;

    Req.Path := PercentDecode(target, false);

    for i := 1 to lines.Count - 1 do begin
      p := Pos(':', lines[i]);
      if p > 0 then begin
        AddHeader(Req.Headers, Trim(Copy(lines[i], 1, p - 1)), Trim(Copy(lines[i], p + 1, MaxInt)));
      end;
    end;
  finally
    lines.Free;
  end;

  // body
  te := HeaderValue(Req.Headers, 'Transfer-Encoding');
  if (te <> '') and not SameText(te, 'identity') then begin
    raise EHttpStatus.Create(411, 'HTTP-LENGTH-REQUIRED', 'Chunked uploads are not supported, send Content-Length');
  end;

  cl := HeaderValue(Req.Headers, 'Content-Length');
  if cl = '' then begin
    if SameText(Req.Method, 'POST') or SameText(Req.Method, 'PUT') then begin
      raise EHttpStatus.Create(411, 'HTTP-LENGTH-REQUIRED', 'Content-Length is required');
    end;

    len := 0;
  end else if not TryStrToInt64(cl, len) or (len < 0) then begin
    raise EHttpStatus.Create(400, 'HTTP-BAD-REQUEST', 'Invalid Content-Length');
  end;

  if len > Server.Opt.MaxBody then begin
    raise EHttpStatus.Create(413, 'HTTP-TOO-LARGE', Format('The request is larger than %d MB',
      [Server.Opt.MaxBody div (1024 * 1024)]));
  end;

  expect := HeaderValue(Req.Headers, 'Expect');
  if SameText(expect, '100-continue') and (used - hEnd < len) then begin
    SockSetSendTimeout(c.Sock, MinSendTimeoutMs);
    SendAll(c.Sock, TEncoding.ASCII.GetBytes('HTTP/1.1 100 Continue'#13#10#13#10));
  end;

  SetLength(Req.Body, len);
  n := used - hEnd;
  if n > len then n := len;

  if n > 0 then begin
    Move(buf[hEnd], Req.Body[0], n);
  end;

  p := n;
  buf := nil;

  while p < len do begin
    n := ReadSome;
    if n = 0 then begin
      raise EHttpStatus.Create(400, 'HTTP-BAD-REQUEST', 'Incomplete request body');
    end;

    if n > len - p then n := len - p;
    Move(chunk[0], Req.Body[p], n);
    Inc(p, n);
  end;

  result := true;
end;

procedure TServer.Handle(const c: TConn);
var
  req: THttpRequest;
  resp: THttpResponse;
  started: Boolean;
  left: Int64;
begin
  started := false;
  req := Default(THttpRequest);
  resp := Default(THttpResponse);

  try
    try
      if not ReadRequest(Self, c, req) then exit;
      resp.Status := 200;
      Handler(req, resp);
    except
      on e: EHttpStatus do begin
        resp := Default(THttpResponse);
        ErrorFunc(e.Status, e.Code, e.Message, resp);
        resp.Status := e.Status;
      end;
      on e: Exception do begin
        resp := Default(THttpResponse);
        ErrorFunc(500, 'INTERNAL', 'Internal error: ' + e.Message, resp);
        resp.Status := 500;
      end;
    end;

    left := Int64(c.Accepted) + Opt.TimeoutMs - Int64(Ticks);
    if left < MinSendTimeoutMs then left := MinSendTimeoutMs;
    SockSetSendTimeout(c.Sock, left);
    started := true;
    SendAll(c.Sock, ResponseBytes(resp));
    Log(c, req, resp.Status, Length(resp.Body));
  except
    on e: Exception do
      if not started then begin
        try
          resp := Default(THttpResponse);
          ErrorFunc(500, 'INTERNAL', 'Internal error: ' + e.Message, resp);
          resp.Status := 500;
          SendAll(c.Sock, ResponseBytes(resp));
          Log(c, req, 500, Length(resp.Body));
        except
          // give up on this connection
        end;
      end;
  end;

  SockClose(c.Sock);
end;

constructor TWorker.Create(AServer: TServer);
begin
  FServer := AServer;
  FreeOnTerminate := true;
  inherited Create(false);
end;

procedure TWorker.Execute;
var
  c: TConn;
  more: Boolean;
begin
  repeat
    try
      if FServer.Pop(c, more) then begin
        if more then begin
          FServer.Wake.SetEvent;   // the event does not count: wake the next worker
        end;

        if Ticks - c.Accepted > UInt64(FServer.Opt.TimeoutMs) then begin
          Reject(FServer, c, 503, 'HTTP-BUSY', 'The server was too busy, the request waited too long');
        end else begin
          FServer.Handle(c);
        end;
      end else begin
        FServer.Wake.WaitFor(INFINITE);
      end;
    except
      // Handle catches everything; this only guards the loop itself
    end;
  until false;
end;

function HttpServe(const Opt: THttpOptions; Handler: THttpHandler; ErrorFunc: THttpErrorFunc;
  out ErrorText: string): Boolean;
var
  server: TServer;
  l: TSock;
  c: TConn;
  i: Integer;
begin
  result := false;
  ErrorText := '';
  SockStartup;
  if not SockListen(Opt.Host, Opt.Port, l, ErrorText) then exit;
  server := TServer.Create(Opt, Handler, ErrorFunc);

  for i := 1 to Opt.Workers do begin
    TWorker.Create(server);
  end;

  if Opt.Banner <> '' then begin
    Writeln(Opt.Banner);
  end;

  // accept loop: runs until the process ends (Ctrl+C)
  repeat
    c := Default(TConn);
    c.Sock := SockAccept(l, c.Remote);
    if c.Sock = NoSock then continue;
    c.Accepted := Ticks;

    if not server.Push(c) then begin
      Reject(server, c, 503, 'HTTP-BUSY', 'The server is busy, try again');
    end;
  until false;
end;

end.
