{ SPDX-License-Identifier: MIT
  Copyright (c) 2026 Ingo Jache }

unit cliutils;

{ abdecker - helpers for the command line tool: console setup, file and
  stdin/stdout I/O, text output. Knows nothing about invoices. }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
{$IFDEF FPC}
  SysUtils, Classes;
{$ELSE}
  System.SysUtils, System.Classes;
{$ENDIF}

{ Switch the console to UTF-8 (Windows). }
procedure SetupConsole;

{ Read a whole file, '-' = stdin. Prints an error and returns False on failure. }
function ReadInput(const Name: string; out Data: TBytes): Boolean;

{ A string as UTF-8 bytes (Delphi: string is UTF-16; FPC: it holds UTF-8) }
function Utf8Bytes(const s: string): TBytes;

{ Write a whole file, '-' = stdout. Prints an error and returns False on failure. }
function WriteOutput(const Name: string; const Data: TBytes): Boolean;

{ True if standard output is an interactive console (not redirected).
  Only detected on Windows; elsewhere always False. }
function StdoutIsConsole: Boolean;

{ "Label:          value" - skipped if Value is empty. }
procedure PrintField(const Lbl, Value: string);

{ Human readable size: '512 bytes', '37 KB'; '' for negative sizes. }
function SizeText(Size: Int64): string;

{ Opens a file with the program associated by the system (e.g. the browser). }
function OpenWithSystem(const FileName: string): Boolean;

{ Folder for temporary files, with trailing path delimiter. }
function TempFolder: string;

{ A file name from a foreign source made safe to save: no path, no
  characters that are invalid on Windows, not empty, not "." or "..".
  Fallback if nothing usable is left. }
function SafeFileName(const Name, Fallback: string): string;

implementation

{$IFDEF MSWINDOWS}
uses
  {$IFDEF FPC} Windows, ShellApi; {$ELSE} Winapi.Windows, Winapi.ShellAPI; {$ENDIF}
{$ENDIF}

{$IF DEFINED(MSWINDOWS) and not DEFINED(FPC)}
{ The Delphi RTL flushes Output/ErrOutput after each Writeln only on a
  console. Redirected to a pipe or file, both are buffered in 128-byte blocks,
  so stdout and stderr lines get cut and interleaved (e.g. with 2>&1). Make
  them flush after each line there, too. Both are opened lazily on the first
  write, which would reset FlushFunc, so open them here first. }
procedure FlushEachLine(var f: Text);
begin
  if TTextRec(f).Mode <> fmOutput then begin
    TTextRec(f).Flags := tfCRLF * Byte(DefaultTextLineBreakStyle);
    Rewrite(f);
  end;

  TTextRec(f).FlushFunc := TTextRec(f).InOutFunc;
end;
{$IFEND}

procedure SetupConsole;
begin
{$IFDEF MSWINDOWS}
  SetConsoleOutputCP(CP_UTF8);
  {$IFNDEF FPC}
  SetTextCodePage(Output, CP_UTF8);
  SetTextCodePage(ErrOutput, CP_UTF8);
  FlushEachLine(Output);
  FlushEachLine(ErrOutput);
  {$ENDIF}
{$ENDIF}
end;

function OpenStdStream(Input: Boolean): THandleStream;
begin
{$IFDEF MSWINDOWS}
  if Input then begin
    result := THandleStream.Create(GetStdHandle(STD_INPUT_HANDLE));
  end else begin
    result := THandleStream.Create(GetStdHandle(STD_OUTPUT_HANDLE));
  end;
{$ELSE}
  if Input then begin
    result := THandleStream.Create(0);
  end else begin
    result := THandleStream.Create(1);
  end;
{$ENDIF}
end;

function ReadInput(const Name: string; out Data: TBytes): Boolean;
var
  s: TStream;
  mem: TBytesStream;
  buf: TBytes;
  n: Integer;
begin
  result := false;
  Data := nil;

  try
    if Name = '-' then begin
      // read until the end: CopyFrom(S, 0) asks the stream for its size,
      // which a pipe does not have (seen: empty input now and then)
      s := OpenStdStream(true);
      mem := TBytesStream.Create;

      try
        SetLength(buf, 65536);

        repeat
          n := s.Read(buf[0], Length(buf));
          if n > 0 then begin
            mem.WriteBuffer(buf[0], n);
          end;
        until n <= 0;

        Data := Copy(mem.Bytes, 0, mem.Size);
      finally
        mem.Free;
        s.Free;
      end;
    end else begin
      s := TFileStream.Create(Name, fmOpenRead or fmShareDenyWrite);

      try
        SetLength(Data, s.Size);

        if Length(Data) > 0 then begin
          s.ReadBuffer(Data[0], Length(Data));
        end;
      finally
        s.Free;
      end;
    end;

    result := true;
  except
    on e: Exception do
      Writeln(ErrOutput, 'Error: "', Name, '" cannot be read: ', e.Message);
  end;
end;

function WriteOutput(const Name: string; const Data: TBytes): Boolean;
var
  s: TStream;
begin
  result := false;

  try
    if Name = '-' then begin
      s := OpenStdStream(false);
    end else begin
      s := TFileStream.Create(Name, fmCreate);
    end;

    try
      if Length(Data) > 0 then begin
        s.WriteBuffer(Data[0], Length(Data));
      end;
    finally
      s.Free;
    end;

    result := true;
  except
    on e: Exception do
      Writeln(ErrOutput, 'Error: "', Name, '" cannot be written: ', e.Message);
  end;
end;

function StdoutIsConsole: Boolean;
{$IFDEF MSWINDOWS}
var
  mode: DWORD;
begin
  // GetConsoleMode fails for pipes, files and NUL
  result := GetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), mode);
end;
{$ELSE}
begin
  result := false;
end;
{$ENDIF}

procedure PrintField(const Lbl, Value: string);
begin
  if Value <> '' then begin
    Writeln(Format('%-16s %s', [Lbl + ':', Value]));
  end;
end;

function SizeText(Size: Int64): string;
begin
  if Size < 0 then begin
    result := '';
  end else if Size < 10240 then begin
    result := IntToStr(Size) + ' bytes';
  end else begin
    result := IntToStr((Size + 512) div 1024) + ' KB';
  end;
end;

function OpenWithSystem(const FileName: string): Boolean;
begin
{$IFDEF MSWINDOWS}
  result := ShellExecute(0, 'open', PChar(FileName), nil, nil, SW_SHOWNORMAL) > 32;
{$ELSE}
  // TODO: macOS 'open', Linux 'xdg-open' (FPC: TProcess)
  result := false;
{$ENDIF}
end;

{ FPC: the unit Windows (used later) hides the SysUtils function }
function EnvVar(const Name: string): string;
begin
  result := {$IFDEF FPC}SysUtils.{$ENDIF}GetEnvironmentVariable(Name);
end;

function Utf8Bytes(const s: string): TBytes;
begin
{$IFDEF FPC}
  SetLength(result, Length(s));
  if Length(s) > 0 then Move(s[1], result[0], Length(s));
{$ELSE}
  result := TEncoding.UTF8.GetBytes(s);
{$ENDIF}
end;

function TempFolder: string;
begin
  result := EnvVar('TEMP');
  if result = '' then result := EnvVar('TMPDIR');
  if result = '' then result := EnvVar('TMP');
{$IFNDEF MSWINDOWS}
  if result = '' then result := '/tmp';
{$ENDIF}
  result := IncludeTrailingPathDelimiter(result);
end;

function SafeFileName(const Name, Fallback: string): string;
var
  i: Integer;
begin
  result := Name;
  i := LastDelimiter('/\', result);
  if i > 0 then result := Copy(result, i + 1, MaxInt);

  for i := 1 to Length(result) do begin
    if (result[i] < ' ') or CharInSet(result[i], ['<', '>', ':', '"', '|', '?', '*']) then begin
      result[i] := '_';
    end;
  end;

  // Windows drops trailing dots and spaces
  while (result <> '') and CharInSet(result[Length(result)], ['.', ' ']) do begin
    SetLength(result, Length(result) - 1);
  end;

  result := Trim(result);
  if (result = '') or (result = '.') or (result = '..') then result := Fallback;
end;

end.
