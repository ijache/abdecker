{ SPDX-License-Identifier: MIT
  Copyright (c) 2026 Ingo Jache }

unit abdecker.pdf;

{ abdecker - PDF reader and stream filters (internal).
  Not part of the public API: use the unit abdecker.

  Reads just enough of the PDF object model to find embedded files and the
  XMP metadata. Objects live in a flat value pool (indices, no pointers). }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
{$IFDEF FPC}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$ENDIF}
  abdecker;

type
  TStringArray = array of string;
  TIntArray = array of Integer;

  TPKind = (pkNull, pkBool, pkInt, pkReal, pkString, pkName, pkArray, pkDict,
    pkRef, pkStream);

  TPVal = record
    Kind: TPKind;
    Int: Int64;              // integer, boolean (0/1), object number of a reference
    Gen: Integer;            // generation number of a reference
    Str: string;             // name, or real number as text
    Bytes: TBytes;           // string content
    Keys: TStringArray;      // dictionary keys (dict, stream)
    Items: TIntArray;        // array elements or dictionary values (pool indices)
    StmPos, StmLen: Integer; // stream data inside the file
  end;

  TPdfEntry = record
    Kind: Byte;      // 0 unknown, 1 at file offset, 2 inside an object stream
    Ofs: Integer;    // file offset, or number of the object stream
    Idx: Integer;    // index inside the object stream
    State: Integer;  // 0 not loaded, -1 loading, -2 failed, >0 pool index + 1
  end;

  TPdfObjStm = record
    Num: Integer;
    Data: TBytes;
    First: Integer;
    Nums, Offs: array of Integer;
  end;

  TPdfFile = record
    Name, Desc, Mime, Relationship: string;
    Size: Int64;
    Stream: Integer;   // pool index of the embedded file stream, -1 if missing
    InAF: Boolean;
    Key: Int64;        // for de-duplication (object number or pool index)
  end;
  TPdfFiles = array of TPdfFile;

  TPdf = record
    b: TBytes;
    l: Integer;
    Vals: array of TPVal;
    VCount: Integer;
    Entries: array of TPdfEntry;
    ObjStms: array of TPdfObjStm;
    Trailer: Integer;     // pool index of the newest trailer dictionary
    CatalogObj: Integer;  // fallback found while rebuilding
    Version: string;
    StartXRef: Integer;     // offset of the newest cross-reference section
    XRefIsStream: Boolean;  // the newest section is a cross-reference stream
    Rebuilt: Boolean;
    LoadFailures: Integer;  // objects listed in the xref that could not be read
    function NewVal(k: TPKind): Integer;
    function ReadName(const Buf: TBytes; BufLen: Integer; var p: Integer): string;
    function ParseValue(const Buf: TBytes; BufLen: Integer; var p: Integer;
      Depth: Integer): Integer;
    function ParseObjectAt(Ofs, ExpectNum: Integer): Integer;
    procedure SetEntry(Num: Int64; Kind: Byte; Ofs, Idx: Int64; Overwrite: Boolean);
    function LoadXRefSection(Ofs: Integer; out Prev, XRefStm: Integer): Boolean;
    function LoadXRef(StartOfs: Integer): Boolean;
    procedure Rebuild;
    function ObjStmIndex(StmNum: Integer): Integer;
    function FromObjStm(StmNum, Num, Idx: Integer): Integer;
    function GetObject(Num: Int64): Integer;
    function Resolve(v: Integer): Integer;
    function IntOf(Raw: Integer; Def: Int64): Int64;
    function TextOf(v: Integer): string;
    function DGet(d: Integer; const Key: string): Integer;
    function DRaw(d: Integer; const Key: string): Integer;  // without resolving references
    function ValueText(v: Integer; Depth: Integer = 0): string;  // serialize a direct value
    function DHas(d: Integer; const Key: string): Boolean;
    function DInt(d: Integer; const Key: string; Def: Int64): Int64;
    function DName(d: Integer; const Key: string): string;
    function DText(d: Integer; const Key: string): string;
    function StreamData(s: Integer; out Data: TBytes; out Err: string): Boolean;
    function Open(const Data: TBytes; var Msgs: TAbMessages): Boolean;
    function Catalog: Integer;
    function Encrypted: Boolean;
    function EmbeddedFiles: TPdfFiles;
    function MetadataXML(out Data: TBytes): Boolean;
  end;

{ '/Name' with # escapes }
function PdfNameText(const Name: string): string;
{ Text string: '(...)' for printable ASCII, otherwise '<FEFF...>' (UTF-16BE) }
function PdfTextString(const s: string): string;


implementation

uses
  abdecker.util, abdecker.xml, abdecker.zlib;

{ ===========================================================================
  Stream filters (Flate, PNG predictors, ASCIIHex, ASCII85)
  =========================================================================== }

function UnPredict(const Src: TBytes; Predictor, Colors, Bpc, Columns: Integer;
  out Dst: TBytes): Boolean;
var
  bpp, rowLen, rows, r, i, srcPos, dstPos, x, a, up, upLeft, pa, pb, pc, pp, v: Integer;
  ft: Byte;
  prev: TBytes;
begin
  result := false;
  Dst := nil;

  if Predictor <= 1 then begin
    Dst := Src;
    exit(true);
  end;

  if Predictor < 10 then begin
    exit;  // TIFF predictor 2 is not supported
  end;

  if Colors < 1 then Colors := 1;
  if Bpc < 1 then Bpc := 8;
  if Columns < 1 then Columns := 1;
  bpp := (Colors * Bpc + 7) div 8;
  rowLen := (Colors * Bpc * Columns + 7) div 8;
  if rowLen <= 0 then exit;
  rows := Length(Src) div (rowLen + 1);
  SetLength(Dst, rows * rowLen);
  SetLength(prev, rowLen);
  FillChar(prev[0], rowLen, 0);
  srcPos := 0;
  dstPos := 0;

  for r := 0 to rows - 1 do begin
    ft := Src[srcPos];
    Inc(srcPos);

    for i := 0 to rowLen - 1 do begin
      x := Src[srcPos + i];
      if i >= bpp then a := Dst[dstPos + i - bpp] else a := 0;
      up := prev[i];
      if i >= bpp then upLeft := prev[i - bpp] else upLeft := 0;

      case ft of
        1: v := x + a;
        2: v := x + up;
        3: v := x + (a + up) div 2;
        4:
          begin
            pp := a + up - upLeft;
            pa := Abs(pp - a);
            pb := Abs(pp - up);
            pc := Abs(pp - upLeft);
            if (pa <= pb) and (pa <= pc) then v := x + a
            else if pb <= pc then v := x + up
            else v := x + upLeft;
          end;
      else
        v := x;
      end;

      Dst[dstPos + i] := Byte(v and $FF);
    end;

    Move(Dst[dstPos], prev[0], rowLen);
    Inc(srcPos, rowLen);
    Inc(dstPos, rowLen);
  end;

  result := true;
end;

function DecodeAHx(const Src: TBytes): TBytes;
var
  buf: TByteBuf;
  i, hi: Integer;
begin
  buf.Clear;
  hi := -1;

  for i := 0 to High(Src) do begin
    if Src[i] = Ord('>') then break;

    if IsHexDigit(Src[i]) then begin
      if hi < 0 then begin
        hi := HexVal(Src[i]);
      end else begin
        buf.Add(Byte(hi * 16 + HexVal(Src[i])));
        hi := -1;
      end;
    end;
  end;

  if hi >= 0 then begin
    buf.Add(Byte(hi * 16));
  end;

  result := buf.AsBytes;
end;

function DecodeA85(const Src: TBytes; out Dst: TBytes): Boolean;
var
  buf: TByteBuf;
  i, n, k: Integer;
  v: UInt64;
  c: Byte;
begin
  result := false;
  Dst := nil;
  buf.Clear;
  n := 0;
  v := 0;
  i := 0;
  if (Length(Src) >= 2) and (Src[0] = Ord('<')) and (Src[1] = Ord('~')) then i := 2;

  while i < Length(Src) do begin
    c := Src[i];
    Inc(i);
    if (c = 0) or (c = 9) or (c = 10) or (c = 12) or (c = 13) or (c = 32) then continue;
    if c = Ord('~') then break;

    if (c = Ord('z')) and (n = 0) then begin
      for k := 1 to 4 do begin
        buf.Add(0);
      end;

      continue;
    end;

    if (c < 33) or (c > 117) then exit;
    v := v * 85 + UInt64(c - 33);
    Inc(n);

    if n = 5 then begin
      buf.Add(Byte(v shr 24));
      buf.Add(Byte(v shr 16));
      buf.Add(Byte(v shr 8));
      buf.Add(Byte(v));
      n := 0;
      v := 0;
    end;
  end;

  if n > 1 then begin
    for k := n to 4 do begin
      v := v * 85 + 84;
    end;

    for k := 0 to n - 2 do begin
      buf.Add(Byte(v shr (24 - 8 * k)));
    end;
  end;

  Dst := buf.AsBytes;
  result := true;
end;

{ PDF text string: UTF-16BE with BOM, UTF-8 with BOM (PDF 2.0) or PDFDocEncoding }
const
  PdfDocHigh: array[$80..$A0] of Word = (
    $2022, $2020, $2021, $2026, $2014, $2013, $0192, $2044, $2039, $203A, $2212,
    $2030, $201E, $201C, $201D, $2018, $2019, $201A, $2122, $FB01, $FB02, $0141,
    $0152, $0160, $0178, $017D, $0131, $0142, $0153, $0161, $017E, $FFFD, $20AC);

function PdfText(const s: TBytes): string;
var
  u: UnicodeString;
  i, n: Integer;
  c: Word;
begin
  n := Length(s);
  if (n >= 2) and (s[0] = $FE) and (s[1] = $FF) then begin
    SetLength(u, (n - 2) div 2);

    for i := 1 to Length(u) do begin
      u[i] := WideChar((s[2 * i] shl 8) or s[2 * i + 1]);
    end;
  end else if (n >= 3) and (s[0] = $EF) and (s[1] = $BB) and (s[2] = $BF) then begin
    u := UnicodeString(Utf8Str(s, 3, n - 3));
  end else begin
    SetLength(u, n);

    for i := 0 to n - 1 do begin
      c := s[i];
      if (c >= $80) and (c <= $A0) then c := PdfDocHigh[c];
      u[i + 1] := WideChar(c);
    end;
  end;

  while (Length(u) > 0) and (u[Length(u)] = #0) do begin
    SetLength(u, Length(u) - 1);
  end;

  result := string(u);
end;

{ ===========================================================================
  PDF reader

  Reads just enough of the PDF object model to find embedded files and the
  XMP metadata. Objects live in a flat value pool (indices, no pointers).
  Supports classic xref tables, xref streams, object streams, incremental
  updates and - as fallback - reconstruction by scanning for "n g obj".
  =========================================================================== }

function IsPdfWS(c: Byte): Boolean;
begin
  result := (c = 0) or (c = 9) or (c = 10) or (c = 12) or (c = 13) or (c = 32);
end;

function IsPdfDelim(c: Byte): Boolean;
begin
  case c of
    Ord('('), Ord(')'), Ord('<'), Ord('>'), Ord('['), Ord(']'), Ord('{'), Ord('}'),
    Ord('/'), Ord('%'):
      result := true;
  else
    result := false;
  end;
end;

function IsPdfRegular(c: Byte): Boolean;
begin
  result := not IsPdfWS(c) and not IsPdfDelim(c);
end;

function IsDigit(c: Byte): Boolean;
begin
  result := (c >= Ord('0')) and (c <= Ord('9'));
end;

procedure PdfSkipWS(const b: TBytes; l: Integer; var p: Integer);
begin
  while p < l do begin
    if IsPdfWS(b[p]) then begin
      Inc(p);
    end else if b[p] = Ord('%') then begin
      while (p < l) and (b[p] <> 10) and (b[p] <> 13) do begin
        Inc(p);
      end;
    end else begin
      break;
    end;
  end;
end;

function PdfReadInt(const b: TBytes; l: Integer; var p: Integer; out v: Int64): Boolean;
var
  neg: Boolean;
  start: Integer;
begin
  v := 0;
  neg := false;
  start := p;

  if (p < l) and ((b[p] = Ord('+')) or (b[p] = Ord('-'))) then begin
    neg := b[p] = Ord('-');
    Inc(p);
  end;

  if (p >= l) or not IsDigit(b[p]) then begin
    p := start;
    exit(false);
  end;

  while (p < l) and IsDigit(b[p]) do begin
    if v < 100000000000000 then v := v * 10 + (b[p] - Ord('0'));
    Inc(p);
  end;

  if neg then v := -v;
  result := true;
end;

{ keyword K at P, followed by whitespace, a delimiter or the end }
function PdfKeyword(const b: TBytes; l, p: Integer; const k: AnsiString): Boolean;
begin
  result := MatchAt(b, l, p, k) and
    ((p + Length(k) >= l) or not IsPdfRegular(b[p + Length(k)]));
end;

function ReadBE(const Data: TBytes; p, Width: Integer; Def: Int64): Int64;
var
  i: Integer;
begin
  if Width = 0 then exit(Def);
  result := 0;

  for i := 0 to Width - 1 do begin
    result := (result shl 8) or Data[p + i];
  end;
end;

function TPdf.NewVal(k: TPKind): Integer;
begin
  if VCount >= Length(Vals) then begin
    SetLength(Vals, VCount * 2 + 64);
  end;

  result := VCount;
  Inc(VCount);
  Vals[result] := Default(TPVal);
  Vals[result].Kind := k;
end;

function TPdf.ReadName(const Buf: TBytes; BufLen: Integer; var p: Integer): string;
var
  hexEscape: Boolean;
  nb: TByteBuf;
begin
  nb.Clear;
  Inc(p);  // '/'

  while (p < BufLen) and IsPdfRegular(Buf[p]) do begin
    hexEscape := (Buf[p] = Ord('#')) and (p + 2 < BufLen) and IsHexDigit(Buf[p + 1]) and
      IsHexDigit(Buf[p + 2]);

    if hexEscape then begin
      nb.Add(Byte(HexVal(Buf[p + 1]) * 16 + HexVal(Buf[p + 2])));
      Inc(p, 3);
    end else begin
      nb.Add(Buf[p]);
      Inc(p);
    end;
  end;

  result := Utf8Str(nb.Data, 0, nb.Len);
end;

function TPdf.ParseValue(const Buf: TBytes; BufLen: Integer; var p: Integer;
  Depth: Integer): Integer;
var
  c: Byte;
  v, v2: Int64;
  start, p2, n, nest, hi, i: Integer;
  kids: TIntArray;
  keyNames: TStringArray;
  sb: TByteBuf;
  isReal: Boolean;
  kw: string;
begin
  if Depth > 64 then begin
    raise EAbParse.Create('PDF: nesting too deep');
  end;

  PdfSkipWS(Buf, BufLen, p);

  if p >= BufLen then begin
    raise EAbParse.Create('PDF: unexpected end');
  end;

  c := Buf[p];

  if c = Ord('/') then begin
    kw := ReadName(Buf, BufLen, p);
    result := NewVal(pkName);
    Vals[result].Str := kw;
  end

  else if c = Ord('(') then begin
    sb.Clear;
    Inc(p);
    nest := 1;

    while p < BufLen do begin
      c := Buf[p];
      if c = Ord('\') then begin
        Inc(p);
        if p >= BufLen then break;
        c := Buf[p];

        case c of
          Ord('n'): sb.Add(10);
          Ord('r'): sb.Add(13);
          Ord('t'): sb.Add(9);
          Ord('b'): sb.Add(8);
          Ord('f'): sb.Add(12);
          Ord('0')..Ord('7'):
            begin
              n := 0;
              i := 0;
              while (i < 3) and (p < BufLen) and (Buf[p] >= Ord('0')) and (Buf[p] <= Ord('7')) do begin
                n := n * 8 + Buf[p] - Ord('0');
                Inc(p);
                Inc(i);
              end;

              sb.Add(Byte(n));
              continue;
            end;
          13:
            begin
              Inc(p);
              if (p < BufLen) and (Buf[p] = 10) then Inc(p);
              continue;
            end;
          10:
            begin
              Inc(p);
              continue;
            end;
        else
          sb.Add(c);  // \( \) \\ and unknown escapes
        end;

        Inc(p);
      end else begin
        if c = Ord('(') then begin
          Inc(nest);
        end else if c = Ord(')') then begin
          Dec(nest);

          if nest = 0 then begin
            Inc(p);
            break;
          end;
        end;

        sb.Add(c);
        Inc(p);
      end;
    end;

    result := NewVal(pkString);
    Vals[result].Bytes := sb.AsBytes;
  end

  else if (c = Ord('<')) and (p + 1 < BufLen) and (Buf[p + 1] = Ord('<')) then begin
    Inc(p, 2);
    n := 0;

    while true do begin
      PdfSkipWS(Buf, BufLen, p);

      if p >= BufLen then begin
        raise EAbParse.Create('PDF: unterminated dictionary');
      end;

      if (Buf[p] = Ord('>')) and (p + 1 < BufLen) and (Buf[p + 1] = Ord('>')) then begin
        Inc(p, 2);
        break;
      end;

      if Buf[p] <> Ord('/') then begin
        raise EAbParse.Create('PDF: name expected in dictionary');
      end;

      if n >= Length(kids) then begin
        SetLength(kids, n * 2 + 8);
        SetLength(keyNames, n * 2 + 8);
      end;

      keyNames[n] := ReadName(Buf, BufLen, p);
      kids[n] := ParseValue(Buf, BufLen, p, Depth + 1);
      Inc(n);
    end;

    result := NewVal(pkDict);
    Vals[result].Keys := Copy(keyNames, 0, n);
    Vals[result].Items := Copy(kids, 0, n);
  end

  else if c = Ord('<') then begin
    sb.Clear;
    Inc(p);
    hi := -1;

    while (p < BufLen) and (Buf[p] <> Ord('>')) do begin
      if IsHexDigit(Buf[p]) then begin
        if hi < 0 then begin
          hi := HexVal(Buf[p]);
        end else begin
          sb.Add(Byte(hi * 16 + HexVal(Buf[p])));
          hi := -1;
        end;
      end;

      Inc(p);
    end;

    if hi >= 0 then begin
      sb.Add(Byte(hi * 16));
    end;

    Inc(p);
    result := NewVal(pkString);
    Vals[result].Bytes := sb.AsBytes;
  end

  else if c = Ord('[') then begin
    Inc(p);
    n := 0;

    while true do begin
      PdfSkipWS(Buf, BufLen, p);

      if p >= BufLen then begin
        raise EAbParse.Create('PDF: unterminated array');
      end;

      if Buf[p] = Ord(']') then begin
        Inc(p);
        break;
      end;

      if n >= Length(kids) then begin
        SetLength(kids, n * 2 + 8);
      end;

      kids[n] := ParseValue(Buf, BufLen, p, Depth + 1);
      Inc(n);
    end;

    result := NewVal(pkArray);
    Vals[result].Items := Copy(kids, 0, n);
  end

  else if IsDigit(c) or (c = Ord('+')) or (c = Ord('-')) or (c = Ord('.')) then begin
    start := p;
    isReal := false;
    if (c = Ord('+')) or (c = Ord('-')) then Inc(p);

    while (p < BufLen) and (IsDigit(Buf[p]) or (Buf[p] = Ord('.'))) do begin
      if Buf[p] = Ord('.') then isReal := true;
      Inc(p);
    end;

    if isReal then begin
      result := NewVal(pkReal);
      Vals[result].Str := Utf8Str(Buf, start, p - start);
      exit;
    end;

    p2 := start;
    if not PdfReadInt(Buf, BufLen, p2, v) then v := 0;
    // "n g R" ?
    p2 := p;
    PdfSkipWS(Buf, BufLen, p2);

    if (v >= 0) and (p2 < BufLen) and IsDigit(Buf[p2]) and PdfReadInt(Buf, BufLen, p2, v2) then begin
      PdfSkipWS(Buf, BufLen, p2);

      if PdfKeyword(Buf, BufLen, p2, 'R') then begin
        p := p2 + 1;
        result := NewVal(pkRef);
        Vals[result].Int := v;
        Vals[result].Gen := Integer(v2);
        exit;
      end;
    end;

    result := NewVal(pkInt);
    Vals[result].Int := v;
  end

  else begin
    start := p;

    while (p < BufLen) and IsPdfRegular(Buf[p]) do begin
      Inc(p);
    end;

    if p = start then begin
      raise EAbParse.Create('PDF: unexpected character');
    end;

    kw := Utf8Str(Buf, start, p - start);
    if (kw = 'true') or (kw = 'false') then begin
      result := NewVal(pkBool);
      if kw = 'true' then Vals[result].Int := 1;
    end else begin
      result := NewVal(pkNull);  // null, or an unexpected keyword (consumed)
    end;
  end;
end;

function TPdf.ParseObjectAt(Ofs, ExpectNum: Integer): Integer;
var
  p, s, e: Integer;
  n, g, len: Int64;
begin
  result := -1;
  if (Ofs < 0) or (Ofs >= l) then exit;
  p := Ofs;
  PdfSkipWS(b, l, p);
  if not PdfReadInt(b, l, p, n) then exit;
  PdfSkipWS(b, l, p);
  if not PdfReadInt(b, l, p, g) then exit;
  PdfSkipWS(b, l, p);
  if not PdfKeyword(b, l, p, 'obj') then exit;
  Inc(p, 3);
  if (ExpectNum >= 0) and (n <> ExpectNum) then exit;
  result := ParseValue(b, l, p, 0);
  if Vals[result].Kind <> pkDict then exit;
  PdfSkipWS(b, l, p);
  if not PdfKeyword(b, l, p, 'stream') then exit;
  Inc(p, 6);
  if (p < l) and (b[p] = 13) then Inc(p);
  if (p < l) and (b[p] = 10) then Inc(p);
  s := p;
  len := DInt(result, 'Length', -1);
  e := -1;

  if (len >= 0) and (s + len <= l) then begin
    p := s + Integer(len);
    while (p < l) and IsPdfWS(b[p]) do begin
      Inc(p);
    end;

    if MatchAt(b, l, p, 'endstream') then e := s + Integer(len);
  end;

  if e < 0 then begin
    // /Length missing or wrong: search for "endstream"
    p := FindAt(b, l, s, 'endstream');
    if p < 0 then begin
      e := l;
    end else begin
      e := p;
      if (e > s) and (b[e - 1] = 10) then Dec(e);
      if (e > s) and (b[e - 1] = 13) then Dec(e);
    end;
  end;

  Vals[result].Kind := pkStream;
  Vals[result].StmPos := s;
  Vals[result].StmLen := e - s;
end;

procedure TPdf.SetEntry(Num: Int64; Kind: Byte; Ofs, Idx: Int64; Overwrite: Boolean);
var
  newLen: Integer;
begin
  if (Num < 0) or (Num > 10000000) or (Ofs < 0) or (Ofs > MaxInt) then exit;

  if Num >= Length(Entries) then begin
    newLen := Length(Entries) * 2;
    if newLen <= Num then newLen := Num + 1;
    SetLength(Entries, newLen);
  end;

  if (Entries[Num].Kind <> 0) and not Overwrite then exit;
  Entries[Num].Kind := Kind;
  Entries[Num].Ofs := Integer(Ofs);
  Entries[Num].Idx := Integer(Idx);
  Entries[Num].State := 0;
end;

function TPdf.LoadXRefSection(Ofs: Integer; out Prev, XRefStm: Integer): Boolean;
var
  p, i, k, v, tr, rowLen, row, rowPos: Integer;
  start, cnt, o, g, f1, f2, f3: Int64;
  w: array[0..2] of Integer;
  idx: array of Int64;
  data: TBytes;
  err: string;
begin
  result := false;
  Prev := -1;
  XRefStm := -1;
  if (Ofs < 0) or (Ofs >= l) then exit;
  p := Ofs;
  PdfSkipWS(b, l, p);

  if PdfKeyword(b, l, p, 'xref') then begin
    // classic cross-reference table
    Inc(p, 4);

    while true do begin
      PdfSkipWS(b, l, p);
      if PdfKeyword(b, l, p, 'trailer') then break;
      if not PdfReadInt(b, l, p, start) then exit;
      PdfSkipWS(b, l, p);
      if not PdfReadInt(b, l, p, cnt) then exit;
      if (start < 0) or (cnt < 0) or (cnt > 10000000) then exit;

      for i := 0 to Integer(cnt) - 1 do begin
        PdfSkipWS(b, l, p);
        if not PdfReadInt(b, l, p, o) then exit;
        PdfSkipWS(b, l, p);
        if not PdfReadInt(b, l, p, g) then exit;
        PdfSkipWS(b, l, p);
        if p >= l then exit;

        if b[p] = Ord('n') then begin
          SetEntry(start + i, 1, o, 0, false);
        end else if b[p] <> Ord('f') then exit;

        Inc(p);
      end;
    end;

    Inc(p, 7);
    tr := ParseValue(b, l, p, 0);
    if Vals[tr].Kind <> pkDict then exit;
  end else begin
    // cross-reference stream
    tr := ParseObjectAt(Ofs, -1);
    if (tr < 0) or (Vals[tr].Kind <> pkStream) or (DName(tr, 'Type') <> 'XRef') then exit;
    v := DGet(tr, 'W');
    if (v < 0) or (Vals[v].Kind <> pkArray) or (Length(Vals[v].Items) < 3) then exit;

    for k := 0 to 2 do begin
      w[k] := IntOf(Vals[v].Items[k], -1);
      if (w[k] < 0) or (w[k] > 8) then exit;
    end;

    rowLen := w[0] + w[1] + w[2];
    if rowLen = 0 then exit;
    v := DGet(tr, 'Index');
    if (v >= 0) and (Vals[v].Kind = pkArray) then begin
      SetLength(idx, Length(Vals[v].Items));

      for k := 0 to High(idx) do begin
        idx[k] := IntOf(Vals[v].Items[k], 0);
      end;
    end else begin
      SetLength(idx, 2);
      idx[0] := 0;
      idx[1] := DInt(tr, 'Size', 0);
    end;

    if not StreamData(tr, data, err) then exit;
    row := 0;
    k := 0;
    while k + 1 <= High(idx) do begin
      for i := 0 to Integer(idx[k + 1]) - 1 do begin
        rowPos := row * rowLen;
        if rowPos + rowLen > Length(data) then break;
        f1 := ReadBE(data, rowPos, w[0], 1);
        f2 := ReadBE(data, rowPos + w[0], w[1], 0);
        f3 := ReadBE(data, rowPos + w[0] + w[1], w[2], 0);

        if f1 = 1 then begin
          SetEntry(idx[k] + i, 1, f2, 0, false);
        end else if f1 = 2 then begin
          SetEntry(idx[k] + i, 2, f2, f3, false);
        end;

        Inc(row);
      end;

      Inc(k, 2);
    end;
  end;

  if Trailer < 0 then Trailer := tr;
  Prev := Integer(DInt(tr, 'Prev', -1));
  XRefStm := Integer(DInt(tr, 'XRefStm', -1));
  result := true;
end;

function TPdf.LoadXRef(StartOfs: Integer): Boolean;
var
  ofs, prev, xs, dummy1, dummy2, i: Integer;
  seen: array of Integer;
begin
  ofs := StartOfs;
  while ofs >= 0 do begin
    for i := 0 to High(seen) do begin
      if seen[i] = ofs then begin
        exit(true);  // loop in /Prev chain
      end;
    end;

    if Length(seen) > 1000 then exit(true);
    SetLength(seen, Length(seen) + 1);
    seen[High(seen)] := ofs;
    if not LoadXRefSection(ofs, prev, xs) then exit(false);

    if xs >= 0 then begin
      LoadXRefSection(xs, dummy1, dummy2);  // hybrid file
    end;

    ofs := prev;
  end;

  result := true;
end;

procedure TPdf.Rebuild;
var
  i, p, v, bestXRef: Integer;
  n, g: Int64;
  tPos: array of Integer;
  typ: string;
begin
  Rebuilt := true;
  LoadFailures := 0;
  Entries := nil;
  ObjStms := nil;
  VCount := 0;
  Trailer := -1;
  CatalogObj := -1;
  bestXRef := -1;

  // 1. scan for "n g obj" and "trailer"
  i := 0;
  while i < l do begin
    if IsDigit(b[i]) and ((i = 0) or not IsPdfRegular(b[i - 1])) then begin
      p := i;
      if PdfReadInt(b, l, p, n) and (p < l) and IsPdfWS(b[p]) then begin
        PdfSkipWS(b, l, p);

        if PdfReadInt(b, l, p, g) and (p < l) and IsPdfWS(b[p]) then begin
          PdfSkipWS(b, l, p);

          if PdfKeyword(b, l, p, 'obj') then begin
            SetEntry(n, 1, i, 0, true);  // later definitions win
            i := p + 3;
            continue;
          end;
        end;
      end;
    end else if (b[i] = Ord('t')) and ((i = 0) or not IsPdfRegular(b[i - 1])) and
      PdfKeyword(b, l, i, 'trailer') then
    begin
      SetLength(tPos, Length(tPos) + 1);
      tPos[High(tPos)] := i;
    end;
    Inc(i);
  end;

  // 2. newest trailer with /Root
  for i := High(tPos) downto 0 do begin
    p := tPos[i] + 7;

    try
      v := ParseValue(b, l, p, 0);
      if (Vals[v].Kind = pkDict) and DHas(v, 'Root') then begin
        Trailer := v;
        break;
      end;
    except
      on EAbParse do ;
    end;
  end;

  // 3. object streams, catalog, xref streams (as trailer replacement)
  for i := 0 to High(Entries) do begin
    if Entries[i].Kind = 1 then begin
      v := GetObject(i);
      if v < 0 then continue;
      typ := DName(v, 'Type');
      if typ = 'ObjStm' then begin
        ObjStmIndex(i);
      end else if (typ = 'XRef') and DHas(v, 'Root') then begin
        if (bestXRef < 0) or (Entries[i].Ofs > bestXRef) then begin
          bestXRef := Entries[i].Ofs;
          if Trailer < 0 then Trailer := v;
        end;
      end else if typ = 'Catalog' then CatalogObj := v;
    end;
  end;
end;

{ Loads (and caches) an object stream; registers its objects while rebuilding. }
function TPdf.ObjStmIndex(StmNum: Integer): Integer;
var
  k, v, p, n, i: Integer;
  num, ofs: Int64;
  data: TBytes;
  err: string;
  first: Int64;
begin
  for k := 0 to High(ObjStms) do begin
    if ObjStms[k].Num = StmNum then exit(k);
  end;

  result := -1;
  v := GetObject(StmNum);
  if (v < 0) or (Vals[v].Kind <> pkStream) then exit;
  if not StreamData(v, data, err) then exit;
  n := Integer(DInt(v, 'N', 0));
  first := DInt(v, 'First', 0);
  if (n < 0) or (n > 1000000) or (first < 0) or (first > Length(data)) then exit;
  k := Length(ObjStms);
  SetLength(ObjStms, k + 1);
  ObjStms[k].Num := StmNum;
  ObjStms[k].Data := data;
  ObjStms[k].First := Integer(first);
  SetLength(ObjStms[k].Nums, n);
  SetLength(ObjStms[k].Offs, n);
  p := 0;

  for i := 0 to n - 1 do begin
    PdfSkipWS(data, Integer(first), p);
    if not PdfReadInt(data, Integer(first), p, num) then break;
    PdfSkipWS(data, Integer(first), p);
    if not PdfReadInt(data, Integer(first), p, ofs) then break;
    ObjStms[k].Nums[i] := Integer(num);
    ObjStms[k].Offs[i] := Integer(ofs);

    if Rebuilt then begin
      SetEntry(num, 2, StmNum, i, false);
    end;
  end;

  result := k;
end;

function TPdf.FromObjStm(StmNum, Num, Idx: Integer): Integer;
var
  k, i, j, p: Integer;
begin
  result := -1;
  k := ObjStmIndex(StmNum);
  if k < 0 then exit;
  i := -1;

  if (Idx >= 0) and (Idx < Length(ObjStms[k].Nums)) and (ObjStms[k].Nums[Idx] = Num) then begin
    i := Idx;
  end else begin
    for j := 0 to High(ObjStms[k].Nums) do begin
      if ObjStms[k].Nums[j] = Num then begin
        i := j;
        break;
      end;
    end;
  end;

  if i < 0 then exit;
  p := ObjStms[k].First + ObjStms[k].Offs[i];
  result := ParseValue(ObjStms[k].Data, Length(ObjStms[k].Data), p, 0);
end;

function TPdf.GetObject(Num: Int64): Integer;
var
  v: Integer;
begin
  result := -1;
  if (Num < 0) or (Num >= Length(Entries)) then exit;

  case Entries[Num].State of
    0: ;
    -1, -2: exit;
  else
    exit(Entries[Num].State - 1);
  end;

  Entries[Num].State := -1;
  v := -1;

  try
    case Entries[Num].Kind of
      1: v := ParseObjectAt(Entries[Num].Ofs, Integer(Num));
      2: v := FromObjStm(Entries[Num].Ofs, Integer(Num), Entries[Num].Idx);
    end;
  except
    on EAbParse do
      v := -1;
  end;

  if v >= 0 then begin
    Entries[Num].State := v + 1;
  end else begin
    Entries[Num].State := -2;
    if Entries[Num].Kind <> 0 then Inc(LoadFailures);
  end;

  result := v;
end;

function TPdf.Resolve(v: Integer): Integer;
var
  n: Integer;
begin
  n := 0;
  while (v >= 0) and (Vals[v].Kind = pkRef) and (n < 32) do begin
    v := GetObject(Vals[v].Int);
    Inc(n);
  end;

  if (v >= 0) and (Vals[v].Kind = pkRef) then v := -1;
  result := v;
end;

function TPdf.IntOf(Raw: Integer; Def: Int64): Int64;
var
  v, code: Integer;
  d: Double;
begin
  result := Def;
  v := Resolve(Raw);
  if v < 0 then exit;

  if Vals[v].Kind = pkInt then begin
    result := Vals[v].Int;
  end else if Vals[v].Kind = pkReal then begin
    Val(Vals[v].Str, d, code);  // Val is locale independent
    if (code = 0) and (d > -1E15) and (d < 1E15) then result := Trunc(d);
  end;
end;

function TPdf.TextOf(v: Integer): string;
begin
  result := '';
  if v < 0 then exit;

  case Vals[v].Kind of
    pkString: result := PdfText(Vals[v].Bytes);
    pkName: result := Vals[v].Str;
  end;
end;

function TPdf.DGet(d: Integer; const Key: string): Integer;
var
  i: Integer;
begin
  result := -1;
  if (d < 0) or not (Vals[d].Kind in [pkDict, pkStream]) then exit;

  for i := 0 to High(Vals[d].Keys) do begin
    if Vals[d].Keys[i] = Key then exit(Resolve(Vals[d].Items[i]));
  end;
end;

function TPdf.DRaw(d: Integer; const Key: string): Integer;
var
  i: Integer;
begin
  result := -1;
  if (d < 0) or not (Vals[d].Kind in [pkDict, pkStream]) then exit;

  for i := 0 to High(Vals[d].Keys) do begin
    if Vals[d].Keys[i] = Key then exit(Vals[d].Items[i]);
  end;
end;

function PdfTextString(const s: string): string;
var
  u: UnicodeString;
  i: Integer;
  ascii: Boolean;
begin
  u := UnicodeString(s);
  ascii := true;

  for i := 1 to Length(u) do begin
    if (Ord(u[i]) < 32) or (Ord(u[i]) > 126) then ascii := false;
  end;

  if ascii then begin
    result := '(';

    for i := 1 to Length(u) do begin
      if (u[i] = '\') or (u[i] = '(') or (u[i] = ')') then result := result + '\';
      result := result + Char(u[i]);
    end;

    result := result + ')';
  end else begin
    result := '<FEFF';

    for i := 1 to Length(u) do begin
      result := result + IntToHex(Ord(u[i]), 4);
    end;

    result := result + '>';
  end;
end;

function PdfNameText(const Name: string): string;
const
  Hex: array[0..15] of Char = '0123456789ABCDEF';
var
  u: TBytes;
  i: Integer;
  c: Byte;
begin
  u := Utf8Bytes(Name);
  result := '/';

  for i := 0 to High(u) do begin
    c := u[i];
    if (c > 32) and (c < 127) and (c <> Ord('#')) and IsPdfRegular(c) then begin
      result := result + Char(c);
    end else begin
      result := result + '#' + Hex[c shr 4] + Hex[c and 15];
    end;
  end;
end;

function TPdf.ValueText(v: Integer; Depth: Integer): string;
const
  Hex: array[0..15] of Char = '0123456789abcdef';
var
  i: Integer;
begin
  if Depth > 64 then begin
    raise EAbParse.Create('PDF: nesting too deep');
  end;

  if v < 0 then exit('null');

  case Vals[v].Kind of
    pkNull: result := 'null';
    pkBool:
      if Vals[v].Int <> 0 then begin
        result := 'true';
      end else begin
        result := 'false';
      end;
    pkInt: result := IntToStr(Vals[v].Int);
    pkReal: result := Vals[v].Str;
    pkString:
      begin
        result := '<';

        for i := 0 to High(Vals[v].Bytes) do begin
          result := result + Hex[Vals[v].Bytes[i] shr 4] + Hex[Vals[v].Bytes[i] and 15];
        end;

        result := result + '>';
      end;
    pkName: result := PdfNameText(Vals[v].Str);
    pkRef: result := IntToStr(Vals[v].Int) + ' ' + IntToStr(Vals[v].Gen) + ' R';
    pkArray:
      begin
        result := '[';

        for i := 0 to High(Vals[v].Items) do begin
          if i > 0 then result := result + ' ';
          result := result + ValueText(Vals[v].Items[i], Depth + 1);
        end;

        result := result + ']';
      end;
    pkDict:
      begin
        result := '<<';

        for i := 0 to High(Vals[v].Keys) do begin
          result := result + ' ' + PdfNameText(Vals[v].Keys[i]) + ' ' +
            ValueText(Vals[v].Items[i], Depth + 1);
        end;

        result := result + ' >>';
      end;
  else
    raise EAbParse.Create('PDF: a stream cannot be written directly');
  end;
end;

function TPdf.DHas(d: Integer; const Key: string): Boolean;
var
  i: Integer;
begin
  result := false;
  if (d < 0) or not (Vals[d].Kind in [pkDict, pkStream]) then exit;

  for i := 0 to High(Vals[d].Keys) do begin
    if Vals[d].Keys[i] = Key then exit(true);
  end;
end;

function TPdf.DInt(d: Integer; const Key: string; Def: Int64): Int64;
var
  i: Integer;
begin
  result := Def;
  if (d < 0) or not (Vals[d].Kind in [pkDict, pkStream]) then exit;

  for i := 0 to High(Vals[d].Keys) do begin
    if Vals[d].Keys[i] = Key then exit(IntOf(Vals[d].Items[i], Def));
  end;
end;

function TPdf.DName(d: Integer; const Key: string): string;
var
  v: Integer;
begin
  result := '';
  v := DGet(d, Key);
  if (v >= 0) and (Vals[v].Kind = pkName) then result := Vals[v].Str;
end;

function TPdf.DText(d: Integer; const Key: string): string;
begin
  result := TextOf(DGet(d, Key));
end;

function TPdf.StreamData(s: Integer; out Data: TBytes; out Err: string): Boolean;
var
  predictFailed: Boolean;
  f, parms, i, pIdx: Integer;
  filters: array of string;
  parmList: array of Integer;
  tmp: TBytes;
  name: string;
begin
  result := false;
  Err := '';
  Data := nil;

  if (s < 0) or (Vals[s].Kind <> pkStream) then begin
    Err := 'not a stream';
    exit;
  end;

  Data := Copy(b, Vals[s].StmPos, Vals[s].StmLen);

  f := DGet(s, 'Filter');
  parms := DGet(s, 'DecodeParms');
  if parms < 0 then parms := DGet(s, 'DP');

  if f >= 0 then begin
    if Vals[f].Kind = pkName then begin
      SetLength(filters, 1);
      SetLength(parmList, 1);
      filters[0] := Vals[f].Str;
      parmList[0] := parms;
    end else if Vals[f].Kind = pkArray then begin
      SetLength(filters, Length(Vals[f].Items));
      SetLength(parmList, Length(filters));

      for i := 0 to High(filters) do begin
        filters[i] := TextOf(Resolve(Vals[f].Items[i]));
        parmList[i] := -1;

        if (parms >= 0) and (Vals[parms].Kind = pkArray) and (i < Length(Vals[parms].Items)) then begin
          parmList[i] := Resolve(Vals[parms].Items[i]);
        end;
      end;
    end;
  end;

  for i := 0 to High(filters) do begin
    name := filters[i];
    pIdx := parmList[i];

    if (name = 'FlateDecode') or (name = 'Fl') then begin
      if not InflateBytes(Data, tmp) then begin
        Err := 'broken Flate data';
        exit;
      end;

      Data := tmp;

      if DInt(pIdx, 'Predictor', 1) > 1 then begin
        predictFailed := not UnPredict(Data, Integer(DInt(pIdx, 'Predictor', 1)), Integer(DInt(pIdx, 'Colors', 1)),
          Integer(DInt(pIdx, 'BitsPerComponent', 8)), Integer(DInt(pIdx, 'Columns', 1)), tmp);

        if predictFailed then begin
          Err := 'predictor not supported';
          exit;
        end;

        Data := tmp;
      end;
    end else if (name = 'ASCIIHexDecode') or (name = 'AHx') then begin
      Data := DecodeAHx(Data);
    end else if (name = 'ASCII85Decode') or (name = 'A85') then begin
      if not DecodeA85(Data, tmp) then begin
        Err := 'broken ASCII85 data';
        exit;
      end;

      Data := tmp;
    end else if name = 'Crypt' then begin
;      // only /Identity can occur in unencrypted files
    end else begin
      Err := 'Filter ' + name + ' not supported';
      exit;
    end;
  end;
  result := true;
end;

function TPdf.Open(const Data: TBytes; var Msgs: TAbMessages): Boolean;
var
  h, sx, p, s: Integer;
  ofs: Int64;
  ok: Boolean;
begin
  b := Data;
  l := Length(b);
  Vals := nil;
  VCount := 0;
  Entries := nil;
  ObjStms := nil;
  Trailer := -1;
  CatalogObj := -1;
  Rebuilt := false;
  LoadFailures := 0;
  Version := '';
  StartXRef := -1;
  XRefIsStream := false;

  h := FindAt(b, IMin(l, 1024), 0, '%PDF-');
  if h < 0 then exit(false);
  p := h + 5;
  s := p;
  while (p < l) and IsPdfRegular(b[p]) and (p - s < 8) do begin
    Inc(p);
  end;

  Version := Utf8Str(b, s, p - s);

  ok := false;
  sx := FindBack(b, l, 'startxref');
  if sx >= 0 then begin
    p := sx + 9;
    PdfSkipWS(b, l, p);

    if PdfReadInt(b, l, p, ofs) and (ofs >= 0) and (ofs < l) then begin
      try
        StartXRef := Integer(ofs);
        p := StartXRef;
        PdfSkipWS(b, l, p);
        XRefIsStream := not PdfKeyword(b, l, p, 'xref');
        ok := LoadXRef(Integer(ofs));
      except
        on EAbParse do
          ok := false;
      end;
    end;
  end;

  if ok then ok := Catalog >= 0;

  if not ok then begin
    Rebuild;
    AddMsg(Msgs, abWarning, 'PDF-XREF',
      'The PDF cross-reference table is broken, the structure was reconstructed');
  end;

  result := Catalog >= 0;
end;

function TPdf.Catalog: Integer;
begin
  result := DGet(Trailer, 'Root');
  if (result < 0) or (Vals[result].Kind <> pkDict) then begin
    if (CatalogObj >= 0) and (Vals[CatalogObj].Kind = pkDict) then begin
      result := CatalogObj;
    end else begin
      result := -1;
    end;
  end;
end;

function TPdf.Encrypted: Boolean;
begin
  result := DHas(Trailer, 'Encrypt');
end;

function TPdf.EmbeddedFiles: TPdfFiles;
var
  files: TPdfFiles;
  count, cat, a, i, v: Integer;

  procedure AddSpec(Raw: Integer; const TreeName: string; FromAF: Boolean);
  var
    key: Int64;
    fs, ef, s, j: Integer;
    name: string;
  begin
    if Raw < 0 then exit;

    if Vals[Raw].Kind = pkRef then begin
      key := Vals[Raw].Int;
    end else begin
      key := -1 - Raw;
    end;

    for j := 0 to count - 1 do begin
      if files[j].Key = key then begin
        if FromAF then files[j].InAF := true;
        exit;
      end;
    end;

    fs := Resolve(Raw);
    if (fs < 0) or (Vals[fs].Kind <> pkDict) then exit;
    ef := DGet(fs, 'EF');
    s := DGet(ef, 'UF');
    if s < 0 then s := DGet(ef, 'F');
    name := DText(fs, 'UF');
    if name = '' then name := DText(fs, 'F');
    if name = '' then name := TreeName;

    if count >= Length(files) then begin
      SetLength(files, count * 2 + 4);
    end;

    files[count] := Default(TPdfFile);
    files[count].Key := key;
    files[count].Name := name;
    files[count].Desc := DText(fs, 'Desc');
    files[count].Relationship := DName(fs, 'AFRelationship');
    files[count].InAF := FromAF;
    files[count].Size := -1;
    files[count].Stream := -1;

    if (s >= 0) and (Vals[s].Kind = pkStream) then begin
      files[count].Stream := s;
      files[count].Mime := DName(s, 'Subtype');
      files[count].Size := DInt(DGet(s, 'Params'), 'Size', -1);
    end;

    Inc(count);
  end;

  procedure Walk(Node, Depth: Integer);
  var
    arr, j: Integer;
  begin
    if (Node < 0) or (Depth > 32) or (count > 10000) then exit;
    arr := DGet(Node, 'Names');
    if (arr >= 0) and (Vals[arr].Kind = pkArray) then begin
      j := 0;
      while j + 1 <= High(Vals[arr].Items) do begin
        AddSpec(Vals[arr].Items[j + 1], TextOf(Resolve(Vals[arr].Items[j])), false);
        Inc(j, 2);
      end;
    end;

    arr := DGet(Node, 'Kids');
    if (arr >= 0) and (Vals[arr].Kind = pkArray) then begin
      for j := 0 to High(Vals[arr].Items) do begin
        Walk(Resolve(Vals[arr].Items[j]), Depth + 1);
      end;
    end;
  end;

begin
  files := nil;
  count := 0;
  cat := Catalog;
  Walk(DGet(DGet(cat, 'Names'), 'EmbeddedFiles'), 0);
  a := DGet(cat, 'AF');
  if (a >= 0) and (Vals[a].Kind = pkArray) then begin
    for i := 0 to High(Vals[a].Items) do begin
      AddSpec(Vals[a].Items[i], '', true);
    end;
  end;

  // damaged files only: any stream of type /EmbeddedFile (in intact files
  // such streams may be leftovers that are no longer part of the document)
  if (count = 0) and Rebuilt then begin
    for i := 0 to High(Entries) do begin
      if Entries[i].Kind <> 0 then begin
        v := GetObject(i);
        if (v >= 0) and (Vals[v].Kind = pkStream) and (DName(v, 'Type') = 'EmbeddedFile') then begin
          if count >= Length(files) then begin
            SetLength(files, count * 2 + 4);
          end;

          files[count] := Default(TPdfFile);
          files[count].Key := i;
          files[count].Stream := v;
          files[count].Mime := DName(v, 'Subtype');
          files[count].Size := DInt(DGet(v, 'Params'), 'Size', -1);
          Inc(count);
        end;
      end;
    end;
  end;

  SetLength(files, count);
  result := files;
end;

function TPdf.MetadataXML(out Data: TBytes): Boolean;
var
  err: string;
begin
  Data := nil;
  result := StreamData(DGet(Catalog, 'Metadata'), Data, err);
end;

end.
