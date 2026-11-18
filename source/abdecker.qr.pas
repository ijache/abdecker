{ SPDX-License-Identifier: MIT
  Copyright (c) 2026 Ingo Jache }

unit abdecker.qr;

{ abdecker - QR code encoder (internal), for the GiroCode. Not part of the
  public API: use TAbdecker.QrCodeSvg.

  Only what the GiroCode needs: byte mode, error correction level M (the EPC
  demands M), versions 1 to 40, no ECI, no Micro QR. The mask is chosen by
  the penalty rules of ISO/IEC 18004. Output as SVG with a quiet zone of four
  modules. Checked against the Python library segno (tests/qr.py). }

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

type
  TQrCode = record
    Version: Integer;   // 1..40
    Mask: Integer;      // 0..7
    Size: Integer;      // modules per side: 17 + 4 * Version
    Modules: TBytes;    // Size * Size, row by row, 1 = dark
    function Dark(x, y: Integer): Boolean;
  end;

{ Data in byte mode, level M, the smallest version that fits. Mask -1: chosen
  by the penalty rules, 0..7: that mask. false if the data does not fit. }
function QrEncode(const Data: TBytes; out Qr: TQrCode; Mask: Integer = -1): Boolean;

{ The code as SVG (dark modules as one path, quiet zone of 4 modules); Title
  goes into <title> (escaped by the caller), '' = none. }
function QrSvg(const Qr: TQrCode; const Title: string = ''): string;

implementation

const
  // level M per version 1..40 (ISO/IEC 18004, table 9)
  EccPerBlock: array[1..40] of Integer = (10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24,
    28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28);
  BlockCount: array[1..40] of Integer = (1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14,
    16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49);
  FormatM = 0;  // the two bits of level M in the format information

type
  TIntArray = array of Integer;

  TBuilder = record
    Size: Integer;
    Modules: TBytes;
    IsFunc: TBytes;   // 1 = function pattern (not data, not masked)
    procedure Init(ASize: Integer);
    procedure SetFunc(x, y: Integer; IsDark: Boolean);
    function Get(x, y: Integer): Boolean;
  end;

function IMax(a, b: Integer): Integer;
begin
  if a > b then result := a else result := b;
end;

function TQrCode.Dark(x, y: Integer): Boolean;
begin
  result := Modules[y * Size + x] <> 0;
end;

procedure TBuilder.Init(ASize: Integer);
begin
  Size := ASize;
  SetLength(Modules, Size * Size);
  SetLength(IsFunc, Size * Size);
  FillChar(Modules[0], Length(Modules), 0);
  FillChar(IsFunc[0], Length(IsFunc), 0);
end;

procedure TBuilder.SetFunc(x, y: Integer; IsDark: Boolean);
begin
  Modules[y * Size + x] := Ord(IsDark);
  IsFunc[y * Size + x] := 1;
end;

function TBuilder.Get(x, y: Integer): Boolean;
begin
  result := Modules[y * Size + x] <> 0;
end;

{ ---- sizes ---- }

{ modules available for data and error correction }
function RawModules(Ver: Integer): Integer;
var
  n: Integer;
begin
  result := (16 * Ver + 128) * Ver + 64;

  if Ver >= 2 then begin
    n := Ver div 7 + 2;
    result := result - ((25 * n - 10) * n - 55);
    if Ver >= 7 then result := result - 36;
  end;
end;

function DataCodewords(Ver: Integer): Integer;
begin
  result := RawModules(Ver) div 8 - EccPerBlock[Ver] * BlockCount[Ver];
end;

{ bits needed for Len bytes in byte mode }
function DataBits(Ver, Len: Integer): Integer;
begin
  if Ver <= 9 then begin
    result := 4 + 8 + 8 * Len;
  end else begin
    result := 4 + 16 + 8 * Len;
  end;
end;

{ ---- Reed-Solomon over GF(256), polynomial x^8 + x^4 + x^3 + x^2 + 1 ---- }

function GfMul(x, y: Integer): Integer;
var
  i: Integer;
begin
  result := 0;

  for i := 7 downto 0 do begin
    result := (result shl 1) xor ((result shr 7) * $11D);
    result := result xor (((y shr i) and 1) * x);
  end;
end;

{ generator polynomial of the given degree, highest coefficient (1) left out }
function RsDivisor(Degree: Integer): TBytes;
var
  i, j, root: Integer;
begin
  SetLength(result, Degree);
  FillChar(result[0], Degree, 0);
  result[Degree - 1] := 1;
  root := 1;

  for i := 0 to Degree - 1 do begin
    for j := 0 to Degree - 1 do begin
      result[j] := GfMul(result[j], root);
      if j + 1 < Degree then result[j] := result[j] xor result[j + 1];
    end;

    root := GfMul(root, 2);
  end;
end;

function RsRemainder(const Data: TBytes; Start, Count: Integer; const Divisor: TBytes): TBytes;
var
  i, j, factor, n: Integer;
begin
  n := Length(Divisor);
  SetLength(result, n);
  FillChar(result[0], n, 0);

  for i := Start to Start + Count - 1 do begin
    factor := Data[i] xor result[0];
    Move(result[1], result[0], n - 1);
    result[n - 1] := 0;

    for j := 0 to n - 1 do begin
      result[j] := result[j] xor GfMul(Divisor[j], factor);
    end;
  end;
end;

{ ---- codewords ---- }

{ data codewords: mode, length, data, terminator, padding }
function MakeDataCodewords(const Data: TBytes; Ver: Integer): TBytes;
var
  bits: TBytes;   // one bit per byte, simple and small enough
  n, i, capacity: Integer;
  pad: Byte;

  procedure Put(Value, Count: Integer);
  var
    k: Integer;
  begin
    for k := Count - 1 downto 0 do begin
      bits[n] := (Value shr k) and 1;
      Inc(n);
    end;
  end;

begin
  capacity := DataCodewords(Ver) * 8;
  SetLength(bits, capacity);
  FillChar(bits[0], capacity, 0);
  n := 0;
  Put(4, 4);   // byte mode

  if Ver <= 9 then begin
    Put(Length(Data), 8);
  end else begin
    Put(Length(Data), 16);
  end;

  for i := 0 to High(Data) do begin
    Put(Data[i], 8);
  end;

  // terminator: up to four zero bits (the buffer is zeroed)
  if capacity - n < 4 then n := capacity else n := n + 4;
  n := (n + 7) and not 7;
  pad := $EC;

  while n < capacity do begin
    Put(pad, 8);
    pad := pad xor ($EC xor $11);
  end;

  SetLength(result, capacity div 8);

  for i := 0 to High(result) do begin
    result[i] := 0;

    for n := 0 to 7 do begin
      result[i] := (result[i] shl 1) or bits[i * 8 + n];
    end;
  end;
end;

{ split into blocks, add the error correction, interleave }
function AddEcc(const Data: TBytes; Ver: Integer): TBytes;
var
  blocks, eccLen, raw, shortCount, shortLen, i, k, start, len, n: Integer;
  divisor, ecc: TBytes;
  starts, lens: array of Integer;
  eccs: array of TBytes;
begin
  blocks := BlockCount[Ver];
  eccLen := EccPerBlock[Ver];
  raw := RawModules(Ver) div 8;
  shortCount := blocks - raw mod blocks;
  shortLen := raw div blocks;   // block length incl. error correction
  divisor := RsDivisor(eccLen);
  SetLength(starts, blocks);
  SetLength(lens, blocks);
  SetLength(eccs, blocks);
  start := 0;

  for i := 0 to blocks - 1 do begin
    len := shortLen - eccLen;
    if i >= shortCount then Inc(len);
    starts[i] := start;
    lens[i] := len;
    eccs[i] := RsRemainder(Data, start, len, divisor);
    start := start + len;
  end;

  SetLength(result, raw);
  n := 0;

  // data codewords, column by column (the long blocks have one more)
  for k := 0 to shortLen - eccLen do begin
    for i := 0 to blocks - 1 do begin
      if k < lens[i] then begin
        result[n] := Data[starts[i] + k];
        Inc(n);
      end;
    end;
  end;

  for k := 0 to eccLen - 1 do begin
    for i := 0 to blocks - 1 do begin
      ecc := eccs[i];
      result[n] := ecc[k];
      Inc(n);
    end;
  end;

end;

{ ---- function patterns ---- }

procedure DrawFinder(var b: TBuilder; cx, cy: Integer);
var
  dx, dy, x, y, d: Integer;
begin
  for dy := -4 to 4 do begin
    for dx := -4 to 4 do begin
      x := cx + dx;
      y := cy + dy;
      if (x < 0) or (y < 0) or (x >= b.Size) or (y >= b.Size) then continue;
      d := IMax(Abs(dx), Abs(dy));
      b.SetFunc(x, y, (d <> 2) and (d <> 4));
    end;
  end;
end;

procedure DrawAlignment(var b: TBuilder; cx, cy: Integer);
var
  dx, dy: Integer;
begin
  for dy := -2 to 2 do begin
    for dx := -2 to 2 do begin
      b.SetFunc(cx + dx, cy + dy, IMax(Abs(dx), Abs(dy)) <> 1);
    end;
  end;
end;

function AlignmentPositions(Ver, Size: Integer): TIntArray;
var
  n, step, i, pos: Integer;
begin
  SetLength(result, 0);
  if Ver = 1 then exit;
  n := Ver div 7 + 2;
  step := (Ver * 8 + n * 3 + 5) div (n * 4 - 4) * 2;
  SetLength(result, n);
  result[0] := 6;
  pos := Size - 7;

  for i := n - 1 downto 1 do begin
    result[i] := pos;
    pos := pos - step;
  end;
end;

{ Blank: all modules of the area light (while the masks are evaluated) }
procedure DrawFormat(var b: TBuilder; Mask: Integer; Blank: Boolean = false);
var
  data, rem, bits, i: Integer;

  function Bit(k: Integer): Boolean;
  begin
    result := ((bits shr k) and 1) <> 0;
  end;

begin
  data := (FormatM shl 3) or Mask;
  rem := data;

  for i := 0 to 9 do begin
    rem := (rem shl 1) xor ((rem shr 9) * $537);
  end;

  bits := ((data shl 10) or rem) xor $5412;
  if Blank then bits := 0;

  // around the top left finder
  for i := 0 to 5 do b.SetFunc(8, i, Bit(i));
  b.SetFunc(8, 7, Bit(6));
  b.SetFunc(8, 8, Bit(7));
  b.SetFunc(7, 8, Bit(8));
  for i := 9 to 14 do b.SetFunc(14 - i, 8, Bit(i));

  // the second copy
  for i := 0 to 7 do b.SetFunc(b.Size - 1 - i, 8, Bit(i));
  for i := 8 to 14 do b.SetFunc(8, b.Size - 15 + i, Bit(i));
  b.SetFunc(8, b.Size - 8, not Blank);   // the dark module
end;

procedure DrawVersion(var b: TBuilder; Ver: Integer; Blank: Boolean = false);
var
  rem, bits, i, x, y: Integer;
  d: Boolean;
begin
  if Ver < 7 then exit;
  rem := Ver;

  for i := 0 to 11 do begin
    rem := (rem shl 1) xor ((rem shr 11) * $1F25);
  end;

  bits := (Ver shl 12) or rem;
  if Blank then bits := 0;

  for i := 0 to 17 do begin
    d := ((bits shr i) and 1) <> 0;
    x := b.Size - 11 + i mod 3;
    y := i div 3;
    b.SetFunc(x, y, d);
    b.SetFunc(y, x, d);
  end;
end;

procedure DrawFunctionPatterns(var b: TBuilder; Ver: Integer);
var
  i, j, n, last: Integer;
  pos: TIntArray;
begin
  for i := 0 to b.Size - 1 do begin
    b.SetFunc(6, i, i mod 2 = 0);
    b.SetFunc(i, 6, i mod 2 = 0);
  end;

  DrawFinder(b, 3, 3);
  DrawFinder(b, b.Size - 4, 3);
  DrawFinder(b, 3, b.Size - 4);
  pos := AlignmentPositions(Ver, b.Size);
  n := Length(pos);
  last := n - 1;

  for i := 0 to n - 1 do begin
    for j := 0 to n - 1 do begin
      if ((i = 0) and (j = 0)) or ((i = 0) and (j = last)) or ((i = last) and (j = 0)) then continue;
      DrawAlignment(b, pos[i], pos[j]);
    end;
  end;

  DrawFormat(b, 0);   // reserves the area, drawn again with the mask
  DrawVersion(b, Ver);
end;

{ ---- data and mask ---- }

procedure DrawCodewords(var b: TBuilder; const Codewords: TBytes);
var
  i, right, vert, j, x, y: Integer;
  upward: Boolean;
begin
  i := 0;
  right := b.Size - 1;

  while right >= 1 do begin
    if right = 6 then right := 5;   // skip the vertical timing pattern

    for vert := 0 to b.Size - 1 do begin
      for j := 0 to 1 do begin
        x := right - j;
        upward := ((right + 1) and 2) = 0;

        if upward then begin
          y := b.Size - 1 - vert;
        end else begin
          y := vert;
        end;

        if (b.IsFunc[y * b.Size + x] = 0) and (i < Length(Codewords) * 8) then begin
          b.Modules[y * b.Size + x] := (Codewords[i shr 3] shr (7 - (i and 7))) and 1;
          Inc(i);
        end;
      end;
    end;

    right := right - 2;
  end;
end;

function MaskBit(Mask, x, y: Integer): Boolean;
begin
  case Mask of
    0: result := (x + y) mod 2 = 0;
    1: result := y mod 2 = 0;
    2: result := x mod 3 = 0;
    3: result := (x + y) mod 3 = 0;
    4: result := (x div 3 + y div 2) mod 2 = 0;
    5: result := (x * y) mod 2 + (x * y) mod 3 = 0;
    6: result := ((x * y) mod 2 + (x * y) mod 3) mod 2 = 0;
  else
    result := ((x + y) mod 2 + (x * y) mod 3) mod 2 = 0;
  end;
end;

{ XOR: applying it twice removes it again }
procedure ApplyMask(var b: TBuilder; Mask: Integer);
var
  x, y: Integer;
begin
  for y := 0 to b.Size - 1 do begin
    for x := 0 to b.Size - 1 do begin
      if (b.IsFunc[y * b.Size + x] = 0) and MaskBit(Mask, x, y) then begin
        b.Modules[y * b.Size + x] := b.Modules[y * b.Size + x] xor 1;
      end;
    end;
  end;
end;

{ ISO/IEC 18004, 7.8.3: N1 = 3, N2 = 3, N3 = 40, N4 = 10 }
function Penalty(const b: TBuilder): Integer;
var
  x, y, i, run, dark, total, k: Integer;
  line: TBytes;

  { a module of the line, outside counts as light }
  function At(p: Integer): Byte;
  begin
    if (p < 0) or (p >= b.Size) then begin
      result := 0;
    end else begin
      result := line[p];
    end;
  end;

  function LineScore: Integer;
  var
    p, q: Integer;
    finder, lightBefore, lightAfter: Boolean;
  begin
    result := 0;
    // N1: runs of five or more of the same colour
    run := 1;

    for p := 1 to b.Size do begin
      if (p < b.Size) and (line[p] = line[p - 1]) then begin
        Inc(run);
      end else begin
        if run >= 5 then result := result + 3 + (run - 5);
        run := 1;
      end;
    end;

    // N3: 1:1:3:1:1 (dark light dark dark dark light dark) with four light
    // modules before or after; after a hit, the search goes on behind it
    p := 0;

    while p <= b.Size - 7 do begin
      finder := (line[p] = 1) and (line[p + 1] = 0) and (line[p + 2] = 1) and (line[p + 3] = 1) and
        (line[p + 4] = 1) and (line[p + 5] = 0) and (line[p + 6] = 1);
      lightBefore := true;
      lightAfter := true;

      for q := 1 to 4 do begin
        if At(p - q) <> 0 then lightBefore := false;
        if At(p + 6 + q) <> 0 then lightAfter := false;
      end;

      if finder and (lightBefore or lightAfter) then begin
        result := result + 40;
        p := p + 7;
      end else begin
        Inc(p);
      end;
    end;
  end;

begin
  result := 0;
  SetLength(line, b.Size);

  for y := 0 to b.Size - 1 do begin
    for i := 0 to b.Size - 1 do line[i] := b.Modules[y * b.Size + i];
    result := result + LineScore;
  end;

  for x := 0 to b.Size - 1 do begin
    for i := 0 to b.Size - 1 do line[i] := b.Modules[i * b.Size + x];
    result := result + LineScore;
  end;

  // N2: 2x2 blocks of the same colour
  for y := 0 to b.Size - 2 do begin
    for x := 0 to b.Size - 2 do begin
      k := b.Modules[y * b.Size + x];
      if (b.Modules[y * b.Size + x + 1] = k) and (b.Modules[(y + 1) * b.Size + x] = k) and
        (b.Modules[(y + 1) * b.Size + x + 1] = k) then begin
        result := result + 3;
      end;
    end;
  end;

  // N4: share of dark modules, 10 points per 5 % away from 50 %
  dark := 0;
  for i := 0 to High(b.Modules) do dark := dark + b.Modules[i];
  total := b.Size * b.Size;
  result := result + 10 * (Abs(dark * 2 - total) * 10 div total);
end;

function QrEncode(const Data: TBytes; out Qr: TQrCode; Mask: Integer): Boolean;
var
  ver, m, best, score, bestScore: Integer;
  b: TBuilder;
  codewords: TBytes;
begin
  Qr := Default(TQrCode);
  ver := 1;

  while (ver <= 40) and (DataBits(ver, Length(Data)) > DataCodewords(ver) * 8) do begin
    Inc(ver);
  end;

  if ver > 40 then exit(false);
  codewords := AddEcc(MakeDataCodewords(Data, ver), ver);
  b.Init(17 + 4 * ver);
  DrawFunctionPatterns(b, ver);
  DrawCodewords(b, codewords);

  if (Mask >= 0) and (Mask <= 7) then begin
    best := Mask;
  end else begin
    // evaluated without format and version information (they are added
    // after masking, ISO/IEC 18004, 7.8; as segno does it)
    DrawFormat(b, 0, true);
    DrawVersion(b, ver, true);
    best := 0;
    bestScore := MaxInt;

    for m := 0 to 7 do begin
      ApplyMask(b, m);
      score := Penalty(b);

      if score < bestScore then begin
        best := m;
        bestScore := score;
      end;

      ApplyMask(b, m);
    end;
  end;

  ApplyMask(b, best);
  DrawFormat(b, best);
  DrawVersion(b, ver);
  Qr.Version := ver;
  Qr.Mask := best;
  Qr.Size := b.Size;
  Qr.Modules := b.Modules;
  result := true;
end;

function QrSvg(const Qr: TQrCode; const Title: string): string;
const
  Quiet = 4;
var
  sb: TStringBuilder;
  x, y, start, w: Integer;
begin
  w := Qr.Size + 2 * Quiet;
  sb := TStringBuilder.Create;

  try
    sb.Append('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + IntToStr(w) + ' ' + IntToStr(w) +
      '" shape-rendering="crispEdges">');
    if Title <> '' then sb.Append('<title>' + Title + '</title>');
    sb.Append('<rect width="' + IntToStr(w) + '" height="' + IntToStr(w) + '" fill="#fff"/><path fill="#000" d="');

    // each run of dark modules in a row as one rectangle
    for y := 0 to Qr.Size - 1 do begin
      x := 0;

      while x < Qr.Size do begin
        if not Qr.Dark(x, y) then begin
          Inc(x);
          continue;
        end;

        start := x;
        while (x < Qr.Size) and Qr.Dark(x, y) do Inc(x);
        sb.Append('M' + IntToStr(start + Quiet) + ' ' + IntToStr(y + Quiet) + 'h' + IntToStr(x - start) +
          'v1h-' + IntToStr(x - start) + 'z');
      end;
    end;

    sb.Append('"/></svg>');
    result := sb.ToString;
  finally
    sb.Free;
  end;
end;

end.
