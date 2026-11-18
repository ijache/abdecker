{ SPDX-License-Identifier: MIT
  Copyright (c) 2026 Ingo Jache }

unit abdecker.zlib;

{ abdecker - zlib compression (FlateDecode), internal. Not part of the public
  API.

  A unit of its own, so that only this unit sees the zlib units: paszlib
  (FPC) exports names like COPY and units like zdeflate, which would hide or
  clash with names of the other units. }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
{$IFDEF FPC}
  SysUtils;
{$ELSE}
  System.SysUtils;
{$ENDIF}

{ zlib format; raises EAbParse on failure }
function DeflateBytes(const Src: TBytes): TBytes;
{ zlib, gzip or raw deflate; lenient: truncated or slightly damaged streams
  still yield what could be read. False if nothing could be read. }
function InflateBytes(const Src: TBytes; out Dst: TBytes): Boolean;

implementation

uses
{$IFDEF FPC}
  zbase, zinflate, zdeflate,  // paszlib
{$ELSE}
  System.ZLib,
{$ENDIF}
  abdecker.util;

function DeflateBytes(const Src: TBytes): TBytes;
var
  z: z_stream;
  res: Integer;
begin
  FillChar(z, SizeOf(z), 0);
{$IFNDEF FPC}
  z.zalloc := zlibAllocMem;
  z.zfree := zlibFreeMem;
{$ENDIF}
  if deflateInit(z, Z_DEFAULT_COMPRESSION) <> Z_OK then begin
    raise EAbParse.Create('deflate: initialization failed');
  end;

  try
    SetLength(result, Length(Src) + Length(Src) div 100 + 64);
    if Length(Src) > 0 then z.next_in := @Src[0];
    z.avail_in := Length(Src);
    z.next_out := @result[0];
    z.avail_out := Length(result);
    res := deflate(z, Z_FINISH);
    if res <> Z_STREAM_END then begin
      raise EAbParse.Create('deflate failed');
    end;

    SetLength(result, z.total_out);
  finally
    deflateEnd(z);
  end;
end;

function InflateBytes(const Src: TBytes; out Dst: TBytes): Boolean;
const
{$IFDEF FPC}
  WindowBits: array[0..1] of Integer = (15, -15);
{$ELSE}
  WindowBits: array[0..1] of Integer = (15 + 32, -15);  // zlib/gzip, then raw
{$ENDIF}
var
  z: z_stream;
  res, attempt, outLen: Integer;
begin
  Dst := nil;
  if Length(Src) = 0 then exit(true);

  for attempt := 0 to 1 do begin
    FillChar(z, SizeOf(z), 0);
{$IFNDEF FPC}
    z.zalloc := zlibAllocMem;
    z.zfree := zlibFreeMem;
{$ENDIF}
    if inflateInit2(z, WindowBits[attempt]) <> Z_OK then continue;
    outLen := 0;

    try
      SetLength(Dst, Length(Src) * 4 + 1024);
      z.next_in := @Src[0];
      z.avail_in := Length(Src);

      repeat
        if outLen >= Length(Dst) then begin
          SetLength(Dst, Length(Dst) * 2);
        end;

        z.next_out := @Dst[outLen];
        z.avail_out := Cardinal(Length(Dst) - outLen);
        res := inflate(z, Z_NO_FLUSH);
        outLen := Length(Dst) - Integer(z.avail_out);
      until (res <> Z_OK) or ((z.avail_in = 0) and (z.avail_out > 0));
    finally
      inflateEnd(z);
    end;

    // be lenient: truncated or slightly damaged streams still yield data
    if (res = Z_STREAM_END) or (outLen > 0) then begin
      SetLength(Dst, outLen);
      exit(true);
    end;
  end;
  Dst := nil;
  result := false;
end;

end.
